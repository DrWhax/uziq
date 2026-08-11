import SwiftUI

struct UpNextView: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                queuePane
                    .frame(minHeight: 230, idealHeight: 320)
                ProviderLyricsView()
                    .frame(minHeight: 180, idealHeight: 320)
            }
        }
        .background(.bar)
    }

    private var queuePane: some View {
        VStack(spacing: 0) {
            if let current = queue.currentItem {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NOW PLAYING")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    QueueItemRow(
                        item: current,
                        isCurrent: true,
                        onPlay: queue.replay,
                        onRemove: nil
                    )
                }
                .padding(16)
                Divider()
            }

            upcomingHeader

            if queue.upcomingItems.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                } description: {
                    Text(queue.currentItem == nil
                        ? "Choose music or start a random queue."
                        : "This is the last item in the queue.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(queue.upcomingItems)) { item in
                        QueueItemRow(
                            item: item,
                            isCurrent: false,
                            onPlay: { queue.play(item) },
                            onRemove: { queue.remove(item) }
                        )
                        .contextMenu {
                            Button("Play Now") { queue.play(item) }
                            Divider()
                            Button("Remove from Queue", role: .destructive) {
                                queue.remove(item)
                            }
                        }
                    }
                    .onDelete(perform: queue.removeUpcoming)
                    .onMove(perform: queue.moveUpcoming)
                }
                .listStyle(.inset)
            }

            Divider()
            queueControls
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up Next")
                    .font(.title2.weight(.bold))
                Text(queue.upcomingItems.count == 1 ? "1 track queued" : "\(queue.upcomingItems.count) tracks queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close Up Next")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var upcomingHeader: some View {
        HStack {
            Text("COMING UP")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear Up Next") { queue.clearUpcoming() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(queue.upcomingItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 7)
    }

    private var queueControls: some View {
        HStack(spacing: 12) {
            Button { queue.shuffleEnabled.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(queue.shuffleEnabled ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help(queue.shuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On")

            Button { queue.cycleRepeatMode() } label: {
                Image(systemName: queue.repeatMode.systemImage)
                    .foregroundStyle(queue.repeatMode == .off ? .secondary : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help(queue.repeatMode.title)

            Spacer()
            ReplayTrackButton()
            RandomPlaybackMenu()
        }
        .padding(14)
    }
}

private struct ProviderLyricsView: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(PlaybackEngine.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    @State private var state: ProviderLyricsState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Lyrics", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                if case .available(_, let source) = state {
                    Text(source)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            lyricsBody
        }
        .task(id: lyricsIdentity) { await loadLyrics() }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        switch state {
        case .idle:
            lyricsMessage("Choose something to play.", systemImage: "music.note")
                .padding(16)
        case .loading(let provider):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading lyrics from \(provider)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(16)
        case .available(let lyrics, _):
            if lyrics.timedLines.isEmpty {
                ScrollView {
                    Text(lyrics.plainText)
                        .font(.callout)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            } else {
                SyncedLyricsView(lines: lyrics.timedLines)
            }
        case .unavailable(let message):
            lyricsMessage(message, systemImage: "text.quote")
                .padding(16)
        }
    }

    private func lyricsMessage(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lyricsIdentity: String {
        guard let source = queue.currentItem?.source else { return "none" }
        let trackID = source == .spotify
            ? spotify.playback?.itemID
            : playback.currentTrack?.id
        return "\(source.rawValue):\(trackID ?? queue.currentItem?.sourceID ?? "")"
    }

    private func loadLyrics() async {
        guard let source = queue.currentItem?.source else {
            state = .idle
            return
        }
        switch source {
        case .local:
            guard let track = playback.currentTrack else {
                state = .unavailable("This local track is no longer available.")
                return
            }
            if let lyrics = lyricsPresentation(track.lyrics) {
                state = .available(lyrics, source: "Embedded")
                return
            }
            state = .loading(provider: "LRCLIB")
            let result = await library.remoteLyrics(for: track)
            guard !Task.isCancelled else { return }
            switch result {
            case .lyrics(let lyrics):
                let presentation = LyricsPresentation(plain: lyrics.plain, synced: lyrics.synced)
                state = .available(
                    presentation,
                    source: presentation.timedLines.isEmpty ? "LRCLIB · Plain" : "LRCLIB · Synced"
                )
            case .instrumental:
                state = .unavailable("LRCLIB identifies this track as instrumental.")
            case .notFound:
                state = .unavailable("No embedded or LRCLIB lyrics were found for this track.")
            case .unavailable(let message):
                state = .unavailable(message)
            }
        case .bandcamp:
            state = lyricsPresentation(playback.currentTrack?.lyrics)
                .map { .available($0, source: "Bandcamp") }
                ?? .unavailable("Bandcamp did not provide lyrics for this track.")
        case .jellyfin:
            guard let item = queue.currentItem?.jellyfinItem else {
                state = .unavailable("This Jellyfin track is no longer available.")
                return
            }
            state = .loading(provider: "Jellyfin")
            let lyrics = await jellyfin.lyrics(for: item)
            guard !Task.isCancelled else { return }
            state = lyrics.map { .available(LyricsPresentation(plain: $0), source: "Jellyfin") }
                ?? .unavailable("Jellyfin has no lyrics for this track.")
        case .spotify:
            state = .unavailable("Lyrics aren’t available through Uziq’s Spotify integration.")
        }
    }

    private func lyricsPresentation(_ value: String?) -> LyricsPresentation? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : LyricsPresentation(plain: normalized)
    }
}

private enum ProviderLyricsState: Equatable {
    case idle
    case loading(provider: String)
    case available(LyricsPresentation, source: String)
    case unavailable(String)
}

private struct SyncedLyricsView: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let lines: [TimedLyricsLine]

    var body: some View {
        TimelineView(.periodic(from: .now, by: queue.isPlaying ? 0.5 : 5)) { _ in
            let activeIndex = lines.lastIndex { $0.time <= queue.currentTime + 0.05 }
            let activeID = activeIndex.map { lines[$0].id }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            Button {
                                queue.seek(to: line.time)
                            } label: {
                                Text(line.text)
                                    .font(.title3.weight(index == activeIndex ? .bold : .medium))
                                    .foregroundStyle(lineColor(index: index, activeIndex: activeIndex))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        index == activeIndex ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(line.id)
                            .help("Jump to \(formatted(line.time))")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 50)
                }
                .onChange(of: activeID, initial: true) { _, newID in
                    guard let newID else { return }
                    withAnimation(.smooth(duration: 0.45)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func lineColor(index: Int, activeIndex: Int?) -> Color {
        guard let activeIndex else { return .secondary }
        if index == activeIndex { return .accentColor }
        return index < activeIndex ? .primary.opacity(0.55) : .secondary.opacity(0.7)
    }

    private func formatted(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct QueueItemRow: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let item: UnifiedQueueItem
    let isCurrent: Bool
    let onPlay: () -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    queueArtwork
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.artist.isEmpty ? item.album : item.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Label(item.source.title, systemImage: item.source.systemImage)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        Image(systemName: queue.isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from Queue")

                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .help("Drag to Reorder")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var queueArtwork: some View {
        switch item.source {
        case .local:
            ArtworkView(data: queue.localTrack(for: item)?.artworkData)
        case .jellyfin:
            if let jellyfinItem = item.jellyfinItem {
                JellyfinArtwork(item: jellyfinItem)
            } else {
                artworkPlaceholder
            }
        case .bandcamp, .spotify:
            CachedRemoteArtwork(url: item.artworkURL) {
                artworkPlaceholder
            }
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.68), .purple.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: item.source.systemImage)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

struct ReplayTrackButton: View {
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        Button(action: queue.replay) {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 34, height: 34)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(queue.currentItem == nil)
        .help("Replay Current Track")
    }
}

struct RandomPlaybackMenu: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(LibraryStore.self) private var library
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin

    var body: some View {
        Menu {
            Section("Play a Random Queue") {
                randomButton(
                    source: .local,
                    title: "Local Library",
                    count: library.tracks.count,
                    isEnabled: !library.tracks.isEmpty
                )
                randomButton(
                    source: .bandcamp,
                    title: "Bandcamp Collection",
                    count: playableBandcampCount,
                    isEnabled: playableBandcampCount > 0
                )
                randomButton(
                    source: .spotify,
                    title: "Spotify Liked Songs",
                    count: playableSpotifyCount,
                    isEnabled: playableSpotifyCount > 0
                )
                randomButton(
                    source: .jellyfin,
                    title: "Jellyfin Library",
                    count: nil,
                    isEnabled: jellyfin.isConnected
                )
            }
        } label: {
            Group {
                if queue.preparingRandomSource != nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "dice.fill")
                }
            }
            .frame(width: 34, height: 34)
            .background(.quaternary, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Play Random Music")
    }

    private var playableBandcampCount: Int {
        bandcamp.ownedResults.lazy.filter(\.isPlayable).count
    }

    private var playableSpotifyCount: Int {
        spotify.likedSongs.lazy.filter { $0.kind == .track && !$0.uri.isEmpty }.count
    }

    private func randomButton(
        source: PlaybackSource,
        title: String,
        count: Int?,
        isEnabled: Bool
    ) -> some View {
        Button { queue.playRandom(from: source) } label: {
            Label(
                count.map { "\(title) (\($0))" } ?? title,
                systemImage: queue.preparingRandomSource == source ? "hourglass" : source.systemImage
            )
        }
        .disabled(!isEnabled)
    }
}
