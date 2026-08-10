import Darwin
import Foundation

final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private let fileURL: URL
    private let previousFileURL: URL
    private let maximumFileBytes: UInt64 = 512 * 1_024

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uziq", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("uziq.log")
        previousFileURL = directory.appendingPathComponent("uziq.previous.log")
    }

    func record(_ category: String, _ message: String) {
        let line = "\(Self.timestamp(for: .now)) [\(category)] \(Self.redact(message))\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded(adding: UInt64(data.count))
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never interfere with playback or app shutdown.
        }
    }

    func recentText(maximumBytes: Int = 128 * 1_024) -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = [previousFileURL, fileURL]
            .compactMap { try? Data(contentsOf: $0) }
            .reduce(into: Data()) { $0.append($1) }
        let suffix = data.suffix(maximumBytes)
        return String(decoding: suffix, as: UTF8.self)
    }

    private func rotateIfNeeded(adding bytes: UInt64) {
        let currentBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(UInt64.init) ?? 0
        guard currentBytes + bytes > maximumFileBytes else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
    }

    nonisolated static func redact(_ value: String) -> String {
        var redacted = value.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
        let patterns = [
            "(?i)(access_token|refresh_token|authorization|password|secret)([=: ]+)[^\\s,;]+",
            "(?i)(bearer\\s+)[A-Za-z0-9._~-]+",
            "(https?://)[^/@\\s]+:[^/@\\s]+@"
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        return redacted
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

@MainActor
enum DiagnosticsReport {
    static func make(
        library: LibraryStore,
        playback: PlaybackEngine,
        bandcamp: BandcampStore,
        spotify: SpotifyStore,
        jellyfin: JellyfinStore,
        queue: PlaybackQueueStore
    ) -> String {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let sourceCounts = Dictionary(grouping: queue.items, by: \UnifiedQueueItem.source)
            .mapValues(\.count)
        let folderNames = library.folderRoots.map(\.lastPathComponent).sorted()
        let currentSource = queue.currentItem?.source.title ?? "None"
        let currentDuration = queue.duration.isFinite ? queue.duration : 0
        let currentPosition = queue.currentTime.isFinite ? queue.currentTime : 0
        let errors = [
            ("Library", library.lastError),
            ("Playback", queue.error),
            ("Bandcamp", bandcamp.error ?? bandcamp.collectionError ?? bandcamp.authError),
            ("Spotify", spotify.error ?? spotify.playbackMessage),
            ("Jellyfin", jellyfin.error)
        ].compactMap { label, value in
            value.map { "\(label): \(DiagnosticsLog.redact($0))" }
        }

        let recentEvents = DiagnosticsLog.shared.recentText()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = [
            "Uziq Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: .now))",
            "",
            "Application",
            "Version: \(version) (\(build))",
            "Bundle: \(bundle.bundleIdentifier ?? "SwiftPM development executable")",
            "Packaged app: \(bundle.bundleURL.pathExtension == "app" ? "Yes" : "No")",
            "Architecture: \(architecture)",
            "Operating system: \(process.operatingSystemVersionString)",
            "System uptime: \(Int(process.systemUptime)) seconds",
            "Thermal state: \(thermalState(process.thermalState))",
            "Processor count: \(process.processorCount)",
            "System memory: \(ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory))",
            "Process resident memory: \(processResidentMemory)",
            "",
            "Library",
            "Tracks: \(library.tracks.count)",
            "Folders: \(library.folderRoots.count)\(folderNames.isEmpty ? "" : " (\(folderNames.joined(separator: ", "))) ")",
            "Initial load complete: \(yesNo(library.isInitialLoadComplete))",
            "Scanning: \(yesNo(library.isScanning))",
            "Artwork enrichment: \(yesNo(library.isEnrichingArtwork))",
            "Artist artwork enrichment: \(yesNo(library.isEnrichingArtistArtwork))",
            "",
            "Services",
            "Bandcamp authenticated: \(yesNo(bandcamp.isAuthenticated))",
            "Bandcamp collection items: \(bandcamp.ownedResults.count)",
            "Bandcamp wishlist items: \(bandcamp.wishlistResults.count)",
            "Bandcamp followed artists: \(bandcamp.followedArtists.count)",
            "Bandcamp account feed releases: \(bandcamp.accountNewReleases.count)",
            "Bandcamp cache: \(byteCount(bandcamp.cacheBytes)) in \(bandcamp.cachedFileCount) files",
            "Spotify Web API connected: \(yesNo(spotify.isAuthorized))",
            "Spotify playback engine: \(spotify.librespot.status.title)",
            "Spotify helper bundled: \(yesNo(spotify.librespot.isUsingBundledExecutable))",
            "Spotify local transport control: \(yesNo(spotify.librespot.supportsDirectControl))",
            "Jellyfin connected: \(yesNo(jellyfin.isConnected))",
            "Jellyfin server name: \(jellyfin.serverName ?? "Unavailable")",
            "Jellyfin cache: \(byteCount(jellyfin.cacheBytes)) in \(jellyfin.cachedFileCount) files",
            "",
            "Playback",
            "Source: \(currentSource)",
            "Playing: \(yesNo(queue.isPlaying))",
            "Position: \(String(format: "%.1f", currentPosition)) / \(String(format: "%.1f", currentDuration)) seconds",
            "Queue items: \(queue.items.count)",
            "Queue sources: \(PlaybackSource.allCases.map { "\($0.title)=\(sourceCounts[$0, default: 0])" }.joined(separator: ", "))",
            "Shuffle: \(yesNo(queue.shuffleEnabled))",
            "Repeat: \(queue.repeatMode.title)",
            "Equalizer: \(playback.equalizerEnabled ? playback.equalizerPreset.title : "Off")",
            "",
            "Current errors",
            errors.isEmpty ? "None" : errors.joined(separator: "\n"),
            "",
            "Recent events",
            recentEvents.isEmpty ? "No events recorded" : recentEvents,
            "",
            "Privacy note: credentials, access tokens, full home paths, raw librespot output, and complete local file paths are not included."
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    nonisolated private static var processResidentMemory: String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
    }

    nonisolated private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    nonisolated private static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
    nonisolated private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
