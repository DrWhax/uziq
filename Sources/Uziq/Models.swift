import Foundation

enum LibrarySection: String, CaseIterable, Identifiable {
    case library
    case artists
    case albums
    case genres
    case playlists
    case history
    case mostPlayed
    case recentlyAdded
    case bandcamp
    case spotify
    case jellyfin
    case settings

    var id: String { rawValue }

    var usesLocalLibrary: Bool {
        switch self {
        case .history, .bandcamp, .spotify, .jellyfin, .settings:
            false
        default:
            true
        }
    }

    var title: String {
        switch self {
        case .library: "Library"
        case .artists: "Artists"
        case .albums: "Albums"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .history: "Listening History"
        case .mostPlayed: "Most Played"
        case .recentlyAdded: "Recently Added"
        case .bandcamp: "Bandcamp"
        case .spotify: "Spotify"
        case .jellyfin: "Jellyfin"
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
        case .history: "clock.arrow.circlepath"
        case .mostPlayed: "chart.bar.fill"
        case .recentlyAdded: "clock"
        case .bandcamp: "dot.radiowaves.left.and.right"
        case .spotify: "music.note.house.fill"
        case .jellyfin: "server.rack"
        case .settings: "gearshape"
        }
    }
}

struct ListeningHistoryEvent: Hashable, Sendable {
    let source: PlaybackSource
    let sourceID: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let queueItem: UnifiedQueueItem
    let playedAt: Date

    var itemKey: String { "\(source.rawValue):\(sourceID)" }
}

struct ListeningHistoryItem: Identifiable, Hashable, Sendable {
    let itemKey: String
    let source: PlaybackSource
    let sourceID: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let queueItem: UnifiedQueueItem
    let lastPlayedAt: Date
    let playCount: Int

    var id: String { itemKey }
}

enum SmartMixKind: String, Sendable {
    case rotation
    case rediscover
    case acrossUziq

    var systemImage: String {
        switch self {
        case .rotation: "repeat.circle.fill"
        case .rediscover: "sparkles"
        case .acrossUziq: "square.grid.2x2.fill"
        }
    }
}

struct SmartMix: Identifiable, Hashable, Sendable {
    let kind: SmartMixKind
    let title: String
    let subtitle: String
    let items: [ListeningHistoryItem]

    var id: String { kind.rawValue }
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
    var replayGainTrackDB: Double? = nil
    var replayGainAlbumDB: Double? = nil
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
    var replayGainTrackDB: Double? = nil
    var replayGainAlbumDB: Double? = nil
    let artworkData: Data?
    let lyrics: String?
    let musicBrainzRecordingID: String?
    let musicBrainzReleaseID: String?
    let acoustID: String?
    let modifiedAt: Date
    let fileSize: Int64
}

struct CachedLyrics: Sendable, Equatable {
    let lyrics: String?
    let syncedLyrics: String?
    let isInstrumental: Bool
    let fetchedAt: Date
}

struct MetadataOverrideChanges: Sendable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var genre: String?
    var year: String?
    var trackNumber: Int?
    var discNumber: Int?
    var overridesTrackNumber = false
    var overridesDiscNumber = false
    var artworkData: Data?
    var overridesArtwork = false

    var isEmpty: Bool {
        title == nil && artist == nil && albumArtist == nil && album == nil &&
            genre == nil && year == nil && !overridesTrackNumber &&
            !overridesDiscNumber && !overridesArtwork
    }
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

struct ArtistLetterSection: Identifiable, Sendable {
    let letter: String
    let artists: [ArtistGroup]

    var id: String { letter }

    static func grouped(_ tracks: [Track]) -> [ArtistLetterSection] {
        grouped(ArtistGroup.grouped(tracks))
    }

    static func grouped(_ artists: [ArtistGroup]) -> [ArtistLetterSection] {
        Dictionary(grouping: artists) { artist in
            guard let first = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).first,
                  first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        .map { ArtistLetterSection(letter: $0.key, artists: $0.value) }
        .sorted {
            if $0.letter == "#" { return false }
            if $1.letter == "#" { return true }
            return $0.letter < $1.letter
        }
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

struct LocalLibraryBrowseSnapshot: Sendable {
    let albums: [AlbumGroup]
    let artists: [ArtistGroup]
    let artistSections: [ArtistLetterSection]
    let genres: [GenreGroup]

    static let empty = LocalLibraryBrowseSnapshot(albums: [], artists: [], artistSections: [], genres: [])

    static func grouped(_ tracks: [Track]) -> LocalLibraryBrowseSnapshot {
        let artists = ArtistGroup.grouped(tracks)
        return LocalLibraryBrowseSnapshot(
            albums: AlbumGroup.grouped(tracks),
            artists: artists,
            artistSections: ArtistLetterSection.grouped(artists),
            genres: GenreGroup.grouped(tracks)
        )
    }

    var artistCount: Int { artists.count }
}

struct RecentArtistPlay: Identifiable, Equatable, Sendable {
    let name: String
    let playCount: Int
    let lastPlayedAt: Date

    var id: String { name.lowercased() }
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

enum ArtistProfileSource: String, Codable, Sendable {
    case lastFM
    case bandcamp

    var title: String {
        switch self {
        case .lastFM: "Last.fm"
        case .bandcamp: "Bandcamp"
        }
    }
}

struct ArtistProfile: Codable, Hashable, Sendable {
    let summary: String
    let source: ArtistProfileSource
}

enum BandcampSubscriptionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case keyword
    case artist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyword: "Keyword"
        case .artist: "Artist"
        }
    }
}

struct BandcampSubscription: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: BandcampSubscriptionKind
    let value: String
}

struct BandcampTrackDetails: Identifiable, Hashable, Sendable {
    let id: Int
    let number: Int?
    let title: String
    let duration: Double
    let isStreamable: Bool
    let pageURL: URL?
    let lyrics: String?
    let streamURL: URL?
}

struct BandcampAlbumDetails: Identifiable, Hashable, Sendable {
    let id: Int
    let bandID: Int
    let type: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let tracks: [BandcampTrackDetails]
}

struct BandcampArtistPage: Sendable {
    let artist: BandcampResult
    let summary: String?
    let releases: [BandcampResult]
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
