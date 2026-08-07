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
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let imageURL = decoded.artist.images
                .sorted(by: { imageRank($0.size) > imageRank($1.size) })
                .compactMap({ URL(string: $0.url) })
                .first else { return nil }

            let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return imageData
        } catch {
            return nil
        }
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

    private struct Response: Decodable {
        let artist: Artist
    }

    private struct Artist: Decodable {
        let images: [Image]

        enum CodingKeys: String, CodingKey {
            case images = "image"
        }
    }

    private struct Image: Decodable {
        let url: String
        let size: String

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

struct BandcampResult: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let url: URL
}

/// Bandcamp's documented API is for approved account/label integrations. This
/// provider intentionally fails clearly instead of scraping undocumented pages.
struct UnavailableBandcampProvider: BandcampProvider {
    func search(query: String) async throws -> [BandcampResult] {
        throw UziqError.metadata("Bandcamp search is not available without an approved official integration.")
    }
}
