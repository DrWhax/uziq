import Foundation
import Observation
import SwiftUI

private struct ArtworkCandidate: Sendable {
    let attemptKey: String
    let artist: String
    let album: String
    let releaseID: String?
    let existingArtwork: Data?
    let trackIDs: [String]
}

@MainActor
@Observable
final class LibraryStore {
    var tracks: [Track] = []
    var searchText = ""
    var selectedSection: LibrarySection = .library
    var mostPlayedRange: MostPlayedRange = .week
    var listeningHistoryRange: MostPlayedRange = .week
    var isScanning = false
    var scanProgress: ScanProgress?
    var scanMessage: String?
    var isEnrichingArtwork = false
    var artworkProgress: ArtworkProgress?
    var artistArtwork: [String: Data] = [:]
    private(set) var browseSnapshot = LocalLibraryBrowseSnapshot.empty
    private(set) var isPreparingBrowseSnapshot = false
    var artistProfiles: [String: ArtistProfile] = [:]
    var artistProfilesLoading: Set<String> = []
    var isEnrichingArtistArtwork = false
    var artistArtworkProgress: ArtistArtworkProgress?
    var lastError: String?
    var showingFolderImporter = false
    var folderRoots: [URL] = []
    private(set) var folderWatchingEnabled = UserDefaults.standard.object(forKey: "folder-watching-enabled") == nil
        || UserDefaults.standard.bool(forKey: "folder-watching-enabled")
    private(set) var isFolderWatching = false
    private(set) var isApplyingFolderChanges = false
    private(set) var folderWatchMessage: String?
    var matchingTrackID: String?
    var playlists: [PlaylistSummary] = []
    private(set) var smartPlaylists: [SmartPlaylistSummary] = []
    var favoriteTrackIDs: Set<String> = []
    private(set) var recentlyPlayedArtists: [RecentArtistPlay] = []
    private(set) var recentListeningHistory: [ListeningHistoryItem] = []
    private(set) var mostPlayedListeningHistory: [ListeningHistoryItem] = []
    private(set) var smartMixes: [SmartMix] = []
    private(set) var isInitialLoadComplete = false

