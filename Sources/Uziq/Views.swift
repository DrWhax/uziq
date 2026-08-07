import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @State private var showingNowPlaying = false

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                LibraryContentView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            MiniPlayerView { showingNowPlaying = true }

            if library.isScanning {
                ScanProgressView()
            } else if library.isEnrichingArtistArtwork {
                ArtistArtworkProgressView()
            } else if library.isEnrichingArtwork {
                ArtworkProgressView()
            } else if let scanMessage = library.scanMessage {
                ScanStatusView(message: scanMessage)
            }
        }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search titles, artists, albums")
        .onChange(of: library.searchText) { _, _ in
            Task { await library.refresh() }
        }
        .onChange(of: library.selectedSection) { _, _ in
            Task { await library.refresh() }
        }
        .onChange(of: library.mostPlayedRange) { _, _ in
            guard library.selectedSection == .mostPlayed else { return }
            Task { await library.refresh() }
        }
        .fileImporter(
            isPresented: $library.showingFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { library.importFolders(urls) }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.clearError() } }
        )) {
            Button("OK") { library.clearError() }
        } message: {
            Text(library.lastError ?? "Unknown error")
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
                .environment(library)
                .environment(playback)
        }
    }
}

struct SidebarView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selectedSection) {
            Section("Your Library") {
                ForEach([LibrarySection.library, .artists, .albums, .genres], id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            Section("Collections") {
                ForEach([LibrarySection.playlists, .mostPlayed, .recentlyAdded], id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            Section {
                Label(LibrarySection.settings.title, systemImage: LibrarySection.settings.systemImage)
                    .tag(LibrarySection.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Uziq")
        .toolbar {
            ToolbarItem {
                Button { library.presentFolderImporter() } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .help("Add a music folder")
            }
        }
    }
}

struct LibraryContentView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if library.selectedSection == .settings {
                SettingsView()
            } else if library.selectedSection == .playlists {
                PlaylistsLibraryView()
            } else if library.tracks.isEmpty && library.selectedSection != .mostPlayed {
                EmptyLibraryView()
            } else {
                switch library.selectedSection {
                case .library, .recentlyAdded:
                    TrackListView()
                case .albums:
                    AlbumsLibraryView()
                case .artists:
                    ArtistsLibraryView()
                case .genres:
                    GenresLibraryView()
                case .playlists:
                    PlaylistsLibraryView()
                case .mostPlayed:
                    TrackListView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackListView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        @Bindable var library = library
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.selectedSection.title)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text(library.selectedSection == .mostPlayed
                            ? "\(library.displayedTracks.count) tracks played this \(library.mostPlayedRange.title.lowercased())"
                            : "\(library.displayedTracks.count) tracks")
                            .foregroundStyle(.secondary)
                    }
                    if library.selectedSection == .mostPlayed {
                        Picker("Period", selection: $library.mostPlayedRange) {
                            ForEach(MostPlayedRange.allCases) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    Spacer()
                }

                if library.displayedTracks.isEmpty && library.selectedSection == .mostPlayed {
                    ContentUnavailableView(
                        "No plays yet",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Tracks you start playing will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(library.displayedTracks) { track in
                            TrackRow(track: track) {
                                playback.play(track, in: library.displayedTracks)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct ScanProgressView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let progress = library.scanProgress
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.tint)
                Text("Indexing library in background")
                    .font(.subheadline.weight(.semibold))
                if let progress {
                    Text("\(progress.completed) / \(progress.discovered)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer()
                    Text("Preparing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct ScanStatusView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

struct ArtworkProgressView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let progress = library.artworkProgress
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.tint)
                Text("Fetching album artwork in background")
                    .font(.subheadline.weight(.semibold))
                if let progress {
                    Text("\(progress.completed) / \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.currentAlbum)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer()
                    Text("Preparing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct ArtistArtworkProgressView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let progress = library.artistArtworkProgress
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.square")
                    .foregroundStyle(.tint)
                Text("Fetching artist images in background")
                    .font(.subheadline.weight(.semibold))
                if let progress {
                    Text("\(progress.completed) / \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.currentArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer()
                    Text("Preparing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct AlbumsLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selectedAlbum: AlbumGroup?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LibraryHeading(title: "Albums", subtitle: "\(albums.count) albums")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(albums) { album in
                            Button { selectedAlbum = album } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(28)
            }
            .navigationDestination(item: $selectedAlbum) { album in
                AlbumDetailView(album: album)
            }
        }
    }

    private var albums: [AlbumGroup] { AlbumGroup.grouped(library.displayedTracks) }
}

struct ArtistsLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selectedArtist: ArtistGroup?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LibraryHeading(title: "Artists", subtitle: "\(artists.count) artists")
                    LazyVStack(spacing: 0) {
                        ForEach(artists) { artist in
                            Button { selectedArtist = artist } label: {
                                ArtistRow(artist: artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(28)
            }
            .navigationDestination(item: $selectedArtist) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }

    private var artists: [ArtistGroup] { ArtistGroup.grouped(library.displayedTracks) }
}

struct GenresLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selectedAlbum: AlbumGroup?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    LibraryHeading(title: "Genres", subtitle: "\(genres.count) genres")
                    ForEach(genres) { genre in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .lastTextBaseline) {
                                Text(genre.name)
                                    .font(.title2.weight(.bold))
                                Text("\(genre.trackCount) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 18) {
                                    ForEach(genre.albums) { album in
                                        Button { selectedAlbum = album } label: {
                                            AlbumCard(album: album, width: 132, compact: true)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(28)
            }
            .navigationDestination(item: $selectedAlbum) { album in
                AlbumDetailView(album: album)
            }
        }
    }

    private var genres: [GenreGroup] { GenreGroup.grouped(library.displayedTracks) }
}

struct AlbumDetailView: View {
    let album: AlbumGroup
    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 22) {
                    ArtworkView(data: album.artworkData)
                        .frame(width: 190, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Album")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(album.title)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text(album.artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("\(album.tracks.count) tracks")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Play Album") {
                            if let first = album.tracks.first { playback.play(first, in: album.tracks) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                LazyVStack(spacing: 0) {
                    ForEach(album.tracks) { track in
                        TrackRow(track: track) {
                            playback.play(track, in: album.tracks)
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(album.title)
    }
}

struct ArtistDetailView: View {
    let artist: ArtistGroup
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @State private var selectedAlbum: AlbumGroup?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 18) {
                        ArtworkView(data: library.artistArtwork[artist.name] ?? artist.albums.first?.artworkData)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(artist.name)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            Text("\(artist.albums.count) albums · \(artist.tracks.count) tracks")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Albums")
                        .font(.title2.weight(.bold))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(artist.albums) { album in
                            Button { selectedAlbum = album } label: {
                                AlbumCard(album: album, width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("All Tracks")
                        .font(.title2.weight(.bold))
                        .padding(.top, 8)
                    LazyVStack(spacing: 0) {
                        ForEach(artist.tracks.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }) { track in
                            TrackRow(track: track) {
                                playback.play(track, in: artist.tracks)
                            }
                        }
                    }
                }
                .padding(28)
            }
            .navigationDestination(item: $selectedAlbum) { album in
                AlbumDetailView(album: album)
            }
        }
        .navigationTitle(artist.name)
    }
}

struct LibraryHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct AlbumCard: View {
    let album: AlbumGroup
    var width: CGFloat = 180
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            ArtworkView(data: album.artworkData)
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
            Text(album.title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

struct ArtistRow: View {
    let artist: ArtistGroup
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(data: library.artistArtwork[artist.name] ?? artist.albums.first?.artworkData)
                .frame(width: 58, height: 58)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.headline)
                Text("\(artist.albums.count) albums · \(artist.tracks.count) tracks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        Divider()
    }
}

struct TrackRow: View {
    let track: Track
    let play: () -> Void
    var playlist: PlaylistSummary? = nil
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                ArtworkView(data: track.artworkData)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                Text(track.displayAlbum)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
                if library.selectedSection == .mostPlayed {
                    Text("\(track.playCount) plays")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                Text(track.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, alignment: .trailing)
                if playback.currentTrack?.id == track.id && playback.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { play() }
            if !library.playlists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) { library.add(track, to: playlist) }
                    }
                }
            }
            if let playlist {
                Button("Remove from \(playlist.name)", role: .destructive) {
                    library.remove(track, from: playlist)
                }
            }
            Button("Identify with AcoustID") { library.identify(track) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
        }
        Divider()
    }
}

struct PlaceholderLibraryView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}

struct PlaylistsLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selectedPlaylist: PlaylistSummary?
    @State private var showingNewPlaylist = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .lastTextBaseline) {
                        LibraryHeading(title: "Playlists", subtitle: "\(library.playlists.count) playlists")
                        Button { showingNewPlaylist = true } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(library.playlists) { playlist in
                            Button { selectedPlaylist = playlist } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "music.note.list")
                                        .font(.title3)
                                        .frame(width: 48, height: 48)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .font(.headline)
                                        Text("\(playlist.trackCount) tracks")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Playlist", role: .destructive) { library.deletePlaylist(playlist) }
                            }
                            Divider()
                        }
                    }
                }
                .padding(28)
            }
            .navigationDestination(item: $selectedPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .sheet(isPresented: $showingNewPlaylist) {
                NewPlaylistSheet { name in library.createPlaylist(name: name) }
            }
        }
        .task { await library.loadPlaylists() }
    }
}

struct PlaylistDetailView: View {
    let playlist: PlaylistSummary
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @State private var tracks: [Track] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .lastTextBaseline) {
                    LibraryHeading(title: playlist.name, subtitle: "\(tracks.count) tracks")
                    if let first = tracks.first {
                        Button("Play Playlist") { playback.play(first, in: tracks) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if tracks.isEmpty {
                    Text("Add tracks from the Library using the track context menu.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 30)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(tracks) { track in
                            TrackRow(
                                track: track,
                                play: { playback.play(track, in: tracks) },
                                playlist: playlist
                            )
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(playlist.name)
        .task { tracks = await library.playlistTracks(playlist) }
    }
}

struct NewPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let create: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Playlist")
                .font(.title2.weight(.bold))
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        create(trimmed)
        dismiss()
    }
}

struct TrackCard: View {
    let track: Track
    let play: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(data: track.artworkData)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if playback.currentTrack?.id == track.id && playback.isPlaying {
                        Image(systemName: "waveform")
                            .font(.title3.weight(.bold))
                            .padding(9)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                    }
                }
                Text(track.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(track.displayAlbum)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { play() }
            if !library.playlists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) { library.add(track, to: playlist) }
                    }
                }
            }
            Button("Identify with AcoustID") { library.identify(track) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
        }
    }
}

struct NowPlayingView: View {
    @Environment(PlaybackEngine.self) private var playback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var playback = playback
        VStack(spacing: 20) {
            HStack {
                Text("Now Playing")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ArtworkView(data: playback.currentTrack?.artworkData)
                .frame(width: 320, height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(radius: 18, y: 8)

            VStack(spacing: 5) {
                Text(playback.currentTrack?.displayTitle ?? "Nothing playing")
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                Text(playback.currentTrack?.displayArtist ?? "Choose a track from your library")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let album = playback.currentTrack?.displayAlbum {
                    Text(album)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Slider(value: $playback.currentTime, in: 0...max(playback.duration, 1)) { editing in
                if !editing { playback.seek(to: playback.currentTime) }
            }
            HStack {
                Text(formatTime(playback.currentTime))
                Spacer()
                Text(formatTime(playback.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 28) {
                Button { playback.previous() } label: { Image(systemName: "backward.fill") }
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                Button { playback.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Lyrics")
                    .font(.headline)
                if let lyrics = playback.currentTrack?.lyrics, !lyrics.isEmpty {
                    ScrollView {
                        Text(lyrics)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No embedded lyrics found for this track.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(width: 560, height: 760)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct MiniPlayerView: View {
    @Environment(PlaybackEngine.self) private var playback
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Button(action: onOpen) {
                    HStack(spacing: 14) {
                        ArtworkView(data: playback.currentTrack?.artworkData)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playback.currentTrack?.displayTitle ?? "Nothing playing")
                                .font(.headline)
                                .lineLimit(1)
                            Text(playback.currentTrack?.displayArtist ?? "Choose a track from your library")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(playback.currentTrack?.displayAlbum ?? "")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 18)

                HStack(spacing: 22) {
                    Button { playback.previous() } label: { Image(systemName: "backward.fill") }
                    Button { playback.toggle() } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                    }
                    Button { playback.next() } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.plain)

                Button(action: onOpen) {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.plain)
                .help("Open Now Playing")
            }

            HStack(spacing: 10) {
                Text(formatTime(playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                WaveformView(
                    url: playback.currentTrack?.url,
                    progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                    duration: playback.duration
                ) { seconds in
                    playback.seek(to: seconds)
                }
                .frame(height: 28)

                Text(formatTime(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct WaveformView: View {
    let url: URL?
    let progress: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var samples: [CGFloat] = []

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    Capsule()
                        .fill(index < playedSampleCount ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, sample * 26))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration.isFinite, duration > 0, geometry.size.width > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / geometry.size.width))
                        onSeek(duration * fraction)
                    }
            )
        }
        .task(id: url) {
            guard let url else {
                samples = []
                return
            }
            samples = await Task.detached(priority: .utility) {
                WaveformSampler.samples(for: url)
            }.value
        }
        .animation(.linear(duration: 0.1), value: progress)
    }

    private var playedSampleCount: Int {
        Int(Double(samples.count) * min(1, max(0, progress)))
    }
}

struct EmptyLibraryView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Your library is waiting")
                .font(.title2.weight(.semibold))
            Text("Add a folder containing music files to get started.")
                .foregroundStyle(.secondary)
            Button("Add Music Folder…") { library.presentFolderImporter() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct ArtworkView: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.indigo.opacity(0.65), .purple.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
        }
        .clipped()
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Form {
            Section("Library folders") {
                if library.folderRoots.isEmpty {
                    Text("No folders added")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.folderRoots, id: \.self) { url in
                        HStack {
                            Label(url.lastPathComponent, systemImage: "folder")
                            Spacer()
                            Button(role: .destructive) { library.removeFolder(url) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button("Add Folder…") { library.presentFolderImporter() }
                    Button("Rescan All") { library.scan() }
                }
            }
            Section("Metadata") {
                Text("Embedded tags and artwork are used first. Missing album covers are looked up from MusicBrainz and the Cover Art Archive in the background.")
                    .foregroundStyle(.secondary)
                SecureField("AcoustID API key", text: Binding(
                    get: { library.acoustIDAPIKey },
                    set: { library.acoustIDAPIKey = $0 }
                ))
                Text("Install Chromaprint's fpcalc and add your AcoustID application key to enable track identification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Artist artwork") {
                SecureField("Last.fm API key", text: Binding(
                    get: { library.lastFMAPIKey },
                    set: { library.lastFMAPIKey = $0 }
                ))
                Button("Fetch Artist Images") { library.fetchArtistArtwork() }
                    .disabled(library.isEnrichingArtistArtwork)
                Text("Artist images are cached locally and fetched from Last.fm using the artist name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720)
    }
}
