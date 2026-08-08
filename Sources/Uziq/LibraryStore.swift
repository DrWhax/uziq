import Foundation
import Observation
import SwiftUI

private struct ArtworkCandidate: Sendable {
    let artist: String
    let album: String
    let releaseID: String?
    let existingArtwork: Data?
    let trackIDs: [String]
}

@MainActor
@Observable
final class LibraryStore {
    var tracks: [Track] = []
    var searchText = ""
    var selectedSection: LibrarySection = .library
    var mostPlayedRange: MostPlayedRange = .week
    var isScanning = false
    var scanProgress: ScanProgress?
    var scanMessage: String?
    var isEnrichingArtwork = false
    var artworkProgress: ArtworkProgress?
    var artistArtwork: [String: Data] = [:]
    var artistProfiles: [String: ArtistProfile] = [:]
    var artistProfilesLoading: Set<String> = []
    var isEnrichingArtistArtwork = false
    var artistArtworkProgress: ArtistArtworkProgress?
    var lastError: String?
    var showingFolderImporter = false
    var folderRoots: [URL] = []
    var matchingTrackID: String?
    var playlists: [PlaylistSummary] = []
    var favoriteTrackIDs: Set<String> = []
    private(set) var isInitialLoadComplete = false

    @ObservationIgnored private let database = LibraryDatabase()
    @ObservationIgnored private let scanner = LibraryScanner()
    @ObservationIgnored private let bookmarks = BookmarkStore()
    @ObservationIgnored private let matcher = MetadataMatcher(fingerprintProvider: FpcalcFingerprintProvider())
    @ObservationIgnored private let artworkEnricher = AlbumArtworkEnricher()
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artistArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var playObserver: NSObjectProtocol?

    init() {
        folderRoots = bookmarks.resolvedURLs()
        playObserver = NotificationCenter.default.addObserver(
            forName: .uziqTrackPlayed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let trackID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.database.recordPlay(trackID: trackID)
                    await self.refresh()
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
        }
        Task {
            await refresh()
            isInitialLoadComplete = true
            await loadFavoriteTrackIDs()
            await loadPlaylists()
            await loadArtistArtwork()
            startArtworkEnrichment()
            startArtistArtworkEnrichment()
        }
    }

    deinit {
        if let playObserver { NotificationCenter.default.removeObserver(playObserver) }
    }

