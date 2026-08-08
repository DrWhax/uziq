import CryptoKit
import Foundation

protocol FingerprintProvider: Sendable {
    func fingerprint(for url: URL) throws -> Fingerprint
}

struct Fingerprint: Sendable {
    let duration: Int
    let value: String
}

/// Uses Chromaprint's `fpcalc` command when it is installed. Keeping this behind a
/// protocol lets the app replace it with a bundled C module without changing the UI.
struct FpcalcFingerprintProvider: FingerprintProvider {
    private let executableCandidates = [
        "/opt/homebrew/bin/fpcalc",
        "/usr/local/bin/fpcalc",
        "/usr/bin/fpcalc"
    ]

    func fingerprint(for url: URL) throws -> Fingerprint {
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UziqError.metadata("Chromaprint fpcalc is not installed. Install Chromaprint to identify files with AcoustID.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UziqError.metadata("Chromaprint could not fingerprint \(url.lastPathComponent).")
        }
        let response = try JSONDecoder().decode(FpcalcResponse.self, from: output)
        return Fingerprint(duration: response.duration, value: response.fingerprint)
    }

    private struct FpcalcResponse: Decodable {
        let duration: Int
        let fingerprint: String
    }
}

struct AcoustIDMatch: Sendable {
    let score: Double
    let acoustID: String
    let recordingID: String?
    let releaseGroupID: String?
}

struct MusicBrainzRecording: Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let year: String?
    let releaseID: String?
}

struct MusicBrainzReleaseCandidate: Sendable {
    let releaseID: String
    let releaseGroupID: String?
}

struct MusicBrainzClient: Sendable {
    func releaseCandidates(artist: String, album: String) async throws -> [MusicBrainzReleaseCandidate] {
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let cleanAlbum = album.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(cleanArtist)\" AND release:\"\(cleanAlbum)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return [] }

        // MusicBrainz asks clients to stay at or below one request per second.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var request = URLRequest(url: url)
        request.setValue("Uziq/1.0 (macOS music player; local metadata enrichment)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let decoded = try JSONDecoder().decode(ReleaseSearchResponse.self, from: data)
        return decoded.releases.map {
            MusicBrainzReleaseCandidate(releaseID: $0.id, releaseGroupID: $0.releaseGroup?.id)
        }
    }

    /// Finds a release group by the tags already present in the local file.
    /// This is used for artwork enrichment when AcoustID has not been run.
    func releaseGroupID(artist: String, album: String) async throws -> String? {
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let cleanAlbum = album.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(cleanArtist)\" AND releasegroup:\"\(cleanAlbum)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }

        // MusicBrainz asks clients to stay at or below one request per second.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var request = URLRequest(url: url)
        request.setValue("Uziq/1.0 (macOS music player; local metadata enrichment)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(ReleaseGroupSearchResponse.self, from: data)
        return decoded.releaseGroups.first?.id
    }

    func recording(id: String) async throws -> MusicBrainzRecording? {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording/\(id)?fmt=json&inc=artists+releases") else { return nil }
        // MusicBrainz asks clients to stay at or below one request per second.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var request = URLRequest(url: url)
        request.setValue("Uziq/1.0 (macOS music player; local metadata enrichment)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let firstRelease = decoded.releases?.first
        let artists = decoded.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: ", ")
        let albumArtist = firstRelease?.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: ", ")
        return MusicBrainzRecording(
            title: decoded.title,
            artist: artists,
            album: firstRelease?.title,
            albumArtist: albumArtist,
            year: firstRelease?.date.map { String($0.prefix(4)) },
            releaseID: firstRelease?.id
        )
    }

    private struct Response: Decodable {
        let title: String?
        let artistCredit: [ArtistCredit]?
        let releases: [Release]?

        enum CodingKeys: String, CodingKey {
            case title
            case artistCredit = "artist-credit"
            case releases
        }
    }

    private struct ArtistCredit: Decodable {
        let name: String?
        let artist: Artist?
    }

    private struct Artist: Decodable { let name: String? }

    private struct Release: Decodable {
        let id: String?
        let title: String?
        let date: String?
        let artistCredit: [ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case id, title, date
            case artistCredit = "artist-credit"
        }
    }

    private struct ReleaseSearchResponse: Decodable {
        let releases: [ReleaseSearchResult]
    }

    private struct ReleaseSearchResult: Decodable {
        let id: String
        let releaseGroup: ReleaseGroupLink?

        enum CodingKeys: String, CodingKey {
            case id
            case releaseGroup = "release-group"
        }
    }

    private struct ReleaseGroupLink: Decodable {
        let id: String
    }

    private struct ReleaseGroupSearchResponse: Decodable {
        let releaseGroups: [ReleaseGroupSearchResult]

        enum CodingKeys: String, CodingKey {
            case releaseGroups = "release-groups"
        }
    }

    private struct ReleaseGroupSearchResult: Decodable {
        let id: String
    }
}

struct AcoustIDClient: Sendable {
    let apiKey: String

