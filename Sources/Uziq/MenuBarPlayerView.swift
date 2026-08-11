import AppKit
import SwiftUI

struct MenuBarPlayerView: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(PlaybackEngine.self) private var playback
    @Environment(SpotifyStore.self) private var spotify
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 13) {
                artwork
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(currentTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(currentArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let source = queue.currentItem?.source {
                        Label(source.title, systemImage: source.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            MenuBarProgressView()

            ZStack {
                HStack(spacing: 18) {
                    Button { queue.previous() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .disabled(queue.currentItem == nil)
                    Button { queue.toggle() } label: {
                        Image(systemName: queue.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                            .background(.tint, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(queue.currentItem == nil)
                    Button { queue.next() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .disabled(!queue.hasNext)
                }
                HStack {
                    Button { queue.shuffleEnabled.toggle() } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(queue.shuffleEnabled ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { queue.cycleRepeatMode() } label: {
                        Image(systemName: queue.repeatMode.systemImage)
                            .foregroundStyle(queue.repeatMode == .off ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 9) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(queue.volume) },
                        set: { queue.volume = Float($0) }
                    ),
                    in: 0...1
                )
            }

            Divider()

            HStack {
                Button("Open Uziq") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder private var artwork: some View {
        if queue.currentItem?.source == .local {
            ArtworkView(
                data: playback.currentTrack?.artworkData
                    ?? queue.currentItem.flatMap(queue.localTrack(for:))?.artworkData
            )
        } else if queue.currentItem?.source == .spotify {
            SpotifyRemoteArtwork(
                url: spotify.playback?.artworkURL ?? queue.currentItem?.artworkURL,
                systemImage: "music.note"
            )
        } else if queue.currentItem?.source == .jellyfin {
            ArtworkView(data: playback.currentTrack?.artworkData)
        } else {
            SpotifyRemoteArtwork(
                url: queue.currentItem?.artworkURL,
                systemImage: "dot.radiowaves.left.and.right"
            )
        }
    }

    private var currentTitle: String {
        if queue.currentItem?.source == .spotify {
            return spotify.playback?.title ?? queue.currentItem?.title ?? "Nothing playing"
        }
        return playback.currentTrack?.displayTitle ?? queue.currentItem?.title ?? "Nothing playing"
    }

    private var currentArtist: String {
        if queue.currentItem?.source == .spotify {
            return spotify.playback?.artist ?? queue.currentItem?.artist ?? ""
        }
        return playback.currentTrack?.displayArtist ?? queue.currentItem?.artist ?? "Choose something to play"
    }
}

private struct MenuBarProgressView: View {
    @Environment(PlaybackQueueStore.self) private var queue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { min(max(0, queue.currentTime), safeDuration) },
                        set: { queue.seek(to: $0) }
                    ),
                    in: 0...safeDuration
                )
                .disabled(queue.duration <= 0)
                HStack {
                    Text(timeText(queue.currentTime))
                    Spacer()
                    Text("−" + timeText(max(0, queue.duration - queue.currentTime)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var safeDuration: Double {
        let duration = queue.duration
        return duration.isFinite && duration > 0 ? duration : 1
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
