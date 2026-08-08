import AppKit
import Combine
import Foundation
import Observation
import SpotifyWebAPI

@MainActor
@Observable
final class SpotifyStore {
    static let redirectURI = SpotifyLoopbackServer.callbackURL
    static let likedSongsID = "uziq:spotify:liked-songs"
    nonisolated static let artistAlbumsPageLimit = 10
    nonisolated static let albumTracksPageLimit = 50

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
    private(set) var isAuthorized = false
    private(set) var profileName: String?
    private(set) var playlists: [SpotifyCatalogItem] = []
    private(set) var likedSongs: [SpotifyCatalogItem] = []
    private(set) var likedSongsTotal = 0
    private(set) var topArtists: [SpotifyCatalogItem] = []
    private(set) var needsPersonalLibraryPermission = false
    private(set) var searchTracks: [SpotifyCatalogItem] = []
    private(set) var searchAlbums: [SpotifyCatalogItem] = []
    private(set) var searchArtists: [SpotifyCatalogItem] = []
    private(set) var searchPlaylists: [SpotifyCatalogItem] = []
    private(set) var selectedPlaylist: SpotifyCatalogItem?
    private(set) var playlistTracks: [SpotifyCatalogItem] = []
    private(set) var selectedArtist: SpotifyCatalogItem?
    private(set) var artistAlbums: [SpotifyCatalogItem] = []
    private(set) var artistTopTracks: [SpotifyCatalogItem] = []
    private(set) var artistAlbumsError: String?
    private(set) var artistRadioError: String?
    private(set) var isLoadingArtist = false
    private(set) var selectedAlbum: SpotifyCatalogItem?
    private(set) var albumTracks: [SpotifyCatalogItem] = []
    private(set) var albumTracksError: String?
    private(set) var isLoadingAlbum = false
    private(set) var playback: SpotifyPlaybackSnapshot?
    private(set) var isLoading = false
    private(set) var isStartingPlayback = false
    private(set) var playbackMessage: String?
    private(set) var availableDeviceNames: [String] = []
    var error: String?
    let librespot = LibrespotService()

    @ObservationIgnored private var api: SpotifyAPI<UziqSpotifyAuthorizationManager>
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private let loopbackServer = SpotifyLoopbackServer()
    @ObservationIgnored private var codeVerifier: String?
    @ObservationIgnored private var authorizationState: String?
    @ObservationIgnored private var playbackTimer: Timer?
    @ObservationIgnored private var desiredVolume: Float = 1
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var artistLoadGeneration = UUID()
    @ObservationIgnored private var albumLoadGeneration = UUID()
    @ObservationIgnored private var artistTopTracksFinished = false
    @ObservationIgnored private var artistAlbumsFinished = false
    @ObservationIgnored private var playbackTick = 0
    @ObservationIgnored private var isSpotifyPlaybackSuppressed = false
    @ObservationIgnored private var uziqDeviceID: String?
    @ObservationIgnored private var localPlaybackObserver: NSObjectProtocol?
    @ObservationIgnored private var toggleObserver: NSObjectProtocol?
    @ObservationIgnored private weak var playbackEngine: PlaybackEngine?

