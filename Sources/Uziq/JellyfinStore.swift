import Foundation
import JellyfinAPI
import Observation

@MainActor
@Observable
final class JellyfinStore {
    var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: "jellyfin-server-url") }
    }
    var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "jellyfin-username") }
    }
    var query = ""

    private(set) var session: JellyfinSession?
    private(set) var libraries: [JellyfinCatalogItem] = []
    private(set) var albums: [JellyfinCatalogItem] = []
    private(set) var artists: [JellyfinCatalogItem] = []
    private(set) var playlists: [JellyfinCatalogItem] = []
    private(set) var favoriteTracks: [JellyfinCatalogItem] = []
    private(set) var favoriteMutationIDs: Set<String> = []
    private(set) var searchTracks: [JellyfinCatalogItem] = []
    private(set) var searchAlbums: [JellyfinCatalogItem] = []
    private(set) var searchArtists: [JellyfinCatalogItem] = []
    private(set) var searchPlaylists: [JellyfinCatalogItem] = []
    private(set) var isConnecting = false
    private(set) var isLoading = false
    private(set) var isPreparingPlayback = false
    private(set) var cacheBytes: Int64 = 0
    private(set) var cachedFileCount = 0
    private(set) var isCleaningCache = false
    private(set) var cacheMessage: String?
    var error: String?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private let cache = JellyfinCacheManager()
    @ObservationIgnored private let imageCache = NSCache<NSString, NSData>()
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var prefetchingItemIDs: Set<String> = []
    @ObservationIgnored private var isLibraryLoadInProgress = false
    @ObservationIgnored private var musicLibraryID: String?

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "jellyfin-server-url") ?? ""
        username = UserDefaults.standard.string(forKey: "jellyfin-username") ?? ""
        if let session = JellyfinKeychain.readSession() {
            self.session = session
            serverAddress = session.serverURL.absoluteString
            username = session.username
            client = makeClient(url: session.serverURL, token: session.accessToken)
        }
        Task {
            await refreshCacheStats()
            await cleanUpCache(automatic: true)
        }
    }

    var isConnected: Bool { session != nil && client?.accessToken != nil }
    var serverName: String? { session?.serverName }
    var profileName: String? { session?.username }

    func clearError() { error = nil }

    func isFavorite(_ item: JellyfinCatalogItem) -> Bool {
        favoriteTracks.contains { $0.id == item.id }
    }

    func isUpdatingFavorite(_ item: JellyfinCatalogItem) -> Bool {
        favoriteMutationIDs.contains(item.id)
    }

    func toggleFavorite(_ item: JellyfinCatalogItem) {
        guard item.kind == .track, let client, let session,
              !favoriteMutationIDs.contains(item.id) else { return }
        let wasFavorite = isFavorite(item)
        let shouldFavorite = !wasFavorite
        favoriteMutationIDs.insert(item.id)
        setFavorite(item, isFavorite: shouldFavorite)

        Task {
            do {
                let userData: UserItemDataDto
                if shouldFavorite {
                    userData = try await client.send(
                        Paths.markFavoriteItem(itemID: item.id, userID: session.userID)
                    ).value
                } else {
                    userData = try await client.send(
                        Paths.unmarkFavoriteItem(itemID: item.id, userID: session.userID)
                    ).value
                }
                setFavorite(item, isFavorite: userData.isFavorite ?? shouldFavorite)
            } catch {
                setFavorite(item, isFavorite: wasFavorite)
                self.error = "Jellyfin could not update this favorite: \(error.localizedDescription)"
            }
            favoriteMutationIDs.remove(item.id)
        }
    }

    func connect(password: String) {
        guard !isConnecting else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            error = "Enter your Jellyfin username and password."
            return
        }
        guard let url = normalizedServerURL() else {
            error = "Enter a valid Jellyfin server address beginning with http:// or https://."
            return
        }

        isConnecting = true
        error = nil
        Task {
            defer { isConnecting = false }
            do {
                let newClient = makeClient(url: url, token: nil)
                async let publicInfo = newClient.send(Paths.getPublicSystemInfo).value
                let authentication = try await newClient.signIn(username: username, password: password)
                guard let token = authentication.accessToken,
                      let userID = authentication.user?.id else {
                    throw JellyfinStoreError.invalidAuthentication
                }
                let info = try? await publicInfo
                let newSession = JellyfinSession(
                    serverURL: url,
                    accessToken: token,
                    userID: userID,
                    username: authentication.user?.name ?? username,
                    serverName: info?.serverName ?? "Jellyfin"
                )
                try JellyfinKeychain.write(newSession)
                self.session = newSession
                self.client = newClient
                self.serverAddress = url.absoluteString
                self.username = newSession.username
                await loadLibrary()
            } catch {
                self.error = "Could not connect to Jellyfin: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        let oldClient = client
        session = nil
        client = nil
        musicLibraryID = nil
        libraries = []
        albums = []
        artists = []
        playlists = []
        favoriteTracks = []
        clearSearch()
        JellyfinKeychain.remove()
        Task { try? await oldClient?.signOut() }
    }

    func loadLibrary(showProgress: Bool = true) async {
        guard let client, let session, !isLibraryLoadInProgress else { return }
        isLibraryLoadInProgress = true
        if showProgress {
            isLoading = true
            error = nil
        }
        defer {
            isLibraryLoadInProgress = false
            if showProgress { isLoading = false }
        }
        do {
            let views = try await client.send(Paths.getUserViews(parameters: .init(userID: session.userID))).value.items ?? []
            let musicView = views.first { $0.collectionType == .music }
            musicLibraryID = musicView?.id
            libraries = views.compactMap(JellyfinCatalogItem.init(dto:))

            async let loadedAlbums = items(
                kinds: [.musicAlbum], parentID: musicView?.id, limit: 10_000,
                sortBy: [.sortName], sortOrder: [.ascending]
            )
            async let loadedArtists = items(
                kinds: [.musicArtist], parentID: musicView?.id, limit: 10_000,
                sortBy: [.sortName], sortOrder: [.ascending]
            )
            async let loadedPlaylists = items(
                kinds: [.playlist], parentID: nil, limit: 1_000,
                sortBy: [.sortName], sortOrder: [.ascending]
            )
            async let loadedFavorites = items(
                kinds: [.audio], parentID: musicView?.id, limit: 10_000,
                sortBy: [.sortName], sortOrder: [.ascending], isFavorite: true
            )
            (albums, artists, playlists, favoriteTracks) = try await (
                loadedAlbums, loadedArtists, loadedPlaylists, loadedFavorites
            )
        } catch {
            if showProgress { handleAPIError(error) }
        }
    }

    func search() { search(query: query) }

    func search(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = normalized
        guard isConnected else {
            error = "Connect to Jellyfin before searching."
            return
        }
        guard !normalized.isEmpty else {
            clearSearch()
            return
        }
        isLoading = true
        error = nil
        Task {
            do {
                let results = try await items(
                    kinds: [.audio, .musicAlbum, .musicArtist, .playlist],
                    parentID: nil,
                    limit: 60,
                    sortBy: [.sortName],
                    sortOrder: [.ascending],
                    searchTerm: normalized
                )
                searchTracks = results.filter { $0.kind == .track }
                searchAlbums = results.filter { $0.kind == .album }
                searchArtists = results.filter { $0.kind == .artist }
                searchPlaylists = results.filter { $0.kind == .playlist }
            } catch {
                handleAPIError(error)
            }
            isLoading = false
        }
    }

    func tracks(for collection: JellyfinCatalogItem) async throws -> [JellyfinCatalogItem] {
        if collection.kind == .playlist {
            return try await playlistItems(playlistID: collection.id, limit: 10_000)
        }
        let albumIDs = collection.kind == .album ? [collection.id] : nil
        return try await items(
            kinds: [.audio], parentID: nil,
            limit: 10_000, sortBy: [.parentIndexNumber, .indexNumber, .sortName],
            sortOrder: [.ascending], albumIDs: albumIDs
        )
    }

    func albums(for artist: JellyfinCatalogItem) async throws -> [JellyfinCatalogItem] {
        let albumArtistReleases = try await items(
            kinds: [.musicAlbum], parentID: musicLibraryID, limit: 500,
            sortBy: [.productionYear, .sortName], sortOrder: [.descending],
            albumArtistIDs: [artist.id]
        )
        if !albumArtistReleases.isEmpty { return albumArtistReleases }
        return try await items(
            kinds: [.musicAlbum], parentID: musicLibraryID, limit: 500,
            sortBy: [.productionYear, .sortName], sortOrder: [.descending],
            artistIDs: [artist.id]
        )
    }

    func tracks(forArtist artist: JellyfinCatalogItem) async throws -> [JellyfinCatalogItem] {
        try await items(
            kinds: [.audio], parentID: musicLibraryID, limit: 500,
            sortBy: [.album, .parentIndexNumber, .indexNumber], sortOrder: [.ascending],
            artistIDs: [artist.id]
        )
    }

    func artworkData(for item: JellyfinCatalogItem, maxWidth: Int = 500) async -> Data? {
        guard let imageItemID = item.imageItemID, let client else { return nil }
        let key = "\(imageItemID)-\(item.imageTag ?? "")-\(maxWidth)" as NSString
        if let data = imageCache.object(forKey: key) { return data as Data }
        do {
            let request = Paths.getItemImage(
                itemID: imageItemID,
                imageType: "Primary",
                parameters: .init(maxWidth: maxWidth, quality: 90, tag: item.imageTag)
            )
            let data = try await client.data(for: request).value
            imageCache.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        } catch {
            return nil
        }
    }

    func play(
        _ item: JellyfinCatalogItem,
        using playback: PlaybackEngine,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard item.kind == .track else {
            onFailure("This item is not an audio track.")
            return
        }
        let generation = UUID()
        playbackGeneration = generation
        isPreparingPlayback = true
        Task {
            do {
                let url = try await cachedAudioURL(for: item)
                guard playbackGeneration == generation else { return }
                let artwork = await artworkData(for: item)
                guard playbackGeneration == generation else { return }
                playback.play(makeTrack(from: item, url: url, artwork: artwork))
                isPreparingPlayback = false
            } catch {
                guard playbackGeneration == generation else { return }
                isPreparingPlayback = false
                onFailure(error.localizedDescription)
            }
        }
    }

    func cancelPendingPlayback() {
        playbackGeneration = UUID()
        isPreparingPlayback = false
    }

    func prefetch(_ item: JellyfinCatalogItem) {
        guard item.kind == .track,
              !prefetchingItemIDs.contains(item.id),
              !FileManager.default.fileExists(atPath: cache.audioURL(itemID: item.id, container: item.container).path) else { return }
        prefetchingItemIDs.insert(item.id)
        Task {
            _ = try? await cachedAudioURL(for: item)
            prefetchingItemIDs.remove(item.id)
        }
    }

    func cleanUpCache() {
        Task { await cleanUpCache(automatic: false) }
    }

    func refreshCacheStats() async {
        let stats = (try? cache.stats()) ?? JellyfinCacheStats()
        cacheBytes = stats.totalBytes
        cachedFileCount = stats.fileCount
    }

    private func cleanUpCache(automatic: Bool) async {
        guard !isCleaningCache else { return }
        isCleaningCache = true
        defer { isCleaningCache = false }
        do {
            try cache.prepareDirectory()
            let removed = try cache.clean(olderThan: .now.addingTimeInterval(-JellyfinCacheManager.retentionInterval))
            await refreshCacheStats()
            if !automatic || removed > 0 {
                cacheMessage = removed == 1 ? "Removed 1 old Jellyfin file." : "Removed \(removed) old Jellyfin files."
            }
        } catch {
            if !automatic { cacheMessage = "Cache cleanup failed: \(error.localizedDescription)" }
        }
    }

    private func items(
        kinds: [BaseItemKind],
        parentID: String?,
        limit: Int,
        sortBy: [ItemSortBy],
        sortOrder: [JellyfinAPI.SortOrder],
        searchTerm: String? = nil,
        isFavorite: Bool? = nil,
        albumIDs: [String]? = nil,
        artistIDs: [String]? = nil,
        albumArtistIDs: [String]? = nil
    ) async throws -> [JellyfinCatalogItem] {
        guard let client, let session else { throw JellyfinStoreError.notConnected }
        var loaded: [JellyfinCatalogItem] = []
        var startIndex = 0
        while loaded.count < limit {
            let pageSize = min(200, limit - loaded.count)
            let parameters = Paths.GetItemsParameters(
                userID: session.userID,
                startIndex: startIndex,
                limit: pageSize,
                isRecursive: true,
                searchTerm: searchTerm,
                sortOrder: sortOrder,
                parentID: parentID,
                fields: [.genres, .mediaSources, .overview, .parentID, .dateCreated],
                includeItemTypes: kinds,
                isFavorite: isFavorite,
                sortBy: sortBy,
                enableUserData: true,
                artistIDs: artistIDs,
                albumArtistIDs: albumArtistIDs,
                albumIDs: albumIDs,
                enableTotalRecordCount: true,
                enableImages: true
            )
            let response = try await client.send(Paths.getItems(parameters: parameters)).value
            let page = response.items ?? []
            loaded.append(contentsOf: page.compactMap(JellyfinCatalogItem.init(dto:)))
            startIndex += page.count
            if page.count < pageSize || startIndex >= (response.totalRecordCount ?? startIndex) { break }
        }
        return loaded
    }

    private func playlistItems(playlistID: String, limit: Int) async throws -> [JellyfinCatalogItem] {
        guard let client, let session else { throw JellyfinStoreError.notConnected }
        var loaded: [JellyfinCatalogItem] = []
        var startIndex = 0
        while loaded.count < limit {
            let pageSize = min(200, limit - loaded.count)
            let parameters = Paths.GetPlaylistItemsParameters(
                userID: session.userID,
                startIndex: startIndex,
                limit: pageSize,
                fields: [.genres, .mediaSources, .parentID],
                enableImages: true
            )
            let response = try await client.send(
                Paths.getPlaylistItems(playlistID: playlistID, parameters: parameters)
            ).value
            let page = response.items ?? []
            loaded.append(contentsOf: page.compactMap(JellyfinCatalogItem.init(dto:)).filter { $0.kind == .track })
            startIndex += page.count
            if page.count < pageSize || startIndex >= (response.totalRecordCount ?? startIndex) { break }
        }
        return loaded
    }

    private func cachedAudioURL(for item: JellyfinCatalogItem) async throws -> URL {
        guard let client else { throw JellyfinStoreError.notConnected }
        try cache.prepareDirectory()
        let destination = cache.audioURL(itemID: item.id, container: item.container)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? cache.markUsed(destination)
            return destination
        }
        let request = Paths.getAudioStream(
            itemID: item.id,
            parameters: .init(container: item.container, isStatic: true)
        )
        let temporaryURL = try await client.download(for: request).value
        if FileManager.default.fileExists(atPath: destination.path) {
            try? cache.markUsed(destination)
            return destination
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try? cache.markUsed(destination)
        await refreshCacheStats()
        return destination
    }

    private func makeTrack(from item: JellyfinCatalogItem, url: URL, artwork: Data?) -> Track {
        Track(
            id: "jellyfin-\(item.id)", url: url, fileName: url.lastPathComponent,
            title: item.name, artist: item.artists.joined(separator: ", "),
            albumArtist: item.albumArtist, album: item.album,
            genre: item.genres.joined(separator: ", "), year: item.year.map(String.init) ?? "",
            trackNumber: item.trackNumber, discNumber: item.discNumber,
            duration: item.duration, codec: item.container?.uppercased() ?? "Jellyfin",
            bitrate: nil, sampleRate: nil, artworkData: artwork, lyrics: nil,
            musicBrainzRecordingID: nil, musicBrainzReleaseID: nil, acoustID: nil,
            addedAt: .now, modifiedAt: .now, isFavorite: false, playCount: 0
        )
    }

    private func normalizedServerURL() -> URL? {
        let raw = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else { return nil }
        while components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func makeClient(url: URL, token: String?) -> JellyfinClient {
        let defaults = UserDefaults.standard
        let deviceKey = "jellyfin-device-id"
        let deviceID = defaults.string(forKey: deviceKey) ?? UUID().uuidString
        defaults.set(deviceID, forKey: deviceKey)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return JellyfinClient(configuration: .init(
            url: url, accessToken: token, client: "Uziq",
            deviceName: Host.current().localizedName ?? "Mac", deviceID: deviceID, version: version
        ))
    }

    private func clearSearch() {
        searchTracks = []
        searchAlbums = []
        searchArtists = []
        searchPlaylists = []
    }

    private func setFavorite(_ item: JellyfinCatalogItem, isFavorite: Bool) {
        favoriteTracks.removeAll { $0.id == item.id }
        if isFavorite {
            favoriteTracks.append(item)
            favoriteTracks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func handleAPIError(_ error: Error) {
        self.error = "Jellyfin request failed: \(error.localizedDescription)"
    }
}

private enum JellyfinStoreError: LocalizedError {
    case invalidAuthentication
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidAuthentication: "The server did not return a usable Jellyfin session."
        case .notConnected: "Connect to Jellyfin first."
        }
    }
}
