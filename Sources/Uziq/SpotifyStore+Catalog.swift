import AppKit
import Combine
import Foundation
import Observation
import SpotifyWebAPI

extension SpotifyStore {
    func search(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = normalized
        guard isAuthorized else {
            error = "Connect your Spotify account before searching."
            return
        }
        guard spotifyRequestsAllowed() else { return }
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
        .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
            guard let self else { return }
            if case .failure(let error) = completion {
                isLoading = false
                handleAPIError(error)
            }
        } receiveValue: { [weak self] result in
            guard let self else { return }
            searchTracks = result.tracks?.items.map { Self.catalogItem($0) } ?? []
            searchAlbums = result.albums?.items.map(Self.catalogItem) ?? []
            searchArtists = result.artists?.items.map(Self.catalogItem) ?? []
            searchPlaylistsWithCurrentToken(query: normalized)
        }
    }

    func openPlaylist(_ playlist: SpotifyCatalogItem) {
        closeAlbum()
        closeArtist()
        selectedPlaylist = playlist
        playlistTracks = []
        guard isAuthorized, spotifyRequestsAllowed() else { return }
        isLoading = true
        api.playlistItems(playlist.uri, limit: 100)
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self else { return }
                isLoading = false
                if case .failure(let error) = completion { handleAPIError(error) }
            } receiveValue: { [weak self] page in
                self?.playlistTracks = page.items.compactMap { container in
                    guard case .track(let track)? = container.item else { return nil }
                    return Self.catalogItem(track)
                }
            }
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
        guard artist.kind == .artist, !artist.uri.isEmpty, spotifyRequestsAllowed() else { return }
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
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self, artistLoadGeneration == generation else { return }
                artistTopTracksFinished = true
                finishArtistLoadingIfReady()
                if case .failure(let error) = completion {
                    artistRadioError = handleAPIError(error)
                }
            } receiveValue: { [weak self] result in
                guard let self, artistLoadGeneration == generation else { return }
                artistTopTracks = result.tracks?.items.map { Self.catalogItem($0) } ?? []
            }
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
        guard album.kind == .album, !album.uri.isEmpty, spotifyRequestsAllowed() else { return }
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

    func loadArtistAlbums(
        _ artist: SpotifyCatalogItem,
        offset: Int,
        accumulated: [SpotifyCatalogItem],
        generation: UUID
    ) {
        guard spotifyRequestsAllowed(reportError: false) else {
            artistAlbumsFinished = true
            finishArtistLoadingIfReady()
            return
        }
        api.artistAlbums(
            artist.uri,
            groups: [.album, .single],
            country: nil,
            limit: Self.artistAlbumsPageLimit,
            offset: offset
        )
        .receive(on: DispatchQueue.main)
        .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
            guard let self, artistLoadGeneration == generation else { return }
            if case .failure(let error) = completion {
                artistAlbumsFinished = true
                finishArtistLoadingIfReady()
                artistAlbumsError = handleAPIError(error)
            }
        } receiveValue: { [weak self] page in
            guard let self, artistLoadGeneration == generation else { return }
            let combined = accumulated + page.items.map(Self.catalogItem)
            if !page.items.isEmpty,
               combined.count < page.total,
               combined.count < Self.artistAlbumsMaximum {
                loadArtistAlbums(
                    artist,
                    offset: offset + page.items.count,
                    accumulated: combined,
                    generation: generation
                )
            } else {
                var seen = Set<String>()
                artistAlbums = Array(combined.prefix(Self.artistAlbumsMaximum))
                    .filter { seen.insert($0.id).inserted }
                artistAlbumsFinished = true
                finishArtistLoadingIfReady()
            }
        }
    }

    func loadAlbumTracks(
        _ album: SpotifyCatalogItem,
        offset: Int,
        accumulated: [SpotifyCatalogItem],
        generation: UUID
    ) {
        guard spotifyRequestsAllowed(reportError: false) else {
            isLoadingAlbum = false
            return
        }
        api.albumTracks(
            album.uri,
            market: "from_token",
            limit: Self.albumTracksPageLimit,
            offset: offset
        )
        .receive(on: DispatchQueue.main)
        .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
            guard let self, albumLoadGeneration == generation else { return }
            if case .failure(let error) = completion {
                isLoadingAlbum = false
                albumTracksError = handleAPIError(error)
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
    }

    func finishArtistLoadingIfReady() {
        if artistAlbumsFinished && artistTopTracksFinished {
            isLoadingArtist = false
        }
    }

    func clearSearch() {
        searchTracks = []
        searchAlbums = []
        searchArtists = []
        searchPlaylists = []
    }

    func searchPlaylistsWithCurrentToken(query: String) {
        guard spotifyRequestsAllowed() else {
            isLoading = false
            return
        }
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
                if output.response.statusCode == 429 {
                    let retryAfter = output.response.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Int.init)
                    throw SpotifyRateLimitResponseError(retryAfter: retryAfter)
                }
                guard (200..<300).contains(output.response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return try JSONDecoder().decode(RawPlaylistSearchEnvelope.self, from: output.data)
            }
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self else { return }
                isLoading = false
                if case .failure(let error) = completion { handleAPIError(error) }
            } receiveValue: { [weak self] (response: RawPlaylistSearchEnvelope) in
                self?.searchPlaylists = response.playlists.items.compactMap { $0?.catalogItem }
            }
    }

    static func catalogItem(
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

    static func catalogItem(_ album: SpotifyWebAPI.Album) -> SpotifyCatalogItem {
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

    static func catalogItem(_ artist: SpotifyWebAPI.Artist) -> SpotifyCatalogItem {
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

    static func catalogItem(_ playlist: Playlist<PlaylistItemsReference>) -> SpotifyCatalogItem {
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

