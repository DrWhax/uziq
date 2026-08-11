import CoreServices
import Foundation

/// Recursively watches the active library roots using macOS FSEvents.
///
/// FSEvents deliberately reports only which roots were affected. LibraryStore
/// debounces those notifications and asks LibraryScanner to reconcile the
/// changed roots off the main actor.
final class FolderWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([URL]) -> Void

    private let queue = DispatchQueue(label: "fm.uziq.folder-watcher", qos: .utility)
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var roots: [URL] = []
    private var securityScopedRoots: [URL] = []
    private var changeHandler: ChangeHandler?

    @discardableResult
    func start(roots requestedRoots: [URL], changeHandler: @escaping ChangeHandler) -> Bool {
        stop()

        let watchedRoots = Self.minimalRoots(requestedRoots)
        guard !watchedRoots.isEmpty else { return false }

        let accessedRoots = watchedRoots.filter { $0.startAccessingSecurityScopedResource() }
        stateLock.lock()
        roots = watchedRoots
        self.changeHandler = changeHandler
        securityScopedRoots = accessedRoots
        stateLock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            watchedRoots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            stop()
            return false
        }

        stateLock.lock()
        stream = createdStream
        stateLock.unlock()
        FSEventStreamSetDispatchQueue(createdStream, queue)
        guard FSEventStreamStart(createdStream) else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        stateLock.lock()
        let stoppedStream = stream
        let stoppedSecurityScopedRoots = securityScopedRoots
        stream = nil
        changeHandler = nil
        roots = []
        securityScopedRoots = []
        stateLock.unlock()

        if let stream = stoppedStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stoppedSecurityScopedRoots.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    deinit { stop() }

    static func minimalRoots(_ roots: [URL]) -> [URL] {
        let normalized = Array(Set(roots.map { $0.standardizedFileURL }))
            .sorted { $0.path.count < $1.path.count }
        return normalized.reduce(into: []) { result, candidate in
            guard !result.contains(where: { LibraryPath.contains(candidate, in: $0) }) else { return }
            result.append(candidate)
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
        guard let callbackInfo else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(callbackInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        watcher.receive(paths: Array(paths.prefix(eventCount)), flags: eventFlags, count: eventCount)
    }

    private func receive(
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        stateLock.lock()
        let watchedRoots = roots
        let handler = changeHandler
        stateLock.unlock()

        var affected = Set<URL>()
        for index in 0..<count {
            let flag = flags[index]
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let eventURL = index < paths.count
                ? URL(fileURLWithPath: paths[index]).standardizedFileURL
                : nil
            if let eventURL {
                affected.formUnion(watchedRoots.filter { LibraryPath.contains(eventURL, in: $0) })
            }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                affected.formUnion(watchedRoots)
            }
        }
        guard !affected.isEmpty else { return }
        handler?(affected.sorted { $0.path < $1.path })
    }
}

enum LibraryPath {
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
