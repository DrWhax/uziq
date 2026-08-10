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
        .background(.bar)
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
