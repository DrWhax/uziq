import CryptoKit
import Foundation

actor RemoteArtworkCache {
    static let shared = RemoteArtworkCache()
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let session: URLSession
    private let memoryCache = NSCache<NSString, NSData>()
    private var inFlight: [URL: Task<Data?, Never>] = [:]
    private var didPrepare = false

    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Uziq", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
        memoryCache.countLimit = 320
        memoryCache.totalCostLimit = 32 * 1_024 * 1_024
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func data(for url: URL?) async -> Data? {
        guard let url else { return nil }
        prepareIfNeeded()
        let key = url.absoluteString as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached as Data
        }

        let fileURL = cachedFileURL(for: url)
        if let cached = try? Data(contentsOf: fileURL, options: .mappedIfSafe), !cached.isEmpty {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: fileURL.path)
            memoryCache.setObject(cached as NSData, forKey: key, cost: cached.count)
            return cached
        }

        if let task = inFlight[url] { return await task.value }
        let session = session
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await session.data(for: request),
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  !data.isEmpty else { return nil }
            return data
        }
        inFlight[url] = task
        let downloaded = await task.value
        inFlight[url] = nil
        guard let downloaded else { return nil }

        try? downloaded.write(to: fileURL, options: .atomic)
        memoryCache.setObject(downloaded as NSData, forKey: key, cost: downloaded.count)
        return downloaded
    }

    private func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date.now.addingTimeInterval(-Self.retentionInterval)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func cachedFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest)
    }
}
