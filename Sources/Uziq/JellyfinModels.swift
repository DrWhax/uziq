import Foundation
import JellyfinAPI

enum JellyfinItemKind: String, Codable, Sendable {
    case track
    case album
    case artist
    case playlist

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .track: "music.note"
        case .album: "square.stack"
        case .artist: "person.fill"
        case .playlist: "rectangle.stack.fill"
        }
    }
}

struct JellyfinCatalogItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let kind: JellyfinItemKind
    let album: String
    let albumArtist: String
    let artists: [String]
    let artistIDs: [String]
    let albumID: String?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double
    let container: String?
    let year: Int?
    let genres: [String]
    let imageItemID: String?
    let imageTag: String?
    let itemCount: Int?

    var durationText: String? {
        guard duration.isFinite, duration > 0 else { return nil }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    init?(dto: BaseItemDto) {
        guard let id = dto.id, let name = dto.name else { return nil }
        let kind: JellyfinItemKind
        switch dto.type {
        case .audio: kind = .track
        case .musicAlbum: kind = .album
        case .musicArtist: kind = .artist
        case .playlist: kind = .playlist
        default: return nil
        }

        let artists = dto.artists ?? dto.artistItems?.compactMap(\.name) ?? []
        let artistIDs = dto.artistItems?.compactMap(\.id) ?? []
        let album = dto.album ?? (kind == .album ? name : "")
        let albumArtist = dto.albumArtist ?? artists.first ?? ""
        let imageTag = dto.imageTags?["Primary"] ?? dto.albumPrimaryImageTag ?? dto.parentPrimaryImageTag
        let imageItemID: String?
        if dto.imageTags?["Primary"] != nil {
            imageItemID = id
        } else if dto.albumPrimaryImageTag != nil, let albumID = dto.albumID {
            imageItemID = albumID
        } else {
            imageItemID = dto.parentPrimaryImageItemID ?? dto.albumID
        }

        self.id = id
        self.name = name
        self.kind = kind
        self.album = album
        self.albumArtist = albumArtist
        self.artists = artists
        self.artistIDs = artistIDs
        self.albumID = dto.albumID
        self.trackNumber = dto.indexNumber
        self.discNumber = dto.parentIndexNumber
        self.duration = Double(dto.runTimeTicks ?? 0) / 10_000_000
        self.container = dto.container
        self.year = dto.productionYear
        self.genres = dto.genres ?? []
        self.imageItemID = imageItemID
        self.imageTag = imageTag
        self.itemCount = dto.childCount

        switch kind {
        case .track:
            self.subtitle = artists.joined(separator: ", ").nilIfEmpty ?? albumArtist.nilIfEmpty ?? "Unknown Artist"
        case .album:
            self.subtitle = albumArtist.nilIfEmpty ?? artists.joined(separator: ", ").nilIfEmpty ?? "Unknown Artist"
        case .artist:
            self.subtitle = dto.albumCount.map { "\($0) albums" } ?? "Artist"
        case .playlist:
            self.subtitle = dto.childCount.map { "\($0) tracks" } ?? "Playlist"
        }
    }
}

struct JellyfinSession: Codable, Sendable {
    let serverURL: URL
    let accessToken: String
    let userID: String
    let username: String
    let serverName: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