    var displayedTracks: [Track] {
        switch selectedSection {
        case .recentlyAdded:
            return Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(100))
        case .artists, .albums, .genres, .playlists, .mostPlayed, .bandcamp, .spotify, .jellyfin, .library, .settings:
            return tracks
        }
    }

    func presentFolderImporter() { showingFolderImporter = true }

    func importFolders(_ urls: [URL]) {
        for url in urls {
            let normalizedURL = url.standardizedFileURL
            bookmarks.add(normalizedURL)
            if !folderRoots.contains(normalizedURL) { folderRoots.append(normalizedURL) }
        }
        scan()
    }

    func removeFolder(_ url: URL) {
        bookmarks.remove(url)
        folderRoots.removeAll { $0 == url }
    }

    func scan() {
        guard !isScanning else { return }
        guard !folderRoots.isEmpty else {
            scanMessage = "No library folders added"
            return
        }
        isScanning = true
        lastError = nil
        scanMessage = "Starting library rescan…"
        let roots = folderRoots
        Task {
            let discovered = await scanner.scan(roots: roots) { [weak self] progress in
                Task { @MainActor in self?.scanProgress = progress }
            }
            do {
                for item in discovered { try await database.upsert(item) }
                try await database.removeMissingFiles()
                await refresh()
                scanMessage = "Indexed \(discovered.count) audio files"
            } catch {
                lastError = error.localizedDescription
                scanMessage = "Rescan failed"
            }
            scanProgress = nil
            isScanning = false
            if lastError == nil {
                startArtworkEnrichment()
                startArtistArtworkEnrichment()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.isScanning == false { self?.scanMessage = nil }
            }
        }
    }

    private func startArtworkEnrichment() {
        guard artworkTask == nil, !isScanning else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let allTracks = (try? await database.fetchTracks()) ?? []
            let candidates = Self.artworkCandidates(from: allTracks)
            guard !candidates.isEmpty else {
                artworkTask = nil
                return
            }

            isEnrichingArtwork = true
            artworkProgress = ArtworkProgress(completed: 0, total: candidates.count, currentAlbum: "Preparing…")
            defer {
                isEnrichingArtwork = false
                artworkProgress = nil
                artworkTask = nil
            }

            for (index, candidate) in candidates.enumerated() {
                guard !Task.isCancelled else { return }
                artworkProgress = ArtworkProgress(
                    completed: index,
                    total: candidates.count,
                    currentAlbum: "\(candidate.artist) — \(candidate.album)"
                )
                let artwork: Data?
                if let existingArtwork = candidate.existingArtwork {
                    artwork = existingArtwork
                } else {
                    artwork = await artworkEnricher.artwork(
                        artist: candidate.artist,
                        album: candidate.album,
                        releaseID: candidate.releaseID
                    )
                }
                if let artwork {
                    try? await database.updateArtwork(trackIDs: candidate.trackIDs, artworkData: artwork)
                    await refresh()
                }
                artworkProgress = ArtworkProgress(
                    completed: index + 1,
                    total: candidates.count,
                    currentAlbum: "\(candidate.artist) — \(candidate.album)"
                )
            }
        }
    }

    private func startArtistArtworkEnrichment() {
        guard artistArtworkTask == nil, !isScanning, !lastFMAPIKey.isEmpty else { return }
        artistArtworkTask = Task { [weak self] in
            guard let self else { return }
            let allTracks = (try? await database.fetchTracks()) ?? []
            let artists = Array(Set(allTracks.map(\.displayArtist)
                .filter { !$0.isEmpty && $0 != "Unknown Artist" })).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            let missingArtists = artists.filter { self.artistArtwork[$0] == nil }
            guard !missingArtists.isEmpty else {
                artistArtworkTask = nil
                return
            }

            isEnrichingArtistArtwork = true
            artistArtworkProgress = ArtistArtworkProgress(completed: 0, total: missingArtists.count, currentArtist: "Preparing…")
            defer {
                isEnrichingArtistArtwork = false
                artistArtworkProgress = nil
                artistArtworkTask = nil
            }

            let client = LastFMClient(apiKey: lastFMAPIKey)
            for (index, artist) in missingArtists.enumerated() {
                guard !Task.isCancelled else { return }
                artistArtworkProgress = ArtistArtworkProgress(
                    completed: index,
                    total: missingArtists.count,
                    currentArtist: artist
                )
                if let artwork = await client.artistImage(for: artist) {
                    try? await database.updateArtistArtwork(artist: artist, artworkData: artwork)
                    artistArtwork[artist] = artwork
                }
                artistArtworkProgress = ArtistArtworkProgress(
                    completed: index + 1,
                    total: missingArtists.count,
                    currentArtist: artist
                )
            }
        }
    }

    private static func artworkCandidates(from tracks: [Track]) -> [ArtworkCandidate] {
        let eligible = tracks.filter { track in
            !track.album.isEmpty && (!track.albumArtist.isEmpty || !track.artist.isEmpty)
        }
        let knownAlbumsByArtist = Dictionary(grouping: eligible, by: albumGroupingArtist)
            .mapValues { Set($0.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) }
        let grouped = Dictionary(grouping: eligible) { track in
            albumGroupingKey(for: track, knownAlbums: knownAlbumsByArtist[albumGroupingArtist(track)] ?? [])
        }
        return grouped.values.compactMap { tracks in
            let missingTracks = tracks.filter { $0.artworkData == nil }
            guard let first = tracks.first, !missingTracks.isEmpty else { return nil }
            let displayAlbum = tracks
                .map(\.album)
                .first { $0.localizedStandardContains(" / ") } ?? first.album
            return ArtworkCandidate(
                artist: albumGroupingArtist(first),
                album: displayAlbum,
                releaseID: tracks.compactMap(\.musicBrainzReleaseID).first,
                existingArtwork: tracks.compactMap(\.artworkData).first,
                trackIDs: missingTracks.map(\.id)
            )
        }
        .sorted {
            let lhs = "\($0.artist)\u{1F}\($0.album)"
            let rhs = "\($1.artist)\u{1F}\($1.album)"
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    func refresh() async {
        do {
            tracks = try await database.fetchTracks(
                search: searchText,
                recentlyAdded: selectedSection == .recentlyAdded,
                favoritesOnly: false,
                mostPlayedSince: selectedSection == .mostPlayed ? mostPlayedRange.startDate : nil
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadArtistArtwork() async {
        do {
            artistArtwork = try await database.fetchArtistArtwork().filter {
                !LastFMClient.isPlaceholderImage($0.value)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshArtistArtworkIfNeeded() {
        guard !lastFMAPIKey.isEmpty else { return }
        startArtistArtworkEnrichment()
    }

    func artistArtworkData(for artist: String) -> Data? {
        if let artwork = artistArtwork[artist] { return artwork }
        let normalized = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return artistArtwork.first {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }?.value
    }

    func fetchArtistArtwork() {
        guard !lastFMAPIKey.isEmpty else {
            lastError = "Add a Last.fm API key in Settings first."
            return
        }
        startArtistArtworkEnrichment()
    }

    func loadArtistProfile(for artist: String) {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedArtist.isEmpty,
              artistProfiles[normalizedArtist] == nil,
              !artistProfilesLoading.contains(normalizedArtist) else { return }

        artistProfilesLoading.insert(normalizedArtist)
        let lastFMAPIKey = self.lastFMAPIKey
        Task { [weak self] in
            let lastFMProfile = await LastFMClient(apiKey: lastFMAPIKey).artistBiography(for: normalizedArtist)
            let profile: ArtistProfile?
            if let lastFMProfile {
                profile = ArtistProfile(summary: lastFMProfile, source: .lastFM)
            } else if let bandcampProfile = await BandcampClient().artistBiography(for: normalizedArtist) {
                profile = ArtistProfile(summary: bandcampProfile, source: .bandcamp)
            } else {
                profile = nil
            }

            guard let self else { return }
            if let profile {
                self.artistProfiles[normalizedArtist] = profile
            }
            self.artistProfilesLoading.remove(normalizedArtist)
        }
    }

    func clearError() { lastError = nil }

    func isFavorite(_ track: Track) -> Bool {
        favoriteTrackIDs.contains(track.id)
    }

    func toggleFavorite(_ track: Track) {
        if favoriteTrackIDs.contains(track.id) {
            favoriteTrackIDs.remove(track.id)
        } else {
            favoriteTrackIDs.insert(track.id)
        }
        Task {
            do {
                try await database.toggleFavorite(trackID: track.id)
                await refresh()
                await loadFavoriteTrackIDs()
            } catch {
                if favoriteTrackIDs.contains(track.id) {
                    favoriteTrackIDs.remove(track.id)
                } else {
                    favoriteTrackIDs.insert(track.id)
                }
                lastError = error.localizedDescription
            }
        }
    }

    private func loadFavoriteTrackIDs() async {
        do {
            favoriteTrackIDs = Set(try await database.fetchTracks(favoritesOnly: true).map(\.id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadPlaylists() async {
        do {
            playlists = try await database.fetchPlaylists()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createPlaylist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await database.createPlaylist(name: trimmed)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func deletePlaylist(_ playlist: PlaylistSummary) {
        Task {
            do {
                try await database.deletePlaylist(id: playlist.id)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func playlistTracks(_ playlist: PlaylistSummary) async -> [Track] {
        do {
            return try await database.fetchPlaylistTracks(playlistID: playlist.id)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func add(_ track: Track, to playlist: PlaylistSummary) {
        Task {
            do {
                try await database.addTrack(trackID: track.id, toPlaylist: playlist.id)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func remove(_ track: Track, from playlist: PlaylistSummary) {
        Task {
            do {
                try await database.removeTrack(trackID: track.id, fromPlaylist: playlist.id)
                await loadPlaylists()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    var acoustIDAPIKey: String {
        get { UserDefaults.standard.string(forKey: "acoustid-api-key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "acoustid-api-key") }
    }

    var lastFMAPIKey: String {
        get { UserDefaults.standard.string(forKey: "lastfm-api-key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastfm-api-key") }
    }

    func identify(_ track: Track) {
        guard matchingTrackID == nil else { return }
        matchingTrackID = track.id
        lastError = nil
        Task {
            do {
                guard let result = try await matcher.match(track: track, acoustIDKey: acoustIDAPIKey) else {
                    throw UziqError.metadata("AcoustID did not find a confident match for \(track.displayTitle).")
                }
                try await database.updateMatch(trackID: track.id, result: result)
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
            matchingTrackID = nil
        }
    }
}
