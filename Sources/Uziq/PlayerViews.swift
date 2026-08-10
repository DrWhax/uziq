import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        HStack(spacing: 12) {
            transportButton("backward.fill", size: 36, action: queue.previous)
            Button(action: queue.toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
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

    private var isPlaying: Bool {
        if queue.currentItem?.source == .spotify {
            return spotify.playback?.isPlaying == true
        }
        return queue.isPlaying
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