    func lookup(_ fingerprint: Fingerprint) async throws -> AcoustIDMatch? {
        var components = URLComponents(string: "https://api.acoustid.org/v2/lookup")
        components?.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "meta", value: "recordings+releasegroups"),
            URLQueryItem(name: "duration", value: String(fingerprint.duration)),
            URLQueryItem(name: "fingerprint", value: fingerprint.value)
        ]
        guard let url = components?.url else { throw UziqError.metadata("Invalid AcoustID request.") }
        var request = URLRequest(url: url)
        request.setValue("Uziq/1.0 (macOS music player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UziqError.metadata("AcoustID returned an HTTP error.")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.status == "ok" else { throw UziqError.metadata("AcoustID returned status \(decoded.status).") }
        guard let result = decoded.results.max(by: { $0.score < $1.score }), result.score >= 0.50 else { return nil }
        let recording = result.recordings?.first
        let releaseGroup = recording?.releasegroups?.first?.id
        return AcoustIDMatch(
            score: result.score,
            acoustID: result.id,
            recordingID: recording?.id,
            releaseGroupID: releaseGroup
        )
    }

    private struct Response: Decodable {
        let status: String
        let results: [Result]
    }

    private struct Result: Decodable {
        let score: Double
        let id: String
        let recordings: [Recording]?
    }

    private struct Recording: Decodable {
        let id: String
        let releasegroups: [ReleaseGroup]?
    }

    private struct ReleaseGroup: Decodable { let id: String }
}

