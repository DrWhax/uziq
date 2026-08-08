import Foundation
import Observation

@MainActor
@Observable
final class BandcampStore {
    var subscriptions: [BandcampSubscription] = []
    var results: [BandcampResult] = []
    var savedResults: [BandcampResult] = []
    var ownedResults: [BandcampResult] = []
    var subscribedArtists: [BandcampResult] = []
    var artistSubscriptionsCheckedAt: Date?
    var query = ""
    var isLoading = false
    var isLoadingCollection = false
    var loadingMessage = "Looking through Bandcamp…"
    var preparingPlaybackResultID: String?
    var error: String?
    var collectionError: String?
    var cacheBytes: Int64 = 0
    var cachedFileCount = 0
    var isCleaningCache = false
    var cacheMessage: String?
    var accountEmail: String {
        didSet { defaults.set(accountEmail, forKey: accountEmailKey) }
    }
    private(set) var isAuthenticated = false
    private(set) var isAuthenticating = false
    private(set) var authError: String?
    private(set) var authStatusMessage: String?
    private(set) var authRequiresRetry = false
    private var playbackResultsByTrackID: [String: BandcampResult] = [:]
    private var cachedURLsByTrackID: [String: URL] = [:]

    @ObservationIgnored private let client = BandcampClient()
    @ObservationIgnored private let authClient = BandcampAuthClient()
    @ObservationIgnored private let cache = BandcampCacheManager()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let subscriptionsKey = "bandcamp-subscriptions"
    @ObservationIgnored private let savedResultsKey = "bandcamp-saved-results"
    @ObservationIgnored private let accountEmailKey = "bandcamp-account-email"
    @ObservationIgnored private var authSession: BandcampOAuthSession?
    @ObservationIgnored private var playObserver: NSObjectProtocol?
    @ObservationIgnored private var cacheMaintenanceTimer: Timer?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var collectionTask: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = UUID()

