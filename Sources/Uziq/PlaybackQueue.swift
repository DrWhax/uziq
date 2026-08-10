import Foundation
import Observation

private struct RandomPlaybackError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum PlaybackSource: String, Codable, CaseIterable, Sendable {
    case local
    case bandcamp
    case spotify
    case jellyfin

    var title: String {
        switch self {
        case .local: "Local Library"
        case .bandcamp: "Bandcamp"
        case .spotify: "Spotify"
        case .jellyfin: "Jellyfin"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "internaldrive"
        case .bandcamp: "dot.radiowaves.left.and.right"
        case .spotify: "music.note.house.fill"
        case .jellyfin: "server.rack"
        }
    }
}

enum PlaybackRepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one

    var systemImage: String { self == .one ? "repeat.1" : "repeat" }

    var title: String {
        switch self {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }
}

struct UnifiedQueueItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let source: PlaybackSource
    let sourceID: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let localURL: URL?
    let artworkURL: URL?
    let bandcampResult: BandcampResult?
    let spotifyItem: SpotifyCatalogItem?
    let jellyfinItem: JellyfinCatalogItem?

    init(local track: Track) {
        id = UUID()
        source = .local
        sourceID = track.id
        title = track.displayTitle
        artist = track.displayArtist
        album = track.displayAlbum
        duration = track.duration
        localURL = track.url
        artworkURL = nil
        bandcampResult = nil
        spotifyItem = nil
        jellyfinItem = nil
    }

    init(bandcamp result: BandcampResult) {
        id = UUID()
        source = .bandcamp
        sourceID = result.id
        title = result.title
        artist = result.artist
        album = result.type == "a" ? result.title : "Bandcamp"
        duration = 0
        localURL = nil
        artworkURL = result.artworkURL
        bandcampResult = result
        spotifyItem = nil
        jellyfinItem = nil
    }

    init(spotify item: SpotifyCatalogItem) {
        id = UUID()
        source = .spotify
        sourceID = item.id
        title = item.name
        artist = item.subtitle
        album = item.kind.title
        duration = Double(item.durationMS ?? 0) / 1_000
        localURL = nil
        artworkURL = item.artworkURL
        bandcampResult = nil
        spotifyItem = item
        jellyfinItem = nil
    }

    init(jellyfin item: JellyfinCatalogItem) {
        id = UUID()
        source = .jellyfin
        sourceID = item.id
        title = item.name
        artist = item.subtitle
        album = item.album
        duration = item.duration
        localURL = nil
        artworkURL = nil
        bandcampResult = nil
        spotifyItem = nil
        jellyfinItem = item
    }
}

private struct PlaybackSession: Codable {
    let items: [UnifiedQueueItem]
    let currentIndex: Int?
    let position: Double
    let shuffleEnabled: Bool
    let repeatMode: PlaybackRepeatMode
    let volume: Float
}

@MainActor
@Observable
final class PlaybackQueueStore {
    nonisolated static func shouldDelegateSpotifySequenceToHelper(
        currentItem: UnifiedQueueItem?,
        helperControlsPlaybackSequence: Bool
    ) -> Bool {
        guard helperControlsPlaybackSequence,
              currentItem?.source == .spotify else { return false }
        // Track lists (albums, search results, radio, and restored sessions)
        // are represented as individual queue items, so Uziq owns Next/Back.
        // Only an opaque album/playlist/artist context is advanced by librespot.
        return currentItem?.spotifyItem?.kind != .track
    }

