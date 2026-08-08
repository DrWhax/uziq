import Foundation

enum SearchProvider: String, CaseIterable, Identifiable {
    case local
    case bandcamp
    case spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .bandcamp: "Bandcamp"
        case .spotify: "Spotify"
        }
    }
}

enum SpotifyItemKind: String, Codable, Sendable {
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

enum SpotifyArtistPageSection: String, CaseIterable, Identifiable {
    case albums
    case radio

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct SpotifyCatalogItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let uri: String
    let kind: SpotifyItemKind
    let artworkURL: URL?
    let durationMS: Int?
    let itemCount: Int?

    var durationText: String? {
        guard let durationMS else { return nil }
        let totalSeconds = durationMS / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct SpotifyPlaybackSnapshot: Equatable, Sendable {
    let itemID: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let duration: Double
    let progress: Double
    let isPlaying: Bool
    let deviceName: String
    let observedAt: Date

    func effectiveProgress(at date: Date) -> Double {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(observedAt)) : 0
        return min(duration, max(0, progress + elapsed))
    }
}

enum LibrespotStatus: Equatable, Sendable {
    case unavailable
    case stopped
    case starting
    case authenticating
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .unavailable: "librespot not found"
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .authenticating: "Waiting for Spotify login…"
        case .ready: "Ready"
        case .failed(let message): message
        }
    }

    var isRunning: Bool {
        switch self {
        case .starting, .authenticating, .ready: true
        case .unavailable, .stopped, .failed: false
        }
    }
}

enum LibrespotPlayerEvent: String, Equatable, Sendable {
    case trackChanged = "track_changed"
    case playing
    case paused
    case seeked
    case stopped
}
