import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var showingNowPlaying = false
    @State private var showingOnboarding = false
    @AppStorage("has-completed-onboarding") private var hasCompletedOnboarding = false
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
        .toolbar {
            ToolbarItem(placement: .automatic) {
                globalSearchField
            }
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
        .onChange(of: library.tracks.count) { _, _ in
            queue.resolveRestoredSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .uziqShowNowPlaying)) { _ in
            showingNowPlaying = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .uziqShowOnboarding)) { _ in
            showingOnboarding = true
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
        .alert("Playback issue", isPresented: Binding(
            get: { queue.error != nil },
            set: { if !$0 { queue.clearError() } }
        )) {
            Button("OK") { queue.clearError() }
        } message: {
            Text(queue.error ?? "Unknown playback error")
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
                .environment(library)
                .environment(playback)
                .environment(bandcamp)
                .environment(spotify)
                .environment(jellyfin)
                .environment(queue)
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
                showingOnboarding = false
            }
            .environment(library)
            .environment(bandcamp)
            .environment(spotify)
            .environment(jellyfin)
        }
        .task {
            queue.attach(library: library, playback: playback, bandcamp: bandcamp, spotify: spotify, jellyfin: jellyfin)
            synchronizeSearchProvider()
            if !hasCompletedOnboarding { showingOnboarding = true }
        }
    }

    private var globalSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $globalSearchText)
                .textFieldStyle(.plain)
                .onSubmit { performGlobalSearch() }

            if !globalSearchText.isEmpty {
                Button { globalSearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Divider()
                .frame(height: 18)

            Menu {
                ForEach(SearchProvider.allCases) { provider in
                    Button {
                        searchProvider = provider
                    } label: {
                        if searchProvider == provider {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Text(provider.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(searchProvider.title)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose where Uziq searches")
        }
        .padding(.horizontal, 10)
        .frame(width: 390, height: 30)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private func performGlobalSearch() {
        switch searchProvider {
        case .local:
            library.searchText = globalSearchText
            library.selectedSection = .library
            Task { await library.refresh() }
        case .bandcamp:
            bandcamp.query = globalSearchText
            library.selectedSection = .bandcamp
            bandcamp.search()
        case .spotify:
            spotify.query = globalSearchText
            library.selectedSection = .spotify
            spotify.search()
        case .jellyfin:
            jellyfin.query = globalSearchText
            library.selectedSection = .jellyfin
            jellyfin.search()
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
        case .jellyfin:
            searchProvider = .jellyfin
            globalSearchText = jellyfin.query
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
            Section("External") {
                ForEach([LibrarySection.bandcamp, .spotify, .jellyfin], id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            Section("Uziq") {
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
            } else if library.selectedSection == .jellyfin {
                JellyfinLibraryView()
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
                case .jellyfin:
                    JellyfinLibraryView()
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
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        @Bindable var library = library
        List {
            Section {
                if library.displayedTracks.isEmpty && library.selectedSection == .mostPlayed {
                    ContentUnavailableView(
                        "No plays yet",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Tracks you start playing will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(library.displayedTracks) { track in
                        TrackRow(
                            track: track,
                            play: { queue.replace(with: library.displayedTracks, startingAt: track) },
                            showsDivider: false
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
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
                .textCase(nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                                    NavigationLink {
                                        ArtistDetailView(artist: artist)
                                    } label: {
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
    @Environment(PlaybackQueueStore.self) private var queue

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
                            if let first = album.tracks.first { queue.replace(with: album.tracks, startingAt: first) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                LazyVStack(spacing: 0) {
                    ForEach(album.tracks) { track in
                        TrackRow(track: track) {
                            queue.replace(with: album.tracks, startingAt: track)
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
    @Environment(PlaybackQueueStore.self) private var queue
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
                                queue.replace(with: artist.tracks, startingAt: track)
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
    var showsDivider = true
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlaybackQueueStore.self) private var queue

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
            Button("Play Next") { queue.playNext(track) }
            Button("Add to Queue") { queue.add(track) }
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
        if showsDivider { Divider() }
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
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var tracks: [Track] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .lastTextBaseline) {
                    LibraryHeading(title: playlist.name, subtitle: "\(tracks.count) tracks")
                    if let first = tracks.first {
                        Button("Play Playlist") { queue.replace(with: tracks, startingAt: first) }
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
                                play: { queue.replace(with: tracks, startingAt: track) },
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
    @Environment(PlaybackQueueStore.self) private var queue

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
            Button("Play Next") { queue.playNext(track) }
            Button("Add to Queue") { queue.add(track) }
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
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(PlaybackEngine.self) private var playback
    @Environment(SpotifyStore.self) private var spotify
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        Label(queue.currentItem?.source.title ?? "Uziq", systemImage: queue.currentItem?.source.systemImage ?? "music.note")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }

                    currentArtwork
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.24), radius: 22, y: 10)

                    VStack(spacing: 6) {
                        Text(currentTitle).font(.title.weight(.bold)).lineLimit(2)
                        Text(currentArtist).font(.title3).foregroundStyle(.secondary)
                        Text(currentAlbum).font(.subheadline).foregroundStyle(.tertiary)
                    }
                    .multilineTextAlignment(.center)

                    PlayerTimeline(height: 42)
                    PlayerTransportControls()

                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(queue.volume) },
                                set: { queue.volume = Float($0) }
                            ),
                            in: 0...1
                        )
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Lyrics").font(.title3.weight(.bold))
                        if let lyrics = playback.currentTrack?.lyrics, !lyrics.isEmpty {
                            Text(lyrics)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } else {
                            Text("No lyrics are available for this track yet.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(28)
            }
            .frame(minWidth: 520)

            Divider()
            QueueSidebarView()
                .frame(width: 340)
        }
        .frame(minWidth: 880, minHeight: 680)
    }

    @ViewBuilder private var currentArtwork: some View {
        if queue.currentItem?.source == .local {
            ArtworkView(data: playback.currentTrack?.artworkData ?? queue.currentItem.flatMap(queue.localTrack(for:))?.artworkData)
        } else if queue.currentItem?.source == .spotify {
            SpotifyRemoteArtwork(url: spotify.playback?.artworkURL ?? queue.currentItem?.artworkURL, systemImage: "music.note")
        } else if queue.currentItem?.source == .jellyfin {
            ArtworkView(data: playback.currentTrack?.artworkData)
        } else {
            SpotifyRemoteArtwork(url: queue.currentItem?.artworkURL, systemImage: "dot.radiowaves.left.and.right")
        }
    }

    private var currentTitle: String {
        if queue.currentItem?.source == .spotify { return spotify.playback?.title ?? queue.currentItem?.title ?? "Nothing playing" }
        return playback.currentTrack?.displayTitle ?? queue.currentItem?.title ?? "Nothing playing"
    }
    private var currentArtist: String {
        if queue.currentItem?.source == .spotify { return spotify.playback?.artist ?? queue.currentItem?.artist ?? "" }
        return playback.currentTrack?.displayArtist ?? queue.currentItem?.artist ?? "Choose something to play"
    }
    private var currentAlbum: String {
        if queue.currentItem?.source == .spotify { return spotify.playback?.album ?? queue.currentItem?.album ?? "" }
        return playback.currentTrack?.displayAlbum ?? queue.currentItem?.album ?? ""
    }
}

private struct QueueSidebarView: View {
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up Next").font(.title2.weight(.bold))
                    Text("\(queue.items.count) items").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { queue.clear() }.disabled(queue.items.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)

            if queue.items.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                        Button { queue.play(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.source.systemImage)
                                    .foregroundStyle(queue.currentItem?.id == item.id ? Color.accentColor : .secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text("\(item.artist) · \(item.source.title)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if queue.currentItem?.id == item.id {
                                    Image(systemName: queue.isPlaying ? "waveform" : "pause.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from Queue", role: .destructive) {
                                queue.remove(at: IndexSet(integer: index))
                            }
                        }
                    }
                    .onDelete(perform: queue.remove)
                    .onMove(perform: queue.move)
                }
                .listStyle(.inset)
            }

            HStack {
                Button { queue.shuffleEnabled.toggle() } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .foregroundStyle(queue.shuffleEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { queue.cycleRepeatMode() } label: {
                    Label(queue.repeatMode.title, systemImage: queue.repeatMode.systemImage)
                        .foregroundStyle(queue.repeatMode == .off ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .background(.bar)
    }
}

struct MiniPlayerView: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(PlaybackEngine.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 18) {
                    Button(action: onOpen) {
                        HStack(spacing: 14) {
                            miniArtwork
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(currentTitle).font(.headline).lineLimit(1)
                                Text(currentArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                HStack(spacing: 7) {
                                    Text(currentAlbum)
                                        .lineLimit(1)
                                    if let source = queue.currentItem?.source {
                                        Label(source.title, systemImage: source.systemImage)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(.quaternary, in: Capsule())
                                            .fixedSize()
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    HStack(spacing: 12) {
                        Button(action: toggleCurrentTrackLike) {
                            Image(systemName: isCurrentTrackLiked ? "heart.fill" : "heart")
                                .foregroundStyle(isCurrentTrackLiked ? .pink : .secondary)
                                .frame(width: 34, height: 34).background(.quaternary, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            queue.currentItem == nil || queue.currentItem?.source == .spotify ||
                            (queue.currentItem?.source == .jellyfin && queue.currentItem?.jellyfinItem.map(jellyfin.isUpdatingFavorite) == true)
                        )
                        Button(action: onOpen) {
                            Image(systemName: "list.bullet.rectangle")
                                .frame(width: 34, height: 34).background(.quaternary, in: Circle())
                        }
                        .buttonStyle(.plain).help("Open Now Playing and Queue")
                    }
                }
                PlayerTransportControls()
            }
            PlayerTimeline(height: 28)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder private var miniArtwork: some View {
        if queue.currentItem?.source == .local {
            ArtworkView(data: playback.currentTrack?.artworkData ?? queue.currentItem.flatMap(queue.localTrack(for:))?.artworkData)
        } else if queue.currentItem?.source == .spotify {
            SpotifyRemoteArtwork(url: spotify.playback?.artworkURL ?? queue.currentItem?.artworkURL, systemImage: "music.note")
        } else if queue.currentItem?.source == .jellyfin {
            ArtworkView(data: playback.currentTrack?.artworkData)
        } else {
            SpotifyRemoteArtwork(url: queue.currentItem?.artworkURL, systemImage: "dot.radiowaves.left.and.right")
        }
    }

    private var currentTitle: String {
        queue.currentItem?.source == .spotify ? spotify.playback?.title ?? queue.currentItem?.title ?? "Nothing playing" : playback.currentTrack?.displayTitle ?? queue.currentItem?.title ?? "Nothing playing"
    }
    private var currentArtist: String {
        queue.currentItem?.source == .spotify ? spotify.playback?.artist ?? queue.currentItem?.artist ?? "" : playback.currentTrack?.displayArtist ?? queue.currentItem?.artist ?? "Choose something to play"
    }
    private var currentAlbum: String {
        queue.currentItem?.source == .spotify ? spotify.playback?.album ?? queue.currentItem?.album ?? "" : playback.currentTrack?.displayAlbum ?? queue.currentItem?.album ?? ""
    }
    private var isCurrentTrackLiked: Bool {
        if queue.currentItem?.source == .jellyfin, let item = queue.currentItem?.jellyfinItem {
            return jellyfin.isFavorite(item)
        }
        guard let track = playback.currentTrack else { return false }
        return track.id.hasPrefix("bandcamp-") ? bandcamp.isSaved(track) : library.isFavorite(track)
    }
    private func toggleCurrentTrackLike() {
        if queue.currentItem?.source == .jellyfin, let item = queue.currentItem?.jellyfinItem {
            jellyfin.toggleFavorite(item)
            return
        }
        guard let track = playback.currentTrack else { return }
        track.id.hasPrefix("bandcamp-") ? bandcamp.toggleSaved(track) : library.toggleFavorite(track)
    }
}

private struct PlayerTimeline: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(PlaybackEngine.self) private var playback
    @Environment(SpotifyStore.self) private var spotify
    let height: CGFloat

    var body: some View {
        Group {
            if shouldAnimate {
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    timelineContent(at: timeline.date)
                }
            } else {
                timelineContent(at: .now)
            }
        }
    }

    private var shouldAnimate: Bool {
        if queue.currentItem?.source == .spotify { return spotify.playback?.isPlaying == true }
        return playback.isPlaying
    }

    private func timelineContent(at date: Date) -> some View {
        HStack(spacing: 10) {
            Text(formatTime(time(at: date))).frame(width: 42, alignment: .leading)
            Group {
                if queue.currentItem?.source == .spotify, let current = spotify.playback {
                    StreamingWaveformView(
                        seed: current.itemID,
                        progress: current.duration > 0 ? current.effectiveProgress(at: date) / current.duration : 0,
                        duration: current.duration,
                        onSeek: queue.seek
                    )
                } else {
                    WaveformView(
                        url: playback.currentTrack?.url,
                        progress: queue.duration > 0 ? queue.currentTime / queue.duration : 0,
                        duration: queue.duration,
                        onSeek: queue.seek
                    )
                }
            }
            .frame(height: height)
            Text(formatTime(queue.duration)).frame(width: 42, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func time(at date: Date) -> Double {
        if queue.currentItem?.source == .spotify { return spotify.playback?.effectiveProgress(at: date) ?? queue.currentTime }
        return queue.currentTime
    }
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct PlayerTransportControls: View {
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        HStack(spacing: 12) {
            transportButton("backward.fill", size: 36, action: queue.previous)
            Button(action: queue.toggle) {
                Image(systemName: queue.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.gradient, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            transportButton("forward.fill", size: 36, action: queue.next)
        }
        .disabled(queue.currentItem == nil && queue.items.isEmpty)
    }

    private func transportButton(_ image: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).font(.system(size: 13, weight: .semibold))
                .frame(width: size, height: size).background(.quaternary, in: Circle())
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
            if let data, let image = ArtworkImageCache.shared.image(for: data) {
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

struct CachedRemoteArtwork<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var data: Data?

    var body: some View {
        Group {
            if let data {
                ArtworkView(data: data)
            } else {
                placeholder()
            }
        }
        .clipped()
        .task(id: url) {
            data = nil
            data = await RemoteArtworkCache.shared.data(for: url)
        }
    }
}

private final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for data: Data) -> NSImage? {
        let key = cacheKey(for: data)
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private func cacheKey(for data: Data) -> NSString {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data.prefix(32) {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        for byte in data.suffix(32) {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "\(data.count)-\(hash)" as NSString
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var bandcampPassword = ""
    @State private var bandcampAuthCode = ""
    @State private var jellyfinPassword = ""
    @State private var diagnosticsMessage: String?

    var body: some View {
        Form {
            Section("Setup") {
                Button {
                    NotificationCenter.default.post(name: .uziqShowOnboarding, object: nil)
                } label: {
                    Label("Run Setup Assistant…", systemImage: "wand.and.stars")
                }
                Text("Configure local folders and streaming accounts in one guided flow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library folders") {
                if library.folderRoots.isEmpty {
                    if library.tracks.isEmpty {
                        Text("No folders added")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "The index contains \(library.tracks.count) tracks, but Uziq no longer has an active folder root. Re-add the parent music folders to enable rescanning.",
                            systemImage: "folder.badge.questionmark"
                        )
                        .foregroundStyle(.orange)
                    }
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
                        .disabled(library.folderRoots.isEmpty)
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
                Text("Ten-band equalization is applied to local files and cached Bandcamp and Jellyfin playback. Spotify uses librespot’s native CoreAudio output for stable streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Jellyfin") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Self-hosted music", systemImage: "server.rack")
                        .font(.headline)
                    Text("Connect a Jellyfin account to browse, search, and play music from your server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Server URL (for example, http://jellyfin.local:8096)", text: Binding(
                    get: { jellyfin.serverAddress },
                    set: { jellyfin.serverAddress = $0 }
                ))
                .disabled(jellyfin.isConnected || jellyfin.isConnecting)
                TextField("Username", text: Binding(
                    get: { jellyfin.username },
                    set: { jellyfin.username = $0 }
                ))
                .disabled(jellyfin.isConnected || jellyfin.isConnecting)

                if jellyfin.isConnected {
                    HStack {
                        Label(
                            "Connected to \(jellyfin.serverName ?? "Jellyfin") as \(jellyfin.profileName ?? jellyfin.username)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) { jellyfin.disconnect() }
                    }
                } else {
                    SecureField("Password", text: $jellyfinPassword)
                        .disabled(jellyfin.isConnecting)
                    HStack {
                        Button("Connect Jellyfin") { jellyfin.connect(password: jellyfinPassword) }
                            .disabled(
                                jellyfin.isConnecting || jellyfin.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                jellyfin.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jellyfinPassword.isEmpty
                            )
                        if jellyfin.isConnecting { ProgressView().controlSize(.small) }
                    }
                }
                if let error = jellyfin.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Your password is never stored. Jellyfin’s access token is kept in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Bandcamp") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Fan account", systemImage: "person.crop.circle")
                        .font(.headline)
                    Text("Connect your Bandcamp account to use authenticated high-quality streams for music you own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Bandcamp email", text: Binding(
                    get: { bandcamp.accountEmail },
                    set: { bandcamp.accountEmail = $0 }
                ))
                .textContentType(.emailAddress)
                .disabled(bandcamp.isAuthenticated || bandcamp.isAuthenticating)

                if bandcamp.isAuthenticated {
                    HStack {
                        Label(
                            bandcamp.authStatusMessage ?? "Connected as \(bandcamp.accountEmail)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) { bandcamp.signOut() }
                    }
                } else {
                    SecureField("Bandcamp password", text: $bandcampPassword)
                        .textContentType(.password)
                        .disabled(bandcamp.isAuthenticating)
                    SecureField("Two-factor code (if enabled)", text: $bandcampAuthCode)
                        .disabled(bandcamp.isAuthenticating)
                    HStack {
                        Button(bandcamp.authRequiresRetry ? "Connect Again" : "Connect Bandcamp Account") {
                            bandcamp.signIn(password: bandcampPassword, authCode: bandcampAuthCode)
                        }
                        .disabled(
                            bandcamp.isAuthenticating ||
                            bandcamp.accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            bandcampPassword.isEmpty
                        )
                        if bandcamp.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let error = bandcamp.authError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if bandcamp.authRequiresRetry {
                    Label(
                        "Bandcamp may have emailed you to approve this login. Open that email and confirm the sign-in, then return here and click Connect Again.",
                        systemImage: "envelope.badge"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("Your password is sent directly to Bandcamp for login and is never stored. OAuth access and refresh tokens are kept in the macOS Keychain. Unowned releases continue using their normal artist-enabled preview streams.")
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

                HStack {
                    Label("Spotify audio", systemImage: "music.note.house.fill")
                    Spacer()
                    Text("Not cached")
                        .foregroundStyle(.secondary)
                }
                Text("Spotify streams directly through librespot. Audio caching is disabled, so there is nothing to clean up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Label("Jellyfin audio", systemImage: "server.rack")
                    Spacer()
                    Text(jellyfinCacheSummary).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Button("Clean Up Jellyfin Cache") { jellyfin.cleanUpCache() }
                        .disabled(jellyfin.isCleaningCache)
                    if jellyfin.isCleaningCache { ProgressView().controlSize(.small) }
                }
                if let message = jellyfin.cacheMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text("Jellyfin tracks are cached for AVFoundation playback and equalization, then removed after seven days without use.")
                    .font(.caption).foregroundStyle(.secondary)
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

                if spotify.librespot.isUsingBundledExecutable {
                    Label("Playback engine bundled with Uziq", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else if let executable = spotify.librespot.resolvedExecutableURL {
                    Label("Playback engine found automatically", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(executable.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Label("Playback engine not found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                DisclosureGroup("Use a custom librespot binary") {
                    HStack {
                        TextField("librespot executable", text: Binding(
                            get: { spotify.librespot.executablePath },
                            set: { spotify.librespot.executablePath = $0 }
                        ))
                        Button("Choose…") { chooseLibrespotExecutable() }
                    }
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
                Text(spotify.librespot.isUsingBundledExecutable
                    ? "No separate installation is needed. Its first start opens a separate Spotify login; afterward Uziq reuses the credential from Application Support. Audio caching is disabled."
                    : "Development builds find librespot in Homebrew, Cargo, or the custom path above. Install it with `cargo install librespot --version 0.8.0 --locked`. Packaged Uziq builds include the helper automatically.")
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
            Section("Diagnostics") {
                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export Diagnostics…", systemImage: "doc.badge.arrow.up")
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Exports app, library, connection, cache, playback, and recent event information. Passwords, tokens, full home paths, raw librespot output, and complete music file paths are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720)
        .onChange(of: bandcamp.isAuthenticated) { _, connected in
            guard connected else { return }
            bandcampPassword = ""
            bandcampAuthCode = ""
        }
        .onChange(of: jellyfin.isConnected) { _, connected in
            if connected { jellyfinPassword = "" }
        }
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

    private var jellyfinCacheSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: jellyfin.cacheBytes, countStyle: .file)
        return "\(size) · \(jellyfin.cachedFileCount) \(jellyfin.cachedFileCount == 1 ? "file" : "files")"
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

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Uziq Diagnostics"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Uziq-Diagnostics-\(formatter.string(from: .now)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let report = DiagnosticsReport.make(
            library: library,
            playback: playback,
            bandcamp: bandcamp,
            spotify: spotify,
            jellyfin: jellyfin,
            queue: queue
        )
        do {
            try report.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            diagnosticsMessage = "Exported \(url.lastPathComponent)"
            DiagnosticsLog.shared.record("diagnostics", "Export completed")
        } catch {
            diagnosticsMessage = "Export failed: \(error.localizedDescription)"
            DiagnosticsLog.shared.record("diagnostics", "Export failed: \(error.localizedDescription)")
        }
    }
}
