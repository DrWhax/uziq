import AVFoundation
import Foundation
import Observation

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat
    case bassBoost
    case trebleBoost
    case vocal
    case rock
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .trebleBoost: "Treble Boost"
        case .vocal: "Vocal"
        case .rock: "Rock"
        case .custom: "Custom"
        }
    }

    var gains: [Float]? {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]
        case .vocal: [-2, -1, 0, 2, 4, 5, 4, 2, 0, -1]
        case .rock: [5, 4, 2, 0, -1, 1, 3, 4, 5, 4]
        case .custom: nil
        }
    }
}

@MainActor
@Observable
final class PlaybackEngine {
    static let equalizerFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    var currentTrack: Track?
    var isPlaying = false
    var currentTime = 0.0
    var duration = 0.0
    var volume: Float = 1.0 {
        didSet {
            playerNode.volume = volume
            spotifyPlayerNode.volume = volume
        }
    }
    var queue: [Track] = []
    private(set) var isSpotifyPCMActive = false
    private(set) var spotifyReceivedByteCount = 0
    private(set) var spotifyAudioError: String?
    var equalizerEnabled: Bool {
        didSet {
            applyEqualizerSettings()
            UserDefaults.standard.set(equalizerEnabled, forKey: "equalizer-enabled")
        }
    }
    var equalizerGains: [Float]
    var equalizerPreset: EqualizerPreset

    private var currentIndex = 0

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    @ObservationIgnored private let spotifyPlayerNode = AVAudioPlayerNode()
    @ObservationIgnored private let sourceMixer = AVAudioMixerNode()
    @ObservationIgnored private let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var startingFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var totalFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var sampleRate = 44_100.0
    @ObservationIgnored private var scheduleGeneration = 0
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var toggleObserver: NSObjectProtocol?
    @ObservationIgnored private var nextTrackProvider: (@MainActor () async -> Track?)?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var isWaitingForNextTrack = false
    @ObservationIgnored private var spotifyPCMBytes = Data()
    @ObservationIgnored private var spotifyScheduledBuffers: [UUID: AVAudioPCMBuffer] = [:]
    @ObservationIgnored private var spotifyShouldPlay = true
    @ObservationIgnored private var spotifyHasStartedPlayback = false
    @ObservationIgnored private var spotifyIsWaitingForTransition = false

    private let spotifyFramesPerBuffer = 4_096
    private let spotifyPrebufferCount = 4