    private let authorizationKey = "spotify-pkce-authorization"
    private let requiredScopes: Set<Scope> = [
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
        let clientID = UserDefaults.standard.string(forKey: "spotify-client-id") ?? ""
        self.clientID = clientID
        api = SpotifyAPI(
            authorizationManager: UziqSpotifyAuthorizationManager(
                backend: UziqSpotifyPKCEBackend(
                    clientId: clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        )
        configureAPISubscriptions()
        restoreAuthorization()
        localPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .uziqLocalPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let shouldPauseSpotify = self.isUziqPlaybackActive
                self.playbackGeneration = UUID()
                self.isStartingPlayback = false
                self.playbackMessage = nil
                self.isSpotifyPlaybackSuppressed = true
                self.playback = nil
                if shouldPauseSpotify { self.pause() }
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
        loopbackServer.stop()
        if let localPlaybackObserver { NotificationCenter.default.removeObserver(localPlaybackObserver) }
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
    }

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        api.authorizationManager.deauthorize()
        SpotifyKeychain.remove(authorizationKey)
        closeDetail()
        isAuthorized = false
        profileName = nil
        playlists = []
        likedSongs = []
        likedSongsTotal = 0
        topArtists = []
        needsPersonalLibraryPermission = false
        clearSearch()
        playback = nil
        uziqDeviceID = nil
        isSpotifyPlaybackSuppressed = false
        librespot.signOut()
    }

    func loadAccount() {
        guard isAuthorized else { return }
        isLoading = true
        error = nil
        Publishers.Zip(api.currentUserProfile(), api.currentUserPlaylists(limit: 50))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                isLoading = false
                if case .failure(let error) = completion { self.error = error.localizedDescription }
            } receiveValue: { [weak self] profile, page in
                guard let self else { return }
                profileName = profile.displayName ?? profile.id
                playlists = page.items
                    .filter { $0.owner?.id == profile.id }
                    .map(Self.catalogItem)
                needsPersonalLibraryPermission = !api.authorizationManager.isAuthorized(for: requiredScopes)
                if !needsPersonalLibraryPermission {
                    loadPersonalLibrary()
                }
                refreshPlayback()
            }
            .store(in: &cancellables)
    }

    func search() {
        search(query: query)
    }

    func search(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = normalized
        guard isAuthorized else {
            error = "Connect your Spotify account before searching."
            return
        }
        closeDetail()
        guard !normalized.isEmpty else {
            clearSearch()
            return
        }

        isLoading = true
        error = nil
        api.search(
            query: normalized,
            categories: [.track, .album, .artist],
            limit: 10
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            guard let self else { return }
            if case .failure(let error) = completion {
                isLoading = false
                self.error = error.localizedDescription
            }
        } receiveValue: { [weak self] result in
            guard let self else { return }
            searchTracks = result.tracks?.items.map { Self.catalogItem($0) } ?? []
            searchAlbums = result.albums?.items.map(Self.catalogItem) ?? []
            searchArtists = result.artists?.items.map(Self.catalogItem) ?? []
            searchPlaylistsWithCurrentToken(query: normalized)
        }
        .store(in: &cancellables)
    }

