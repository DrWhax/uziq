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

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stderrPipe: Pipe?
    @ObservationIgnored private var eraseCredentialsWhenStopped = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var appTerminationObserver: NSObjectProtocol?

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
    }

    var resolvedExecutableURL: URL? {
        let fileManager = FileManager.default
        if let bundledExecutableURL { return bundledExecutableURL }

        if !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: executablePath).standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }

        var candidates = [
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
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("librespot")
            .standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var isUsingBundledExecutable: Bool {
        guard let bundledExecutableURL, let resolvedExecutableURL else { return false }
        return bundledExecutableURL == resolvedExecutableURL
    }

    func start(using _: PlaybackEngine) {
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
                    self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    self.stderrPipe = nil
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
            stderrPipe = nil
            status = .failed(error.localizedDescription)
        }
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
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        UserDefaults.standard.removeObject(forKey: processIDDefaultsKey)
    }

    deinit {
        if let appTerminationObserver { NotificationCenter.default.removeObserver(appTerminationObserver) }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }
}