    private(set) var items: [UnifiedQueueItem] = []
    private(set) var currentIndex: Int?
    var shuffleEnabled = false {
        didSet { if !isRestoringSession { persistSession() } }
    }
    var repeatMode: PlaybackRepeatMode = .off {
        didSet { if !isRestoringSession { persistSession() } }
    }
    private var volumeValue: Float = 1
    var volume: Float {
        get { volumeValue }
        set {
            let clamped = newValue.isFinite ? min(1, max(0, newValue)) : 1
            guard volumeValue != clamped else { return }
            volumeValue = clamped
            playback?.volume = clamped
            spotify?.setVolume(clamped)
            if !isRestoringSession { persistSession() }
        }
    }
    private(set) var restoredPosition = 0.0
    private(set) var error: String?
    private(set) var preparingRandomSource: PlaybackSource?

    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var playback: PlaybackEngine?
    @ObservationIgnored private weak var bandcamp: BandcampStore?
    @ObservationIgnored private weak var spotify: SpotifyStore?
    @ObservationIgnored private weak var jellyfin: JellyfinStore?
    @ObservationIgnored private var finishObserver: NSObjectProtocol?
    @ObservationIgnored private var toggleObserver: NSObjectProtocol?
    @ObservationIgnored private var persistTimer: Timer?
    @ObservationIgnored private var spotifyPlaybackSeen = false
    @ObservationIgnored private var jellyfinPrefetchedItemID: String?
    @ObservationIgnored private var lastPositionCheckpoint = Date.distantPast
    @ObservationIgnored private var isDispatching = false
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private let sessionURLOverride: URL?
    @ObservationIgnored private var nowPlayingController: NowPlayingController?
    @ObservationIgnored private var randomPlaybackTask: Task<Void, Never>?
    @ObservationIgnored private var randomPlaybackGeneration = UUID()

