import AppKit
import SwiftUI

struct SpotifyLibraryView: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackEngine.self) private var playback
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var spotify = spotify
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if !spotify.isConfigured {
                    SpotifyUnavailableView(
                        title: "Spotify Web API isn’t connected",
                        detail: "The playback engine is a separate connection. To show playlists and search Spotify here, add a Spotify developer-app Client ID in Settings, then connect your account.",
                        buttonTitle: "Open Spotify Settings"
                    ) { library.selectedSection = .settings }
                } else if !spotify.isAuthorized {
                    SpotifyUnavailableView(
                        title: "Connect Spotify",
                        detail: "Sign in with PKCE to load your playlists and search Spotify's catalog. Your client secret is not needed.",
                        buttonTitle: "Connect Account"
                    ) { spotify.logIn() }
                } else if let selectedAlbum = spotify.selectedAlbum {
                    SpotifyAlbumDetail(album: selectedAlbum)
                } else if let selectedArtist = spotify.selectedArtist {
                    SpotifyArtistDetail(artist: selectedArtist)
                } else if let selectedPlaylist = spotify.selectedPlaylist {
                    SpotifyPlaylistDetail(playlist: selectedPlaylist)
                } else {
                    SpotifyBrowseView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if spotify.isLoading || spotify.isLoadingArtist || spotify.isLoadingAlbum {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 34)
                    .padding(.trailing, 28)
            }
        }
        .task {
            spotify.attachPlaybackEngine(playback)
            if spotify.isAuthorized && spotify.playlists.isEmpty { spotify.loadAccount() }
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spotify")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(spotify.profileName.map { "Connected as \($0)" } ?? "Lightweight Spotify playback through Uziq")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if spotify.isAuthorized {
                if spotify.selectedPlaylist != nil || spotify.selectedArtist != nil || spotify.selectedAlbum != nil {
                    Button { spotify.closeDetail() } label: {
                        Label("Spotify Home", systemImage: "house.fill")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(spotify.librespot.status == .ready ? .green : .secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(spotify.librespot.status.title)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())

                if !spotify.librespot.status.isRunning {
                    Button("Start Player") { spotify.startPlaybackEngine() }
                        .buttonStyle(.bordered)
                        .disabled(spotify.librespot.resolvedExecutableURL == nil)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }
}

private struct SpotifyBrowseView: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        @Bindable var spotify = spotify
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search artists, albums, tracks, and playlists", text: $spotify.query)
                        .textFieldStyle(.plain)
                        .onSubmit { spotify.search() }
                    if !spotify.query.isEmpty {
                        Button { spotify.query = ""; spotify.search() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Search") { spotify.search() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(11)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                SpotifyPlaybackNotice()

                if spotify.needsPersonalLibraryPermission {
                    HStack(spacing: 14) {
                        Label("Reconnect Spotify once to add Liked Songs and your artist radio.", systemImage: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reconnect") { spotify.reconnectForPersonalLibrary() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if spotify.likedSongsTotal > 0 || !spotify.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your Library")
                            .font(.title2.weight(.bold))
                        Text("Liked songs and playlists from your Spotify account.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                if spotify.likedSongsTotal > 0 {
                                    SpotifyPlaylistTile(
                                        item: spotify.likedSongsCollection,
                                        systemImage: "heart.fill",
                                        isPreparing: spotify.isStartingPlayback,
                                        onOpen: { spotify.openLikedSongs() },
                                        onPlay: { playLibraryItem(spotify.likedSongsCollection) }
                                    )
                                }
                                ForEach(spotify.playlists) { playlist in
                                    SpotifyPlaylistTile(
                                        item: playlist,
                                        isPreparing: spotify.isStartingPlayback,
                                        onOpen: { spotify.openPlaylist(playlist) },
                                        onPlay: { playLibraryItem(playlist) }
                                    )
                                }
                            }
                        }
                        .frame(height: 190)
                    }
                }

                if !spotify.topArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your Artist Radio")
                            .font(.title2.weight(.bold))
                        Text("Artists Spotify thinks you’ll want to hear again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(spotify.topArtists) { artist in
                                    SpotifyArtistRadioTile(item: artist) {
                                        spotify.openArtist(artist)
                                    }
                                }
                            }
                        }
                    }
                }

                if hasSearchResults {
                    SpotifyResultSection(title: "Tracks", items: spotify.searchTracks)
                    SpotifyResultSection(title: "Albums", items: spotify.searchAlbums)
                    SpotifyResultSection(title: "Artists", items: spotify.searchArtists)
                    SpotifyResultSection(title: "Playlists", items: spotify.searchPlaylists, opensPlaylists: true)
                } else if !spotify.query.isEmpty && !spotify.isLoading {
                    ContentUnavailableView(
                        "No Spotify results",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different artist, album, track, or playlist name.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
    }

    private var hasSearchResults: Bool {
        !spotify.searchTracks.isEmpty || !spotify.searchAlbums.isEmpty ||
            !spotify.searchArtists.isEmpty || !spotify.searchPlaylists.isEmpty
    }

    private func playLibraryItem(_ item: SpotifyCatalogItem) {
        if item.id == SpotifyStore.likedSongsID, let first = spotify.likedSongs.first {
            queue.replace(with: first, context: spotify.likedSongs)
        } else {
            queue.replace(with: item)
        }
    }
}

