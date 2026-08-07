import Foundation

enum LibrarySection: String, CaseIterable, Identifiable {
    case library
    case artists
    case albums
    case genres
    case playlists
    case mostPlayed
    case recentlyAdded
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .artists: "Artists"
        case .albums: "Albums"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .mostPlayed: "Most Played"
        case .recentlyAdded: "Recently Added"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "music.note.list"
        case .artists: "person.2"
        case .albums: "square.stack"
        case .genres: "guitars"
        case .playlists: "rectangle.stack"
        case .mostPlayed: "chart.bar.fill"
        case .recentlyAdded: "clock"
        case .settings: "gearshape"
        }
    }
}

enum MostPlayedRange: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    var startDate: Date {
        let component: Calendar.Component
        let value: Int
        switch self {
        case .week:
            component = .day
            value = -7
        case .month:
            component = .month
            value = -1
        case .year:
            component = .year
            value = -1
        }
        return Calendar.current.date(byAdding: component, value: value, to: .now) ?? .now
    }
}

struct Track: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let fileName: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let genre: String
    let year: String
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double
    let codec: String
    let bitrate: Int?
    let sampleRate: Double?
    let artworkData: Data?
    let lyrics: String?
    let musicBrainzRecordingID: String?
    let musicBrainzReleaseID: String?
    let acoustID: String?
    let addedAt: Date
    let modifiedAt: Date
    let isFavorite: Bool
    let playCount: Int

    var displayArtist: String {
        artist.isEmpty ? "Unknown Artist" : artist
    }

    var displayAlbum: String {
        album.isEmpty ? "Unknown Album" : album
    }

    var displayTitle: String {
        title.isEmpty ? fileName : title
    }

    var durationText: String {
        guard duration.isFinite, duration >= 0 else { return "—" }
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct TrackMetadata: Sendable {
    let url: URL
    let fileName: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let genre: String
    let year: String
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double
    let codec: String
    let bitrate: Int?
    let sampleRate: Double?
    let artworkData: Data?
    let lyrics: String?
    let musicBrainzRecordingID: String?
    let musicBrainzReleaseID: String?
    let acoustID: String?
    let modifiedAt: Date
    let fileSize: Int64
}

struct PlaylistSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let trackCount: Int
    let createdAt: Date
}

struct AlbumGroup: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]

    var artworkData: Data? { tracks.first(where: { $0.artworkData != nil })?.artworkData }

    static func grouped(_ tracks: [Track]) -> [AlbumGroup] {
        let knownAlbumsByArtist = Dictionary(grouping: tracks, by: albumGroupingArtist)
            .mapValues { Set($0.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) }
        let groups = Dictionary(grouping: tracks) { track in
            albumGroupingKey(for: track, knownAlbums: knownAlbumsByArtist[albumGroupingArtist(track)] ?? [])
        }
        return groups.map { key, tracks in
            let sortedTracks = tracks.sorted {
                if let lhs = $0.trackNumber, let rhs = $1.trackNumber, lhs != rhs { return lhs < rhs }
                return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
            let splitReleaseTitle = sortedTracks
                .map(\.album)
                .first { $0.localizedStandardContains(" / ") }
            return AlbumGroup(
                id: key,
                title: splitReleaseTitle ?? sortedTracks.first?.displayAlbum ?? "Unknown Album",
                artist: sortedTracks.first?.albumArtist.isEmpty == false ? sortedTracks[0].albumArtist : (sortedTracks.first?.displayArtist ?? "Unknown Artist"),
                tracks: sortedTracks
            )
        }
        .sorted {
            if $0.artist.localizedCaseInsensitiveCompare($1.artist) != .orderedSame {
                return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

func albumGroupingArtist(_ track: Track) -> String {
    track.albumArtist.isEmpty ? track.displayArtist : track.albumArtist
}

func albumGroupingKey(for track: Track, knownAlbums: Set<String>) -> String {
    let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedAlbum = album.lowercased()
    let splitParts = album.components(separatedBy: " / ")
    let baseAlbum = splitParts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? normalizedAlbum
    let groupingAlbum = splitParts.count > 1 && knownAlbums.contains(baseAlbum) ? baseAlbum : normalizedAlbum
    return "\(albumGroupingArtist(track).lowercased())\u{1F}\(groupingAlbum)"
}

struct ArtistGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let tracks: [Track]
    let albums: [AlbumGroup]

    static func grouped(_ tracks: [Track]) -> [ArtistGroup] {
        Dictionary(grouping: tracks, by: { $0.displayArtist })
            .map { name, tracks in
                ArtistGroup(id: name, name: name, tracks: tracks, albums: AlbumGroup.grouped(tracks))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct GenreGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let albums: [AlbumGroup]
    let trackCount: Int

    static func grouped(_ tracks: [Track]) -> [GenreGroup] {
        Dictionary(grouping: tracks, by: { $0.genre.isEmpty ? "Unknown Genre" : $0.genre })
            .map { name, tracks in
                GenreGroup(id: name, name: name, albums: AlbumGroup.grouped(tracks), trackCount: tracks.count)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct ScanProgress: Sendable {
    let completed: Int
    let discovered: Int
    let currentFile: String

    var fractionCompleted: Double? {
        guard discovered > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(discovered)))
    }
}

struct ArtworkProgress: Sendable {
    let completed: Int
    let total: Int
    let currentAlbum: String

    var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct ArtistArtworkProgress: Sendable {
    let completed: Int
    let total: Int
    let currentArtist: String

    var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum UziqError: LocalizedError {
    case unsupportedFile(URL)
    case inaccessibleFolder(URL)
    case database(String)
    case metadata(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): "Unsupported audio file: \(url.lastPathComponent)"
        case .inaccessibleFolder(let url): "Could not access folder: \(url.path)"
        case .database(let message): "Library database error: \(message)"
        case .metadata(let message): "Metadata error: \(message)"
        }
    }
}
