import Foundation

/// Persists both a security-scoped bookmark and the plain path.
///
/// The path fallback is important when the executable is launched with
/// `swift run`: depending on how the package is launched, Foundation may not
/// be able to resolve a security-scoped bookmark even though the folder is
/// still available to the process.
struct BookmarkStore: Sendable {
    private struct Record: Codable, Sendable {
        let path: String
        let bookmark: Data?
    }

    private let storageURL: URL
    private let legacyKey = "library-folder-bookmarks"

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uziq", isDirectory: true)
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        storageURL = applicationSupport.appendingPathComponent("folder-bookmarks.json")
    }

    func add(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        var records = loadRecords()
        records.removeAll { $0.path == normalizedURL.path }
        records.append(Record(
            path: normalizedURL.path,
            bookmark: try? normalizedURL.bookmarkData(options: [.withSecurityScope])
        ))
        saveRecords(records)
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        saveRecords(loadRecords().filter { $0.path != path })
    }

    func resolvedURLs() -> [URL] {
        var records = loadRecords()
        var changed = false
        let urls = records.enumerated().compactMap { index, record -> URL? in
            if let bookmark = record.bookmark {
                var stale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    if stale {
                        records[index] = Record(
                            path: resolved.standardizedFileURL.path,
                            bookmark: try? resolved.bookmarkData(options: [.withSecurityScope])
                        )
                        changed = true
                    }
                    return resolved
                }
            }

            // Keep the folder visible and usable for non-sandboxed `swift run`
            // launches even if bookmark resolution is unavailable.
            return URL(fileURLWithPath: record.path, isDirectory: true)
        }

        if changed { saveRecords(records) }
        return urls
    }

    private func loadRecords() -> [Record] {
        if let data = try? Data(contentsOf: storageURL),
           let records = try? JSONDecoder().decode([Record].self, from: data) {
            return records
        }

        // Migrate the original UserDefaults-only format once. Old bookmarks
        // that cannot be resolved are ignored; newly selected folders always
        // retain their plain path as well.
        let legacy = UserDefaults.standard.array(forKey: legacyKey) as? [Data] ?? []
        let migrated = legacy.compactMap { data -> Record? in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return nil }
            return Record(
                path: url.standardizedFileURL.path,
                bookmark: try? url.bookmarkData(options: [.withSecurityScope])
            )
        }
        if !migrated.isEmpty { saveRecords(migrated) }
        return migrated
    }

    private func saveRecords(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
