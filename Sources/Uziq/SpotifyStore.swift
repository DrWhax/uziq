import AppKit
import Combine
import Foundation
import Observation
import SpotifyWebAPI

struct SpotifyRateLimitResponseError: LocalizedError {
    let retryAfter: Int?

    var errorDescription: String? {
        "Spotify API rate limit reached."
    }
}

@MainActor
@Observable
final class SpotifyStore {
    static let redirectURI = SpotifyLoopbackServer.callbackURL
    static let likedSongsID = "uziq:spotify:liked-songs"
    nonisolated static let artistAlbumsPageLimit = 10
    nonisolated static let artistAlbumsMaximum = 50
    nonisolated static let albumTracksPageLimit = 50

    nonisolated static func rateLimitDeadline(
        now: Date,
        current: Date?,
        retryAfter: Int?
    ) -> Date {
        let proposed = now.addingTimeInterval(TimeInterval(max(60, retryAfter ?? 60)))
        return max(current ?? .distantPast, proposed)
    }

    static var bundledClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "UziqSpotifyClientID") as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated static func artistRadioSearchQuery(for artistName: String) -> String {
        let escaped = artistName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "artist:\"\(escaped)\""
    }

    var clientID: String {
        didSet {
            UserDefaults.standard.set(clientID, forKey: "spotify-client-id")
            let normalized = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized != api.authorizationManager.clientId { rebuildAPI(clientID: normalized) }
        }
    }
    var query = ""
    var directPlaybackInput = ""
    var isAuthorized = false
    var profileName: String?
    var playlists: [SpotifyCatalogItem] = []
    var likedSongs: [SpotifyCatalogItem] = []
    var likedSongsTotal = 0
    var topArtists: [SpotifyCatalogItem] = []
    var needsPersonalLibraryPermission = false
    var searchTracks: [SpotifyCatalogItem] = []
    var searchAlbums: [SpotifyCatalogItem] = []
    var searchArtists: [SpotifyCatalogItem] = []
    var searchPlaylists: [SpotifyCatalogItem] = []
    var selectedPlaylist: SpotifyCatalogItem?
    var playlistTracks: [SpotifyCatalogItem] = []
    var selectedArtist: SpotifyCatalogItem?
    var artistAlbums: [SpotifyCatalogItem] = []
    var artistTopTracks: [SpotifyCatalogItem] = []
    var artistAlbumsError: String?
    var artistRadioError: String?
    var isLoadingArtist = false
    var selectedAlbum: SpotifyCatalogItem?
    var albumTracks: [SpotifyCatalogItem] = []
    var albumTracksError: String?
    var isLoadingAlbum = false
    var playback: SpotifyPlaybackSnapshot?
    var isLoading = false
    var isLoadingAccount = false
    var isStartingPlayback = false
    var playbackMessage: String?
    var availableDeviceNames: [String] = []
    var rateLimitedUntil: Date?
    var librarySnapshotDate: Date?
    var error: String?
    let librespot = LibrespotService()

    @ObservationIgnored var api: SpotifyAPI<UziqSpotifyAuthorizationManager>
    @ObservationIgnored var persistentCancellables = Set<AnyCancellable>()
    @ObservationIgnored let oneShotSubscriptions = OneShotCancellableStore()
    @ObservationIgnored let loopbackServer = SpotifyLoopbackServer()
    @ObservationIgnored var codeVerifier: String?
    @ObservationIgnored var authorizationState: String?
    @ObservationIgnored var playbackTimer: Timer?
    @ObservationIgnored var playbackRefreshCancellable: AnyCancellable?
    @ObservationIgnored var accountLoadCancellable: AnyCancellable?
    @ObservationIgnored var desiredVolume: Float = 1
    @ObservationIgnored var playbackGeneration = UUID()
    @ObservationIgnored var artistLoadGeneration = UUID()
    @ObservationIgnored var albumLoadGeneration = UUID()
    @ObservationIgnored var artistTopTracksFinished = false
    @ObservationIgnored var artistAlbumsFinished = false
    @ObservationIgnored var personalLibraryTracksFinished = false
    @ObservationIgnored var personalLibraryArtistsFinished = false
    @ObservationIgnored var playbackTick = 0
    @ObservationIgnored var isSpotifyPlaybackSuppressed = false
    @ObservationIgnored var helperPendingItem: SpotifyCatalogItem?
    @ObservationIgnored var helperAdvancesWithUziqQueue = false
    @ObservationIgnored var uziqDeviceID: String?
    @ObservationIgnored var localPlaybackObserver: NSObjectProtocol?
    @ObservationIgnored var toggleObserver: NSObjectProtocol?
    @ObservationIgnored weak var playbackEngine: PlaybackEngine?
    @ObservationIgnored let libraryCache = SpotifyLibraryCache()

    let authorizationKey = "spotify-pkce-authorization"
    let rateLimitUntilKey = "spotify-rate-limit-until"
    let requiredScopes: Set<Scope> = [
        .playlistReadPrivate,
        .playlistReadCollaborative,
        .userReadPlaybackState,
        .userReadCurrentlyPlaying,
        .userModifyPlaybackState,
        .userReadPrivate,
        .userLibraryRead,
        .userTopRead
    ]

    init() {
        let storedClientID = UserDefaults.standard.string(forKey: "spotify-client-id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = storedClientID.flatMap { $0.isEmpty ? nil : $0 } ?? Self.bundledClientID ?? ""
        self.clientID = clientID
        api = SpotifyAPI(
            authorizationManager: UziqSpotifyAuthorizationManager(
                backend: UziqSpotifyPKCEBackend(
                    clientId: clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        )
        if let snapshot = libraryCache.load(clientID: clientID) {
            profileName = snapshot.profileName
            playlists = snapshot.playlists
            likedSongs = snapshot.likedSongs
            likedSongsTotal = snapshot.likedSongsTotal
            topArtists = snapshot.topArtists
            librarySnapshotDate = snapshot.savedAt
        }
        let storedRateLimit = UserDefaults.standard.double(forKey: rateLimitUntilKey)
        if storedRateLimit > Date.now.timeIntervalSince1970 {
            rateLimitedUntil = Date(timeIntervalSince1970: storedRateLimit)
        }
        librespot.onEvent = { [weak self] event in
            self?.handleLibrespotEvent(event)
        }
        configureAPISubscriptions()
        restoreAuthorization()
        localPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .uziqLocalPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suppressForNonSpotifyPlayback()
            }
        }
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .uziqTogglePlayback,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isUziqPlaybackActive else { return }
                self.togglePlayback()
            }
        }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playbackTimerFired() }
        }
    }

    deinit {
        playbackTimer?.invalidate()
        playbackRefreshCancellable?.cancel()
        accountLoadCancellable?.cancel()
        loopbackServer.stop()
        if let localPlaybackObserver { NotificationCenter.default.removeObserver(localPlaybackObserver) }
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
    }

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRateLimited: Bool {
        guard let rateLimitedUntil else { return false }
        return rateLimitedUntil > .now
    }

    var rateLimitMessage: String? {
        guard let rateLimitedUntil, rateLimitedUntil > .now else { return nil }
        let cacheAvailability = librarySnapshotDate == nil
            ? "No cached Spotify library snapshot is available yet."
            : "Cached library metadata remains available."
        let playbackAvailability = librespot.supportsDirectControl
            ? "Playback through the Uziq helper remains available."
            : "Current librespot playback may continue, but new playback commands are paused."
        return "Spotify Web API requests are paused until \(rateLimitedUntil.formatted(date: .abbreviated, time: .shortened)). \(cacheAvailability) Audio is streamed and not cached. \(playbackAvailability)"
    }

    var isUsingBundledClientID: Bool {
        guard let bundledClientID = Self.bundledClientID else { return false }
        return clientID.trimmingCharacters(in: .whitespacesAndNewlines) == bundledClientID
    }

    var isUziqPlaybackActive: Bool {
        !isSpotifyPlaybackSuppressed &&
            playback?.deviceName.caseInsensitiveCompare("Uziq") == .orderedSame
    }

    var isUziqDeviceAvailable: Bool {
        availableDeviceNames.contains { $0.caseInsensitiveCompare("Uziq") == .orderedSame }
    }

    var likedSongsCollection: SpotifyCatalogItem {
        SpotifyCatalogItem(
            id: Self.likedSongsID,
            name: "Liked Songs",
            subtitle: "Your saved Spotify tracks",
            uri: "",
            kind: .playlist,
            artworkURL: nil,
            durationMS: nil,
            itemCount: likedSongsTotal
        )
    }

    func attachPlaybackEngine(_ playback: PlaybackEngine) {
        playbackEngine = playback
    }

    func logIn() {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            error = "Add your Spotify Client ID in Settings first."
            return
        }

        let verifier = String.randomURLSafe(length: 128)
        let state = String.randomURLSafe(length: 128)
        guard let authorizationURL = api.authorizationManager.makeAuthorizationURL(
            redirectURI: Self.redirectURI,
            codeChallenge: String.makeCodeChallenge(codeVerifier: verifier),
            state: state,
            scopes: requiredScopes
        ) else {
            error = "Could not create the Spotify authorization URL."
            return
        }
        codeVerifier = verifier
        authorizationState = state
        error = nil

        do {
            try loopbackServer.start(
                onReady: {
                    DispatchQueue.main.async { NSWorkspace.shared.open(authorizationURL) }
                },
                onCallback: { [weak self] callbackURL in
                    Task { @MainActor [weak self] in self?.completeLogin(callbackURL) }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in self?.error = error.localizedDescription }
                }
            )
        } catch {
            self.error = "Could not listen for Spotify's login response: \(error.localizedDescription)"
        }
    }

    func logOut() {
        playbackRefreshCancellable?.cancel()
        playbackRefreshCancellable = nil
        accountLoadCancellable?.cancel()
        accountLoadCancellable = nil
        oneShotSubscriptions.cancelAll()
        isLoadingAccount = false
        isLoading = false
        api.authorizationManager.deauthorize()
        SpotifyKeychain.remove(authorizationKey)
        closeDetail()
        isAuthorized = false
        profileName = nil
        playlists = []
        likedSongs = []
        likedSongsTotal = 0
        topArtists = []
        librarySnapshotDate = nil
        libraryCache.remove()
        needsPersonalLibraryPermission = false
        clearSearch()
        playback = nil
        uziqDeviceID = nil
        isSpotifyPlaybackSuppressed = false
        librespot.signOut()
    }

    func loadAccount(force: Bool = false) {
        guard isAuthorized, spotifyRequestsAllowed(), accountLoadCancellable == nil else { return }
        if !force, let librarySnapshotDate,
           Date.now.timeIntervalSince(librarySnapshotDate) < SpotifyLibrarySnapshot.refreshInterval {
            return
        }
        isLoadingAccount = true
        isLoading = true
        error = nil
        accountLoadCancellable = Publishers.Zip(api.currentUserProfile(), api.currentUserPlaylists(limit: 50))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                accountLoadCancellable = nil
                isLoadingAccount = false
                isLoading = false
                if case .failure(let error) = completion { handleAPIError(error) }
            } receiveValue: { [weak self] profile, page in
                guard let self else { return }
                profileName = profile.displayName ?? profile.id
                playlists = page.items
                    .filter { $0.owner?.id == profile.id }
                    .map(Self.catalogItem)
                needsPersonalLibraryPermission = !api.authorizationManager.isAuthorized(for: requiredScopes)
                if !needsPersonalLibraryPermission {
                    loadPersonalLibrary()
                } else {
                    persistLibrarySnapshot(markFresh: true)
                }
                refreshPlayback()
            }
    }

    func refreshAccount() {
        loadAccount(force: true)
    }

    func search() {
        search(query: query)
    }

}
