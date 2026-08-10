import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class LibrespotService {
    var executablePath: String {
        didSet {
            UserDefaults.standard.set(executablePath, forKey: "librespot-executable-path")
            if !status.isRunning { status = resolvedExecutableURL == nil ? .unavailable : .stopped }
        }
    }
    private(set) var status: LibrespotStatus = .stopped
    private(set) var recentLog = ""
    private(set) var isDirectPlaybackActive = false
    private(set) var isDirectPlaybackPlaying = false
    var onEvent: ((LibrespotIPCEvent) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdinPipe: Pipe?
    @ObservationIgnored private var stdoutPipe: Pipe?
    @ObservationIgnored private var stderrPipe: Pipe?
    @ObservationIgnored private var stdoutBuffer = Data()
    @ObservationIgnored private var pendingCommands: [Data] = []
    @ObservationIgnored private var eraseCredentialsWhenStopped = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var appTerminationObserver: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var wasRunningBeforeSleep = false
    @ObservationIgnored private var directPlaybackURI: String?

    private let processIDDefaultsKey = "librespot-process-id"

    init() {
        executablePath = UserDefaults.standard.string(forKey: "librespot-executable-path") ?? ""
        if resolvedExecutableURL == nil { status = .unavailable }
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: .uziqWillTerminate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminateForAppExit()
            }
        }
        sleepObserver = NotificationCenter.default.addObserver(
            forName: .uziqWillSleep,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wasRunningBeforeSleep = self?.process?.isRunning == true
            }
        }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .uziqDidWake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wasRunningBeforeSleep else { return }
                self.wasRunningBeforeSleep = false
                try? await Task.sleep(for: .seconds(2))
                if self.process?.isRunning == true {
                    DiagnosticsLog.shared.record("spotify", "Playback engine remained healthy after wake")
                } else {
                    DiagnosticsLog.shared.record("spotify", "Restarting playback engine after wake")
                    self.startProcess()
                }
            }
        }
    }

    var resolvedExecutableURL: URL? {
        let fileManager = FileManager.default
        if let bundledExecutableURL { return bundledExecutableURL }

        var candidates: [String] = []
#if DEBUG
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates += [
            projectRoot.appendingPathComponent("Helpers/uziq-librespot/target/debug/uziq-librespot").path,
            projectRoot.appendingPathComponent("Helpers/uziq-librespot/target/release/uziq-librespot").path
        ]
        if let helper = candidates.lazy
            .map({ URL(fileURLWithPath: $0).standardizedFileURL })
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return helper
        }
        candidates.removeAll(keepingCapacity: true)
