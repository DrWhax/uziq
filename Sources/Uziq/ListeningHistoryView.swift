import SwiftUI

struct ListeningHistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        @Bindable var library = library
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Listening History")
                            .font(.largeTitle.weight(.bold))
                        Text("Everything you’ve played across Uziq, in one place.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Period", selection: $library.listeningHistoryRange) {
                        ForEach(MostPlayedRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }

                if library.recentListeningHistory.isEmpty {
                    ContentUnavailableView(
                        "Nothing Played Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Play something from your library, Bandcamp, Spotify, or Jellyfin and it will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    recentCarousel

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Most Played This \(library.listeningHistoryRange.title)")
                            .font(.title2.weight(.bold))
                        Text("Your most-played tracks across every connected source.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(library.mostPlayedListeningHistory.enumerated()), id: \.element.id) { index, item in
                                ListeningHistoryRow(rank: index + 1, item: item)
                                if item.id != library.mostPlayedListeningHistory.last?.id {
                                    Divider().padding(.leading, 88)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(28)
        }
        .task { await library.loadListeningHistory() }
        .onChange(of: library.listeningHistoryRange) { _, _ in
            Task { await library.loadListeningHistory() }
        }
    }

    private var recentCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.title2.weight(.bold))
            Text("Pick up where you left off, regardless of provider.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(library.recentListeningHistory) { item in
                        Button { queue.replace(with: item.queueItem) } label: {
                            ListeningHistoryCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play") { queue.replace(with: item.queueItem) }
                            Button("Play Next") { queue.playNext(item.queueItem) }
                            Button("Add to Queue") { queue.add(item.queueItem) }
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            .mouseDraggableHorizontalScroll()
            .padding(.horizontal, -28)
            .frame(height: 224)
        }
    }
}

private struct ListeningHistoryCard: View {
    let item: ListeningHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                ListeningHistoryArtwork(item: item)
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Label(item.source.title, systemImage: item.source.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.68), in: Capsule())
                    .padding(8)
            }
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            Text(item.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.lastPlayedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 150, alignment: .leading)
    }
}

private struct ListeningHistoryRow: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let rank: Int
    let item: ListeningHistoryItem

    var body: some View {
        Button { queue.replace(with: item.queueItem) } label: {
            HStack(spacing: 13) {
                Text("\(rank)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                ListeningHistoryArtwork(item: item)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label(item.source.title, systemImage: item.source.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 105, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.playCount == 1 ? "1 play" : "\(item.playCount) plays")
                        .font(.callout.weight(.semibold))
                    Text(item.lastPlayedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 86, alignment: .trailing)
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { queue.replace(with: item.queueItem) }
            Button("Play Next") { queue.playNext(item.queueItem) }
            Button("Add to Queue") { queue.add(item.queueItem) }
        }
    }
}

private struct ListeningHistoryArtwork: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let item: ListeningHistoryItem

    var body: some View {
        switch item.source {
        case .local:
            ArtworkView(data: queue.localTrack(for: item.queueItem)?.artworkData)
        case .jellyfin:
            if let jellyfinItem = item.queueItem.jellyfinItem {
                JellyfinArtwork(item: jellyfinItem)
            } else {
                placeholder
            }
        case .bandcamp, .spotify:
            CachedRemoteArtwork(url: item.artworkURL ?? item.queueItem.artworkURL) {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.72), .purple.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: item.source.systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
