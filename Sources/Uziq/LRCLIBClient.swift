import Foundation

struct LRCLIBQuery: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: Double

    init(title: String, artist: String, album: String, duration: Double) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.duration = duration
    }

    init(track: Track) {
        self.init(
            title: track.displayTitle,
            artist: track.artist,
            album: track.album,
            duration: track.duration
        )
    }

    var isUsable: Bool {
        !title.isEmpty && !artist.isEmpty && artist.caseInsensitiveCompare("Unknown Artist") != .orderedSame
    }

    var cacheKey: String {
        [title, artist, album, duration.isFinite ? String(Int(duration.rounded())) : "0"]
            .map(Self.normalized)
            .joined(separator: "\u{1F}")
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum LRCLIBLookup: Sendable, Equatable {
    case lyrics(LyricsPayload)
    case instrumental
    case notFound
}

enum LocalLyricsLookupResult: Sendable, Equatable {
    case lyrics(LyricsPayload)
    case instrumental
    case notFound
    case unavailable(String)
}

enum LRCLIBError: Error, Sendable, Equatable {
    case invalidResponse
    case rateLimited(until: Date?)
    case serviceUnavailable(statusCode: Int)
}

actor LRCLIBClient {
    private let session: URLSession
    private var rateLimitedUntil: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lookup(_ query: LRCLIBQuery) async throws -> LRCLIBLookup {
        guard query.isUsable else { return .notFound }
        if let rateLimitedUntil, rateLimitedUntil > .now {
            throw LRCLIBError.rateLimited(until: rateLimitedUntil)
        }

        var exactFallback: LRCLIBLookup?
        if !query.album.isEmpty, query.duration.isFinite, query.duration > 0 {
            let exact = try await request(
                path: "/api/get",
                queryItems: [
                    URLQueryItem(name: "track_name", value: query.title),
                    URLQueryItem(name: "artist_name", value: query.artist),
                    URLQueryItem(name: "album_name", value: query.album),
                    URLQueryItem(name: "duration", value: String(Int(query.duration.rounded())))
                ],
                responseType: LRCLIBRecord.self
            )
            switch exact {
            case .value(let record):
                let lookup = Self.lookup(from: record)
                if lookup.hasSynchronizedLyrics { return lookup }
                exactFallback = lookup
            case .notFound:
                break
            }
        }

        var searchItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist)
        ]
        if !query.album.isEmpty {
            searchItems.append(URLQueryItem(name: "album_name", value: query.album))
        }
        let search = try await request(
            path: "/api/search",
            queryItems: searchItems,
            responseType: [LRCLIBRecord].self
        )
        guard case .value(let records) = search,
              let record = Self.bestRecord(in: records, for: query) else {
            return exactFallback ?? .notFound
        }
        let searchResult = Self.lookup(from: record)
        return searchResult.hasSynchronizedLyrics ? searchResult : (exactFallback ?? searchResult)
    }

    private func request<Value: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        responseType: Value.Type
    ) async throws -> HTTPResult<Value> {
        try await ProviderRequestLimiters.lrclib.waitForTurn()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw LRCLIBError.invalidResponse }

        var request = URLRequest(url: url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        request.setValue("Uziq/\(version) (macOS music player; LRCLIB lyrics)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LRCLIBError.invalidResponse }

        switch response.statusCode {
        case 200:
            return .value(try JSONDecoder().decode(responseType, from: data))
        case 404:
            return .notFound
        case 429:
            let until = Self.retryDate(from: response)
            rateLimitedUntil = until ?? Date.now.addingTimeInterval(60)
            throw LRCLIBError.rateLimited(until: until)
        default:
            throw LRCLIBError.serviceUnavailable(statusCode: response.statusCode)
        }
    }

    private static func lookup(from record: LRCLIBRecord) -> LRCLIBLookup {
        if record.instrumental { return .instrumental }
        let synced = normalized(record.syncedLyrics)
        if let lyrics = normalized(record.plainLyrics) ?? synced.map({
            SyncedLyricsParser.parse($0).map(\.text).joined(separator: "\n")
        }).flatMap(normalized) {
            return .lyrics(LyricsPayload(plain: lyrics, synced: synced))
        }
        return .notFound
    }

    private static func bestRecord(in records: [LRCLIBRecord], for query: LRCLIBQuery) -> LRCLIBRecord? {
        let title = LRCLIBQuery.normalized(query.title)
        let artist = LRCLIBQuery.normalized(query.artist)
        let album = LRCLIBQuery.normalized(query.album)
        return records.compactMap { record -> (LRCLIBRecord, Int)? in
            guard LRCLIBQuery.normalized(record.trackName) == title else { return nil }
            let candidateArtist = LRCLIBQuery.normalized(record.artistName)
            var score = 100
            if candidateArtist == artist {
                score += 60
            } else if candidateArtist.contains(artist) || artist.contains(candidateArtist) {
                score += 30
            } else {
                return nil
            }
            if !album.isEmpty, LRCLIBQuery.normalized(record.albumName) == album { score += 25 }
            if query.duration.isFinite, query.duration > 0 {
                let difference = abs(record.duration - query.duration)
                if difference <= 2 { score += 30 }
                else if difference <= 5 { score += 15 }
            }
            if normalized(record.syncedLyrics) != nil { score += 40 }
            return (record, score)
        }
        .max { $0.1 < $1.1 }?.0
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func retryDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return .now.addingTimeInterval(seconds) }
        return HTTPDateFormatter.shared.date(from: value)
    }
}

private extension LRCLIBLookup {
    var hasSynchronizedLyrics: Bool {
        guard case .lyrics(let payload) = self else { return false }
        return payload.synced?.isEmpty == false
    }
}

private enum HTTPResult<Value> {
    case value(Value)
    case notFound
}

private struct LRCLIBRecord: Decodable {
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}

private final class HTTPDateFormatter: @unchecked Sendable {
    static let shared = HTTPDateFormatter()
    private let formatter: DateFormatter
    private let lock = NSLock()

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    }

    func date(from value: String) -> Date? {
        lock.withLock { formatter.date(from: value) }
    }
}