#endif
        if !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: executablePath).standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        candidates += [
            "/opt/homebrew/bin/librespot",
            "/usr/local/bin/librespot",
            "/usr/bin/librespot",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin/librespot").path
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/librespot" }
        }
        return candidates.lazy
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    var bundledExecutableURL: URL? {
        let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        for name in ["uziq-librespot", "librespot"] {
            let url = helpers.appendingPathComponent(name).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    var isUsingBundledExecutable: Bool {
        guard let bundledExecutableURL, let resolvedExecutableURL else { return false }
        return bundledExecutableURL == resolvedExecutableURL
    }

    var supportsDirectControl: Bool {
        resolvedExecutableURL.map(isDirectHelper) == true
    }

    func start(using _: PlaybackEngine) {
        startProcess()
    }

    private func startProcess() {
        guard process?.isRunning != true else {
            return
        }
        guard let executable = resolvedExecutableURL else {
            status = .unavailable
            return
        }
        terminateTrackedStaleProcess(expectedExecutable: executable)

        do {
            let systemCache = try makeSystemCacheDirectory()
            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = executable
            let directHelper = isDirectHelper(executable)
            if directHelper {
                process.arguments = [
                    "--system-cache", systemCache.path,
                    "--oauth-port", "5590"
                ]
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                self.stdinPipe = stdinPipe
                self.stdoutPipe = stdoutPipe
                stdoutBuffer.removeAll(keepingCapacity: true)
                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    Task { @MainActor [weak self] in self?.consumeOutput(data) }
                }
            } else {
                process.arguments = [
                    "--name", "Uziq",
                    "--device-type", "computer",
                    "--bitrate", "320",
                    "--backend", "rodio",
                    "--system-cache", systemCache.path,
                    "--disable-audio-cache",
                    "--disable-discovery",
                    "--enable-oauth",
                    "--oauth-port", "5590"
                ]
                process.standardOutput = FileHandle.nullDevice
            }
            process.standardError = stderrPipe
            self.process = process
            self.stderrPipe = stderrPipe
            recentLog = ""
            status = .starting
            stopRequested = false
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in self?.consumeLog(text) }
            }
            process.terminationHandler = { [weak self, weak process] finished in
                Task { @MainActor [weak self, weak process] in
                    guard let self, self.process === process else { return }
                    self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                    self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    self.stdinPipe = nil
                    self.stdoutPipe = nil
                    self.stderrPipe = nil
                    self.stdoutBuffer.removeAll(keepingCapacity: false)
                    self.pendingCommands.removeAll()
                    self.isDirectPlaybackActive = false
                    self.isDirectPlaybackPlaying = false
                    self.directPlaybackURI = nil
                    if UserDefaults.standard.integer(forKey: self.processIDDefaultsKey) == Int(finished.processIdentifier) {
                        UserDefaults.standard.removeObject(forKey: self.processIDDefaultsKey)
                    }
                    if self.eraseCredentialsWhenStopped {
                        self.eraseCredentialsWhenStopped = false
                        self.removeCredentialDirectory()
                    }
                    if self.stopRequested || finished.terminationStatus == 0 {
                        self.status = .stopped
                    } else {
                        self.status = .failed("librespot exited with code \(finished.terminationStatus)")
                    }
                }
            }
            try process.run()
            UserDefaults.standard.set(Int(process.processIdentifier), forKey: processIDDefaultsKey)
        } catch {
            self.process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            status = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func loadContext(_ uri: String, offsetURI: String? = nil, position: Double = 0) -> Bool {
        let accepted = send(.loadContext(uri, offsetURI: offsetURI, positionMS: milliseconds(position)))
        if accepted {
            directPlaybackURI = offsetURI
            isDirectPlaybackActive = true
            isDirectPlaybackPlaying = false
        }
        return accepted
    }

    @discardableResult
    func loadTracks(_ uris: [String], offsetURI: String? = nil, position: Double = 0) -> Bool {
        guard !uris.isEmpty else { return false }
        let accepted = send(.loadTracks(uris, offsetURI: offsetURI, positionMS: milliseconds(position)))
        if accepted {
            directPlaybackURI = offsetURI ?? uris.first
            isDirectPlaybackActive = true
            isDirectPlaybackPlaying = false
        }
        return accepted
    }

    @discardableResult
    func play() -> Bool {
        let accepted = send(.transport("play"))
        if accepted { isDirectPlaybackPlaying = true }
        return accepted
    }

    @discardableResult
    func togglePlayback() -> Bool {
        let accepted = send(.transport("toggle"))
        if accepted { isDirectPlaybackPlaying.toggle() }
        return accepted
    }

    @discardableResult
    func pause() -> Bool {
        let accepted = send(.transport("pause"))
        if accepted { isDirectPlaybackPlaying = false }
        return accepted
    }

    @discardableResult
    func next() -> Bool { send(.transport("next")) }

    @discardableResult
    func previous() -> Bool { send(.transport("previous")) }

    @discardableResult
    func seek(to seconds: Double) -> Bool { send(.seek(positionMS: milliseconds(seconds))) }

    @discardableResult
    func setVolume(_ volume: Float) -> Bool {
        send(.setVolume(Double(min(1, max(0, volume)))))
    }

    func stop() {
        guard let process else {
            status = resolvedExecutableURL == nil ? .unavailable : .stopped
            return
        }
        stopRequested = true
        process.interrupt()
        let runningProcess = process
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if runningProcess.isRunning { runningProcess.terminate() }
        }
    }

    func signOut() {
        if process?.isRunning == true {
            eraseCredentialsWhenStopped = true
            stop()
        } else {
            removeCredentialDirectory()
            status = resolvedExecutableURL == nil ? .unavailable : .stopped
        }
    }

    private func consumeLog(_ text: String) {
        recentLog = String((recentLog + text).suffix(6_000))
        guard process?.executableURL.map(isDirectHelper) != true else { return }
        let lowercased = text.lowercased()
        if lowercased.contains("authenticated as") || lowercased.contains("spirc") {
            status = .ready
        } else if lowercased.contains("oauth") || lowercased.contains("browser") {
            status = .authenticating
        } else if lowercased.contains("error") && !lowercased.contains("no active user") {
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "librespot failed"
            if lowercased.contains("failed") || lowercased.contains("invalid") {
                status = .failed(line)
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(LibrespotIPCEvent.self, from: line) else {
                continue
            }
            consume(event)
        }
    }

    private func consume(_ event: LibrespotIPCEvent) {
        if event.event == "status" {
            switch event.state {
            case "starting": status = .starting
            case "authenticating": status = .authenticating
            case "ready":
                status = .ready
                flushPendingCommands()
            default: break
            }
        } else if event.event == "error", let message = event.message {
            recentLog = String((recentLog + "\n" + message).suffix(6_000))
        }

        switch event.event {
        case "loading", "track_changed":
            if let uri = event.uri { directPlaybackURI = uri }
            isDirectPlaybackActive = true
        case "playing":
            if let uri = event.uri { directPlaybackURI = uri }
            isDirectPlaybackActive = true
            isDirectPlaybackPlaying = true
        case "paused", "end_of_track", "stopped":
            guard eventBelongsToCurrentTrack(event.uri) else { return }
            isDirectPlaybackPlaying = false
        case "position", "seeked":
            guard eventBelongsToCurrentTrack(event.uri) else { return }
            isDirectPlaybackActive = true
        case "unavailable":
            guard eventBelongsToCurrentTrack(event.uri) else { return }
            isDirectPlaybackActive = false
            isDirectPlaybackPlaying = false
        default:
            break
        }
        onEvent?(event)
    }

    private func eventBelongsToCurrentTrack(_ eventURI: String?) -> Bool {
        guard let eventURI, let directPlaybackURI else { return true }
        return eventURI == directPlaybackURI
    }

    private func send(_ command: LibrespotIPCCommand) -> Bool {
        guard supportsDirectControl else { return false }
        if process?.isRunning != true { startProcess() }
        guard process?.isRunning == true,
              var data = try? JSONEncoder().encode(command) else { return false }
        data.append(0x0A)
        if status == .ready {
            return writeCommand(data)
        }
        pendingCommands.append(data)
        return true
    }

    private func flushPendingCommands() {
        let commands = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        for command in commands where !writeCommand(command) {
            pendingCommands.append(command)
        }
    }

    private func writeCommand(_ data: Data) -> Bool {
        guard let handle = stdinPipe?.fileHandleForWriting else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            status = .failed("Could not communicate with the Spotify helper: \(error.localizedDescription)")
            return false
        }
    }

    private func milliseconds(_ seconds: Double) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(min(Double(UInt32.max), seconds * 1_000))
    }

    private func isDirectHelper(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().contains("uziq-librespot")
    }

    private func makeSystemCacheDirectory() throws -> URL {
        let directory = credentialDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private var credentialDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uziq", isDirectory: true)
            .appendingPathComponent("Librespot", isDirectory: true)
    }

    private func removeCredentialDirectory() {
        try? FileManager.default.removeItem(at: credentialDirectory)
    }

    private func terminateTrackedStaleProcess(expectedExecutable: URL) {
        let defaults = UserDefaults.standard
        let storedPID = pid_t(defaults.integer(forKey: processIDDefaultsKey))
        defaults.removeObject(forKey: processIDDefaultsKey)
        guard storedPID > 1,
              storedPID != getpid(),
              executablePath(for: storedPID) == expectedExecutable.standardizedFileURL.path else { return }
        Darwin.kill(storedPID, SIGTERM)
    }

    private func executablePath(for processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func terminateForAppExit() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        UserDefaults.standard.removeObject(forKey: processIDDefaultsKey)
    }

    deinit {
        if let appTerminationObserver { NotificationCenter.default.removeObserver(appTerminationObserver) }
        if let sleepObserver { NotificationCenter.default.removeObserver(sleepObserver) }
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }
}
