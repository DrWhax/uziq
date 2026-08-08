import Foundation

struct BandcampCacheStats: Sendable, Equatable {
    var fileCount = 0
    var totalBytes: Int64 = 0
}

struct BandcampCacheManager: Sendable {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Uziq", isDirectory: true)
                .appendingPathComponent("BandcampCache", isDirectory: true)
        }
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func stats() throws -> BandcampCacheStats {
        let files = try cachedFiles()
        return try files.reduce(into: BandcampCacheStats()) { result, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            result.fileCount += 1
            result.totalBytes += Int64(values.fileSize ?? 0)
        }
    }

    @discardableResult
    func removeFilesNotUsed(since cutoff: Date) throws -> Int {
        var removed = 0
        for url in try cachedFiles() {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let lastUsed = values.contentModificationDate ?? values.creationDate ?? .distantFuture
            guard lastUsed < cutoff else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    func markUsed(_ url: URL, at date: Date = .now) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func cachedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