private struct SpotifyResultSection: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue
    let title: String
    let items: [SpotifyCatalogItem]
    var opensPlaylists = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                ForEach(items) { item in
                    SpotifyResultRow(item: item) {
                        if opensPlaylists {
                            spotify.openPlaylist(item)
                        } else if item.kind == .artist {
                            spotify.openArtist(item)
                        } else if item.kind == .album {
                            spotify.openAlbum(item)
                        } else {
                            queue.replace(with: item, context: items)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

private struct SpotifyPlaylistTile: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let item: SpotifyCatalogItem
    var systemImage = "rectangle.stack.fill"
    let isPreparing: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: onOpen) {
                    SpotifyRemoteArtwork(url: item.artworkURL, systemImage: systemImage)
                        .frame(width: 142, height: 142)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onPlay) {
                    Group {
                        if isPreparing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.65), in: Circle())
                .padding(8)
                .disabled(isPreparing || (item.id != SpotifyStore.likedSongsID && item.uri.isEmpty))
                .help("Play \(item.name)")
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.itemCount.map { "\($0) items" } ?? item.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.72))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 142, alignment: .leading)
        .contextMenu {
            Button("View Track List", action: onOpen)
            Button("Play", action: onPlay)
            if item.id != SpotifyStore.likedSongsID, !item.uri.isEmpty {
                Button("Play Next") { queue.playNext(item) }
                Button("Add to Queue") { queue.add(item) }
            }
            if let url = spotifyWebURL(for: item.uri) {
                Button("Open in Spotify", action: { NSWorkspace.shared.open(url) })
            }
        }
    }
}

