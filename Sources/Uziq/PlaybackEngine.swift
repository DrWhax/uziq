import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackEngine {
    var currentTrack: Track?
    var isPlaying = false
    var currentTime = 0.0
    var duration = 0.0
    var volume: Float = 1.0 {
        didSet { audioPlayer?.volume = volume }
    }
    var queue: [Track] = []
    private var currentIndex = 0

    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private let delegate = LocalPlaybackDelegate()
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var toggleObserver: NSObjectProtocol?

    init() {
        delegate.onFinished = { [weak self] in
            Task { @MainActor in self?.advanceCurrentTrack() }
        }
        delegate.onDecodeError = { [weak self] in
            Task { @MainActor in self?.advanceCurrentTrack() }
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .uziqTogglePlayback,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
        }
    }

    deinit {
        progressTimer?.invalidate()
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        audioPlayer?.stop()
    }

    func play(_ track: Track, in tracks: [Track]? = nil) {
        queue = tracks ?? [track]
        let requestedIndex = queue.firstIndex(of: track) ?? 0
        guard let firstAvailable = firstAvailableIndex(startingAt: requestedIndex) else {
            stopPlayback()
            return
        }
        startTrack(at: firstAvailable)
    }

    func toggle() {
        guard let audioPlayer else { return }
        if isPlaying {
            audioPlayer.pause()
            isPlaying = false
        } else if audioPlayer.play() {
            isPlaying = true
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let value = min(safeSeconds, duration > 0 ? duration : safeSeconds)
        audioPlayer?.currentTime = value
        currentTime = value
    }

    func next() {
        guard let nextIndex = firstAvailableIndex(startingAt: currentIndex + 1) else {
            stopPlayback()
            return
        }
        startTrack(at: nextIndex)
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let previousIndex = previousAvailableIndex(before: currentIndex) else {
            seek(to: 0)
            return
        }
        startTrack(at: previousIndex)
    }

    private func startTrack(at index: Int) {
        guard index >= 0, index < queue.count, fileExists(queue[index]) else {
            guard let nextIndex = firstAvailableIndex(startingAt: index + 1) else {
                stopPlayback()
                return
            }
            startTrack(at: nextIndex)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: queue[index].url)
            player.delegate = delegate
            player.volume = volume
            player.prepareToPlay()
            audioPlayer?.stop()
            audioPlayer = player
            currentIndex = index
            currentTrack = queue[index]
            currentTime = 0
            duration = validDuration(player.duration)
            isPlaying = player.play()
            if isPlaying {
                NotificationCenter.default.post(name: .uziqTrackPlayed, object: queue[index].id)
            }
        } catch {
            // A file can disappear or become unreadable between the scan and
            // playback. Treat decode failures like removed queue items.
            guard let nextIndex = firstAvailableIndex(startingAt: index + 1) else {
                stopPlayback()
                return
            }
            startTrack(at: nextIndex)
        }
    }

    private func advanceCurrentTrack() {
        guard let nextIndex = firstAvailableIndex(startingAt: currentIndex + 1) else {
            stopPlayback()
            return
        }
        startTrack(at: nextIndex)
    }

    private func updateProgress() {
        guard let audioPlayer else { return }
        currentTime = audioPlayer.currentTime.isFinite ? max(0, audioPlayer.currentTime) : 0
        duration = validDuration(audioPlayer.duration)
        isPlaying = audioPlayer.isPlaying
    }

    private func firstAvailableIndex(startingAt index: Int) -> Int? {
        guard index < queue.count else { return nil }
        return (max(index, 0)..<queue.count).first(where: { fileExists(queue[$0]) })
    }

    private func previousAvailableIndex(before index: Int) -> Int? {
        guard index > 0 else { return nil }
        return stride(from: index - 1, through: 0, by: -1).first(where: { fileExists(queue[$0]) })
    }

    private func fileExists(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: track.url.path)
    }

    private func validDuration(_ value: TimeInterval) -> Double {
        value.isFinite && value >= 0 ? value : 0
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentTrack = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }
}

private final class LocalPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinished: (() -> Void)?
    var onDecodeError: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onDecodeError?()
    }
}