    init(sessionURL: URL? = nil) {
        sessionURLOverride = sessionURL
        restoreSession()
        finishObserver = NotificationCenter.default.addObserver(
            forName: .uziqPlaybackItemFinished,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceAfterCompletion() }
        }
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .uziqToggleQueuePlayback,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
        }
        persistTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.timerFired() }
        }
    }

    deinit {
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        persistTimer?.invalidate()
        randomPlaybackTask?.cancel()
    }

    var currentItem: UnifiedQueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var upcomingItems: ArraySlice<UnifiedQueueItem> {
        items[upcomingStartIndex...]
    }

    var hasPrevious: Bool { currentIndex.map { $0 > 0 } ?? false }
    var hasNext: Bool {
        guard let currentIndex else { return !items.isEmpty }
        return currentIndex + 1 < items.count || repeatMode == .all
    }

    func attach(
        library: LibraryStore,
        playback: PlaybackEngine,
        bandcamp: BandcampStore,
        spotify: SpotifyStore,
        jellyfin: JellyfinStore
    ) {
        self.library = library
        self.playback = playback
        self.bandcamp = bandcamp
        self.spotify = spotify
        self.jellyfin = jellyfin
        playback.volume = volume
        spotify.attachPlaybackEngine(playback)
        if nowPlayingController == nil {
            let controller = NowPlayingController()
            controller.configure(
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.toggle() },
                next: { [weak self] in self?.next() },
                previous: { [weak self] in self?.previous() },
                seek: { [weak self] in self?.seek(to: $0) }
            )
            nowPlayingController = controller
        }
        resolveRestoredSession()
        updateNowPlaying(force: true)
    }

    func replace(with tracks: [Track], startingAt track: Track) {
        guard !tracks.isEmpty else { return }
        cancelRandomPlayback()
        items = tracks.map(UnifiedQueueItem.init(local:))
        currentIndex = tracks.firstIndex(of: track) ?? 0
        restoredPosition = 0
        dispatchCurrent()
    }

    func replace(with result: BandcampResult) {
        cancelRandomPlayback()
        items = [UnifiedQueueItem(bandcamp: result)]
        currentIndex = 0
        restoredPosition = 0
        dispatchCurrent()
    }

    func replace(with item: SpotifyCatalogItem, context: [SpotifyCatalogItem]? = nil) {
        let playableContext = (context ?? [item]).filter { !$0.uri.isEmpty }
        guard !playableContext.isEmpty else { return }
        cancelRandomPlayback()
        items = playableContext.map(UnifiedQueueItem.init(spotify:))
        currentIndex = playableContext.firstIndex(of: item) ?? 0
        restoredPosition = 0
        dispatchCurrent()
    }

    func replace(with item: JellyfinCatalogItem, context: [JellyfinCatalogItem]? = nil) {
        let playableContext = (context ?? [item]).filter { $0.kind == .track }
        guard !playableContext.isEmpty else { return }
        cancelRandomPlayback()
        items = playableContext.map(UnifiedQueueItem.init(jellyfin:))
        currentIndex = playableContext.firstIndex(of: item) ?? 0
        restoredPosition = 0
        dispatchCurrent()
    }

    func play(_ item: UnifiedQueueItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        cancelRandomPlayback()
        currentIndex = index
        restoredPosition = 0
        dispatchCurrent()
    }

    func replay() {
        guard currentItem != nil else { return }
        restoredPosition = 0
        if currentItem?.source == .spotify {
            if spotify?.hasControllablePlayback == true {
                spotify?.seek(to: 0)
                spotify?.resume()
            } else {
                dispatchCurrent()
            }
        } else if playback?.currentTrack != nil {
            playback?.seek(to: 0)
            if playback?.isPlaying != true { playback?.toggle() }
        } else {
            dispatchCurrent()
        }
        persistSession()
        updateNowPlaying(force: true)
    }

    func playRandom(from source: PlaybackSource) {
        cancelRandomPlayback()
        let generation = UUID()
        randomPlaybackGeneration = generation
        preparingRandomSource = source
        error = nil
        randomPlaybackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await randomQueueItems(for: source)
                try Task.checkCancellation()
                guard randomPlaybackGeneration == generation else { return }
                guard !candidates.isEmpty else {
                    throw RandomPlaybackError(message: "No playable music is available in \(source.title).")
                }
                items = candidates
                currentIndex = 0
                restoredPosition = 0
                preparingRandomSource = nil
                randomPlaybackTask = nil
                dispatchCurrent()
            } catch is CancellationError {
                return
            } catch {
                guard randomPlaybackGeneration == generation else { return }
                self.error = error.localizedDescription
                preparingRandomSource = nil
                randomPlaybackTask = nil
            }
        }
    }

    func add(_ track: Track) { append(UnifiedQueueItem(local: track)) }
    func add(_ result: BandcampResult) { append(UnifiedQueueItem(bandcamp: result)) }
    func add(_ item: SpotifyCatalogItem) { append(UnifiedQueueItem(spotify: item)) }
    func add(_ item: JellyfinCatalogItem) { append(UnifiedQueueItem(jellyfin: item)) }

    func playNext(_ track: Track) { insertNext(UnifiedQueueItem(local: track)) }
    func playNext(_ result: BandcampResult) { insertNext(UnifiedQueueItem(bandcamp: result)) }
    func playNext(_ item: SpotifyCatalogItem) { insertNext(UnifiedQueueItem(spotify: item)) }
    func playNext(_ item: JellyfinCatalogItem) { insertNext(UnifiedQueueItem(jellyfin: item)) }

    func remove(at offsets: IndexSet) {
        cancelRandomPlayback()
        let oldCurrentID = currentItem?.id
        let oldSource = currentItem?.source
        let removedCurrent = currentIndex.map(offsets.contains) ?? false
        for index in offsets.sorted(by: >) where items.indices.contains(index) {
            items.remove(at: index)
        }
        if let oldCurrentID, let newIndex = items.firstIndex(where: { $0.id == oldCurrentID }) {
            currentIndex = newIndex
        } else if items.isEmpty {
            currentIndex = nil
        } else if let currentIndex {
            self.currentIndex = min(currentIndex, items.count - 1)
        }
        if removedCurrent {
            restoredPosition = 0
            if items.isEmpty {
                if oldSource == .spotify { spotify?.pause() } else { playback?.stop() }
            } else {
                dispatchCurrent()
            }
        }
        persistSession()
        updateNowPlaying(force: true)
    }

    func remove(_ item: UnifiedQueueItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        remove(at: IndexSet(integer: index))
    }

    func removeUpcoming(at offsets: IndexSet) {
        let start = upcomingStartIndex
        let mappedOffsets = IndexSet(offsets.compactMap { offset in
            let index = start + offset
            return items.indices.contains(index) ? index : nil
        })
        guard !mappedOffsets.isEmpty else { return }
        remove(at: mappedOffsets)
    }

    func move(from offsets: IndexSet, to destination: Int) {
        cancelRandomPlayback()
        let moving = offsets.sorted().map { items[$0] }
        let currentID = currentItem?.id
        for index in offsets.sorted(by: >) { items.remove(at: index) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = min(items.count, max(0, destination - removedBeforeDestination))
        items.insert(contentsOf: moving, at: insertion)
        currentIndex = currentID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        persistSession()
        updateNowPlaying(force: true)
    }

    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        let start = upcomingStartIndex
        let upcomingCount = items.count - start
        let mappedOffsets = IndexSet(offsets.compactMap { offset in
            guard offset >= 0, offset < upcomingCount else { return nil }
            return start + offset
        })
        guard !mappedOffsets.isEmpty else { return }
        move(
            from: mappedOffsets,
            to: start + min(upcomingCount, max(0, destination))
        )
    }

    func clearUpcoming() {
        cancelRandomPlayback()
        let start = upcomingStartIndex
        guard start < items.count else { return }
        items.removeSubrange(start...)
        persistSession()
        updateNowPlaying(force: true)
    }

    func clear() {
        cancelRandomPlayback()
        let source = currentItem?.source
        items = []
        currentIndex = nil
        restoredPosition = 0
        if source == .spotify { spotify?.pause() } else { playback?.stop() }
        persistSession()
        updateNowPlaying(force: true)
    }

    func clearError() { error = nil }

    func toggle() {
        guard let currentItem else {
            if !items.isEmpty {
                currentIndex = 0
                dispatchCurrent()
            }
            return
        }
        switch currentItem.source {
        case .spotify:
            if spotify?.hasControllablePlayback == true {
                spotify?.togglePlayback()
            } else {
                dispatchCurrent()
            }
        case .local, .bandcamp, .jellyfin:
            if playback?.currentTrack == nil { dispatchCurrent() } else { playback?.toggle() }
        }
        persistSession()
        updateNowPlaying(force: true)
    }

    func play() {
        if !isPlaying { toggle() }
    }

    func pause() {
        if currentItem?.source == .spotify,
           spotify?.hasControllablePlayback == true {
            spotify?.pause()
            persistSession()
            updateNowPlaying(force: true)
        } else if isPlaying {
            toggle()
        }
    }

    func next() {
        if Self.shouldDelegateSpotifySequenceToHelper(
            currentItem: currentItem,
            helperControlsPlaybackSequence: spotify?.helperControlsPlaybackSequence == true
        ) {
            if repeatMode == .one {
                seek(to: 0)
                spotify?.resume()
            } else {
                restoredPosition = 0
                spotify?.next()
                persistSession()
                updateNowPlaying(force: true)
            }
            return
        }
        guard !items.isEmpty else { return }
        if repeatMode == .one {
            restoredPosition = 0
            dispatchCurrent()
            return
        }
        if shuffleEnabled, items.count > 1 {
            var candidates = Array(items.indices)
            if let currentIndex { candidates.removeAll { $0 == currentIndex } }
            currentIndex = candidates.randomElement()
        } else if let currentIndex, currentIndex + 1 < items.count {
            self.currentIndex = currentIndex + 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            return
        }
        restoredPosition = 0
        dispatchCurrent()
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if Self.shouldDelegateSpotifySequenceToHelper(
            currentItem: currentItem,
            helperControlsPlaybackSequence: spotify?.helperControlsPlaybackSequence == true
        ) {
            restoredPosition = 0
            spotify?.previous()
            persistSession()
            updateNowPlaying(force: true)
            return
        }
        guard let currentIndex, currentIndex > 0 else {
            seek(to: 0)
            return
        }
        self.currentIndex = currentIndex - 1
        restoredPosition = 0
        dispatchCurrent()
    }

    func seek(to seconds: Double) {
        restoredPosition = max(0, seconds)
        if currentItem?.source == .spotify {
            spotify?.seek(to: restoredPosition)
        } else {
            playback?.seek(to: restoredPosition)
        }
        persistSession()
        updateNowPlaying(force: true)
    }

    var isPlaying: Bool {
        currentItem?.source == .spotify
            ? spotify?.isPlaying == true
            : playback?.isPlaying == true
    }

    var currentTime: Double {
        if currentItem?.source == .spotify {
            return spotify?.playback?.effectiveProgress(at: .now) ?? restoredPosition
        }
        return playback?.currentTrack == nil ? restoredPosition : playback?.currentTime ?? restoredPosition
    }

    var duration: Double {
        if currentItem?.source == .spotify {
            return spotify?.playback?.duration ?? currentItem?.duration ?? 0
        }
        return playback?.duration ?? currentItem?.duration ?? 0
    }

    func localTrack(for item: UnifiedQueueItem) -> Track? {
        guard item.source == .local else { return nil }
        return library?.tracks.first { $0.id == item.sourceID || $0.url == item.localURL }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateNowPlaying(force: true)
    }

    private func append(_ item: UnifiedQueueItem) {
        cancelRandomPlayback()
        items.append(item)
        if currentIndex == nil { currentIndex = 0 }
        persistSession()
        updateNowPlaying(force: true)
    }

    private var upcomingStartIndex: Int {
        guard let currentIndex, items.indices.contains(currentIndex) else { return 0 }
        return min(items.count, currentIndex + 1)
    }

    private func insertNext(_ item: UnifiedQueueItem) {
        cancelRandomPlayback()
        let index = min(items.count, (currentIndex ?? -1) + 1)
        items.insert(item, at: index)
        if currentIndex == nil { currentIndex = 0 }
        persistSession()
        updateNowPlaying(force: true)
    }

    private func randomQueueItems(for source: PlaybackSource) async throws -> [UnifiedQueueItem] {
        let limit = 100
        switch source {
        case .local:
            guard let library else {
                throw RandomPlaybackError(message: "The local library is not ready yet.")
            }
            let availableTracks = Array(
                library.tracks
                    .shuffled()
                    .lazy
                    .filter { FileManager.default.fileExists(atPath: $0.url.path) }
                    .prefix(limit)
            )
            return availableTracks.map(UnifiedQueueItem.init(local:))
        case .bandcamp:
            guard let bandcamp else {
                throw RandomPlaybackError(message: "Bandcamp is not ready yet.")
            }
            return bandcamp.ownedResults
                .filter(\.isPlayable)
                .shuffled()
                .prefix(limit)
                .map(UnifiedQueueItem.init(bandcamp:))
        case .spotify:
            guard let spotify else {
                throw RandomPlaybackError(message: "Spotify is not ready yet.")
            }
            return spotify.likedSongs
                .filter { $0.kind == .track && !$0.uri.isEmpty }
                .shuffled()
                .prefix(limit)
                .map(UnifiedQueueItem.init(spotify:))
        case .jellyfin:
            guard let jellyfin else {
                throw RandomPlaybackError(message: "Jellyfin is not ready yet.")
            }
            return try await jellyfin.randomTracks(limit: limit)
                .shuffled()
                .map(UnifiedQueueItem.init(jellyfin:))
        }
    }

    private func cancelRandomPlayback() {
        randomPlaybackGeneration = UUID()
        randomPlaybackTask?.cancel()
        randomPlaybackTask = nil
        preparingRandomSource = nil
    }

    private func dispatchCurrent() {
        guard !isDispatching, let item = currentItem else { return }
        isDispatching = true
        defer {
            isDispatching = false
            persistSession()
            updateNowPlaying(force: true)
        }
        error = nil
        spotifyPlaybackSeen = false
        jellyfinPrefetchedItemID = nil
        DiagnosticsLog.shared.record("playback", "Dispatching \(item.source.title) queue item")
        if item.source != .spotify {
            // Pause Spotify before local or externally cached audio begins.
            // Bandcamp and Jellyfin may prepare asynchronously, so waiting for
            // PlaybackEngine's start notification can leave two streams alive.
            spotify?.suppressForNonSpotifyPlayback()
        }
        switch item.source {
        case .local:
            bandcamp?.cancelPendingPlayback()
            jellyfin?.cancelPendingPlayback()
            guard let track = localTrack(for: item) else {
                error = "The local file for \(item.title) is no longer available."
                DispatchQueue.main.async { [weak self] in self?.next() }
                return
            }
            playback?.play(track)
            if restoredPosition > 0 { playback?.seek(to: restoredPosition) }
        case .bandcamp:
            jellyfin?.cancelPendingPlayback()
            guard let result = item.bandcampResult, let playback, let bandcamp else { return }
            bandcamp.play(result, using: playback) { [weak self] message in
                self?.error = "Bandcamp could not play \(item.title): \(message)"
            }
            seekWhenPlaybackStarts(itemID: item.id, seconds: restoredPosition)
        case .spotify:
            bandcamp?.cancelPendingPlayback()
            jellyfin?.cancelPendingPlayback()
            guard let spotifyItem = item.spotifyItem else { return }
            guard spotify?.isAuthorized == true || spotify?.librespot.supportsDirectControl == true else {
                error = "Reconnect Spotify before playing \(item.title)."
                return
            }
            spotify?.play(spotifyItem)
            seekSpotifyAfterStart(itemID: item.id, seconds: restoredPosition)
        case .jellyfin:
            bandcamp?.cancelPendingPlayback()
            guard let jellyfinItem = item.jellyfinItem, let playback, let jellyfin else { return }
            guard jellyfin.isConnected else {
                error = "Reconnect Jellyfin before playing \(item.title)."
                return
            }
            jellyfin.play(jellyfinItem, using: playback) { [weak self] message in
                self?.error = "Jellyfin could not play \(item.title): \(message)"
            }
            seekWhenPlaybackStarts(itemID: item.id, seconds: restoredPosition)
        }
    }

    private func advanceAfterCompletion() {
        guard !isDispatching else { return }
        next()
    }

    func resolveRestoredSession() {
        guard currentItem?.source == .local,
              let item = currentItem,
              playback?.currentTrack == nil,
              let track = localTrack(for: item) else { return }
        playback?.restore(track, at: restoredPosition)
        updateNowPlaying(force: true)
    }

    private func timerFired() {
        if currentItem?.source == .spotify,
           spotify?.librespot.isDirectPlaybackActive != true,
           let snapshot = spotify?.playback {
            if snapshot.itemID == currentItem?.sourceID {
                if spotifyPlaybackSeen,
                   (hasNext || repeatMode == .one),
                   Self.spotifyPlaybackReachedEnd(snapshot, at: .now) {
                    spotifyPlaybackSeen = false
                    advanceAfterCompletion()
                    return
                }
                spotifyPlaybackSeen = true
            } else if spotifyPlaybackSeen && snapshot.isPlaying {
                spotifyPlaybackSeen = false
                advanceAfterCompletion()
                return
            }
        }
        if currentItem?.source == .jellyfin,
           duration > 0,
           duration - currentTime <= 15,
           let nextItem = nextSequentialItem,
           let jellyfinItem = nextItem.jellyfinItem,
           jellyfinPrefetchedItemID != jellyfinItem.id {
            jellyfinPrefetchedItemID = jellyfinItem.id
            jellyfin?.prefetch(jellyfinItem)
        }
        // Structural queue changes persist immediately. During playback, a
        // 15-second crash-recovery checkpoint avoids repeatedly encoding and
        // atomically rewriting a potentially large queue.
        if isPlaying, Date.now.timeIntervalSince(lastPositionCheckpoint) >= 15 {
            persistSession()
        }
        updateNowPlaying()
    }

    private func updateNowPlaying(force: Bool = false) {
        guard let item = currentItem else {
            nowPlayingController?.update(nil)
            return
        }

        let activeTrack = item.source == .spotify ? nil : playback?.currentTrack
        let spotifySnapshot = item.source == .spotify ? spotify?.playback : nil
        let snapshot = NowPlayingSnapshot(
            itemID: item.id,
            sourceID: item.sourceID,
            source: item.source,
            title: spotifySnapshot?.title ?? activeTrack?.displayTitle ?? item.title,
            artist: spotifySnapshot?.artist ?? activeTrack?.displayArtist ?? item.artist,
            album: spotifySnapshot?.album ?? activeTrack?.displayAlbum ?? item.album,
            duration: max(0, duration.isFinite ? duration : 0),
            elapsed: max(0, currentTime.isFinite ? currentTime : 0),
            isPlaying: isPlaying,
            hasPrevious: hasPrevious,
            hasNext: hasNext,
            artworkData: activeTrack?.artworkData,
            artworkURL: spotifySnapshot?.artworkURL ?? item.artworkURL
        )
        nowPlayingController?.update(snapshot, force: force)
    }

    private var nextSequentialItem: UnifiedQueueItem? {
        guard let currentIndex else { return nil }
        if currentIndex + 1 < items.count { return items[currentIndex + 1] }
        if repeatMode == .all { return items.first }
        return nil
    }

    nonisolated static func spotifyPlaybackReachedEnd(
        _ snapshot: SpotifyPlaybackSnapshot,
        at date: Date
    ) -> Bool {
        guard snapshot.duration.isFinite, snapshot.duration > 0 else { return false }
        return snapshot.effectiveProgress(at: date) >= snapshot.duration - 0.05
    }

    private func seekWhenPlaybackStarts(itemID: UUID, seconds: Double) {
        guard seconds > 0 else { return }
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.currentItem?.id == itemID else { return }
                if self.playback?.currentTrack != nil {
                    self.playback?.seek(to: seconds)
                    return
                }
            }
        }
    }

    private func seekSpotifyAfterStart(itemID: UUID, seconds: Double) {
        guard seconds > 0 else { return }
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.currentItem?.id == itemID else { return }
                if self.spotify?.isUziqPlaybackActive == true {
                    self.spotify?.seek(to: seconds)
                    return
                }
            }
        }
    }

    private var sessionURL: URL {
        if let sessionURLOverride { return sessionURLOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uziq", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playback-session.json")
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(PlaybackSession.self, from: data) else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }
        items = session.items
        currentIndex = session.currentIndex.flatMap { session.items.indices.contains($0) ? $0 : nil }
        restoredPosition = max(0, session.position)
        shuffleEnabled = session.shuffleEnabled
        repeatMode = session.repeatMode
        volume = min(1, max(0, session.volume))
    }

    private func persistSession() {
        let session = PlaybackSession(
            items: items,
            currentIndex: currentIndex,
            position: currentTime,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            volume: volume
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        do {
            try data.write(to: sessionURL, options: .atomic)
            lastPositionCheckpoint = .now
        } catch {
            // Playback persistence is best-effort; playback itself must continue.
        }
    }
}
