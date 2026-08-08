import AppKit
import Foundation
import MediaPlayer

struct NowPlayingSnapshot: Equatable {
    let itemID: UUID
    let sourceID: String
    let source: PlaybackSource
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsed: Double
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool
    let artworkData: Data?
    let artworkURL: URL?
}

@MainActor
final class NowPlayingController {
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var lastSnapshot: NowPlayingSnapshot?
    private var artwork: NSImage?
    private var artworkTask: Task<Void, Never>?

    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        toggle: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void,
        previous: @escaping @MainActor () -> Void,
        seek: @escaping @MainActor (Double) -> Void
    ) {
        guard commandTargets.isEmpty else { return }
        addTarget(to: commands.playCommand, name: "play", action: play)
        addTarget(to: commands.pauseCommand, name: "pause", action: pause)
        addTarget(to: commands.togglePlayPauseCommand, name: "toggle", action: toggle)
        addTarget(to: commands.nextTrackCommand, name: "next", action: next)
        addTarget(to: commands.previousTrackCommand, name: "previous", action: previous)

        let positionTarget = commands.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite else { return .commandFailed }
            Task { @MainActor in seek(max(0, event.positionTime)) }
            DiagnosticsLog.shared.record("media", "Control Center seek")
            return .success
        }
        commandTargets.append((commands.changePlaybackPositionCommand, positionTarget))
        commands.changePlaybackPositionCommand.isEnabled = true
    }

    func update(_ snapshot: NowPlayingSnapshot?, force: Bool = false) {
        guard let snapshot else {
            clear()
            return
        }

        let artworkChanged = snapshot.itemID != lastSnapshot?.itemID ||
            (snapshot.artworkData == nil) != (lastSnapshot?.artworkData == nil) ||
            snapshot.artworkURL != lastSnapshot?.artworkURL
        let presentationChanged = snapshot.itemID != lastSnapshot?.itemID ||
            snapshot.sourceID != lastSnapshot?.sourceID ||
            snapshot.title != lastSnapshot?.title ||
            snapshot.artist != lastSnapshot?.artist ||
            snapshot.album != lastSnapshot?.album ||
            snapshot.duration != lastSnapshot?.duration ||
            snapshot.isPlaying != lastSnapshot?.isPlaying ||
            snapshot.hasPrevious != lastSnapshot?.hasPrevious ||
            snapshot.hasNext != lastSnapshot?.hasNext

        lastSnapshot = snapshot
        commands.playCommand.isEnabled = !snapshot.isPlaying
        commands.pauseCommand.isEnabled = snapshot.isPlaying
        commands.togglePlayPauseCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = snapshot.duration > 0
        commands.previousTrackCommand.isEnabled = snapshot.hasPrevious || snapshot.elapsed > 0
        commands.nextTrackCommand.isEnabled = snapshot.hasNext
        if artworkChanged { updateArtwork(for: snapshot) }
        if force || presentationChanged || artworkChanged { publish(snapshot) }
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        lastSnapshot = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        commands.playCommand.isEnabled = false
        commands.pauseCommand.isEnabled = false
        commands.togglePlayPauseCommand.isEnabled = false
        commands.changePlaybackPositionCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = false
    }

    deinit {
        artworkTask?.cancel()
        for (command, target) in commandTargets { command.removeTarget(target) }
    }

    private func addTarget(
        to command: MPRemoteCommand,
        name: String,
        action: @escaping @MainActor () -> Void
    ) {
        let target = command.addTarget { _ in
            Task { @MainActor in action() }
            DiagnosticsLog.shared.record("media", "Control Center command: \(name)")
            return .success
        }
        commandTargets.append((command, target))
        command.isEnabled = true
    }

    private func publish(_ snapshot: NowPlayingSnapshot) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: max(0, snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(0, snapshot.elapsed), max(0, snapshot.duration)),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: "uziq:\(snapshot.source.rawValue):\(snapshot.sourceID)"
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        center.nowPlayingInfo = info
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    private func updateArtwork(for snapshot: NowPlayingSnapshot) {
        artworkTask?.cancel()
        artworkTask = nil
        artwork = snapshot.artworkData.flatMap(NSImage.init(data:))
        guard artwork == nil, let url = snapshot.artworkURL else { return }
        let itemID = snapshot.itemID
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = NSImage(data: data),
                  let self,
                  self.lastSnapshot?.itemID == itemID else { return }
            self.artwork = image
            if let latest = self.lastSnapshot { self.publish(latest) }
        }
    }
}