    init() {
        accountEmail = UserDefaults.standard.string(forKey: "bandcamp-account-email") ?? ""
        authSession = BandcampKeychain.readSession()
        isAuthenticated = authSession != nil
        if let data = defaults.data(forKey: subscriptionsKey),
           let saved = try? JSONDecoder().decode([BandcampSubscription].self, from: data) {
            subscriptions = saved
        }
        if let data = defaults.data(forKey: savedResultsKey),
           let saved = try? JSONDecoder().decode([BandcampResult].self, from: data) {
            savedResults = saved
        }
        playObserver = NotificationCenter.default.addObserver(
            forName: .uziqTrackPlayed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let trackID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.markCachedTrackUsed(trackID)
            }
        }
        cacheMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performCacheMaintenance(reportResult: false)
            }
        }
        performCacheMaintenance(reportResult: false)
        if authSession != nil {
            Task { [weak self] in
                await self?.refreshAuthentication()
                self?.loadCollection()
            }
        }
    }

    deinit {
        if let playObserver { NotificationCenter.default.removeObserver(playObserver) }
        cacheMaintenanceTimer?.invalidate()
    }

    func saveSubscriptions(keywords: [String], artists: [String]) {
        var saved: [BandcampSubscription] = []
        for value in keywords {
            append(value, kind: .keyword, to: &saved)
        }
        for value in artists {
            append(value, kind: .artist, to: &saved)
        }
        subscriptions = saved
        persistSubscriptions()
        refreshFeed()
    }

    func removeSubscription(_ subscription: BandcampSubscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        persistSubscriptions()
        refreshFeed()
    }

    func removeArtistSubscription(_ artist: BandcampResult) {
        let prefix = "subscription-"
        guard artist.id.hasPrefix(prefix),
              let id = UUID(uuidString: String(artist.id.dropFirst(prefix.count))) else { return }
        subscriptions.removeAll { $0.id == id }
        subscribedArtists.removeAll { $0.id == artist.id }
        persistSubscriptions()
        refreshFeed()
    }

    func signIn(password: String, authCode: String) {
        let email = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            authError = "Enter your Bandcamp email and password."
            return
        }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil
        authStatusMessage = "Connecting to Bandcamp…"
        let authClient = self.authClient
        Task { [weak self] in
            do {
                let session = try await authClient.login(
                    email: email,
                    password: password,
                    authCode: authCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard let self else { return }
                authSession = session
                BandcampKeychain.writeSession(session)
                isAuthenticated = true
                authRequiresRetry = false
                authStatusMessage = "Connected as \(email)"
                loadCollection()
            } catch {
                self?.authError = error.localizedDescription
                if let authError = error as? BandcampAuthError, authError.isLoginRejection {
                    self?.authRequiresRetry = true
                }
                self?.authStatusMessage = nil
            }
            self?.isAuthenticating = false
        }
    }

    func signOut() {
        let session = authSession
        authSession = nil
        isAuthenticated = false
        authError = nil
        authRequiresRetry = false
        authStatusMessage = "Disconnected"
        ownedResults = []
        collectionError = nil
        isLoadingCollection = false
        collectionTask?.cancel()
        collectionTask = nil
        BandcampKeychain.removeSession()
        guard let session else { return }
        let authClient = self.authClient
        Task { await authClient.revoke(session) }
    }

    func clearAuthError() {
        authError = nil
    }

    func releaseDetails(for result: BandcampResult) async throws -> BandcampAlbumDetails {
        var details = try await client.details(for: result)
        details = await detailsWithAuthenticatedStreams(details)
        return details
    }

    func artistPage(for artist: BandcampResult) async throws -> BandcampArtistPage {
        async let searchResultsTask = client.search(query: artist.title)
        async let summaryTask = client.artistBiography(for: artist.title)
        let searchResults = try await searchResultsTask
        let summary = await summaryTask
        let remoteReleases = searchResults.filter { result in
            guard result.type == "a" || result.type == "t" else { return false }
            if let bandID = artist.bandID, result.bandID == bandID { return true }
            return result.artist.caseInsensitiveCompare(artist.title) == .orderedSame
        }
        let ownedReleases = ownedResults.filter {
            $0.artist.caseInsensitiveCompare(artist.title) == .orderedSame
        }
        return BandcampArtistPage(
            artist: artist,
            summary: summary,
            releases: Array(deduplicated(ownedReleases + remoteReleases).prefix(40))
        )
    }

    func loadCollection() {
        guard isAuthenticated else {
            ownedResults = []
            collectionError = nil
            isLoadingCollection = false
            return
        }
        collectionTask?.cancel()
        isLoadingCollection = true
        collectionError = nil
        let authClient = self.authClient
        collectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await validAccessToken()
                var collected: [BandcampResult] = []
                var offset: String?
                var seenOffsets = Set<String>()

                for _ in 0..<10 {
                    try Task.checkCancellation()
                    let page = try await authClient.collectionPage(
                        accessToken: accessToken,
                        offset: offset
                    )
                    collected.append(contentsOf: page.items)
                    guard let nextOffset = page.nextOffset,
                          seenOffsets.insert(nextOffset).inserted else { break }
                    offset = nextOffset
                }

                try Task.checkCancellation()
                ownedResults = deduplicated(collected)
            } catch is CancellationError {
                return
            } catch {
                collectionError = error.localizedDescription
            }
            isLoadingCollection = false
            collectionTask = nil
        }
    }

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            refreshFeed()
            return
        }
        let client = self.client
        isLoading = true
        loadingMessage = "Searching Bandcamp…"
        error = nil
        Task { [weak self] in
            do {
                let found = try await client.search(query: trimmed)
                guard let self, !Task.isCancelled else { return }
                results = deduplicated(found)
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isLoading = false
        }
    }

    func refreshFeed() {
        let subscriptions = subscriptions
        guard !subscriptions.isEmpty else {
            results = []
            subscribedArtists = []
            artistSubscriptionsCheckedAt = nil
            isLoading = false
            return
        }

        let client = self.client
        isLoading = true
        loadingMessage = "Looking through Bandcamp…"
        error = nil
        Task { [weak self] in
            var found: [BandcampResult] = []
            var artistCards: [BandcampResult] = []
            var firstError: Error?
            for subscription in subscriptions {
                guard !Task.isCancelled else { return }
                do {
                    let subscriptionResults = try await client.search(query: subscription.value)
                    found += subscriptionResults
                    if subscription.kind == .artist {
                        artistCards.append(Self.artistCard(
                            for: subscription,
                            searchResults: subscriptionResults
                        ))
                    }
                } catch {
                    if firstError == nil { firstError = error }
                    if subscription.kind == .artist {
                        artistCards.append(Self.artistCard(for: subscription, searchResults: []))
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            results = Array(deduplicated(found).prefix(60))
            subscribedArtists = artistCards
            if !artistCards.isEmpty { artistSubscriptionsCheckedAt = .now }
            if found.isEmpty, let firstError { error = firstError.localizedDescription }
            isLoading = false
        }
    }

    func play(
        _ result: BandcampResult,
        using playback: PlaybackEngine,
        onFailure: ((String) -> Void)? = nil
    ) {
        guard result.isPlayable else { return }
        cancelPendingPlayback()
        let generation = UUID()
        playbackGeneration = generation
        let client = self.client
        preparingPlaybackResultID = result.id
        error = nil
        playbackTask = Task { [weak self] in
            defer {
                if self?.playbackGeneration == generation {
                    self?.preparingPlaybackResultID = nil
                    self?.playbackTask = nil
                }
            }
            do {
                guard let store = self else { return }
                var details = try await client.details(for: result)
                details = await store.detailsWithAuthenticatedStreams(details)
                let playableTracks = details.tracks.filter { $0.isStreamable && $0.streamURL != nil }
                guard !playableTracks.isEmpty else {
                    throw UziqError.metadata("This Bandcamp release has no playable stream.")
                }
                let startIndex: Int
                if result.type == "t", let requestedID = result.tralbumID {
                    startIndex = playableTracks.firstIndex(where: { $0.id == requestedID }) ?? 0
                } else {
                    startIndex = 0
                }
                var remainingTracks = Array(playableTracks.dropFirst(startIndex + 1))
                let firstTrackDetails = playableTracks[startIndex]
                guard let firstStreamURL = firstTrackDetails.streamURL else {
                    throw UziqError.metadata("This Bandcamp track has no playable stream.")
                }
                let artworkData = await store.downloadArtwork(from: details.artworkURL ?? result.artworkURL)
                let firstLocalURL = try await store.cachedStreamURL(
                    for: details,
                    track: firstTrackDetails,
                    source: firstStreamURL
                )
                let firstTrack = store.makeTrack(
                    firstTrackDetails,
                    details: details,
                    localURL: firstLocalURL,
                    artworkData: artworkData,
                    sourceResult: result
                )
                guard !Task.isCancelled else { return }
                playback.playStreaming(firstTrack) { [weak store] in
                    guard let store else { return nil }
                    while !remainingTracks.isEmpty {
                        let next = remainingTracks.removeFirst()
                        guard let streamURL = next.streamURL else { continue }
                        do {
                            let localURL = try await store.cachedStreamURL(
                                for: details,
                                track: next,
                                source: streamURL
                            )
                            return store.makeTrack(
                                next,
                                details: details,
                                localURL: localURL,
                                artworkData: artworkData,
                                sourceResult: result
                            )
                        } catch {
                            continue
                        }
                    }
                    return nil
                }
            } catch {
                self?.error = error.localizedDescription
                onFailure?(error.localizedDescription)
            }
        }
    }

    func cancelPendingPlayback() {
        playbackGeneration = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        preparingPlaybackResultID = nil
    }

    func isSaved(_ result: BandcampResult) -> Bool {
        savedResults.contains { $0.id == result.id }
    }

    func toggleSaved(_ result: BandcampResult) {
        if let index = savedResults.firstIndex(where: { $0.id == result.id }) {
            savedResults.remove(at: index)
        } else {
            savedResults.insert(result, at: 0)
        }
        persistSavedResults()
    }

    func isSaved(_ track: Track) -> Bool {
        guard let result = playbackResultsByTrackID[track.id] else { return false }
        return isSaved(result)
    }

    func toggleSaved(_ track: Track) {
        guard let result = playbackResultsByTrackID[track.id] else { return }
        toggleSaved(result)
    }

    func refreshCacheStats() {
        let cache = cache
        Task { [weak self] in
            let stats = try? await Task.detached(priority: .utility) {
                try cache.stats()
            }.value
            guard let self, let stats else { return }
            cacheBytes = stats.totalBytes
            cachedFileCount = stats.fileCount
        }
    }

    func cleanUpCache() {
        performCacheMaintenance(reportResult: true)
    }

    private func append(_ value: String, kind: BandcampSubscriptionKind, to saved: inout [BandcampSubscription]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !saved.contains(where: { $0.kind == kind && $0.value.caseInsensitiveCompare(normalized) == .orderedSame }) else { return }
        saved.append(BandcampSubscription(id: UUID(), kind: kind, value: normalized))
    }

    private nonisolated static func artistCard(
        for subscription: BandcampSubscription,
        searchResults: [BandcampResult]
    ) -> BandcampResult {
        let exactBand = searchResults.first {
            $0.type == "b" &&
                ($0.title.caseInsensitiveCompare(subscription.value) == .orderedSame ||
                 $0.artist.caseInsensitiveCompare(subscription.value) == .orderedSame)
        }
        let band = exactBand ?? searchResults.first { $0.type == "b" }
        let matchingRelease = searchResults.first {
            ($0.type == "a" || $0.type == "t") &&
                $0.artist.caseInsensitiveCompare(subscription.value) == .orderedSame
        }
        let title = band?.title ?? subscription.value
        let url = band?.openURL
            ?? matchingRelease.flatMap { artistRootURL(from: $0.openURL) }
            ?? artistSearchURL(subscription.value)
        return BandcampResult(
            id: "subscription-\(subscription.id.uuidString)",
            title: title,
            artist: "Subscribed artist",
            url: url,
            type: "b",
            bandID: band?.bandID ?? matchingRelease?.bandID,
            artworkURL: band?.artworkURL ?? matchingRelease?.artworkURL
        )
    }

    private nonisolated static func artistRootURL(from releaseURL: URL) -> URL? {
        guard var components = URLComponents(url: releaseURL, resolvingAgainstBaseURL: false),
              components.host?.contains("bandcamp.com") == true else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private nonisolated static func artistSearchURL(_ artist: String) -> URL {
        var components = URLComponents(string: "https://bandcamp.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: artist)]
        return components?.url ?? URL(string: "https://bandcamp.com")!
    }

    private func refreshAuthentication() async {
        guard let session = authSession, session.needsRefresh else { return }
        do {
            let refreshed = try await authClient.refresh(session)
            authSession = refreshed
            BandcampKeychain.writeSession(refreshed)
            isAuthenticated = true
            authError = nil
            authStatusMessage = accountEmail.isEmpty ? "Connected" : "Connected as \(accountEmail)"
        } catch {
            authError = "Bandcamp session refresh failed: \(error.localizedDescription)"
        }
    }

    private func validAccessToken() async throws -> String {
        guard var session = authSession else { throw BandcampAuthError.serverMessage("Connect Bandcamp in Settings first.") }
        if session.needsRefresh {
            session = try await authClient.refresh(session)
            authSession = session
            BandcampKeychain.writeSession(session)
        }
        return session.accessToken
    }

    private func detailsWithAuthenticatedStreams(_ details: BandcampAlbumDetails) async -> BandcampAlbumDetails {
        guard isAuthenticated else { return details }
        do {
            let accessToken = try await validAccessToken()
            let urls = try await authClient.ownedStreamURLs(
                trackIDs: details.tracks.map(\.id),
                accessToken: accessToken
            )
            guard !urls.isEmpty else { return details }
            let tracks = details.tracks.map { track in
                guard let streamURL = urls[track.id] else { return track }
                return BandcampTrackDetails(
                    id: track.id,
                    number: track.number,
                    title: track.title,
                    duration: track.duration,
                    isStreamable: true,
                    pageURL: track.pageURL,
                    lyrics: track.lyrics,
                    streamURL: streamURL
                )
            }
            return BandcampAlbumDetails(
                id: details.id,
                bandID: details.bandID,
                type: details.type,
                title: details.title,
                artist: details.artist,
                artworkURL: details.artworkURL,
                tracks: tracks
            )
        } catch {
            authError = error.localizedDescription
            return details
        }
    }

    private func persistSubscriptions() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        defaults.set(data, forKey: subscriptionsKey)
    }

    private func persistSavedResults() {
        guard let data = try? JSONEncoder().encode(savedResults) else { return }
        defaults.set(data, forKey: savedResultsKey)
    }

    private func deduplicated(_ values: [BandcampResult]) -> [BandcampResult] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func cachedStreamURL(
        for details: BandcampAlbumDetails,
        track: BandcampTrackDetails,
        source: URL
    ) async throws -> URL {
        try cache.prepareDirectory()
        let extensionName = source.pathExtension.isEmpty ? "mp3" : source.pathExtension
        let destination = cache.directory.appendingPathComponent("\(details.bandID)-\(details.id)-\(track.id).\(extensionName)")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let (temporaryURL, response) = try await URLSession.shared.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UziqError.metadata("Bandcamp returned an HTTP error while loading the stream.")
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        refreshCacheStats()
        return destination
    }

    private func makeTrack(
        _ track: BandcampTrackDetails,
        details: BandcampAlbumDetails,
        localURL: URL,
        artworkData: Data?,
        sourceResult: BandcampResult
    ) -> Track {
        let localTrack = Track(
            id: "bandcamp-\(details.bandID)-\(track.id)",
            url: localURL,
            fileName: localURL.lastPathComponent,
            title: track.title,
            artist: details.artist,
            albumArtist: details.artist,
            album: details.title,
            genre: "",
            year: "",
            trackNumber: track.number,
            discNumber: nil,
            duration: track.duration,
            codec: "mp3",
            bitrate: 128,
            sampleRate: nil,
            artworkData: artworkData,
            lyrics: track.lyrics,
            musicBrainzRecordingID: nil,
            musicBrainzReleaseID: nil,
            acoustID: nil,
            addedAt: .now,
            modifiedAt: .now,
            isFavorite: false,
            playCount: 0
        )
        playbackResultsByTrackID[localTrack.id] = BandcampResult(
            id: "t-\(details.bandID)-\(track.id)",
            title: track.title,
            artist: details.artist,
            url: track.pageURL ?? sourceResult.openURL,
            type: "t",
            bandID: details.bandID,
            tralbumID: track.id,
            artworkURL: details.artworkURL ?? sourceResult.artworkURL
        )
        cachedURLsByTrackID[localTrack.id] = localURL
        return localTrack
    }

    private func markCachedTrackUsed(_ trackID: String) {
        guard let url = cachedURLsByTrackID[trackID] else { return }
        let cache = cache
        Task.detached(priority: .utility) {
            try? cache.markUsed(url)
        }
    }

    private func performCacheMaintenance(reportResult: Bool) {
        guard !isCleaningCache else { return }
        isCleaningCache = true
        if reportResult { cacheMessage = nil }
        let cache = cache
        Task { [weak self] in
            do {
                let cutoff = Date.now.addingTimeInterval(-BandcampCacheManager.retentionInterval)
                let (removed, stats) = try await Task.detached(priority: .utility) {
                    let removed = try cache.removeFilesNotUsed(since: cutoff)
                    return (removed, try cache.stats())
                }.value
                guard let self else { return }
                cacheBytes = stats.totalBytes
                cachedFileCount = stats.fileCount
                if reportResult {
                    cacheMessage = removed == 0
                        ? "No unused cache files were old enough to remove."
                        : "Removed \(removed) cached \(removed == 1 ? "file" : "files")."
                }
            } catch {
                guard let self else { return }
                if reportResult { cacheMessage = "Cache cleanup failed: \(error.localizedDescription)" }
            }
            self?.isCleaningCache = false
        }
    }

    private func downloadArtwork(from url: URL?) async -> Data? {
        await RemoteArtworkCache.shared.data(for: url)
    }
}