    @ObservationIgnored private let database = LibraryDatabase()
    @ObservationIgnored private let scanner = LibraryScanner()
    @ObservationIgnored private let bookmarks = BookmarkStore()
    @ObservationIgnored private let folderWatcher = FolderWatcher()
    @ObservationIgnored private let matcher = MetadataMatcher(fingerprintProvider: FpcalcFingerprintProvider())
    @ObservationIgnored private let lyricsClient = LRCLIBClient()
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artistArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var browseGroupingTask: Task<Void, Never>?
    @ObservationIgnored private var browseGroupingGeneration = UUID()
    @ObservationIgnored private var normalizedArtistArtwork: [String: Data] = [:]
    @ObservationIgnored private var playObserver: NSObjectProtocol?
    @ObservationIgnored private var lyricsLookupTasks: [String: Task<LocalLyricsLookupResult, Never>] = [:]
    @ObservationIgnored private var folderWatchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var folderReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChangedRoots = Set<URL>()
    @ObservationIgnored private var folderWatchGeneration = UUID()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init() {
        folderRoots = bookmarks.resolvedURLs()
        playObserver = NotificationCenter.default.addObserver(
            forName: .uziqTrackPlayed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let trackID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let recorded = try await self.database.recordPlay(trackID: trackID)
                    if recorded {
                        await self.refresh()
                        await self.loadRecentlyPlayedArtists()
                        await self.loadSmartPlaylists()
                    }
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
        }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .uziqDidWake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureFolderWatcher(reconcileOnStart: true)
            }
        }
        Task {
            await refresh()
            await loadRecentlyPlayedArtists()
            await loadListeningHistory()
            await loadFavoriteTrackIDs()
            await loadPlaylists()
            await loadSmartPlaylists()
            await loadArtistArtwork()
            await loadArtistProfiles()
            isInitialLoadComplete = true
            configureFolderWatcher(reconcileOnStart: true)
            // Let SwiftUI finish installing its List/NSTableView hierarchy before
            // enrichment starts publishing progress changes beneath the table.
            try? await Task.sleep(for: .milliseconds(150))
            startArtworkEnrichment()
            startArtistArtworkEnrichment()
        }
    }

    deinit {
        folderWatcher.stop()
        folderWatchDebounceTask?.cancel()
        folderReconciliationTask?.cancel()
        browseGroupingTask?.cancel()
        lyricsLookupTasks.values.forEach { $0.cancel() }
        if let playObserver { NotificationCenter.default.removeObserver(playObserver) }
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
    }

    func remoteLyrics(for track: Track) async -> LocalLyricsLookupResult {
        let query = LRCLIBQuery(track: track)
        guard query.isUsable else { return .notFound }
        let key = query.cacheKey
        if let cached = try? await database.fetchCachedLyrics(key: key),
           cached.lyrics != nil || cached.isInstrumental || cached.fetchedAt > Date.now.addingTimeInterval(-30 * 24 * 60 * 60) {
            if let lyrics = cached.lyrics {
                return .lyrics(LyricsPayload(plain: lyrics, synced: cached.syncedLyrics))
            }
            return cached.isInstrumental ? .instrumental : .notFound
        }
        if let task = lyricsLookupTasks[key] { return await task.value }

        let database = database
        let client = lyricsClient
        let task = Task<LocalLyricsLookupResult, Never> {
            do {
                let lookup = try await client.lookup(query)
                try? await database.cacheLyrics(key: key, result: lookup)
                switch lookup {
                case .lyrics(let value): return .lyrics(value)
                case .instrumental: return .instrumental
                case .notFound: return .notFound
                }
            } catch is CancellationError {
                return .unavailable("Lyrics lookup was cancelled.")
            } catch let error as LRCLIBError {
                if case .rateLimited = error {
                    return .unavailable("LRCLIB is temporarily rate limiting requests. Try again later.")
                }
                return .unavailable("LRCLIB lyrics are temporarily unavailable.")
            } catch {
                return .unavailable("LRCLIB lyrics could not be loaded right now.")
            }
        }
        lyricsLookupTasks[key] = task
        let result = await task.value
        lyricsLookupTasks[key] = nil
        return result
    }

    @discardableResult
    func applyMetadataOverrides(trackIDs: [String], changes: MetadataOverrideChanges) async -> Bool {
        do {
            try await database.applyMetadataOverrides(trackIDs: trackIDs, changes: changes)
            await refresh()
            await loadSmartPlaylists()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearMetadataOverrides(trackIDs: [String]) async -> Bool {
        do {
            try await database.clearMetadataOverrides(trackIDs: trackIDs)
            await refresh()
            await loadSmartPlaylists()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func overrideArtistArtwork(artist: String, artworkData: Data) async -> Bool {
        do {
            try await database.updateArtistArtwork(artist: artist, artworkData: artworkData)
            artistArtwork[artist] = artworkData
            normalizedArtistArtwork[Self.normalizedArtistName(artist)] = artworkData
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearArtistArtworkOverride(artist: String) async -> Bool {
        do {
            try await database.removeArtistArtwork(artist: artist)
            artistArtwork[artist] = nil
            normalizedArtistArtwork[Self.normalizedArtistName(artist)] = nil
            startArtistArtworkEnrichment(forceRetry: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    var displayedTracks: [Track] {
        switch selectedSection {
        case .recentlyAdded:
            return Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(100))
        case .artists, .albums, .genres, .playlists, .history, .mostPlayed, .bandcamp, .spotify, .jellyfin, .library, .settings:
            return tracks
        }
    }

    func presentFolderImporter() { showingFolderImporter = true }

    func importFolders(_ urls: [URL]) {
        for url in urls {
            let normalizedURL = url.standardizedFileURL
            bookmarks.add(normalizedURL)
            if !folderRoots.contains(normalizedURL) { folderRoots.append(normalizedURL) }
        }
        configureFolderWatcher(reconcileOnStart: false)
        scan()
    }

    func removeFolder(_ url: URL) {
        bookmarks.remove(url)
        folderRoots.removeAll { $0 == url }
        configureFolderWatcher(reconcileOnStart: false)
    }

    func setFolderWatchingEnabled(_ enabled: Bool) {
        guard folderWatchingEnabled != enabled else { return }
        folderWatchingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "folder-watching-enabled")
        configureFolderWatcher(reconcileOnStart: enabled)
    }

    func scan() {
        guard !isScanning else { return }
        guard !folderRoots.isEmpty else {
            scanMessage = tracks.isEmpty
                ? "No library folders added"
                : "The existing index has no active folder access. Re-add its parent music folders in Settings."
            return
        }
        // A manual rescan is authoritative for every root. Cancel any pending
        // incremental pass so metadata is never read twice in parallel.
        folderWatchDebounceTask?.cancel()
        folderWatchDebounceTask = nil
        folderReconciliationTask?.cancel()
        folderReconciliationTask = nil
        pendingChangedRoots.removeAll()
        isApplyingFolderChanges = false
        isScanning = true
        lastError = nil
        scanMessage = "Starting library rescan…"
        let roots = folderRoots
        Task {
            let discovered = await scanner.scan(roots: roots) { [weak self] progress in
                Task { @MainActor in self?.scanProgress = progress }
            }
            do {
                try await database.upsertBatch(discovered)
                let removedPaths = try await database.removeMissingFiles()
                notifyPlaybackOfRemovedFiles(removedPaths)
                await refresh()
                await loadSmartPlaylists()
                scanMessage = "Indexed \(discovered.count) audio files"
            } catch {
                lastError = error.localizedDescription
                scanMessage = "Rescan failed"
            }
            scanProgress = nil
            isScanning = false
            processPendingFolderChangesIfNeeded()
            if lastError == nil {
                startArtworkEnrichment()
                startArtistArtworkEnrichment()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.isScanning == false { self?.scanMessage = nil }
            }
        }
    }

    private func configureFolderWatcher(reconcileOnStart: Bool) {
        folderWatchGeneration = UUID()
        folderWatchDebounceTask?.cancel()
        folderWatchDebounceTask = nil
        folderReconciliationTask?.cancel()
        folderReconciliationTask = nil
        pendingChangedRoots.removeAll()
        folderWatcher.stop()
        isFolderWatching = false
        isApplyingFolderChanges = false

        guard folderWatchingEnabled else {
            folderWatchMessage = "Automatic folder updates are off"
            return
        }
        let roots = FolderWatcher.minimalRoots(folderRoots)
        guard !roots.isEmpty else {
            folderWatchMessage = "Add a library folder to enable automatic updates"
            return
        }

        let started = folderWatcher.start(roots: roots) { [weak self] changedRoots in
            Task { @MainActor [weak self] in
                self?.queueFolderChanges(changedRoots)
            }
        }
        isFolderWatching = started
        folderWatchMessage = started
            ? "Watching \(roots.count) library folder\(roots.count == 1 ? "" : "s")"
            : "Folder watching could not be started"
        if started, reconcileOnStart {
            queueFolderChanges(roots, delay: .milliseconds(500))
        }
    }

    private func queueFolderChanges(_ roots: [URL], delay: Duration = .seconds(2)) {
        let activeRoots = Set(FolderWatcher.minimalRoots(folderRoots))
        pendingChangedRoots.formUnion(roots.filter { activeRoots.contains($0.standardizedFileURL) })
        guard !pendingChangedRoots.isEmpty else { return }
        folderWatchDebounceTask?.cancel()
        folderWatchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.processPendingFolderChangesIfNeeded()
        }
    }

    private func processPendingFolderChangesIfNeeded() {
        guard folderWatchingEnabled, isFolderWatching, !pendingChangedRoots.isEmpty else { return }
        guard !isScanning, folderReconciliationTask == nil else {
            queueFolderChanges(Array(pendingChangedRoots))
            return
        }

        let roots = pendingChangedRoots.sorted { $0.path < $1.path }
        pendingChangedRoots.removeAll()
        let generation = folderWatchGeneration
        isApplyingFolderChanges = true
        folderWatchMessage = "Checking library folder changes…"
        folderReconciliationTask = Task { [weak self] in
            guard let self else { return }
            var changedCount = 0
            var removedCount = 0
            var inaccessibleRoots: [URL] = []
            do {
                for root in roots {
                    try Task.checkCancellation()
                    let indexed = try await database.indexedFiles(under: root)
                    guard let reconciliation = await scanner.reconcile(root: root, indexedFiles: indexed) else {
                        inaccessibleRoots.append(root)
                        continue
                    }
                    try Task.checkCancellation()
                    try await database.applyReconciliation(reconciliation)
                    notifyPlaybackOfRemovedFiles(reconciliation.removedPaths)
                    changedCount += reconciliation.changedMetadata.count
                    removedCount += reconciliation.removedPaths.count
                }
                if changedCount > 0 || removedCount > 0 {
                    await refresh()
                    await loadSmartPlaylists()
                }
                guard folderWatchGeneration == generation, !Task.isCancelled else { return }
                if changedCount > 0 || removedCount > 0 {
                    await loadFavoriteTrackIDs()
                    await loadPlaylists()
                    startArtworkEnrichment()
                    startArtistArtworkEnrichment()
                    folderWatchMessage = "Library updated: \(changedCount) changed, \(removedCount) removed"
                } else if let inaccessible = inaccessibleRoots.first {
                    folderWatchMessage = "Waiting for \(inaccessible.lastPathComponent) to become available"
                } else {
                    let rootCount = FolderWatcher.minimalRoots(folderRoots).count
                    folderWatchMessage = "Watching \(rootCount) library folder\(rootCount == 1 ? "" : "s")"
                }
            } catch is CancellationError {
                if changedCount > 0 || removedCount > 0 {
                    await refresh()
                    await loadSmartPlaylists()
                }
                return
            } catch {
                guard folderWatchGeneration == generation else { return }
                lastError = error.localizedDescription
                folderWatchMessage = "Automatic library update failed"
            }
            guard folderWatchGeneration == generation else { return }
            isApplyingFolderChanges = false
            folderReconciliationTask = nil
            processPendingFolderChangesIfNeeded()
        }
    }

    private func notifyPlaybackOfRemovedFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NotificationCenter.default.post(
            name: .uziqLibraryFilesRemoved,
            object: Set(paths)
        )
    }

    private func startArtworkEnrichment() {
        guard artworkTask == nil, !isScanning else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            // Reuse the current snapshot so embedded artwork buffers stay shared. A fresh
            // database fetch can otherwise duplicate the entire artwork payload in memory.
            let allTracks = tracks
            let retryCutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
            let recentAttempts = (try? await database.recentlyAttemptedAlbumArtwork(since: retryCutoff)) ?? []
            let candidates = Self.artworkCandidates(from: allTracks).filter {
                $0.existingArtwork != nil || !recentAttempts.contains($0.attemptKey)
            }
            guard !candidates.isEmpty else {
                artworkTask = nil
                return
            }

            isEnrichingArtwork = true
            artworkProgress = ArtworkProgress(completed: 0, total: candidates.count, currentAlbum: "Preparing…")
            defer {
                isEnrichingArtwork = false
                artworkProgress = nil
                artworkTask = nil
            }

            var updatesSinceRefresh = 0
            for (index, candidate) in candidates.enumerated() {
                guard !Task.isCancelled else { return }
                artworkProgress = ArtworkProgress(
                    completed: index,
                    total: candidates.count,
                    currentAlbum: "\(candidate.artist) — \(candidate.album)"
                )
                let artwork: Data?
                if let existingArtwork = candidate.existingArtwork {
                    artwork = existingArtwork
                } else {
                    let session = Self.makeEnrichmentSession()
                    let artworkEnricher = AlbumArtworkEnricher(session: session)
                    artwork = await artworkEnricher.artwork(
                        artist: candidate.artist,
                        album: candidate.album,
                        releaseID: candidate.releaseID
                    )
                    session.finishTasksAndInvalidate()
                    try? await database.recordAlbumArtworkAttempt(key: candidate.attemptKey)
                }
                if let artwork {
                    try? await database.updateArtwork(trackIDs: candidate.trackIDs, artworkData: artwork)
                    updatesSinceRefresh += 1
                    if updatesSinceRefresh >= 12 {
                        await refresh()
                        updatesSinceRefresh = 0
                    }
                }
                artworkProgress = ArtworkProgress(
                    completed: index + 1,
                    total: candidates.count,
                    currentAlbum: "\(candidate.artist) — \(candidate.album)"
                )
            }
            if updatesSinceRefresh > 0 { await refresh() }
        }
    }

    private func startArtistArtworkEnrichment(forceRetry: Bool = false) {
        guard artistArtworkTask == nil, !isScanning, !lastFMAPIKey.isEmpty else { return }
        artistArtworkTask = Task { [weak self] in
            guard let self else { return }
            // The store already owns a complete snapshot; avoid loading every artwork BLOB
            // again merely to derive the list of artists.
            let allTracks = tracks
            let artists = Array(Set(allTracks.map(\.displayArtist)
                .filter { !$0.isEmpty && $0 != "Unknown Artist" })).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            let retryCutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
            let recentAttempts = forceRetry
                ? Set<String>()
                : ((try? await database.recentlyAttemptedArtistArtwork(since: retryCutoff)) ?? [])
            let missingArtists = artists.filter {
                self.artistArtwork[$0] == nil && !recentAttempts.contains($0)
            }
            guard !missingArtists.isEmpty else {
                artistArtworkTask = nil
                return
            }

            isEnrichingArtistArtwork = true
            artistArtworkProgress = ArtistArtworkProgress(completed: 0, total: missingArtists.count, currentArtist: "Preparing…")
            defer {
                isEnrichingArtistArtwork = false
                artistArtworkProgress = nil
                artistArtworkTask = nil
            }

            let batchSize = 20
            for batchStart in stride(from: 0, to: missingArtists.count, by: batchSize) {
                guard !Task.isCancelled else { return }
                let session = Self.makeEnrichmentSession()
                let client = LastFMClient(apiKey: lastFMAPIKey, session: session)
                let batchEnd = min(batchStart + batchSize, missingArtists.count)
                for index in batchStart..<batchEnd {
                    guard !Task.isCancelled else {
                        session.invalidateAndCancel()
                        return
                    }
                    let artist = missingArtists[index]
                    artistArtworkProgress = ArtistArtworkProgress(
                        completed: index,
                        total: missingArtists.count,
                        currentArtist: artist
                    )
                    if let artwork = await client.artistImage(for: artist) {
                        try? await database.updateArtistArtwork(artist: artist, artworkData: artwork)
                        artistArtwork[artist] = artwork
                        normalizedArtistArtwork[Self.normalizedArtistName(artist)] = artwork
                    }
                    try? await database.recordArtistArtworkAttempt(artist: artist)
                    artistArtworkProgress = ArtistArtworkProgress(
                        completed: index + 1,
                        total: missingArtists.count,
                        currentArtist: artist
                    )
                }
                session.finishTasksAndInvalidate()
            }
        }
    }

    private static func artworkCandidates(from tracks: [Track]) -> [ArtworkCandidate] {
        let eligible = tracks.filter { track in
            !track.album.isEmpty && (!track.albumArtist.isEmpty || !track.artist.isEmpty)
        }
        let knownAlbumsByArtist = Dictionary(grouping: eligible, by: albumGroupingArtist)
            .mapValues { Set($0.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) }
        let grouped = Dictionary(grouping: eligible) { track in
            albumGroupingKey(for: track, knownAlbums: knownAlbumsByArtist[albumGroupingArtist(track)] ?? [])
        }
        return grouped.compactMap { attemptKey, tracks in
            let missingTracks = tracks.filter { $0.artworkData == nil }
            guard let first = tracks.first, !missingTracks.isEmpty else { return nil }
            let displayAlbum = tracks
                .map(\.album)
                .first { $0.localizedStandardContains(" / ") } ?? first.album
            return ArtworkCandidate(
                attemptKey: attemptKey,
                artist: albumGroupingArtist(first),
                album: displayAlbum,
                releaseID: tracks.compactMap(\.musicBrainzReleaseID).first,
                existingArtwork: tracks.compactMap(\.artworkData).first,
                trackIDs: missingTracks.map(\.id)
            )
        }
        .sorted {
            let lhs = "\($0.artist)\u{1F}\($0.album)"
            let rhs = "\($1.artist)\u{1F}\($1.album)"
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    func refresh() async {
        do {
            let refreshedTracks = try await database.fetchTracks(
                search: searchText,
                recentlyAdded: selectedSection == .recentlyAdded,
                favoritesOnly: false,
                mostPlayedSince: selectedSection == .mostPlayed ? mostPlayedRange.startDate : nil
            )
            tracks = refreshedTracks
            prepareBrowseSnapshot(from: refreshedTracks)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func prepareBrowseSnapshot(from tracks: [Track]) {
        browseGroupingTask?.cancel()
        let generation = UUID()
        browseGroupingGeneration = generation
        if browseSnapshot.albums.isEmpty && !tracks.isEmpty {
            isPreparingBrowseSnapshot = true
        }
        let snapshot = tracks
        browseGroupingTask = Task { [weak self] in
            let grouped = await Task.detached(priority: .userInitiated) {
                LocalLibraryBrowseSnapshot.grouped(snapshot)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.browseGroupingGeneration == generation else { return }
            self.browseSnapshot = grouped
            self.isPreparingBrowseSnapshot = false
            self.browseGroupingTask = nil
        }
    }

    func loadArtistArtwork() async {
        do {
            artistArtwork = try await database.fetchArtistArtwork().filter {
                !LastFMClient.isPlaceholderImage($0.value)
            }
            normalizedArtistArtwork = Dictionary(
                artistArtwork.map { (Self.normalizedArtistName($0.key), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadRecentlyPlayedArtists() async {
        do {
            recentlyPlayedArtists = try await database.fetchRecentlyPlayedArtists(
                since: Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func recordListening(_ event: ListeningHistoryEvent) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await database.recordListeningHistory(event)
                await loadListeningHistory()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func loadListeningHistory() async {
        do {
            async let recentRequest = database.fetchRecentListeningHistory(limit: 60)
            async let mostPlayedRequest = database.fetchMostPlayedListeningHistory(
                since: listeningHistoryRange.startDate
            )
            async let rediscoveryRequest = database.fetchRediscoveryListeningHistory(
                notPlayedSince: Date.now.addingTimeInterval(-45 * 24 * 60 * 60),
                limit: 60
            )
            let (recent, mostPlayed, rediscovery) = try await (
                recentRequest,
                mostPlayedRequest,
                rediscoveryRequest
            )
            recentListeningHistory = recent
            mostPlayedListeningHistory = mostPlayed
            smartMixes = Self.makeSmartMixes(
                recent: recent,
                mostPlayed: mostPlayed,
                rediscovery: rediscovery
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func makeSmartMixes(
        recent: [ListeningHistoryItem],
        mostPlayed: [ListeningHistoryItem],
        rediscovery: [ListeningHistoryItem]
    ) -> [SmartMix] {
        var mixes: [SmartMix] = []
        if !mostPlayed.isEmpty {
            mixes.append(SmartMix(
                kind: .rotation,
                title: "Heavy Rotation",
                subtitle: "The tracks you keep coming back to",
                items: Array(mostPlayed.prefix(50))
            ))
        }
        if !rediscovery.isEmpty {
            mixes.append(SmartMix(
                kind: .rediscover,
                title: "Rediscover",
                subtitle: "Old favorites absent for at least 45 days",
                items: Array(rediscovery.prefix(50))
            ))
        }

        let grouped = Dictionary(grouping: recent, by: \.source)
        var blended: [ListeningHistoryItem] = []
        for offset in 0..<15 {
            for source in PlaybackSource.allCases {
                guard let candidates = grouped[source], candidates.indices.contains(offset) else { continue }
                blended.append(candidates[offset])
            }
        }
        if Set(blended.map(\.source)).count > 1 {
            mixes.append(SmartMix(
                kind: .acrossUziq,
                title: "Across Uziq",
                subtitle: "A round-robin mix of your connected sources",
                items: blended
            ))
        }
        return mixes
    }

    func artistGroup(named name: String) -> ArtistGroup? {
        let normalized = Self.normalizedArtistName(name)
        return browseSnapshot.artists.first {
            Self.normalizedArtistName($0.name) == normalized
        }
    }

    func loadArtistProfiles() async {
        do {
            artistProfiles = try await database.fetchArtistProfiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshArtistArtworkIfNeeded() {
        guard !lastFMAPIKey.isEmpty else { return }
        startArtistArtworkEnrichment()
    }

    func artistArtworkData(for artist: String) -> Data? {
        if let artwork = artistArtwork[artist] { return artwork }
        return normalizedArtistArtwork[Self.normalizedArtistName(artist)]
    }

    private nonisolated static func normalizedArtistName(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func fetchArtistArtwork() {
        guard !lastFMAPIKey.isEmpty else {
            lastError = "Add a Last.fm API key in Settings first."
            return
        }
        startArtistArtworkEnrichment(forceRetry: true)
    }

    private nonisolated static func makeEnrichmentSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    func loadArtistProfile(for artist: String) {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedArtist.isEmpty,
              artistProfiles[normalizedArtist] == nil,
              !artistProfilesLoading.contains(normalizedArtist) else { return }

        artistProfilesLoading.insert(normalizedArtist)
        let lastFMAPIKey = self.lastFMAPIKey
        Task { [weak self] in
            guard let self else { return }
            let retryCutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
            let recentAttempts = (try? await database.recentlyAttemptedArtistProfiles(
                since: retryCutoff
            )) ?? []
            guard !recentAttempts.contains(normalizedArtist) else {
                artistProfilesLoading.remove(normalizedArtist)
                return
            }
            let lastFMProfile = await LastFMClient(apiKey: lastFMAPIKey).artistBiography(for: normalizedArtist)
            let profile: ArtistProfile?
            if let lastFMProfile {
                profile = ArtistProfile(summary: lastFMProfile, source: .lastFM)
            } else if let bandcampProfile = await BandcampClient().artistBiography(for: normalizedArtist) {
                profile = ArtistProfile(summary: bandcampProfile, source: .bandcamp)
            } else {
                profile = nil
            }

            if let profile {
                artistProfiles[normalizedArtist] = profile
                try? await database.updateArtistProfile(artist: normalizedArtist, profile: profile)
            }
            try? await database.recordArtistProfileAttempt(artist: normalizedArtist)
            artistProfilesLoading.remove(normalizedArtist)
        }
    }

    func clearError() { lastError = nil }

    func isFavorite(_ track: Track) -> Bool {
        favoriteTrackIDs.contains(track.id)
    }

    func toggleFavorite(_ track: Track) {
        if favoriteTrackIDs.contains(track.id) {
            favoriteTrackIDs.remove(track.id)
        } else {
            favoriteTrackIDs.insert(track.id)
        }
        Task {
            do {
                try await database.toggleFavorite(trackID: track.id)
                await refresh()
                await loadFavoriteTrackIDs()
                await loadSmartPlaylists()
            } catch {
                if favoriteTrackIDs.contains(track.id) {
                    favoriteTrackIDs.remove(track.id)
                } else {
                    favoriteTrackIDs.insert(track.id)
                }
                lastError = error.localizedDescription
            }
        }
    }

    private func loadFavoriteTrackIDs() async {
        do {
            favoriteTrackIDs = Set(try await database.fetchTracks(favoritesOnly: true).map(\.id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadPlaylists() async {
        do {
            playlists = try await database.fetchPlaylists()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadSmartPlaylists() async {
        do {
            smartPlaylists = try await database.fetchSmartPlaylists()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func createSmartPlaylist(
        name: String,
        configuration: SmartPlaylistConfiguration
    ) async -> SmartPlaylistSummary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, configuration.isValid else { return nil }
        do {
            let playlist = try await database.createSmartPlaylist(
                name: trimmed,
                configuration: configuration
            )
            await loadSmartPlaylists()
            return playlist
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateSmartPlaylist(
        _ playlist: SmartPlaylistSummary,
        name: String,
        configuration: SmartPlaylistConfiguration
    ) async -> SmartPlaylistSummary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, configuration.isValid else { return nil }
        do {
            let updated = try await database.updateSmartPlaylist(
                id: playlist.id,
                name: trimmed,
                configuration: configuration
            )
            await loadSmartPlaylists()
            return updated
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func deleteSmartPlaylist(_ playlist: SmartPlaylistSummary) async {
        do {
            try await database.deleteSmartPlaylist(id: playlist.id)
            await loadSmartPlaylists()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func smartPlaylistTracks(_ playlist: SmartPlaylistSummary) async -> [Track] {
        do {
            return try await database.fetchSmartPlaylistTracks(configuration: playlist.configuration)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func createPlaylist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await database.createPlaylist(name: trimmed)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func deletePlaylist(_ playlist: PlaylistSummary) {
        Task {
            do {
                try await database.deletePlaylist(id: playlist.id)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func playlistTracks(_ playlist: PlaylistSummary) async -> [Track] {
        do {
            return try await database.fetchPlaylistTracks(playlistID: playlist.id)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func add(_ track: Track, to playlist: PlaylistSummary) {
        Task {
            do {
                try await database.addTrack(trackID: track.id, toPlaylist: playlist.id)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func remove(_ track: Track, from playlist: PlaylistSummary) {
        Task {
            do {
                try await database.removeTrack(trackID: track.id, fromPlaylist: playlist.id)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    var acoustIDAPIKey: String {
        get { UserDefaults.standard.string(forKey: "acoustid-api-key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "acoustid-api-key") }
    }

    var lastFMAPIKey: String {
        get { UserDefaults.standard.string(forKey: "lastfm-api-key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastfm-api-key") }
    }

    func identify(_ track: Track) {
        guard matchingTrackID == nil else { return }
        matchingTrackID = track.id
        lastError = nil
        Task {
            do {
                guard let result = try await matcher.match(track: track, acoustIDKey: acoustIDAPIKey) else {
                    throw UziqError.metadata("AcoustID did not find a confident match for \(track.displayTitle).")
                }
                try await database.updateMatch(trackID: track.id, result: result)
                await refresh()
                await loadSmartPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
            matchingTrackID = nil
        }
    }
}
