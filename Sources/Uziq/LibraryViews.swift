import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct TrackListView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var selectedArtist: ArtistGroup?

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            VStack(spacing: 0) {
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
                .padding(.horizontal, 28)
                .padding(.vertical, 18)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if library.selectedSection == .library && !recentArtistCards.isEmpty {
                            RecentlyPlayedArtistsCarousel(
                                artists: recentArtistCards,
                                onSelect: { selectedArtist = $0 }
                            )
                            .padding(.top, 22)
                            .padding(.bottom, 18)
                            Divider()
                                .padding(.bottom, 8)
                        }

                        if library.displayedTracks.isEmpty {
                            if !library.isInitialLoadComplete {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading your library…")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                            } else if library.selectedSection == .mostPlayed {
                                ContentUnavailableView(
                                    "No plays yet",
                                    systemImage: "chart.bar.xaxis",
                                    description: Text("Tracks you start playing will appear here.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            } else {
                                ContentUnavailableView(
                                    "Your library is waiting",
                                    systemImage: "music.note.house",
                                    description: Text("Add a folder containing music files to get started.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            }
                        } else {
                            ForEach(library.displayedTracks) { track in
                                TrackRow(
                                    track: track,
                                    play: { queue.replace(with: library.displayedTracks, startingAt: track) },
                                    showsDivider: true
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
            }
            .navigationDestination(item: $selectedArtist) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }

    private var recentArtistCards: [(play: RecentArtistPlay, artist: ArtistGroup)] {
        library.recentlyPlayedArtists.compactMap { play in
            library.artistGroup(named: play.name).map { (play, $0) }
        }
    }
}

private struct RecentlyPlayedArtistsCarousel: View {
    @Environment(LibraryStore.self) private var library
    let artists: [(play: RecentArtistPlay, artist: ArtistGroup)]
    let onSelect: (ArtistGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Played This Week")
                .font(.title2.weight(.bold))
            Text("Artists you’ve listened to in the last seven days.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(artists.indices, id: \.self) { index in
                        let entry = artists[index]
                        Button { onSelect(entry.artist) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ArtworkView(data: library.artistArtworkData(for: entry.artist.name)
                                    ?? entry.artist.albums.first?.artworkData)
                                    .frame(width: 118, height: 118)
                                    .clipShape(Circle())
                                Text(entry.artist.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(entry.play.playCount == 1 ? "1 play" : "\(entry.play.playCount) plays")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 118, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
            }
            .mouseDraggableHorizontalScroll()
            .padding(.horizontal, -28)
            .frame(height: 172)
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    LibraryHeading(title: "Albums", subtitle: "\(albums.count) albums")
                    if albums.isEmpty && library.isPreparingBrowseSnapshot {
                        LibraryBrowsePreparingView(label: "Organizing albums…")
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(albums) { album in
                                Button { selectedAlbum = album } label: {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
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

    private var albums: [AlbumGroup] { library.browseSnapshot.albums }
}

struct ArtistsLibraryView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    LibraryHeading(title: "Artists", subtitle: "\(library.browseSnapshot.artistCount) artists")
                    if library.browseSnapshot.artistSections.isEmpty && library.isPreparingBrowseSnapshot {
                        LibraryBrowsePreparingView(label: "Organizing artists…")
                    } else {
                        ForEach(library.browseSnapshot.artistSections) { section in
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
                }
                .padding(28)
            }
            .task {
                if library.artistArtwork.isEmpty { await library.loadArtistArtwork() }
                library.refreshArtistArtworkIfNeeded()
            }
        }
    }

}

struct GenresLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selectedAlbum: AlbumGroup?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    LibraryHeading(title: "Genres", subtitle: "\(genres.count) genres")
                    if genres.isEmpty && library.isPreparingBrowseSnapshot {
                        LibraryBrowsePreparingView(label: "Organizing genres…")
                    } else {
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
                                .mouseDraggableHorizontalScroll()
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

    private var genres: [GenreGroup] { library.browseSnapshot.genres }
}

private struct LibraryBrowsePreparingView: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
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