    init() {
        let defaults = UserDefaults.standard
        equalizerEnabled = defaults.bool(forKey: "equalizer-enabled")
        if let values = defaults.array(forKey: "equalizer-gains") as? [NSNumber], values.count == 10 {
            equalizerGains = values.map(\.floatValue)
        } else {
            equalizerGains = EqualizerPreset.flat.gains!
        }
        equalizerPreset = EqualizerPreset(rawValue: defaults.string(forKey: "equalizer-preset") ?? "") ?? .flat

        audioEngine.attach(playerNode)
        audioEngine.attach(spotifyPlayerNode)
        audioEngine.attach(sourceMixer)
        audioEngine.attach(equalizer)
        audioEngine.connect(playerNode, to: sourceMixer, fromBus: 0, toBus: 0, format: nil)
        audioEngine.connect(
            spotifyPlayerNode,
            to: sourceMixer,
            fromBus: 0,
            toBus: 1,
            format: SpotifyPCMConverter.outputFormat
        )
        audioEngine.connect(sourceMixer, to: equalizer, format: nil)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format: nil)
        playerNode.volume = volume
        spotifyPlayerNode.volume = volume
        configureEqualizerBands()
        applyEqualizerSettings()
        try? startAudioEngine()

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
        prefetchTask?.cancel()
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        playerNode.stop()
        spotifyPlayerNode.stop()
        audioEngine.stop()
    }

    func play(_ track: Track, in tracks: [Track]? = nil) {
        if isSpotifyPCMActive { endSpotifyPCMStream() }
        NotificationCenter.default.post(name: .uziqLocalPlaybackStarted, object: nil)
        resetStreamingQueue()
        queue = tracks ?? [track]
        let requestedIndex = queue.firstIndex(of: track) ?? 0
        guard let firstAvailable = firstAvailableIndex(startingAt: requestedIndex) else {
            stopPlayback(notifyCompletion: true)
            return
        }
        startTrack(at: firstAvailable)
    }

    func restore(_ track: Track, at seconds: Double) {
        guard fileExists(track), let file = try? AVAudioFile(forReading: track.url) else { return }
        if isSpotifyPCMActive { endSpotifyPCMStream() }
        NotificationCenter.default.post(name: .uziqLocalPlaybackStarted, object: nil)
        resetStreamingQueue()
        queue = [track]
        currentIndex = 0
        scheduleGeneration += 1
        playerNode.stop()
        audioFile = file
        sampleRate = file.processingFormat.sampleRate
        totalFrames = file.length
        currentTrack = track
        duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
        let restoredSeconds = min(max(0, seconds.isFinite ? seconds : 0), duration)
        let frame = min(totalFrames, AVAudioFramePosition(restoredSeconds * sampleRate))
        currentTime = restoredSeconds
        schedule(file, from: frame, shouldPlay: false)
    }

    func playStreaming(
        _ track: Track,
        nextTrackProvider: @escaping @MainActor () async -> Track?
    ) {
        if isSpotifyPCMActive { endSpotifyPCMStream() }
        NotificationCenter.default.post(name: .uziqLocalPlaybackStarted, object: nil)
        resetStreamingQueue()
        queue = [track]
        self.nextTrackProvider = nextTrackProvider
        currentIndex = 0
        startTrack(at: 0)
    }

    func stopForExternalSpotifyPlayback() {
        if isSpotifyPCMActive { endSpotifyPCMStream() }
        stopPlayback()
    }

    func toggle() {
        guard currentTrack != nil, !isSpotifyPCMActive else { return }
        if isPlaying {
            playerNode.pause()
            isPlaying = false
        } else {
            try? startAudioEngine()
            playerNode.play()
            isPlaying = playerNode.isPlaying
        }
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func stop() {
        stopPlayback()
    }

    func seek(to seconds: Double) {
        guard let audioFile, !isSpotifyPCMActive else { return }
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let value = min(safeSeconds, duration > 0 ? duration : safeSeconds)
        let frame = min(totalFrames, max(0, AVAudioFramePosition(value * sampleRate)))
        let shouldResume = isPlaying
        scheduleGeneration += 1
        playerNode.stop()
        schedule(audioFile, from: frame, shouldPlay: shouldResume)
        currentTime = value
    }

    func next() {
        guard let nextIndex = firstAvailableIndex(startingAt: currentIndex + 1) else {
            if nextTrackProvider != nil {
                waitForNextTrack()
            } else {
                stopPlayback(notifyCompletion: true)
            }
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

    func beginSpotifyPCMStream() {
        guard !isSpotifyPCMActive else { return }
        resetStreamingQueue()
        scheduleGeneration += 1
        playerNode.stop()
        spotifyPlayerNode.stop()
        audioFile = nil
        currentTrack = nil
        currentTime = 0
        duration = 0
        spotifyPCMBytes.removeAll(keepingCapacity: true)
        spotifyScheduledBuffers.removeAll(keepingCapacity: true)
        spotifyReceivedByteCount = 0
        spotifyAudioError = nil
        spotifyShouldPlay = true
        spotifyHasStartedPlayback = false
        spotifyIsWaitingForTransition = false
        isSpotifyPCMActive = true
        do {
            try startAudioEngine()
        } catch {
            spotifyAudioError = "Could not start the audio engine: \(error.localizedDescription)"
        }
    }

    func enqueueSpotifyPCM(_ data: Data) {
        guard isSpotifyPCMActive,
              !spotifyIsWaitingForTransition,
              !data.isEmpty else { return }
        spotifyReceivedByteCount += data.count
        spotifyPCMBytes.append(data)
        let bytesPerBuffer = spotifyFramesPerBuffer * SpotifyPCMConverter.bytesPerFrame
        while spotifyPCMBytes.count >= bytesPerBuffer {
            guard let converted = SpotifyPCMConverter.makeBuffer(
                from: spotifyPCMBytes,
                maximumFrameCount: spotifyFramesPerBuffer
            ) else { break }

            spotifyPCMBytes.removeFirst(converted.consumedBytes)
            let bufferID = UUID()
            spotifyScheduledBuffers[bufferID] = converted.buffer
            spotifyPlayerNode.scheduleBuffer(converted.buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.spotifyScheduledBuffers.removeValue(forKey: bufferID)
                }
            }
        }
        guard !spotifyScheduledBuffers.isEmpty else { return }
        if !audioEngine.isRunning {
            do {
                try startAudioEngine()
            } catch {
                spotifyAudioError = "Could not restart the audio engine: \(error.localizedDescription)"
                return
            }
        }
        if spotifyShouldPlay,
           !spotifyHasStartedPlayback,
           spotifyScheduledBuffers.count >= spotifyPrebufferCount {
            spotifyHasStartedPlayback = true
            spotifyPlayerNode.play()
        } else if spotifyShouldPlay,
                  spotifyHasStartedPlayback,
                  !spotifyPlayerNode.isPlaying {
            spotifyPlayerNode.play()
        }
    }

    func handleSpotifyPlayerEvent(_ event: LibrespotPlayerEvent) {
        guard isSpotifyPCMActive else { return }
        switch event {
        case .trackChanged, .seeked:
            guard spotifyIsWaitingForTransition else { return }
            spotifyIsWaitingForTransition = false
            spotifyShouldPlay = true
        case .playing:
            spotifyIsWaitingForTransition = false
            spotifyShouldPlay = true
            if spotifyHasStartedPlayback,
               !spotifyScheduledBuffers.isEmpty,
               !spotifyPlayerNode.isPlaying {
                spotifyPlayerNode.play()
            }
        case .paused:
            spotifyShouldPlay = false
            spotifyPlayerNode.pause()
        case .stopped:
            spotifyShouldPlay = false
            spotifyPlayerNode.pause()
        }
    }

    func prepareForSpotifyTransition() {
        guard isSpotifyPCMActive else { return }
        spotifyIsWaitingForTransition = true
        spotifyShouldPlay = false
        resetSpotifyPCMQueue()
    }

    func setSpotifyPCMPlaying(_ shouldPlay: Bool) {
        guard isSpotifyPCMActive else { return }
        spotifyShouldPlay = shouldPlay
        if shouldPlay {
            if spotifyHasStartedPlayback,
               !spotifyScheduledBuffers.isEmpty,
               !spotifyPlayerNode.isPlaying {
                spotifyPlayerNode.play()
            }
        } else {
            spotifyPlayerNode.pause()
        }
    }

    func endSpotifyPCMStream() {
        guard isSpotifyPCMActive else { return }
        scheduleGeneration += 1
        spotifyPlayerNode.stop()
        spotifyPCMBytes.removeAll(keepingCapacity: false)
        spotifyScheduledBuffers.removeAll(keepingCapacity: false)
        spotifyShouldPlay = false
        spotifyHasStartedPlayback = false
        spotifyIsWaitingForTransition = false
        isSpotifyPCMActive = false
        isPlaying = false
    }

    private func resetSpotifyPCMQueue() {
        spotifyPlayerNode.stop()
        spotifyPCMBytes.removeAll(keepingCapacity: true)
        spotifyScheduledBuffers.removeAll(keepingCapacity: true)
        spotifyReceivedByteCount = 0
        spotifyHasStartedPlayback = false
    }

    func setEqualizerGain(_ gain: Float, at index: Int) {
        guard equalizerGains.indices.contains(index) else { return }
        equalizerGains[index] = min(12, max(-12, gain))
        equalizerPreset = .custom
        applyEqualizerSettings()
        persistEqualizer()
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        guard let gains = preset.gains else { return }
        equalizerPreset = preset
        equalizerGains = gains
        applyEqualizerSettings()
        persistEqualizer()
    }

    private func startTrack(at index: Int) {
        isSpotifyPCMActive = false
        guard index >= 0, index < queue.count, fileExists(queue[index]) else {
            guard let nextIndex = firstAvailableIndex(startingAt: index + 1) else {
                stopPlayback(notifyCompletion: true)
                return
            }
            startTrack(at: nextIndex)
            return
        }

        do {
            let file = try AVAudioFile(forReading: queue[index].url)
            scheduleGeneration += 1
            playerNode.stop()
            try startAudioEngine()
            audioFile = file
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            currentIndex = index
            currentTrack = queue[index]
            currentTime = 0
            duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
            schedule(file, from: 0, shouldPlay: true)
            isPlaying = playerNode.isPlaying
            if isPlaying {
                NotificationCenter.default.post(name: .uziqTrackPlayed, object: queue[index].id)
            }
        } catch {
            guard let nextIndex = firstAvailableIndex(startingAt: index + 1) else {
                if nextTrackProvider != nil {
                    waitForNextTrack()
                } else {
                    stopPlayback(notifyCompletion: true)
                }
                return
            }
            startTrack(at: nextIndex)
        }
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition, shouldPlay: Bool) {
        startingFrame = frame
        let remaining = max(0, totalFrames - frame)
        guard remaining > 0 else {
            advanceCurrentTrack()
            return
        }
        let generation = scheduleGeneration
        let frameCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduleGeneration == generation else { return }
                self.advanceCurrentTrack()
            }
        }
        if shouldPlay {
            playerNode.play()
            isPlaying = playerNode.isPlaying
        } else {
            isPlaying = false
        }
    }

    private func advanceCurrentTrack() {
        guard let nextIndex = firstAvailableIndex(startingAt: currentIndex + 1) else {
            if nextTrackProvider != nil {
                waitForNextTrack()
            } else {
                stopPlayback(notifyCompletion: true)
            }
            return
        }
        startTrack(at: nextIndex)
    }

    private func updateProgress() {
        guard currentTrack != nil, !isSpotifyPCMActive else { return }
        if let renderTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: renderTime) {
            let renderedFrame = max(0, playerTime.sampleTime)
            let absoluteFrame = min(totalFrames, startingFrame + renderedFrame)
            currentTime = sampleRate > 0 ? Double(absoluteFrame) / sampleRate : 0
        }
        isPlaying = playerNode.isPlaying
        if duration > 0, duration - currentTime <= 20 {
            prefetchNextTrackIfNeeded()
        }
    }

    private func waitForNextTrack() {
        scheduleGeneration += 1
        playerNode.stop()
        isPlaying = false
        isWaitingForNextTrack = true
        prefetchNextTrackIfNeeded()
    }

    private func prefetchNextTrackIfNeeded() {
        guard currentIndex + 1 >= queue.count,
              prefetchTask == nil,
              let provider = nextTrackProvider else { return }

        prefetchTask = Task { [weak self] in
            let nextTrack = await provider()
            guard let self, !Task.isCancelled else { return }
            prefetchTask = nil
            guard let nextTrack else {
                nextTrackProvider = nil
                if isWaitingForNextTrack { stopPlayback(notifyCompletion: true) }
                return
            }
            queue.append(nextTrack)
            if isWaitingForNextTrack {
                isWaitingForNextTrack = false
                startTrack(at: currentIndex + 1)
            }
        }
    }

    private func configureEqualizerBands() {
        for (index, frequency) in Self.equalizerFrequencies.enumerated() {
            let band = equalizer.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.bypass = false
        }
    }

    private func applyEqualizerSettings() {
        equalizer.bypass = !equalizerEnabled
        for (index, gain) in equalizerGains.enumerated() where equalizer.bands.indices.contains(index) {
            equalizer.bands[index].gain = gain
        }
    }

    private func persistEqualizer() {
        UserDefaults.standard.set(equalizerGains.map(Double.init), forKey: "equalizer-gains")
        UserDefaults.standard.set(equalizerPreset.rawValue, forKey: "equalizer-preset")
    }

    private func startAudioEngine() throws {
        guard !audioEngine.isRunning else { return }
        audioEngine.prepare()
        try audioEngine.start()
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

    private func stopPlayback(notifyCompletion: Bool = false) {
        resetStreamingQueue()
        scheduleGeneration += 1
        playerNode.stop()
        audioFile = nil
        currentTrack = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        if notifyCompletion {
            NotificationCenter.default.post(name: .uziqPlaybackItemFinished, object: nil)
        }
    }

    private func resetStreamingQueue() {
        prefetchTask?.cancel()
        prefetchTask = nil
        nextTrackProvider = nil
        isWaitingForNextTrack = false
    }
}
