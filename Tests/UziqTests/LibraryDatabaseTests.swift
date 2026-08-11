import XCTest
import SQLite3
@testable import Uziq

final class LibraryDatabaseTests: XCTestCase {
    func testPersistentDatabaseEnablesWALForeignKeysAndCurrentSchema() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-database-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let health = try await database.health()

        XCTAssertEqual(health.schemaVersion, LibraryDatabase.currentSchemaVersion)
        XCTAssertTrue(health.foreignKeysEnabled)
        XCTAssertEqual(health.journalMode.lowercased(), "wal")
    }

    func testLegacyUnversionedDatabaseMigratesWithoutLosingTracks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-legacy-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let trackPath = directory.appendingPathComponent("legacy-song.mp3").path

        try executeSQLite(at: databaseURL, sql: """
            CREATE TABLE tracks (
                id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, file_name TEXT NOT NULL,
                title TEXT NOT NULL, artist TEXT NOT NULL, album_artist TEXT NOT NULL,
                album TEXT NOT NULL, genre TEXT NOT NULL, year TEXT NOT NULL,
                track_number INTEGER, disc_number INTEGER, duration REAL NOT NULL,
                codec TEXT NOT NULL, bitrate INTEGER, sample_rate REAL, artwork BLOB,
                lyrics TEXT, mb_recording_id TEXT, mb_release_id TEXT, acoustid TEXT,
                added_at REAL NOT NULL, modified_at REAL NOT NULL, file_size INTEGER NOT NULL
            );
            CREATE TABLE playlists (id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE TABLE playlist_tracks (
                playlist_id TEXT NOT NULL, track_id TEXT NOT NULL, position INTEGER NOT NULL,
                PRIMARY KEY (playlist_id, track_id)
            );
            CREATE TABLE play_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, track_id TEXT NOT NULL, played_at REAL NOT NULL
            );
            CREATE VIRTUAL TABLE tracks_fts USING fts5(
                track_id UNINDEXED, title, artist, album, album_artist, genre
            );
            INSERT INTO tracks VALUES (
                'legacy-id', '\(trackPath)', 'legacy-song.mp3', 'Legacy Song', 'Legacy Artist',
                'Legacy Artist', 'Legacy Album', '', '', 1, 1, 120, 'MP3', NULL, NULL,
                NULL, NULL, NULL, NULL, NULL, 1, 1, 1
            );
            INSERT INTO play_history(track_id, played_at) VALUES ('legacy-id', 2);
            """)

        let database = LibraryDatabase(databaseURL: databaseURL)
        let health = try await database.health()
        let tracks = try await database.fetchTracks(search: "legacy")

        XCTAssertEqual(health.schemaVersion, LibraryDatabase.currentSchemaVersion)
        XCTAssertTrue(health.foreignKeysEnabled)
        XCTAssertEqual(tracks.map(\.id), ["legacy-id"])
        try await database.toggleFavorite(trackID: "legacy-id")
        let favorites = try await database.fetchTracks(favoritesOnly: true)
        XCTAssertEqual(favorites.map(\.id), ["legacy-id"])
        let migratedHistory = try await database.fetchRecentListeningHistory()
        XCTAssertEqual(migratedHistory.map(\.sourceID), ["legacy-id"])
        XCTAssertEqual(migratedHistory.first?.queueItem.localURL?.path, trackPath)
    }

    func testArtistProfilesAndFailedLookupAttemptsPersist() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        let profile = ArtistProfile(summary: "A cached artist biography.", source: .lastFM)

        try await database.updateArtistProfile(artist: "Cached Artist", profile: profile)
        try await database.recordArtistProfileAttempt(artist: "Missing Artist")

        let profiles = try await database.fetchArtistProfiles()
        let recentAttempts = try await database.recentlyAttemptedArtistProfiles(
            since: Date(timeIntervalSinceNow: -60)
        )
        let futureAttempts = try await database.recentlyAttemptedArtistProfiles(
            since: Date(timeIntervalSinceNow: 60)
        )

        XCTAssertEqual(profiles["Cached Artist"], profile)
        XCTAssertEqual(recentAttempts, ["Missing Artist"])
        XCTAssertTrue(futureAttempts.isEmpty)
    }

    func testAlbumArtworkAttemptsPersistRecentMisses() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        let albumKey = "boards of canada\u{1F}remixes"

        let attemptsBefore = try await database.recentlyAttemptedAlbumArtwork(
            since: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertTrue(attemptsBefore.isEmpty)

        try await database.recordAlbumArtworkAttempt(key: albumKey)

        let recentAttempts = try await database.recentlyAttemptedAlbumArtwork(
            since: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertEqual(recentAttempts, [albumKey])

        let futureAttempts = try await database.recentlyAttemptedAlbumArtwork(
            since: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertTrue(futureAttempts.isEmpty)
    }

    func testLRCLIBLyricsAndMissesPersistInCache() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))

        try await database.cacheLyrics(
            key: "lyrics-hit",
            result: .lyrics(LyricsPayload(
                plain: "A cached verse",
                synced: "[00:02.00]A cached verse"
            ))
        )
        try await database.cacheLyrics(key: "instrumental", result: .instrumental)
        try await database.cacheLyrics(key: "missing", result: .notFound)

        let hit = try await database.fetchCachedLyrics(key: "lyrics-hit")
        XCTAssertEqual(hit?.lyrics, "A cached verse")
        XCTAssertEqual(hit?.syncedLyrics, "[00:02.00]A cached verse")
        XCTAssertEqual(hit?.isInstrumental, false)
        let instrumental = try await database.fetchCachedLyrics(key: "instrumental")
        XCTAssertNil(instrumental?.lyrics)
        XCTAssertEqual(instrumental?.isInstrumental, true)
        let missing = try await database.fetchCachedLyrics(key: "missing")
        XCTAssertNil(missing?.lyrics)
        XCTAssertEqual(missing?.isInstrumental, false)
        let neverRequested = try await database.fetchCachedLyrics(key: "never-requested")
        XCTAssertNil(neverRequested)
    }

    func testUpsertAndSearchByArtist() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        let metadata = TrackMetadata(
            url: URL(fileURLWithPath: "/tmp/uziq-test/track.mp3"),
            fileName: "track",
            title: "Test Track",
            artist: "Test Artist",
            albumArtist: "Test Artist",
            album: "Test Album",
            genre: "Electronic",
            year: "2026",
            trackNumber: 1,
            discNumber: 1,
            duration: 180,
            codec: "MP3",
            bitrate: 320_000,
            sampleRate: 44_100,
            artworkData: nil,
            lyrics: "Test lyrics",
            musicBrainzRecordingID: nil,
            musicBrainzReleaseID: nil,
            acoustID: nil,
            modifiedAt: .now,
            fileSize: 1234
        )

        try await database.upsert(metadata)
        let results = try await database.fetchTracks(search: "Test Artist")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.displayTitle, "Test Track")
        XCTAssertEqual(results.first?.displayArtist, "Test Artist")

        let trackID = try XCTUnwrap(results.first?.id)
        try await database.recordPlay(trackID: trackID)
        try await database.recordPlay(trackID: trackID)
        let mostPlayed = try await database.fetchTracks(mostPlayedSince: Date(timeIntervalSinceNow: -60))
        XCTAssertEqual(mostPlayed.first?.id, trackID)
        XCTAssertEqual(mostPlayed.first?.playCount, 2)

        let searchedMostPlayed = try await database.fetchTracks(
            search: "Test Artist",
            mostPlayedSince: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertEqual(searchedMostPlayed.map(\.id), [trackID])

        let recentArtists = try await database.fetchRecentlyPlayedArtists(
            since: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertEqual(recentArtists.map(\.name), ["Test Artist"])
        XCTAssertEqual(recentArtists.first?.playCount, 2)
    }

    func testBatchUpsertAndForeignKeyCascade() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        let first = makeMetadata(path: "/tmp/uziq-batch/missing-one.mp3", title: "One")
        let second = makeMetadata(path: "/tmp/uziq-batch/missing-two.mp3", title: "Two")

        try await database.upsertBatch([first, second])
        let tracks = try await database.fetchTracks()
        XCTAssertEqual(Set(tracks.map(\.displayTitle)), ["One", "Two"])

        let playlist = try await database.createPlaylist(name: "Cascade")
        let firstTrack = try XCTUnwrap(tracks.first)
        try await database.addTrack(trackID: firstTrack.id, toPlaylist: playlist.id)
        try await database.removeMissingFiles()
        let remainingPlaylistTracks = try await database.fetchPlaylistTracks(playlistID: playlist.id)

        XCTAssertTrue(remainingPlaylistTracks.isEmpty)
    }

    func testExternalTrackPlayIsIgnoredByLocalHistory() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        let metadata = makeMetadata(path: "/tmp/uziq-local-counterpart.mp3", title: "Shared Song")
        try await database.upsert(metadata)

        let recorded = try await database.recordPlay(trackID: "bandcamp-123-shared-song")
        let mostPlayed = try await database.fetchTracks(
            mostPlayedSince: Date(timeIntervalSinceNow: -60)
        )

        XCTAssertFalse(recorded)
        XCTAssertTrue(mostPlayed.isEmpty)
    }

    func testUnifiedListeningHistoryGroupsProvidersAndRoundTripsReplayItems() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        try await database.upsert(makeMetadata(
            path: "/tmp/uziq-history-local.mp3",
            title: "Local Favorite"
        ))
        let localTracks = try await database.fetchTracks()
        let localTrack = try XCTUnwrap(localTracks.first)
        let localQueueItem = UnifiedQueueItem(local: localTrack)
        let spotifyTrack = SpotifyCatalogItem(
            id: "spotify-history-track",
            name: "Remote Favorite",
            subtitle: "Remote Artist",
            uri: "spotify:track:spotify-history-track",
            kind: .track,
            artworkURL: URL(string: "https://example.com/history.jpg"),
            durationMS: 180_000,
            itemCount: nil
        )
        let now = Date()

        for playedAt in [now.addingTimeInterval(-60), now.addingTimeInterval(-30)] {
            try await database.recordListeningHistory(ListeningHistoryEvent(
                source: .local,
                sourceID: localTrack.id,
                title: localTrack.displayTitle,
                artist: localTrack.displayArtist,
                album: localTrack.displayAlbum,
                artworkURL: nil,
                queueItem: localQueueItem,
                playedAt: playedAt
            ))
        }
        try await database.recordListeningHistory(ListeningHistoryEvent(
            source: .spotify,
            sourceID: spotifyTrack.id,
            title: spotifyTrack.name,
            artist: spotifyTrack.subtitle,
            album: "Remote Album",
            artworkURL: spotifyTrack.artworkURL,
            queueItem: UnifiedQueueItem(spotify: spotifyTrack),
            playedAt: now
        ))

        let recent = try await database.fetchRecentListeningHistory()
        let mostPlayed = try await database.fetchMostPlayedListeningHistory(
            since: now.addingTimeInterval(-120)
        )

        XCTAssertEqual(recent.map(\.source), [.spotify, .local])
        XCTAssertEqual(recent.first?.queueItem.spotifyItem?.uri, spotifyTrack.uri)
        XCTAssertEqual(mostPlayed.first?.source, .local)
        XCTAssertEqual(mostPlayed.first?.playCount, 2)
        XCTAssertEqual(mostPlayed.first?.queueItem.localURL, localTrack.url)
    }

    func testFLACVorbisCommentsAreRead() async throws {
        let comments = [
            "TITLE=Tagged Track",
            "ARTIST=Tagged Artist",
            "ALBUM=Tagged Album",
            "album_artist=Tagged Artist",
            "GENRE=Ambient",
            "track=2/8"
        ]
        var block = Data()
        let vendor = Data("test-vendor".utf8)
        block.append(littleEndian(UInt32(vendor.count)))
        block.append(vendor)
        block.append(littleEndian(UInt32(comments.count)))
        for comment in comments {
            let bytes = Data(comment.utf8)
            block.append(littleEndian(UInt32(bytes.count)))
            block.append(bytes)
        }

        let artwork = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let mime = Data("image/jpeg".utf8)
        var picture = Data()
        picture.append(bigEndian(3)) // Front cover
        picture.append(bigEndian(UInt32(mime.count)))
        picture.append(mime)
        picture.append(bigEndian(0)) // Empty description
        picture.append(bigEndian(1)) // Width
        picture.append(bigEndian(1)) // Height
        picture.append(bigEndian(24)) // Color depth
        picture.append(bigEndian(0)) // Indexed colors
        picture.append(bigEndian(UInt32(artwork.count)))
        picture.append(artwork)

        // Real FLAC files commonly place STREAMINFO and SEEKTABLE blocks before
        // Vorbis comments, then store cover art in a native PICTURE block.
        var flac = Data("fLaC".utf8)
        appendFLACBlock(type: 0, data: Data(repeating: 0, count: 34), to: &flac)
        appendFLACBlock(type: 3, data: Data(repeating: 0, count: 18), to: &flac)
        appendFLACBlock(type: 4, data: block, to: &flac)
        appendFLACBlock(type: 6, data: picture, isLast: true, to: &flac)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uziq-tags.flac")
        try flac.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try await MetadataReader.read(url)
        XCTAssertEqual(metadata.title, "Tagged Track")
        XCTAssertEqual(metadata.artist, "Tagged Artist")
        XCTAssertEqual(metadata.album, "Tagged Album")
        XCTAssertEqual(metadata.genre, "Ambient")
        XCTAssertEqual(metadata.trackNumber, 2)
        XCTAssertEqual(metadata.artworkData, artwork)
        XCTAssertEqual(metadata.codec, "FLAC")
    }

    func testFavoritesAndPlaylists() async throws {
        let database = LibraryDatabase(databaseURL: URL(fileURLWithPath: ":memory:"))
        let metadata = TrackMetadata(
            url: URL(fileURLWithPath: "/tmp/uziq-test/favorite.mp3"),
            fileName: "favorite",
            title: "Favorite Track",
            artist: "Favorite Artist",
            albumArtist: "Favorite Artist",
            album: "Favorite Album",
            genre: "Pop",
            year: "2026",
            trackNumber: 1,
            discNumber: nil,
            duration: 120,
            codec: "MP3",
            bitrate: 320_000,
            sampleRate: 44_100,
            artworkData: nil,
            lyrics: "Lyrics",
            musicBrainzRecordingID: nil,
            musicBrainzReleaseID: nil,
            acoustID: nil,
            modifiedAt: .now,
            fileSize: 100
        )
        try await database.upsert(metadata)
        let fetchedTracks = try await database.fetchTracks()
        let track = try XCTUnwrap(fetchedTracks.first)

        try await database.toggleFavorite(trackID: track.id)
        let favorites = try await database.fetchTracks(favoritesOnly: true)
        XCTAssertEqual(favorites.map(\.id), [track.id])

        let playlist = try await database.createPlaylist(name: "Favorites Test")
        try await database.addTrack(trackID: track.id, toPlaylist: playlist.id)
        let playlistTracks = try await database.fetchPlaylistTracks(playlistID: playlist.id)
        XCTAssertEqual(playlistTracks.map(\.id), [track.id])
    }

    func testSplitReleaseAlbumsShareArtworkGroup() {
        let artwork = Data([0x01, 0x02, 0x03])
        let tracks = [
            makeTrack(id: "microcastle", album: "Microcastle", artwork: artwork),
            makeTrack(id: "weird-era", album: "Microcastle / Weird Era Continued", artwork: nil)
        ]

        let albums = AlbumGroup.grouped(tracks)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.title, "Microcastle / Weird Era Continued")
        XCTAssertEqual(albums.first?.artworkData, artwork)
    }

    func testLocalBrowseSnapshotBuildsAlbumsArtistsAndGenresTogether() {
        let tracks = [
            makeTrack(id: "microcastle", album: "Microcastle", artwork: nil),
            makeTrack(id: "weird-era", album: "Microcastle / Weird Era Continued", artwork: nil)
        ]

        let snapshot = LocalLibraryBrowseSnapshot.grouped(tracks)

        XCTAssertEqual(snapshot.albums.count, 1)
        XCTAssertEqual(snapshot.artistCount, 1)
        XCTAssertEqual(snapshot.artistSections.map(\.letter), ["D"])
        XCTAssertEqual(snapshot.genres.map(\.name), ["Indie"])
    }

    private func makeTrack(id: String, album: String, artwork: Data?) -> Track {
        Track(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id).flac"),
            fileName: id,
            title: id,
            artist: "Deerhunter",
            albumArtist: "Deerhunter",
            album: album,
            genre: "Indie",
            year: "2008",
            trackNumber: 1,
            discNumber: 1,
            duration: 180,
            codec: "FLAC",
            bitrate: nil,
            sampleRate: 44_100,
            artworkData: artwork,
            lyrics: nil,
            musicBrainzRecordingID: nil,
            musicBrainzReleaseID: nil,
            acoustID: nil,
            addedAt: .now,
            modifiedAt: .now,
            isFavorite: false,
            playCount: 0
        )
    }

    private func makeMetadata(path: String, title: String) -> TrackMetadata {
        TrackMetadata(
            url: URL(fileURLWithPath: path), fileName: URL(fileURLWithPath: path).lastPathComponent,
            title: title, artist: "Batch Artist", albumArtist: "Batch Artist", album: "Batch Album",
            genre: "", year: "", trackNumber: nil, discNumber: nil, duration: 60,
            codec: "MP3", bitrate: nil, sampleRate: nil, artworkData: nil, lyrics: nil,
            musicBrainzRecordingID: nil, musicBrainzReleaseID: nil, acoustID: nil,
            modifiedAt: .now, fileSize: 1
        )
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
            throw UziqError.database("Could not create legacy test database")
        }
        defer { sqlite3_close(connection) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorPointer)
            throw UziqError.database(message)
        }
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func appendFLACBlock(type: UInt8, data: Data, isLast: Bool = false, to flac: inout Data) {
        flac.append(type | (isLast ? 0x80 : 0))
        flac.append(UInt8((data.count >> 16) & 0xFF))
        flac.append(UInt8((data.count >> 8) & 0xFF))
        flac.append(UInt8(data.count & 0xFF))
        flac.append(data)
    }
}
