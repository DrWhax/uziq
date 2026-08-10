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
    @State private var showingQueue = false
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
            MiniPlayerView(
                onOpen: { showingNowPlaying = true },
                onOpenQueue: { showingQueue.toggle() }
            )

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
            ToolbarItem(placement: .primaryAction) {
                Button { showingQueue.toggle() } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .help(showingQueue ? "Hide Up Next" : "Show Up Next")
            }
        }
        .inspector(isPresented: $showingQueue) { queueInspector }
        .onChange(of: globalSearchText) { _, newValue in
            guard searchProvider == .local else { return }
            library.searchText = newValue
            Task { await library.refresh() }
        }
        .onChange(of: library.selectedSection) { _, selectedSection in
            Task { @MainActor in
                // `List` is backed by NSTableView on macOS. Let its selection
                // delegate finish before changing toolbar state or replacing
                // the detail view's library snapshot.
                await Task.yield()
                guard library.selectedSection == selectedSection else { return }
                synchronizeSearchProvider()
                if selectedSection.usesLocalLibrary {
                    await library.refresh()
                }
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .uziqShowQueue)) { _ in
            showingQueue = true
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
        .alert("Something went wrong", isPresented: libraryErrorPresented) {
            Button("OK") { library.clearError() }
        } message: {
            Text(library.lastError ?? "Unknown error")
        }
        .alert("Playback issue", isPresented: playbackErrorPresented) {
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

    private var libraryErrorPresented: Binding<Bool> {
        Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.clearError() } }
        )
    }

    private var playbackErrorPresented: Binding<Bool> {
        Binding(
            get: { queue.error != nil },
            set: { if !$0 { queue.clearError() } }
        )
    }

    private var queueInspector: some View {
        UpNextView(onClose: { showingQueue = false })
            .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
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
        List(selection: sidebarSelection) {
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

    private var sidebarSelection: Binding<LibrarySection?> {
        Binding(
            get: { library.selectedSection },
            set: { selection in
                guard let selection, selection != library.selectedSection else { return }
                Task { @MainActor in
                    // Publishing through an Observation-backed store from an
                    // NSTableView delegate callback can recursively reload the
                    // table. Commit the selection on the next actor turn.
                    await Task.yield()
                    library.selectedSection = selection
                }
            }
        )
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
            } else if library.tracks.isEmpty &&
                        library.selectedSection != .library &&
                        library.selectedSection != .recentlyAdded &&
                        library.selectedSection != .mostPlayed {
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
