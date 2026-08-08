import Foundation

struct SpotifyLibrarySnapshot: Codable, Sendable {
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    let clientID: String
    let savedAt: Date
    let profileName: String?
    let playlists: [SpotifyCatalogItem]
    let likedSongs: [SpotifyCatalogItem]
    let likedSongsTotal: Int
    let topArtists: [SpotifyCatalogItem]

    func isFresh(at date: Date = .now) -> Bool {
        date.timeIntervalSince(savedAt) < Self.refreshInterval
    }
}

struct SpotifyLibraryCache: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Uziq", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("spotify-library.json")
        }
    }

    func load(clientID: String) -> SpotifyLibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(SpotifyLibrarySnapshot.self, from: data),
              snapshot.clientID == clientID else { return nil }
        return snapshot
    }

    func save(_ snapshot: SpotifyLibrarySnapshot) throws {
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
