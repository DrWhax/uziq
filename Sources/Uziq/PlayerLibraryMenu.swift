import SwiftUI

enum PlayerLibraryTarget: Hashable {
    case album, artist

    func localRoute(trackID: String, snapshot: LocalLibraryBrowseSnapshot) -> LocalBrowseRoute? {
        switch self {
        case .album:
            snapshot.albums.first { $0.tracks.contains { $0.id == trackID } }.map { .album($0.id) }
        case .artist:
            snapshot.artists.first { $0.tracks.contains { $0.id == trackID } }.map { .artist($0.id) }
        }
    }

    func jellyfinID(for item: JellyfinCatalogItem) -> String? {
        switch self {
        case .album: item.kind == .album ? item.id : item.albumID
        case .artist: item.kind == .artist ? item.id : item.artistIDs.first
        }
    }

    static func bandcampArtist(for release: BandcampResult) -> BandcampResult? {
        // Only infer the artist homepage from a canonical artist subdomain.
        guard var url = URLComponents(url: release.openURL, resolvingAgainstBaseURL: false),
              let host = url.host, host.hasSuffix(".bandcamp.com"), host != "www.bandcamp.com",
              !release.artist.isEmpty else { return nil }
        url.path = ""
        url.query = nil
        url.fragment = nil
        guard let root = url.url else { return nil }
        return BandcampResult(id: "player-artist-\(host)", title: release.artist, artist: release.artist,
                              url: root, type: "b", bandID: release.bandID)
    }
}

enum PlayerLibraryNavigationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "This track’s album or artist is not available in the library." }
}

/// Resolves identities, never names: identically titled albums must not collide.
struct PlayerLibraryMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    var compact = false
    var onNavigate: () -> Void = {}
    @State private var request: PlayerLibraryTarget?
    @State private var error: String?

    var body: some View {
        Menu {
            Button(queue.currentItem?.source == .bandcamp ? "Show Release" : "Show Album") { request = .album }
                .disabled(!canShow(.album))
            Button("Show Artist") { request = .artist }
                .disabled(!canShow(.artist))
        } label: {
            if compact {
                Group {
                    if request != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.forward.square")
                    }
                }
                .frame(width: 34, height: 34).background(.quaternary, in: Circle())
            } else {
                Label(request == nil ? "Show in Library" : "Finding album or artist…", systemImage: "arrow.up.forward.square")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help(request == nil ? "Show in Library" : "Finding album or artist…")
        .accessibilityLabel("Show in Library")
        .disabled(queue.currentItem == nil || request != nil)
        .task(id: request) {
            guard let target = request, let item = queue.currentItem else { return }
            let spotifyID = spotify.playback?.itemID
            defer { if !Task.isCancelled { request = nil } }
            do {
                try await navigate(target, item: item, spotifyID: spotifyID)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onChange(of: queue.currentItem?.id) { _, _ in request = nil }
        .onChange(of: spotify.playback?.itemID) { _, _ in
            if queue.currentItem?.source == .spotify { request = nil }
        }
        .onChange(of: spotify.isStartingPlayback) { _, starting in
            if starting && queue.currentItem?.source == .spotify { request = nil }
        }
        .onDisappear { request = nil }
        .alert("Unable to Show in Library", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func canShow(_ target: PlayerLibraryTarget) -> Bool {
        guard let item = queue.currentItem else { return false }
        switch item.source {
        case .local:
            return target.localRoute(trackID: item.sourceID, snapshot: library.browseSnapshot) != nil
        case .spotify:
            // A queued Spotify item can be an entire album/playlist. Wait for
            // actual track metadata instead of using that container's ID.
            return spotify.isAuthorized && !spotify.isStartingPlayback && !spotify.isRateLimited &&
                (spotify.playback?.duration ?? 0) > 0
        case .jellyfin:
            return jellyfin.isConnected && item.jellyfinItem.flatMap { target.jellyfinID(for: $0) } != nil
        case .bandcamp:
            guard let release = item.bandcampResult else { return false }
            return target == .album || PlayerLibraryTarget.bandcampArtist(for: release) != nil
        }
    }

    @MainActor
    private func navigate(_ target: PlayerLibraryTarget, item: UnifiedQueueItem, spotifyID: String?) async throws {
        switch item.source {
        case .local:
            guard let route = target.localRoute(trackID: item.sourceID, snapshot: library.browseSnapshot) else {
                throw PlayerLibraryNavigationError.unavailable
            }
            let section: LibrarySection = target == .album ? .albums : .artists
            library.browsing.show(route, in: section)
            library.selectedSection = section
        case .spotify:
            guard let spotifyID else { throw PlayerLibraryNavigationError.unavailable }
            let destination = try await spotify.playerLibraryDestination(target, trackID: spotifyID)
            try Task.checkCancellation()
            guard queue.currentItem?.id == item.id, spotify.playback?.itemID == spotifyID,
                  spotify.isAuthorized, !spotify.isStartingPlayback else { throw CancellationError() }
            guard spotify.spotifyRequestsAllowed(reportError: false) else { throw PlayerLibraryNavigationError.unavailable }
            spotify.closeDetail()
            if target == .album { spotify.openAlbum(destination) } else { spotify.openArtist(destination) }
            library.selectedSection = .spotify
        case .jellyfin:
            guard let current = item.jellyfinItem, let id = target.jellyfinID(for: current) else {
                throw PlayerLibraryNavigationError.unavailable
            }
            let destination = try await jellyfin.playerLibraryDestination(id: id)
            try Task.checkCancellation()
            guard queue.currentItem?.id == item.id else { throw CancellationError() }
            library.browsing.show(destination, in: .jellyfin)
            library.selectedSection = .jellyfin
        case .bandcamp:
            guard let release = item.bandcampResult else { throw PlayerLibraryNavigationError.unavailable }
            let route: BandcampBrowseRoute
            if target == .album {
                route = .release(release)
            } else {
                guard let artist = PlayerLibraryTarget.bandcampArtist(for: release) else {
                    throw PlayerLibraryNavigationError.unavailable
                }
                route = .artist(artist)
            }
            library.browsing.show(route, in: .bandcamp)
            library.selectedSection = .bandcamp
        }
        onNavigate()
    }
}
