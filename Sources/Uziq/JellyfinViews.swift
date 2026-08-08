import AppKit
import SwiftUI

struct JellyfinLibraryView: View {
    @Environment(JellyfinStore.self) private var jellyfin
    @Environment(LibraryStore.self) private var library
    @State private var path: [JellyfinCatalogItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Group {
                    if !jellyfin.isConnected {
                        ContentUnavailableView {
                            Label("Connect Jellyfin", systemImage: "server.rack")
                        } description: {
                            Text("Add your server and account in Settings to browse and play its music library.")
                        } actions: {
                            Button("Open Jellyfin Settings") { library.selectedSection = .settings }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        JellyfinBrowseView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationDestination(for: JellyfinCatalogItem.self) { item in
                JellyfinItemDetail(item: item)
            }
        }
        .overlay(alignment: .topTrailing) {
            if jellyfin.isLoading {
                ProgressView().controlSize(.small).padding(.top, 36).padding(.trailing, 28)
            }
        }
        .task {
            guard jellyfin.isConnected else { return }
            await jellyfin.loadLibrary()
        }
        .alert("Jellyfin issue", isPresented: Binding(
            get: { jellyfin.error != nil },
            set: { if !$0 { jellyfin.clearError() } }
        )) {
            Button("OK") { jellyfin.clearError() }
        } message: {
            Text(jellyfin.error ?? "Unknown Jellyfin error")
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Jellyfin")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(jellyfin.serverName.map { "\($0) · \(jellyfin.profileName ?? "Connected")" } ?? "Your self-hosted music library")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !path.isEmpty {
                Button { path.removeAll() } label: {
                    Label("Jellyfin Home", systemImage: "house.fill")
                }
                .buttonStyle(.bordered)
            }
            if jellyfin.isConnected {
                Button {
                    Task { await jellyfin.loadLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(jellyfin.isLoading)

                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }
}

private struct JellyfinBrowseView: View {
    @Environment(JellyfinStore.self) private var jellyfin

    var body: some View {
        @Bindable var jellyfin = jellyfin
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your Jellyfin music library", text: $jellyfin.query)
                        .textFieldStyle(.plain)
                        .onSubmit { jellyfin.search() }
                    if !jellyfin.query.isEmpty {
                        Button { jellyfin.query = ""; jellyfin.search() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Search") { jellyfin.search() }.buttonStyle(.borderedProminent)
                }
                .padding(11)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                if hasSearchResults {
                    JellyfinResultSection(title: "Tracks", items: jellyfin.searchTracks)
                    JellyfinResultSection(title: "Albums", items: jellyfin.searchAlbums)
                    JellyfinResultSection(title: "Artists", items: jellyfin.searchArtists)
                    JellyfinResultSection(title: "Playlists", items: jellyfin.searchPlaylists)
                } else if !jellyfin.query.isEmpty && !jellyfin.isLoading {
                    ContentUnavailableView(
                        "No Jellyfin results", systemImage: "magnifyingglass",
                        description: Text("Try another artist, album, track, or playlist name.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else if jellyfin.albums.isEmpty && jellyfin.artists.isEmpty && jellyfin.playlists.isEmpty && !jellyfin.isLoading {
                    ContentUnavailableView(
                        "No music found", systemImage: "music.note.list",
                        description: Text("This Jellyfin account does not currently expose a music library.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    JellyfinCarousel(title: "Liked Tracks", subtitle: "Tracks you favorited in Jellyfin", items: jellyfin.favoriteTracks)
                    JellyfinCarousel(title: "Albums", subtitle: "Your Jellyfin album library", items: jellyfin.albums)
                    JellyfinCarousel(title: "Artists", subtitle: "Browse by artist", items: jellyfin.artists)
                    JellyfinCarousel(title: "Playlists", subtitle: "Playlists stored on your server", items: jellyfin.playlists)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
    }

    private var hasSearchResults: Bool {
        !jellyfin.searchTracks.isEmpty || !jellyfin.searchAlbums.isEmpty ||
            !jellyfin.searchArtists.isEmpty || !jellyfin.searchPlaylists.isEmpty
    }
}

private struct JellyfinCarousel: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let title: String
    let subtitle: String
    let items: [JellyfinCatalogItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            if item.kind == .track {
                                Button { queue.replace(with: item, context: items) } label: {
                                    JellyfinTile(item: item)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: item) { JellyfinTile(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .mouseDraggableHorizontalScroll()
                .padding(.horizontal, -28)
            }
        }
    }
}

private struct JellyfinTile: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(JellyfinStore.self) private var jellyfin
    let item: JellyfinCatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JellyfinArtwork(item: item)
                .frame(width: 148, height: 148)
                .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 11, style: .continuous)))
            Text(item.name).font(.headline).lineLimit(1)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
        .contextMenu {
            if item.kind == .track {
                Button(jellyfin.isFavorite(item) ? "Remove from Liked Tracks" : "Add to Liked Tracks") {
                    jellyfin.toggleFavorite(item)
                }
                .disabled(jellyfin.isUpdatingFavorite(item))
                Button("Play Next") { queue.playNext(item) }
                Button("Add to Queue") { queue.add(item) }
            }
        }
    }
}

private struct JellyfinResultSection: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(JellyfinStore.self) private var jellyfin
    let title: String
    let items: [JellyfinCatalogItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.weight(.bold))
                ForEach(items) { item in
                    HStack(spacing: 13) {
                        JellyfinArtwork(item: item)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: item.kind == .artist ? 28 : 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.headline).lineLimit(1)
                            Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 5) {
                                Text(item.kind.title)
                                if let duration = item.durationText { Text("· \(duration)") }
                            }
                            .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if item.kind == .track {
                            Button { queue.replace(with: item, context: items) } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            NavigationLink(value: item) { Text("View") }.buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 6)
                    .contextMenu {
                        if item.kind == .track {
                            Button(jellyfin.isFavorite(item) ? "Remove from Liked Tracks" : "Add to Liked Tracks") {
                                jellyfin.toggleFavorite(item)
                            }
                            .disabled(jellyfin.isUpdatingFavorite(item))
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

private struct JellyfinItemDetail: View {
    let item: JellyfinCatalogItem

    var body: some View {
        switch item.kind {
        case .artist: JellyfinArtistDetail(artist: item)
        case .album, .playlist: JellyfinCollectionDetail(collection: item)
        case .track: JellyfinCollectionDetail(collection: item)
        }
    }
}

private struct JellyfinCollectionDetail: View {
    @Environment(JellyfinStore.self) private var jellyfin
    @Environment(PlaybackQueueStore.self) private var queue
    let collection: JellyfinCatalogItem
    @State private var tracks: [JellyfinCatalogItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    JellyfinArtwork(item: collection)
                        .frame(width: 190, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 7)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(collection.kind.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(collection.name).font(.system(size: 38, weight: .bold, design: .rounded))
                        Text(collection.subtitle).font(.title3).foregroundStyle(.secondary)
                        if !tracks.isEmpty {
                            Button { queue.replace(with: tracks[0], context: tracks) } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if isLoading {
                    ProgressView("Loading tracks…").frame(maxWidth: .infinity, minHeight: 180)
                } else if let error {
                    ContentUnavailableView("Couldn’t load tracks", systemImage: "exclamationmark.triangle", description: Text(error))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    JellyfinTrackList(tracks: tracks)
                }
            }
            .padding(28)
        }
        .task(id: collection.id) {
            isLoading = true
            do { tracks = try await jellyfin.tracks(for: collection) }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

private struct JellyfinArtistDetail: View {
    @Environment(JellyfinStore.self) private var jellyfin
    @Environment(PlaybackQueueStore.self) private var queue
    let artist: JellyfinCatalogItem
    @State private var albums: [JellyfinCatalogItem] = []
    @State private var tracks: [JellyfinCatalogItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 24) {
                    JellyfinArtwork(item: artist)
                        .frame(width: 190, height: 190).clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 7)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Artist").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(artist.name).font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("\(albums.count) albums · \(tracks.count) tracks").foregroundStyle(.secondary)
                        if let first = tracks.first {
                            Button { queue.replace(with: first, context: tracks) } label: {
                                Label("Play Artist", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                if isLoading {
                    ProgressView("Loading \(artist.name)…").frame(maxWidth: .infinity, minHeight: 180)
                } else if let error {
                    ContentUnavailableView("Couldn’t load artist", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    JellyfinCarousel(title: "Albums", subtitle: "Releases in your library", items: albums)
                    JellyfinTrackList(tracks: tracks)
                }
            }
            .padding(28)
        }
        .task(id: artist.id) {
            isLoading = true
            do {
                async let loadedAlbums = jellyfin.albums(for: artist)
                async let loadedTracks = jellyfin.tracks(forArtist: artist)
                (albums, tracks) = try await (loadedAlbums, loadedTracks)
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

private struct JellyfinTrackList: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(JellyfinStore.self) private var jellyfin
    let tracks: [JellyfinCatalogItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracks").font(.title2.weight(.bold)).padding(.bottom, 10)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { queue.replace(with: track, context: tracks) } label: {
                    HStack(spacing: 12) {
                        Text(track.trackNumber.map(String.init) ?? "\(index + 1)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                            Text(track.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(track.durationText ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.tint)
                    }
                    .padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(jellyfin.isFavorite(track) ? "Remove from Liked Tracks" : "Add to Liked Tracks") {
                        jellyfin.toggleFavorite(track)
                    }
                    .disabled(jellyfin.isUpdatingFavorite(track))
                    Button("Play Next") { queue.playNext(track) }
                    Button("Add to Queue") { queue.add(track) }
                }
                Divider()
            }
        }
    }
}

struct JellyfinArtwork: View {
    @Environment(JellyfinStore.self) private var jellyfin
    let item: JellyfinCatalogItem
    @State private var data: Data?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let data {
                ArtworkView(data: data)
            } else {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: "\(item.imageItemID ?? "")-\(item.imageTag ?? "")") {
            data = nil
            for attempt in 0..<4 {
                guard !Task.isCancelled else { return }
                if let artwork = await jellyfin.artworkData(for: item) {
                    data = artwork
                    return
                }
                if attempt < 3 { try? await Task.sleep(for: .seconds(15)) }
            }
        }
    }
}
