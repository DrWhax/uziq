import Foundation

struct BandcampAccountProfile: Codable, Equatable, Sendable {
    let fanID: Int
    let username: String
    let displayName: String
    let bio: String?
    let artworkURL: URL?
    let profileURL: URL
}

struct BandcampAccountOverview: Sendable {
    let profile: BandcampAccountProfile
    let newReleases: [BandcampResult]
    let knownBandURLs: [Int: URL]
}

struct BandcampAccountFetchResult<Value: Sendable>: Sendable {
    let value: Value?
    let errorDescription: String?
}

struct BandcampAccountSnapshot: Codable, Sendable {
    static let refreshInterval: TimeInterval = 6 * 60 * 60

    let accountIdentifier: String
    let profile: BandcampAccountProfile?
    let ownedResults: [BandcampResult]
    let wishlistResults: [BandcampResult]
    let followedArtists: [BandcampResult]
    let newReleases: [BandcampResult]
    let savedAt: Date

    func isFresh(at date: Date = .now) -> Bool {
        date.timeIntervalSince(savedAt) < Self.refreshInterval
    }
}

struct BandcampAccountCache: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Uziq", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("bandcamp-account.json")
        }
    }

    func load(accountIdentifier: String) -> BandcampAccountSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(BandcampAccountSnapshot.self, from: data),
              snapshot.accountIdentifier.caseInsensitiveCompare(accountIdentifier) == .orderedSame else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: BandcampAccountSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