struct CoverArtArchiveClient: Sendable {
    func frontArtwork(forReleaseID releaseID: String) async throws -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500") else { return nil }
        return try await artwork(from: url)
    }

    func frontArtwork(for releaseGroupID: String) async throws -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release-group/\(releaseGroupID)/front-500") else { return nil }
        return try await artwork(from: url)
    }

    private func artwork(from url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Uziq/1.0 (macOS music player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

struct LastFMClient: Sendable {
    let apiKey: String

    func artistBiography(for artist: String) async -> String? {
        guard let response = await fetchArtist(for: artist) else { return nil }
        return cleanBiography(response.artist.bio?.summary ?? response.artist.bio?.content)
    }

    func artistImage(for artist: String) async -> Data? {
        guard !apiKey.isEmpty, !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "artist.getInfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Uziq/1.0 (macOS music player; artist artwork)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(ImageResponse.self, from: data)
            let apiImageURL = decoded.artist.images
                .sorted(by: { imageRank($0.size ?? "") > imageRank($1.size ?? "") })
                .compactMap({ URL(string: $0.url ?? "") })
                .first(where: { !isPlaceholderURL($0) })
            let imageURL: URL?
            if let apiImageURL {
                imageURL = apiImageURL
            } else {
                imageURL = await artistPageImageURL(decoded.artist.url)
            }
            guard let imageURL else { return nil }
            var imageRequest = URLRequest(url: imageURL)
            imageRequest.setValue("Uziq/1.0 (macOS music player; artist artwork)", forHTTPHeaderField: "User-Agent")
            let (imageData, imageResponse) = try await URLSession.shared.data(for: imageRequest)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard !Self.isPlaceholderImage(imageData) else { return nil }
            return imageData
        } catch {
            return nil
        }
    }

    static func isPlaceholderImage(_ data: Data) -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == "fad5bb8e6aadc987246977682d7b85fd841fc5ff048b955df4837189beacffcf"
    }

    private func fetchArtist(for artist: String) async -> Response? {
        guard !apiKey.isEmpty, !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "artist.getInfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("Uziq/1.0 (macOS music player; artist artwork)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return nil
        }
    }

    private func cleanBiography(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutMarkup = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let cleaned = withoutMarkup
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "Read more on Last.fm", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func imageRank(_ size: String) -> Int {
        switch size.lowercased() {
        case "mega": 5
        case "extralarge": 4
        case "large": 3
        case "medium": 2
        case "small": 1
        default: 0
        }
    }

    private func isPlaceholderURL(_ url: URL) -> Bool {
        url.absoluteString.localizedCaseInsensitiveContains("2a96cbd8b46e442fc41c2b86b821562f")
    }

    private func artistPageImageURL(_ pageValue: String?) async -> URL? {
        guard let pageValue, let pageURL = URL(string: pageValue) else { return nil }
        do {
            var request = URLRequest(url: pageURL)
            request.setValue("Uziq/1.0 (macOS music player; artist artwork)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }
            let pattern = #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["'][^>]*>"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            let value = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: value), !isPlaceholderURL(url) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    private struct Response: Decodable {
        let artist: Artist
    }

    private struct ImageResponse: Decodable {
        let artist: ImageArtist
    }

    private struct ImageArtist: Decodable {
        let images: [Image]
        let url: String?

        enum CodingKeys: String, CodingKey {
            case images = "image"
            case url
        }
    }

    private struct Artist: Decodable {
        let images: [Image]
        let bio: Biography?

        enum CodingKeys: String, CodingKey {
            case images = "image"
            case bio
        }
    }

    private struct Biography: Decodable {
        let summary: String?
        let content: String?
    }

    private struct Image: Decodable {
        let url: String?
        let size: String?

        enum CodingKeys: String, CodingKey {
            case url = "#text"
            case size
        }
    }
}

struct AlbumArtworkEnricher: Sendable {
    private let musicBrainz = MusicBrainzClient()
    private let coverArt = CoverArtArchiveClient()

    func artwork(artist: String, album: String, releaseID: String?) async -> Data? {
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        do {
            if let releaseID, let artwork = try await coverArt.frontArtwork(forReleaseID: releaseID) {
                return artwork
            }

            let releaseCandidates = try await musicBrainz.releaseCandidates(artist: artist, album: album)
            for candidate in releaseCandidates {
                if let artwork = try await coverArt.frontArtwork(forReleaseID: candidate.releaseID) {
                    return artwork
                }
                if let releaseGroupID = candidate.releaseGroupID,
                   let artwork = try await coverArt.frontArtwork(for: releaseGroupID) {
                    return artwork
                }
            }

            guard let releaseGroupID = try await musicBrainz.releaseGroupID(artist: artist, album: album) else {
                return nil
            }
            return try await coverArt.frontArtwork(for: releaseGroupID)
        } catch {
            return nil
        }
    }
}

struct MetadataMatcher: Sendable {
    let fingerprintProvider: any FingerprintProvider
    let artworkClient = CoverArtArchiveClient()
    let musicBrainzClient = MusicBrainzClient()

    func match(track: Track, acoustIDKey: String) async throws -> MetadataMatchResult? {
        guard !acoustIDKey.isEmpty else { throw UziqError.metadata("Add an AcoustID API key in Settings first.") }
        let fingerprint = try fingerprintProvider.fingerprint(for: track.url)
        guard let match = try await AcoustIDClient(apiKey: acoustIDKey).lookup(fingerprint) else { return nil }
        let recording: MusicBrainzRecording? = if let recordingID = match.recordingID {
            try? await musicBrainzClient.recording(id: recordingID)
        } else { nil }
        let artwork: Data? = if let releaseGroupID = match.releaseGroupID {
            try? await artworkClient.frontArtwork(for: releaseGroupID)
        } else { nil }
        return MetadataMatchResult(match: match, recording: recording, artworkData: artwork)
    }
}

struct MetadataMatchResult: Sendable {
    let match: AcoustIDMatch
    let recording: MusicBrainzRecording?
    let artworkData: Data?
}

protocol LyricsProvider: Sendable {
    func lyrics(for track: Track) async throws -> String?
}

struct EmbeddedLyricsProvider: LyricsProvider {
    func lyrics(for track: Track) async throws -> String? { track.lyrics }
}

protocol BandcampProvider: Sendable {
    func search(query: String) async throws -> [BandcampResult]
}

struct BandcampResult: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let url: URL
    let type: String
    let bandID: Int?
    let tralbumID: Int?
    let artworkURL: URL?

    init(
        id: String,
        title: String,
        artist: String,
        url: URL,
        type: String = "",
        bandID: Int? = nil,
        tralbumID: Int? = nil,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.url = url
        self.type = type
        self.bandID = bandID
        self.tralbumID = tralbumID
        self.artworkURL = artworkURL
    }

    var isPlayable: Bool {
        bandID != nil && tralbumID != nil && (type == "a" || type == "t")
    }

    var openURL: URL {
        URL(string: normalizedBandcampURLString(url.absoluteString)) ?? url
    }
}

private func normalizedBandcampURLString(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercase = trimmed.lowercased()

    for (malformedScheme, validScheme) in [("https//", "https://"), ("http//", "http://")] {
        if let range = lowercase.range(of: malformedScheme, options: .backwards) {
            return validScheme + String(trimmed[range.upperBound...])
        }
    }

    for validScheme in ["https://", "http://"] {
        if let range = lowercase.range(of: validScheme, options: .backwards),
           range.lowerBound != lowercase.startIndex {
            return String(trimmed[range.lowerBound...])
        }
    }

    if lowercase.hasPrefix("https:/") && !lowercase.hasPrefix("https://") {
        return "https://" + String(trimmed.dropFirst(7))
    }
    if lowercase.hasPrefix("http:/") && !lowercase.hasPrefix("http://") {
        return "http://" + String(trimmed.dropFirst(6))
    }
    return trimmed
}

/// Uses the public app endpoints documented in the supplied reverse-engineering
/// notes. Search and playback remain best-effort because Bandcamp can change
/// these app-facing endpoints or restrict individual artists' streams.
struct BandcampClient: BandcampProvider, Sendable {
    private let baseURL = URL(string: "https://bandcamp.com")!
    private let userAgent = "Dalvik/2.1.0 (Linux; U; Android 14; Uziq) Bandcamp/3.3.6"

    func search(query: String) async throws -> [BandcampResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/fuzzysearch/2/app_autocomplete"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "param_with_locations", value: "true")
        ]
        guard let url = components?.url else { throw UziqError.metadata("Invalid Bandcamp search request.") }

        var request = URLRequest(url: url)
        request.setValue("com.bandcamp.android", forHTTPHeaderField: "X-Requested-With")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UziqError.metadata("Bandcamp search returned an HTTP error.")
        }
        return parseSearchResults(data)
    }

    func artistBiography(for artist: String) async -> String? {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedArtist.isEmpty,
              let results = try? await search(query: normalizedArtist),
              let result = results.first(where: {
                  $0.type == "b" &&
                  ($0.title.caseInsensitiveCompare(normalizedArtist) == .orderedSame ||
                   $0.artist.caseInsensitiveCompare(normalizedArtist) == .orderedSame)
              }) ?? results.first(where: { $0.type == "b" }),
              result.url.host?.contains("bandcamp.com") == true else { return nil }

        var request = URLRequest(url: result.openURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }

        let preferredDescription = metaContent(in: html, matching: "og:description")
            ?? metaContent(in: html, matching: "description")
        return cleanPageText(preferredDescription)
    }

    func details(for result: BandcampResult) async throws -> BandcampAlbumDetails {
        guard let tralbumID = result.tralbumID, let bandID = result.bandID else {
            throw UziqError.metadata("Bandcamp did not provide enough information to play this result.")
        }

        let endpoint = baseURL.appendingPathComponent("api/mobile/26/tralbum_details")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tralbum_type": result.type,
            "tralbum_id": tralbumID,
            "band_id": bandID
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UziqError.metadata("Bandcamp could not load this release.")
        }
        return try parseDetails(data, fallback: result)
    }

    private func parseSearchResults(_ data: Data) -> [BandcampResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = object["results"] as? [[String: Any]] else { return [] }

        return rawResults.compactMap { raw in
            let type = string(raw["type"]) ?? ""
            guard let rawID = string(raw["id"]), !rawID.isEmpty else { return nil }
            let title = firstString(raw, keys: ["name", "title", "album_name"]) ?? "Untitled"
            let artist = firstString(raw, keys: ["band_name", "artist", "username"]) ?? "Unknown Artist"
            let bandID = integer(raw["band_id"])
            let tralbumID = (type == "a" || type == "t") ? integer(raw["id"]) : nil
            let rawURL = firstString(raw, keys: ["url", "item_url"])
            let url = resolvedURL(rawURL) ?? searchURL(for: title, artist: artist)
            let artworkURL = resolvedArtworkURL(raw)
            return BandcampResult(
                id: "\(type)-\(rawID)-\(artist)-\(title)",
                title: title,
                artist: artist,
                url: url,
                type: type,
                bandID: bandID,
                tralbumID: tralbumID,
                artworkURL: artworkURL
            )
        }
    }

    private func parseDetails(_ data: Data, fallback: BandcampResult) throws -> BandcampAlbumDetails {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UziqError.metadata("Bandcamp returned an invalid release response.")
        }
        guard let bandID = fallback.bandID, let tralbumID = fallback.tralbumID else {
            throw UziqError.metadata("Bandcamp release identifiers are missing.")
        }

        let title = firstString(raw, keys: ["album_title", "title", "name"]) ?? fallback.title
        let artist = firstString(raw, keys: ["band_name", "artist", "username"]) ?? fallback.artist
        let artworkURL = resolvedArtworkURL(raw) ?? fallback.artworkURL
        let rawTracks = raw["tracks"] as? [[String: Any]] ?? []
        let tracks = rawTracks.compactMap { track -> BandcampTrackDetails? in
            guard let trackID = integer(track["track_id"]) ?? integer(track["id"]) else { return nil }
            let trackTitle = firstString(track, keys: ["title", "name"]) ?? "Untitled"
            let streamURL = streamingURL(track)
            return BandcampTrackDetails(
                id: trackID,
                number: integer(track["track_num"]) ?? integer(track["track_number"]),
                title: trackTitle,
                duration: double(track["duration"]) ?? 0,
                isStreamable: boolean(track["is_streamable"]) && streamURL != nil,
                pageURL: resolvedURL(firstString(track, keys: ["track_url", "url"])),
                lyrics: firstString(track, keys: ["lyrics"]),
                streamURL: streamURL
            )
        }

        return BandcampAlbumDetails(
            id: tralbumID,
            bandID: bandID,
            type: fallback.type,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            tracks: tracks
        )
    }

    private func streamingURL(_ raw: [String: Any]) -> URL? {
        let value = raw["streaming_url"] ?? raw["streaming_urls"]
        if let urls = value as? [String: Any] {
            let preferred = ["mp3-128", "mp3-v0"].compactMap { urls[$0] }.compactMap(string).first
            return resolvedURL(preferred)
        }
        return resolvedURL(string(value))
    }

    private func resolvedArtworkURL(_ raw: [String: Any]) -> URL? {
        if let url = resolvedURL(firstString(raw, keys: ["img", "art_url", "artwork_url", "image_url"])) { return url }
        guard let artID = string(raw["art_id"]) ?? string(raw["art_ids"]) else { return nil }
        return URL(string: "https://f4.bcbits.com/img/a\(artID)_16.jpg")
    }

    private func resolvedURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let normalized = normalizedBandcampURLString(value)
        guard !normalized.isEmpty else { return nil }
        if let url = URL(string: normalized), url.scheme != nil { return url }
        return URL(string: normalized, relativeTo: baseURL)?.absoluteURL
    }

    private func searchURL(for title: String, artist: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        return components?.url ?? baseURL
    }

    private func metaContent(in html: String, matching name: String) -> String? {
        let tagPattern = #"<meta\b[^>]*>"#
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else { return nil }
        let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tagRegex.matches(in: html, range: htmlRange) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard tag.range(of: name, options: [.caseInsensitive]) != nil else { continue }
            let contentPattern = #"\bcontent\s*=\s*["']([^"']*)["']"#
            guard let contentRegex = try? NSRegularExpression(pattern: contentPattern, options: [.caseInsensitive]),
                  let contentMatch = contentRegex.firstMatch(
                      in: tag,
                      range: NSRange(tag.startIndex..<tag.endIndex, in: tag)
                  ),
                  let contentRange = Range(contentMatch.range(at: 1), in: tag) else { continue }
            return String(tag[contentRange])
        }
        return nil
    }

    private func cleanPageText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func firstString(_ raw: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(raw[$0]) }.first
    }

    private func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    private func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    private func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    private func boolean(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return value == "1" || value.lowercased() == "true"
        default: return false
        }
    }
}

/// Kept as a provider useful for tests or builds that intentionally disable
/// network-backed discovery.
struct UnavailableBandcampProvider: BandcampProvider {
    func search(query: String) async throws -> [BandcampResult] {
        throw UziqError.metadata("Bandcamp search is not available without an approved official integration.")
    }
}