    func openPlaylist(_ playlist: SpotifyCatalogItem) {
        closeAlbum()
        closeArtist()
        selectedPlaylist = playlist
        playlistTracks = []
        guard isAuthorized else { return }
        isLoading = true
        api.playlistItems(playlist.uri, limit: 100)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                isLoading = false
                if case .failure(let error) = completion { self.error = error.localizedDescription }
            } receiveValue: { [weak self] page in
                self?.playlistTracks = page.items.compactMap { container in
                    guard case .track(let track)? = container.item else { return nil }
                    return Self.catalogItem(track)
                }
            }
            .store(in: &cancellables)
    }

    func openLikedSongs() {
        closeArtist()
        selectedPlaylist = likedSongsCollection
        playlistTracks = likedSongs
    }

    func closePlaylist() {
        selectedPlaylist = nil
        playlistTracks = []
    }

    func openArtist(_ artist: SpotifyCatalogItem) {
        guard artist.kind == .artist, !artist.uri.isEmpty else { return }
        closeAlbum()
        closePlaylist()
        selectedArtist = artist
        artistAlbums = []
        artistTopTracks = []
        artistAlbumsError = nil
        artistRadioError = nil
        error = nil
        isLoadingArtist = true
        artistTopTracksFinished = false
        artistAlbumsFinished = false
        let generation = UUID()
        artistLoadGeneration = generation
        loadArtistAlbums(artist, offset: 0, accumulated: [], generation: generation)
        api.search(
            query: Self.artistRadioSearchQuery(for: artist.name),
            categories: [.track],
            limit: 10
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self, artistLoadGeneration == generation else { return }
                artistTopTracksFinished = true
                finishArtistLoadingIfReady()
                if case .failure(let error) = completion {
                    artistRadioError = error.localizedDescription
                }
            } receiveValue: { [weak self] result in
                guard let self, artistLoadGeneration == generation else { return }
                artistTopTracks = result.tracks?.items.map { Self.catalogItem($0) } ?? []
            }
            .store(in: &cancellables)
    }

    func closeArtist() {
        artistLoadGeneration = UUID()
        selectedArtist = nil
        artistAlbums = []
        artistTopTracks = []
        artistAlbumsError = nil
        artistRadioError = nil
        isLoadingArtist = false
    }

    func openAlbum(_ album: SpotifyCatalogItem) {
        guard album.kind == .album, !album.uri.isEmpty else { return }
        closePlaylist()
        selectedAlbum = album
        albumTracks = []
        albumTracksError = nil
        isLoadingAlbum = true
        let generation = UUID()
        albumLoadGeneration = generation
        loadAlbumTracks(album, offset: 0, accumulated: [], generation: generation)
    }

    func closeAlbum() {
        albumLoadGeneration = UUID()
        selectedAlbum = nil
        albumTracks = []
        albumTracksError = nil
        isLoadingAlbum = false
    }

    func closeDetail() {
        closeAlbum()
        closePlaylist()
        closeArtist()
    }

    func playCollection(_ collection: SpotifyCatalogItem) {
        if collection.id == Self.likedSongsID {
            playLikedSongs(startingAt: nil)
        } else {
            play(collection)
        }
    }

    func startPlaybackEngine() {
        guard let playbackEngine else {
            error = "The audio engine is not ready yet."
            return
        }
        librespot.start(using: playbackEngine)
    }

    func play(_ item: SpotifyCatalogItem) {
        guard item.kind != .artist || item.uri.hasPrefix("spotify:artist:") else { return }
        let request: PlaybackRequest
        if item.kind == .track {
            request = PlaybackRequest(item.uri)
        } else {
            request = PlaybackRequest(context: .contextURI(item.uri), offset: nil)
        }
        startPlayback(request)
    }

    func play(_ track: SpotifyCatalogItem, in playlist: SpotifyCatalogItem) {
        if playlist.id == Self.likedSongsID {
            playLikedSongs(startingAt: track)
            return
        }
        guard track.kind == .track,
              playlist.kind == .playlist,
              !track.uri.isEmpty,
              !playlist.uri.isEmpty else {
            play(track)
            return
        }
        startPlayback(Self.playlistPlaybackRequest(trackURI: track.uri, playlistURI: playlist.uri))
    }

    static func playlistPlaybackRequest(trackURI: String, playlistURI: String) -> PlaybackRequest {
        PlaybackRequest(
            context: .contextURI(playlistURI),
            offset: .uri(trackURI)
        )
    }

    func reconnectForPersonalLibrary() {
        api.authorizationManager.deauthorize()
        SpotifyKeychain.remove(authorizationKey)
        isAuthorized = false
        needsPersonalLibraryPermission = false
        DispatchQueue.main.async { [weak self] in self?.logIn() }
    }

    private func startPlayback(_ request: PlaybackRequest) {
        guard isAuthorized else {
            error = "Connect your Spotify account before playing."
            return
        }
        guard let playbackEngine else {
            error = "The audio engine is not ready yet."
            return
        }
        isSpotifyPlaybackSuppressed = false
        playbackEngine.stopForExternalSpotifyPlayback()
        librespot.start(using: playbackEngine)
        isStartingPlayback = true
        playbackMessage = librespot.status == .ready
            ? "Connecting to the Uziq Spotify device…"
            : "Starting the Uziq Spotify device…"
        error = nil
        let generation = UUID()
        playbackGeneration = generation
        play(request, attemptsRemaining: 20, generation: generation)
    }

    func togglePlayback() {
        guard isAuthorized else { return }
        playback?.isPlaying == true ? pause() : resume()
    }

    func pause() {
        performPlayerCommand(api.pausePlayback(deviceId: uziqDeviceID))
    }

    func resume() {
        performPlayerCommand(api.resumePlayback(deviceId: uziqDeviceID))
    }

    func next() {
        performPlayerCommand(api.skipToNext(deviceId: uziqDeviceID))
    }

    func previous() {
        performPlayerCommand(api.skipToPrevious(deviceId: uziqDeviceID))
    }

    func seek(to seconds: Double) {
        performPlayerCommand(
            api.seekToPosition(max(0, Int(seconds * 1_000)), deviceId: uziqDeviceID)
        )
    }

    func setVolume(_ normalizedVolume: Float) {
        desiredVolume = min(1, max(0, normalizedVolume))
        guard isAuthorized, isUziqPlaybackActive else { return }
        api.setVolume(to: Int((desiredVolume * 100).rounded()), deviceId: uziqDeviceID)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { }
            .store(in: &cancellables)
    }

    func refreshPlayback() {
        guard isAuthorized else { return }
        api.currentPlayback()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case .failure(let error) = completion {
                    self?.error = error.localizedDescription
                }
            } receiveValue: { [weak self] context in
                self?.updatePlayback(context)
            }
            .store(in: &cancellables)
    }

    private func completeLogin(_ callbackURL: URL) {
        guard let codeVerifier, let authorizationState else {
            error = "Spotify returned a login response after the authorization session expired."
            return
        }
        api.authorizationManager.requestAccessAndRefreshTokens(
            redirectURIWithQuery: callbackURL,
            codeVerifier: codeVerifier,
            state: authorizationState
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            guard let self else { return }
            self.codeVerifier = nil
            self.authorizationState = nil
            if case .failure(let error) = completion { self.error = error.localizedDescription }
        } receiveValue: { [weak self] in
            self?.isAuthorized = true
            self?.loadAccount()
        }
        .store(in: &cancellables)
    }

    private func rebuildAPI(clientID: String) {
        cancellables.removeAll()
        api = SpotifyAPI(
            authorizationManager: UziqSpotifyAuthorizationManager(
                backend: UziqSpotifyPKCEBackend(clientId: clientID)
            )
        )
        isAuthorized = false
        profileName = nil
        playlists = []
        clearSearch()
        configureAPISubscriptions()
        restoreAuthorization()
    }

    private func configureAPISubscriptions() {
        api.authorizationManagerDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                isAuthorized = api.authorizationManager.isAuthorized()
                needsPersonalLibraryPermission = isAuthorized &&
                    !api.authorizationManager.isAuthorized(for: requiredScopes)
                if let data = try? JSONEncoder().encode(api.authorizationManager) {
                    SpotifyKeychain.write(data, account: authorizationKey)
                }
            }
            .store(in: &cancellables)
        api.authorizationManagerDidDeauthorize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                SpotifyKeychain.remove(authorizationKey)
                isAuthorized = false
            }
            .store(in: &cancellables)
    }

    private func restoreAuthorization() {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = SpotifyKeychain.read(authorizationKey),
              let manager = try? JSONDecoder().decode(UziqSpotifyAuthorizationManager.self, from: data),
              manager.clientId == clientID.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        api.authorizationManager = manager
        isAuthorized = manager.isAuthorized()
        needsPersonalLibraryPermission = isAuthorized && !manager.isAuthorized(for: requiredScopes)
        if isAuthorized {
            loadAccount()
        } else if manager.refreshToken != nil {
            refreshRestoredAuthorization(using: manager)
        }
    }

    private func refreshRestoredAuthorization(using manager: UziqSpotifyAuthorizationManager) {
        isLoading = true
        error = nil
        manager.refreshTokens(onlyIfExpired: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                if case .failure(let error) = completion {
                    isLoading = false
                    isAuthorized = false
                    self.error = "Could not refresh the Spotify session: \(error.localizedDescription)"
                }
            } receiveValue: { [weak self] in
                guard let self else { return }
                isLoading = false
                isAuthorized = manager.isAuthorized()
                needsPersonalLibraryPermission = isAuthorized && !manager.isAuthorized(for: requiredScopes)
                if isAuthorized { loadAccount() }
            }
            .store(in: &cancellables)
    }

    private func loadPersonalLibrary() {
        loadSavedTracks(offset: 0, accumulated: [])
        api.currentUserTopArtists(.mediumTerm, offset: 0, limit: 12)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case .failure(let error) = completion { self?.error = error.localizedDescription }
            } receiveValue: { [weak self] page in
                self?.topArtists = page.items.map(Self.catalogItem)
            }
            .store(in: &cancellables)
    }

    private func loadArtistAlbums(
        _ artist: SpotifyCatalogItem,
        offset: Int,
        accumulated: [SpotifyCatalogItem],
        generation: UUID
    ) {
        api.artistAlbums(
            artist.uri,
            groups: [.album, .single],
            country: nil,
            limit: Self.artistAlbumsPageLimit,
            offset: offset
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            guard let self, artistLoadGeneration == generation else { return }
            if case .failure(let error) = completion {
                artistAlbumsFinished = true
                finishArtistLoadingIfReady()
                artistAlbumsError = error.localizedDescription
            }
        } receiveValue: { [weak self] page in
            guard let self, artistLoadGeneration == generation else { return }
            let combined = accumulated + page.items.map(Self.catalogItem)
            if !page.items.isEmpty, combined.count < page.total {
                loadArtistAlbums(
                    artist,
                    offset: offset + page.items.count,
                    accumulated: combined,
                    generation: generation
                )
            } else {
                var seen = Set<String>()
                artistAlbums = combined.filter { seen.insert($0.id).inserted }
                artistAlbumsFinished = true
                finishArtistLoadingIfReady()
            }
        }
        .store(in: &cancellables)
    }

    private func loadAlbumTracks(
        _ album: SpotifyCatalogItem,
        offset: Int,
        accumulated: [SpotifyCatalogItem],
        generation: UUID
    ) {
        api.albumTracks(
            album.uri,
            market: "from_token",
            limit: Self.albumTracksPageLimit,
            offset: offset
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            guard let self, albumLoadGeneration == generation else { return }
            if case .failure(let error) = completion {
                isLoadingAlbum = false
                albumTracksError = error.localizedDescription
            }
        } receiveValue: { [weak self] page in
            guard let self, albumLoadGeneration == generation else { return }
            let combined = accumulated + page.items.map {
                Self.catalogItem($0, fallbackArtworkURL: album.artworkURL)
            }
            if !page.items.isEmpty, combined.count < page.total {
                loadAlbumTracks(
                    album,
                    offset: offset + page.items.count,
                    accumulated: combined,
                    generation: generation
                )
            } else {
                albumTracks = combined
                isLoadingAlbum = false
            }
        }
        .store(in: &cancellables)
    }

    private func finishArtistLoadingIfReady() {
        if artistAlbumsFinished && artistTopTracksFinished {
            isLoadingArtist = false
        }
    }

    private func loadSavedTracks(offset: Int, accumulated: [SpotifyCatalogItem]) {
        api.currentUserSavedTracks(limit: 50, offset: offset)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case .failure(let error) = completion { self?.error = error.localizedDescription }
            } receiveValue: { [weak self] page in
                guard let self else { return }
                let combined = accumulated + page.items.map { Self.catalogItem($0.item) }
                likedSongsTotal = page.total
                likedSongs = combined
                if selectedPlaylist?.id == Self.likedSongsID {
                    playlistTracks = combined
                }
                if !page.items.isEmpty, combined.count < page.total {
                    loadSavedTracks(offset: offset + page.items.count, accumulated: combined)
                }
            }
            .store(in: &cancellables)
    }

    private func playLikedSongs(startingAt track: SpotifyCatalogItem?) {
        guard !likedSongs.isEmpty else {
            error = "Your Liked Songs collection is still loading."
            return
        }
        let startIndex = track.flatMap { likedSongs.firstIndex(of: $0) } ?? 0
        let uris = likedSongs[startIndex...]
            .prefix(100)
            .map(\.uri)
            .filter { !$0.isEmpty }
        guard !uris.isEmpty else { return }
        startPlayback(PlaybackRequest(context: .uris(uris), offset: nil))
    }

    private func play(_ request: PlaybackRequest, attemptsRemaining: Int, generation: UUID) {
        api.availableDevices()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                if case .failure(let error) = completion {
                    isStartingPlayback = false
                    self.error = error.localizedDescription
                }
            } receiveValue: { [weak self] devices in
                guard let self else { return }
                guard playbackGeneration == generation else { return }
                availableDeviceNames = devices.map(\.name)
                if let device = devices.first(where: {
                    $0.name.caseInsensitiveCompare("Uziq") == .orderedSame && !$0.isRestricted
                }), let deviceID = device.id {
                    uziqDeviceID = deviceID
                    playbackMessage = "Starting playback in Uziq…"
                    api.play(request, deviceId: deviceID)
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] completion in
                            guard let self else { return }
                            guard playbackGeneration == generation else { return }
                            isStartingPlayback = false
                            playbackMessage = nil
                            if case .failure(let error) = completion {
                                self.error = "Spotify could not start playback: \(error.localizedDescription)"
                            }
                        } receiveValue: { [weak self] in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                guard let self else { return }
                                self.refreshPlayback()
                                self.setVolume(self.desiredVolume)
                            }
                        }
                        .store(in: &cancellables)
                } else if attemptsRemaining > 0, librespot.status.isRunning {
                    playbackMessage = "Waiting for Spotify to discover the Uziq device…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard self?.playbackGeneration == generation else { return }
                        self?.play(request, attemptsRemaining: attemptsRemaining - 1, generation: generation)
                    }
                } else {
                    isStartingPlayback = false
                    playbackMessage = nil
                    if availableDeviceNames.isEmpty {
                        error = "Spotify cannot see any playback devices. Make sure librespot and the Web API are signed into the same Spotify account, then restart the playback engine."
                    } else {
                        error = "Spotify can see \(availableDeviceNames.joined(separator: ", ")), but not an unrestricted Uziq device. Make sure both Spotify connections use the same account, then restart the playback engine."
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func performPlayerCommand(_ publisher: AnyPublisher<Void, Error>) {
        error = nil
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case .failure(let error) = completion { self?.error = error.localizedDescription }
            } receiveValue: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshPlayback() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.refreshPlayback() }
            }
            .store(in: &cancellables)
    }

    private func playbackTimerFired() {
        guard isAuthorized else { return }
        playbackTick += 1
        if playbackTick.isMultiple(of: 5) { refreshPlayback() }
    }

    private func updatePlayback(_ context: CurrentlyPlayingContext?) {
        guard !isSpotifyPlaybackSuppressed else {
            playback = nil
            return
        }
        guard let context, let item = context.item else {
            playback = nil
            return
        }
        if context.device.name.caseInsensitiveCompare("Uziq") == .orderedSame {
            uziqDeviceID = context.device.id
        }
        switch item {
        case .track(let track):
            playback = SpotifyPlaybackSnapshot(
                itemID: track.id ?? track.uri ?? UUID().uuidString,
                title: track.name,
                artist: track.artists?.map(\.name).joined(separator: ", ") ?? "Unknown Artist",
                album: track.album?.name ?? "",
                artworkURL: track.album?.images?.first?.url,
                duration: Double(track.durationMS ?? 0) / 1_000,
                progress: Double(context.progressMS ?? 0) / 1_000,
                isPlaying: context.isPlaying,
                deviceName: context.device.name,
                observedAt: Date()
            )
        case .episode(let episode):
            playback = SpotifyPlaybackSnapshot(
                itemID: episode.id ?? episode.uri ?? UUID().uuidString,
                title: episode.name ?? "Spotify episode",
                artist: episode.show?.name ?? "Spotify",
                album: episode.show?.name ?? "",
                artworkURL: episode.images?.first?.url,
                duration: Double(episode.durationMS ?? 0) / 1_000,
                progress: Double(context.progressMS ?? 0) / 1_000,
                isPlaying: context.isPlaying,
                deviceName: context.device.name,
                observedAt: Date()
            )
        }
    }

    private func clearSearch() {
        searchTracks = []
        searchAlbums = []
        searchArtists = []
        searchPlaylists = []
    }

    private func searchPlaylistsWithCurrentToken(query: String) {
        api.authorizationManager.refreshTokens(onlyIfExpired: true)
            .tryMap { [weak self] _ -> URLRequest in
                guard let self, let token = api.authorizationManager.accessToken else {
                    throw URLError(.userAuthenticationRequired)
                }
                var components = URLComponents(string: "https://api.spotify.com/v1/search")!
                components.queryItems = [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "type", value: "playlist"),
                    URLQueryItem(name: "limit", value: "10")
                ]
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
            .flatMap { [weak self] request -> AnyPublisher<(data: Data, response: HTTPURLResponse), Error> in
                guard let self else { return Fail(error: URLError(.cancelled)).eraseToAnyPublisher() }
                return api.networkAdaptor(request)
            }
            .tryMap { output in
                guard (200..<300).contains(output.response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return try JSONDecoder().decode(RawPlaylistSearchEnvelope.self, from: output.data)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                isLoading = false
                if case .failure(let error) = completion { self.error = error.localizedDescription }
            } receiveValue: { [weak self] response in
                self?.searchPlaylists = response.playlists.items.compactMap { $0?.catalogItem }
            }
            .store(in: &cancellables)
    }

    private static func catalogItem(
        _ track: SpotifyWebAPI.Track,
        fallbackArtworkURL: URL? = nil
    ) -> SpotifyCatalogItem {
        SpotifyCatalogItem(
            id: track.id ?? track.uri ?? UUID().uuidString,
            name: track.name,
            subtitle: track.artists?.map(\.name).joined(separator: ", ") ?? "Unknown Artist",
            uri: track.uri ?? "",
            kind: .track,
            artworkURL: track.album?.images?.first?.url ?? fallbackArtworkURL,
            durationMS: track.durationMS,
            itemCount: nil
        )
    }

    private static func catalogItem(_ album: SpotifyWebAPI.Album) -> SpotifyCatalogItem {
        SpotifyCatalogItem(
            id: album.id ?? album.uri ?? UUID().uuidString,
            name: album.name,
            subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "Unknown Artist",
            uri: album.uri ?? "",
            kind: .album,
            artworkURL: album.images?.first?.url,
            durationMS: nil,
            itemCount: album.totalTracks
        )
    }

    private static func catalogItem(_ artist: SpotifyWebAPI.Artist) -> SpotifyCatalogItem {
        SpotifyCatalogItem(
            id: artist.id ?? artist.uri ?? UUID().uuidString,
            name: artist.name,
            subtitle: artist.genres?.prefix(3).joined(separator: " · ") ?? "Artist",
            uri: artist.uri ?? "",
            kind: .artist,
            artworkURL: artist.images?.first?.url,
            durationMS: nil,
            itemCount: nil
        )
    }

    private static func catalogItem(_ playlist: Playlist<PlaylistItemsReference>) -> SpotifyCatalogItem {
        SpotifyCatalogItem(
            id: playlist.id,
            name: playlist.name,
            subtitle: playlist.owner?.displayName ?? "Spotify playlist",
            uri: playlist.uri,
            kind: .playlist,
            artworkURL: playlist.images.first?.url,
            durationMS: nil,
            itemCount: playlist.items.total
        )
    }
}

struct RawPlaylistSearchEnvelope: Decodable {
    let playlists: RawPlaylistPage
}

struct RawPlaylistPage: Decodable {
    let items: [RawPlaylist?]
}

struct RawPlaylist: Decodable {
    struct Owner: Decodable {
        let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }
    struct Image: Decodable { let url: URL }
    struct Items: Decodable { let total: Int? }

    let id: String?
    let name: String?
    let uri: String?
    let owner: Owner?
    let images: [Image]?
    let items: Items?

    var catalogItem: SpotifyCatalogItem? {
        guard let id, let name, let uri else { return nil }
        return SpotifyCatalogItem(
            id: id,
            name: name,
            subtitle: owner?.displayName ?? "Spotify playlist",
            uri: uri,
            kind: .playlist,
            artworkURL: images?.first?.url,
            durationMS: nil,
            itemCount: items?.total
        )
    }
}
