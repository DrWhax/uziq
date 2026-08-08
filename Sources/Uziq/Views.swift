import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @State private var showingNowPlaying = false
    @State private var globalSearchText = ""
    @State private var searchProvider: SearchProvider = .local

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
        .searchable(text: $globalSearchText, placement: .toolbar, prompt: "Search music")
        .searchScopes($searchProvider) {
            ForEach(SearchProvider.allCases) { provider in
                Text(provider.title).tag(provider)
            }
        }
        .onSubmit(of: .search) {
            performGlobalSearch()
        }
        .onChange(of: globalSearchText) { _, newValue in
            guard searchProvider == .local else { return }
            library.searchText = newValue
            Task { await library.refresh() }
        }
        .onChange(of: library.selectedSection) { _, _ in
            synchronizeSearchProvider()
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
        .task {
            spotify.attachPlaybackEngine(playback)
            synchronizeSearchProvider()
        }
    }

    private func performGlobalSearch() {
        switch searchProvider {
        case .local:
            library.searchText = globalSearchText
            Task { await library.refresh() }
        case .bandcamp:
            bandcamp.query = globalSearchText
            library.selectedSection = .bandcamp
            bandcamp.search()
        case .spotify:
            spotify.query = globalSearchText
            library.selectedSection = .spotify
            spotify.search()
        }
    }

    private func synchronizeSearchProvider() {
        switch library.selectedSection {
        case .bandcamp:
            searchProvider = .bandcamp
            globalSearchText = bandcamp.query
        case .spotify:
            searchProvider = .spotify
            globalSearchText = spotify.query
        case .settings:
            break
        default:
            searchProvider = .local
            globalSearchText = library.searchText
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
                ForEach([LibrarySection.bandcamp, .spotify], id: \.self) { section in
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
            } else if library.selectedSection == .bandcamp {
                BandcampLibraryView()
            } else if library.selectedSection == .spotify {
                SpotifyLibraryView()
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
                case .bandcamp:
                    BandcampLibraryView()
                case .spotify:
                    SpotifyLibraryView()
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
                    ForEach(artistSections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.letter)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                                spacing: 10
                            ) {
                                ForEach(section.artists) { artist in
                                    Button { selectedArtist = artist } label: {
                                        ArtistRow(artist: artist, showDivider: false)
                                            .padding(.horizontal, 12)
                                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(28)
        }
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist)
        }
        .task {
            await library.loadArtistArtwork()
            library.refreshArtistArtworkIfNeeded()
        }
        }
    }

    private var artists: [ArtistGroup] { ArtistGroup.grouped(library.displayedTracks) }

    private var artistSections: [ArtistLetterSection] {
        Dictionary(grouping: artists) { artist in
            guard let first = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).first,
                  first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        .map { ArtistLetterSection(letter: $0.key, artists: $0.value) }
        .sorted {
            if $0.letter == "#" { return false }
            if $1.letter == "#" { return true }
            return $0.letter < $1.letter
        }
    }
}

