import Foundation

struct JellyfinCacheStats: Sendable, Equatable {
    var fileCount = 0
    var totalBytes: Int64 = 0
}

struct JellyfinCacheManager: Sendable {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uziq", isDirectory: true)
            .appendingPathComponent("JellyfinCache", isDirectory: true)
    }

    func audioURL(itemID: String, container: String?) -> URL {
        let safeID = itemID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let safeExtension = (container ?? "audio")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        return directory.appendingPathComponent("\(safeID).\(safeExtension.isEmpty ? "audio" : safeExtension)")
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func stats() throws -> JellyfinCacheStats {
        try files().reduce(into: JellyfinCacheStats()) { stats, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            stats.fileCount += 1
            stats.totalBytes += Int64(values.fileSize ?? 0)
        }
    }

    @discardableResult
    func clean(olderThan cutoff: Date) throws -> Int {
        var count = 0
        for url in try files() {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            guard (values.contentModificationDate ?? values.creationDate ?? .distantFuture) < cutoff else { continue }
            try FileManager.default.removeItem(at: url)
            count += 1
        }
        return count
    }

    func markUsed(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
    }

    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}