private struct SpotifyArtistRadioTile: View {
    let item: SpotifyCatalogItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                SpotifyRemoteArtwork(url: item.artworkURL, systemImage: "person.fill")
                    .frame(width: 132, height: 132)
                    .clipShape(Circle())
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Label("View artist", systemImage: "chevron.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct SpotifyResultRow: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue
    let item: SpotifyCatalogItem
    let primaryAction: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            SpotifyRemoteArtwork(url: item.artworkURL, systemImage: item.kind.systemImage)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: item.kind == .artist ? 28 : 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.kind.title)
                    if let duration = item.durationText { Text("· \(duration)") }
                    if let count = item.itemCount { Text("· \(count) items") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            if item.kind == .playlist || item.kind == .artist || item.kind == .album {
                Button("View", action: primaryAction)
                    .buttonStyle(.bordered)
            }
            Button {
                if item.kind == .playlist || item.kind == .artist || item.kind == .album {
                    queue.replace(with: item)
                } else {
                    primaryAction()
                }
            } label: {
                if spotify.isStartingPlayback {
                    ProgressView().controlSize(.small).frame(width: 44)
                } else {
                    Label("Play", systemImage: "play.fill").frame(minWidth: 44)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(spotify.isStartingPlayback || item.uri.isEmpty)
            Button("Open") {
                if let url = spotifyWebURL(for: item.uri) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
        .contextMenu {
            if !item.uri.isEmpty {
                Button("Play Next") { queue.playNext(item) }
                Button("Add to Queue") { queue.add(item) }
            }
        }
    }
}

private struct SpotifyArtistDetail: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue
    let artist: SpotifyCatalogItem
    @State private var section: SpotifyArtistPageSection = .albums

    private let albumColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SpotifyPlaybackNotice()

                HStack(spacing: 24) {
                    SpotifyRemoteArtwork(url: artist.artworkURL, systemImage: "person.fill")
                        .frame(width: 180, height: 180)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 7)
                    VStack(alignment: .leading, spacing: 10) {
                        Button { spotify.closeArtist() } label: {
                            Label("Back to Spotify", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Text("Artist")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(artist.name)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        if !artist.subtitle.isEmpty {
                            Text(artist.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(action: playRadio) {
                                Label("Play Artist Radio", systemImage: "dot.radiowaves.left.and.right")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                queue.playNext(artist)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Picker("Artist page", selection: $section) {
                    ForEach(SpotifyArtistPageSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                if spotify.isLoadingArtist && spotify.artistAlbums.isEmpty && spotify.artistTopTracks.isEmpty {
                    ProgressView("Loading \(artist.name)…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if section == .albums {
                    albums
                } else {
                    radio
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder private var albums: some View {
        if let error = spotify.artistAlbumsError {
            ContentUnavailableView(
                "Couldn’t load releases",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if spotify.artistAlbums.isEmpty {
            ContentUnavailableView(
                "No releases found",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Spotify did not return albums or singles for this artist.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Albums & Singles")
                    .font(.title2.weight(.bold))
                LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 20) {
                    ForEach(spotify.artistAlbums) { album in
                        SpotifyArtistAlbumTile(album: album)
                    }
                }
            }
        }
    }

    @ViewBuilder private var radio: some View {
        if let error = spotify.artistRadioError {
            ContentUnavailableView(
                "Couldn’t build radio tracks",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if spotify.artistTopTracks.isEmpty {
            ContentUnavailableView(
                "Radio is still available",
                systemImage: "dot.radiowaves.left.and.right",
                description: Text("Spotify did not expose top tracks here, but it can still start the artist context.")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Artist Radio")
                            .font(.title2.weight(.bold))
                        Text("Built from \(artist.name)’s current top tracks.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: playRadio) {
                        Label("Play Radio", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                LazyVStack(spacing: 0) {
                    ForEach(spotify.artistTopTracks) { track in
                        SpotifyResultRow(item: track) {
                            queue.replace(with: track, context: spotify.artistTopTracks)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func playRadio() {
        if let first = spotify.artistTopTracks.first {
            queue.replace(with: first, context: spotify.artistTopTracks)
        } else {
            queue.replace(with: artist)
        }
    }
}

private struct SpotifyArtistAlbumTile: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue
    let album: SpotifyCatalogItem

    var body: some View {
        Button { spotify.openAlbum(album) } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    SpotifyRemoteArtwork(url: album.artworkURL, systemImage: "square.stack")
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                        .padding(8)
                }
                Text(album.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(album.itemCount.map { "\($0) tracks" } ?? album.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play Album") { queue.replace(with: album) }
            Button("Play Album Next") { queue.playNext(album) }
            Button("Add Album to Queue") { queue.add(album) }
        }
    }
}

private struct SpotifyAlbumDetail: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue
    let album: SpotifyCatalogItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SpotifyPlaybackNotice()

                HStack(spacing: 22) {
                    SpotifyRemoteArtwork(url: album.artworkURL, systemImage: "square.stack")
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 7)
                    VStack(alignment: .leading, spacing: 9) {
                        Button { spotify.closeAlbum() } label: {
                            Label(
                                spotify.selectedArtist == nil ? "Back to Spotify" : "Back to Artist",
                                systemImage: "chevron.left"
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Text("Album")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(album.name)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(album.subtitle)
                            .foregroundStyle(.secondary)
                        Text(albumTrackSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(action: playAlbum) {
                                Label("Play Album", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(spotify.isLoadingAlbum || spotify.albumTracks.isEmpty)

                            Button("Open in Spotify") {
                                if let url = spotifyWebURL(for: album.uri) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if spotify.isLoadingAlbum && spotify.albumTracks.isEmpty {
                    ProgressView("Loading tracks…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let error = spotify.albumTracksError {
                    ContentUnavailableView(
                        "Couldn’t load album tracks",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if spotify.albumTracks.isEmpty {
                    ContentUnavailableView(
                        "No tracks available",
                        systemImage: "music.note.slash",
                        description: Text("Spotify did not return playable tracks for this album.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(spotify.albumTracks.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                                SpotifyResultRow(item: track) {
                                    queue.replace(with: track, context: spotify.albumTracks)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
    }

    private var albumTrackSummary: String {
        let count = spotify.albumTracks.isEmpty ? album.itemCount : spotify.albumTracks.count
        let countText = count.map { "\($0) track\($0 == 1 ? "" : "s")" } ?? "Album"
        let durationMS = spotify.albumTracks.compactMap(\.durationMS).reduce(0, +)
        guard durationMS > 0 else { return countText }
        let totalMinutes = durationMS / 60_000
        return "\(countText) · \(totalMinutes) min"
    }

    private func playAlbum() {
        guard let first = spotify.albumTracks.first else { return }
        queue.replace(with: first, context: spotify.albumTracks)
    }
}

private struct SpotifyPlaylistDetail: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackQueueStore.self) private var queue
    let playlist: SpotifyCatalogItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SpotifyPlaybackNotice()

                HStack(spacing: 20) {
                    SpotifyRemoteArtwork(
                        url: playlist.artworkURL,
                        systemImage: playlist.id == SpotifyStore.likedSongsID ? "heart.fill" : "rectangle.stack.fill"
                    )
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        Button { spotify.closePlaylist() } label: {
                            Label("Back to Spotify", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Text(playlist.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(playlist.subtitle)
                            .foregroundStyle(.secondary)
                        Button {
                            if let first = spotify.playlistTracks.first {
                                queue.replace(with: first, context: spotify.playlistTracks)
                            } else {
                                queue.replace(with: playlist)
                            }
                        } label: {
                            Label("Play Playlist", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if spotify.playlistTracks.isEmpty && !spotify.isLoading {
                    ContentUnavailableView(
                        "Tracks unavailable",
                        systemImage: "lock",
                        description: Text("Spotify Development Mode only exposes item lists for playlists you own or collaborate on. You can still play or open this playlist.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(spotify.playlistTracks) { track in
                            SpotifyResultRow(item: track) {
                                queue.replace(with: track, context: spotify.playlistTracks)
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
    }
}

private struct SpotifyPlaybackNotice: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        if let message = spotify.playbackMessage {
            Label(message, systemImage: "dot.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let error = spotify.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let audioError = playback.spotifyAudioError {
            Label(audioError, systemImage: "speaker.slash")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else if spotify.isUziqPlaybackActive && playback.isSpotifyPCMActive && playback.spotifyReceivedByteCount == 0 {
            Label("Spotify is playing, but Uziq is still waiting for decoded audio from librespot…", systemImage: "waveform.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpotifyUnavailableView: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.green)
            Text(title).font(.title2.weight(.semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 500)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct SpotifyRemoteArtwork: View {
    let url: URL?
    let systemImage: String

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.green.opacity(0.65), .black.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: systemImage)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipped()
    }
}

private func spotifyWebURL(for uri: String) -> URL? {
    let components = uri.split(separator: ":")
    guard components.count == 3, components[0] == "spotify" else { return nil }
    return URL(string: "https://open.spotify.com/\(components[1])/\(components[2])")
}