private struct ArtistLetterSection: Identifiable {
    let letter: String
    let artists: [ArtistGroup]
    var id: String { letter }
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
                        ArtworkView(data: library.artistArtwork[artist.name]
                            ?? library.artistArtworkData(for: artist.name)
                            ?? artist.albums.first?.artworkData)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(artist.name)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            Text("\(artist.albums.count) albums · \(artist.tracks.count) tracks")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let profile = library.artistProfiles[artist.name] {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("About \(artist.name)")
                                    .font(.title2.weight(.bold))
                                Text(profile.source.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(shortSummary(profile.summary))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: 720, alignment: .leading)
                        }
                    } else if library.artistProfilesLoading.contains(artist.name) {
                        ProgressView("Loading artist information…")
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
        .task(id: artist.name) {
            await library.loadArtistArtwork()
            library.refreshArtistArtworkIfNeeded()
            library.loadArtistProfile(for: artist.name)
        }
    }

    private func shortSummary(_ text: String) -> String {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
                if sentences.count == 2 { break }
            }
        }
        if sentences.isEmpty {
            return String(text.prefix(420))
        }
        return sentences.joined(separator: " ")
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
    var showDivider = true
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(data: library.artistArtwork[artist.name]
                ?? library.artistArtworkData(for: artist.name)
                ?? artist.albums.first?.artworkData)
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
        if showDivider { Divider() }
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
    @Environment(LibraryStore.self) private var library
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 18) {
                    Button(action: openCurrentPlayer) {
                        HStack(spacing: 14) {
                            Group {
                                if spotify.isUziqPlaybackActive {
                                    SpotifyRemoteArtwork(url: spotify.playback?.artworkURL, systemImage: "music.note")
                                } else {
                                    ArtworkView(data: playback.currentTrack?.artworkData)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(currentTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(currentArtist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(currentAlbum)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    HStack(spacing: 14) {
                        Button(action: toggleCurrentTrackLike) {
                            Image(systemName: isCurrentTrackLiked ? "heart.fill" : "heart")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isCurrentTrackLiked ? .pink : .secondary)
                                .frame(width: 34, height: 34)
                                .background(.quaternary, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(playback.currentTrack == nil || spotify.isUziqPlaybackActive)
                        .opacity(spotify.isUziqPlaybackActive ? 0 : 1)
                        .help(isCurrentTrackLiked ? "Unlike track" : "Like track")

                        Button(action: openCurrentPlayer) {
                            Image(systemName: "rectangle.expand.vertical")
                                .frame(width: 34, height: 34)
                                .background(.quaternary, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Open Now Playing")
                    }
                }

                PlayerTransportControls()
            }

            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                HStack(spacing: 10) {
                    Text(formatTime(currentTime(at: timeline.date)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)

                    Group {
                        if spotify.isUziqPlaybackActive, let current = spotify.playback {
                            StreamingWaveformView(
                                seed: current.itemID,
                                progress: current.duration > 0 ? current.effectiveProgress(at: timeline.date) / current.duration : 0,
                                duration: current.duration
                            ) { spotify.seek(to: $0) }
                        } else {
                            WaveformView(
                                url: playback.currentTrack?.url,
                                progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                                duration: playback.duration
                            ) { seconds in
                                playback.seek(to: seconds)
                            }
                        }
                    }
                    .frame(height: 28)

                    Text(formatTime(currentDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
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

    private var currentTitle: String {
        spotify.isUziqPlaybackActive
            ? spotify.playback?.title ?? "Spotify"
            : playback.currentTrack?.displayTitle ?? "Nothing playing"
    }

    private var currentArtist: String {
        spotify.isUziqPlaybackActive
            ? spotify.playback?.artist ?? "Spotify"
            : playback.currentTrack?.displayArtist ?? "Choose a track from your library"
    }

    private var currentAlbum: String {
        spotify.isUziqPlaybackActive
            ? spotify.playback?.album ?? ""
            : playback.currentTrack?.displayAlbum ?? ""
    }

    private var currentDuration: Double {
        spotify.isUziqPlaybackActive ? spotify.playback?.duration ?? 0 : playback.duration
    }

    private func currentTime(at date: Date) -> Double {
        spotify.isUziqPlaybackActive
            ? spotify.playback?.effectiveProgress(at: date) ?? 0
            : playback.currentTime
    }

    private func openCurrentPlayer() {
        if spotify.isUziqPlaybackActive {
            library.selectedSection = .spotify
        } else {
            onOpen()
        }
    }

    private var isCurrentTrackLiked: Bool {
        guard let track = playback.currentTrack else { return false }
        return track.id.hasPrefix("bandcamp-")
            ? bandcamp.isSaved(track)
            : library.isFavorite(track)
    }

    private func toggleCurrentTrackLike() {
        guard let track = playback.currentTrack else { return }
        if track.id.hasPrefix("bandcamp-") {
            bandcamp.toggleSaved(track)
        } else {
            library.toggleFavorite(track)
        }
    }
}

struct PlayerTransportControls: View {
    @Environment(PlaybackEngine.self) private var playback
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        HStack(spacing: 12) {
            transportButton("backward.fill", size: 36) {
                spotify.isUziqPlaybackActive ? spotify.previous() : playback.previous()
            }
            Button {
                spotify.isUziqPlaybackActive ? spotify.togglePlayback() : playback.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.gradient, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            transportButton("forward.fill", size: 36) {
                spotify.isUziqPlaybackActive ? spotify.next() : playback.next()
            }
        }
        .disabled(playback.currentTrack == nil && !spotify.isUziqPlaybackActive)
    }

    private var isPlaying: Bool {
        spotify.isUziqPlaybackActive ? spotify.playback?.isPlaying == true : playback.isPlaying
    }

    private func transportButton(_ image: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct StreamingWaveformView: View {
    let seed: String
    let progress: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<64, id: \.self) { index in
                        Capsule()
                            .fill(index < playedBarCount ? Color.accentColor : Color.secondary.opacity(0.28))
                            .frame(maxWidth: .infinity)
                            .frame(height: 4 + deterministicHeight(index) * 20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if duration > 0 {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 2.5, height: 28)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                        .offset(x: max(0, min(geometry.size.width - 2.5, geometry.size.width * clampedProgress)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, geometry.size.width > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / geometry.size.width))
                        onSeek(duration * fraction)
                    }
            )
        }
        .animation(.linear(duration: 0.18), value: progress)
    }

    private var clampedProgress: Double {
        min(1, max(0, progress.isFinite ? progress : 0))
    }

    private var playedBarCount: Int {
        Int(64 * clampedProgress)
    }

    private func deterministicHeight(_ index: Int) -> CGFloat {
        var hasher = Hasher()
        hasher.combine(seed)
        hasher.combine(index)
        return CGFloat(abs(hasher.finalize() % 100)) / 100
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
    @Environment(PlaybackEngine.self) private var playback
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify

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
            Section("Equalizer") {
                Toggle("Enable equalizer", isOn: Binding(
                    get: { playback.equalizerEnabled },
                    set: { playback.equalizerEnabled = $0 }
                ))
                Picker("Preset", selection: Binding(
                    get: { playback.equalizerPreset },
                    set: { playback.applyEqualizerPreset($0) }
                )) {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(PlaybackEngine.equalizerFrequencies.enumerated()), id: \.offset) { index, frequency in
                        HStack(spacing: 10) {
                            Text(equalizerFrequencyLabel(frequency))
                                .font(.caption.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                            Slider(
                                value: Binding(
                                    get: { Double(playback.equalizerGains[index]) },
                                    set: { playback.setEqualizerGain(Float($0), at: index) }
                                ),
                                in: -12...12,
                                step: 0.5
                            )
                            Text(String(format: "%+.1f", playback.equalizerGains[index]))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                .disabled(!playback.equalizerEnabled)
                Text("Ten-band equalization is applied to local files and cached Bandcamp playback. Spotify uses librespot’s native CoreAudio output for stable streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cache") {
                HStack {
                    Label("Bandcamp audio", systemImage: "internaldrive")
                    Spacer()
                    Text(cacheSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Button("Clean Up Now") { bandcamp.cleanUpCache() }
                        .disabled(bandcamp.isCleaningCache)
                    if bandcamp.isCleaningCache {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let message = bandcamp.cacheMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Bandcamp audio that has not been played for seven days is removed automatically. Cleanup runs when Uziq starts and once per day while it remains open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Spotify") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Catalog and playlists", systemImage: "rectangle.stack.badge.play")
                        .font(.headline)
                    Text("This Web API connection supplies the Spotify page, search results, playlists, and playback controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Spotify Client ID", text: Binding(
                    get: { spotify.clientID },
                    set: { spotify.clientID = $0 }
                ))
                Text("Add \(SpotifyStore.redirectURI.absoluteString) as a Redirect URI in your Spotify developer app. PKCE is used, so Uziq never needs your client secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !spotify.isConfigured {
                    Label("Enter a Client ID above before connecting. Librespot’s login cannot provide playlists or catalog search.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Link("Open Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }

                HStack {
                    if spotify.isAuthorized {
                        Label(spotify.profileName ?? "Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) { spotify.logOut() }
                    } else {
                        Button("Connect Spotify Account") { spotify.logIn() }
                            .disabled(!spotify.isConfigured)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Label("Audio playback engine", systemImage: "waveform")
                        .font(.headline)
                    Text("Librespot makes Uziq appear as a Spotify Connect device and plays through its native CoreAudio backend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField("librespot executable", text: Binding(
                        get: { spotify.librespot.executablePath },
                        set: { spotify.librespot.executablePath = $0 }
                    ))
                    Button("Choose…") { chooseLibrespotExecutable() }
                }
                HStack {
                    Label(spotify.librespot.status.title, systemImage: spotify.librespot.status.isRunning ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                        .foregroundStyle(spotify.librespot.status == .ready ? .green : .secondary)
                    Spacer()
                    if spotify.librespot.status.isRunning {
                        Button("Stop Engine") { spotify.librespot.stop() }
                    } else {
                        Button("Start Engine") { spotify.startPlaybackEngine() }
                            .disabled(spotify.librespot.resolvedExecutableURL == nil)
                    }
                }
                Text("Install the lightweight playback engine with `cargo install librespot --version 0.8.0`. Its first start opens a separate Spotify login. Spotify uses librespot’s native output for reliable buffering and track changes; audio caching is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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

    private func equalizerFrequencyLabel(_ frequency: Float) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000))k"
            : "\(Int(frequency))"
    }

    private var cacheSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: bandcamp.cacheBytes, countStyle: .file)
        return "\(size) · \(bandcamp.cachedFileCount) \(bandcamp.cachedFileCount == 1 ? "file" : "files")"
    }

    private func chooseLibrespotExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose librespot"
        if panel.runModal() == .OK, let url = panel.url {
            spotify.librespot.executablePath = url.path
        }
    }
}
