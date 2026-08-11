import Foundation
import SQLite3

struct LibraryDatabaseHealth: Sendable, Equatable {
    let schemaVersion: Int
    let foreignKeysEnabled: Bool
    let journalMode: String
}

actor LibraryDatabase {
    private var connection: OpaquePointer?
    private let databaseURL: URL
    private let initializationError: String?

    nonisolated static let currentSchemaVersion = 10

    private nonisolated static let effectiveTrackColumns = """
        t.id, t.path, t.file_name,
        COALESCE(o.title, t.title), COALESCE(o.artist, t.artist),
        COALESCE(o.album_artist, t.album_artist), COALESCE(o.album, t.album),
        COALESCE(o.genre, t.genre), COALESCE(o.year, t.year),
        CASE WHEN o.track_number_overridden = 1 THEN o.track_number ELSE t.track_number END,
        CASE WHEN o.disc_number_overridden = 1 THEN o.disc_number ELSE t.disc_number END,
        t.duration, t.codec, t.bitrate, t.sample_rate,
        t.replay_gain_track, t.replay_gain_album,
        CASE WHEN o.artwork_overridden = 1 THEN o.artwork ELSE t.artwork END,
        t.lyrics, t.mb_recording_id, t.mb_release_id, t.acoustid,
        t.added_at, t.modified_at, t.file_size, t.is_favorite
        """

    init(databaseURL: URL? = nil) {
        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Uziq", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            } catch {
                self.databaseURL = applicationSupport.appendingPathComponent("library.sqlite")
                self.initializationError = "Could not create the library directory: \(error.localizedDescription)"
                return
            }
            url = applicationSupport.appendingPathComponent("library.sqlite")
        }
        self.databaseURL = url
        var openedConnection: OpaquePointer?
        let sqlitePath = url.lastPathComponent == ":memory:" ? ":memory:" : url.path
        let openResult = sqlite3_open_v2(
            sqlitePath,
            &openedConnection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let openedConnection else {
            let message = openedConnection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned status \(openResult)"
            sqlite3_close(openedConnection)
            connection = nil
            initializationError = "Could not open the library database: \(message)"
            return
        }
        sqlite3_extended_result_codes(openedConnection, 1)
        sqlite3_busy_timeout(openedConnection, 2_000)
        connection = openedConnection
        do {
            try Self.configureAndMigrate(
                openedConnection,
                usesPersistentStorage: sqlitePath != ":memory:"
            )
            initializationError = nil
        } catch {
            initializationError = error.localizedDescription
        }
    }

    deinit { sqlite3_close(connection) }

    func upsert(_ metadata: TrackMetadata) throws {
        try upsertBatch([metadata])
    }

    func upsertBatch(_ metadataItems: [TrackMetadata]) throws {
        guard !metadataItems.isEmpty else { return }
        try withTransaction {
            for metadata in metadataItems {
                try upsertWithoutTransaction(metadata)
            }
        }
    }

    func indexedFiles(under root: URL) throws -> [String: IndexedAudioFile] {
        let statement = try prepare("SELECT path, modified_at, file_size FROM tracks")
        defer { sqlite3_finalize(statement) }
        var result: [String: IndexedAudioFile] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathValue = sqlite3_column_text(statement, 0) else { continue }
            let path = String(cString: pathValue)
            guard LibraryPath.contains(URL(fileURLWithPath: path), in: root) else { continue }
            result[path] = IndexedAudioFile(
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                fileSize: sqlite3_column_int64(statement, 2)
            )
        }
        return result
    }

    func applyReconciliation(_ reconciliation: LibraryReconciliation) throws {
        guard reconciliation.hasChanges else { return }
        try withTransaction {
            for metadata in reconciliation.changedMetadata {
                try upsertWithoutTransaction(metadata)
            }
            for path in reconciliation.removedPaths {
                guard let id = try optionalScalarString(
                    "SELECT id FROM tracks WHERE path = ?",
                    bindings: [path]
                ) else { continue }
                try execute("DELETE FROM tracks_fts WHERE track_id = ?", bindings: [id])
                try execute("DELETE FROM tracks WHERE id = ?", bindings: [id])
            }
        }
    }

    private func upsertWithoutTransaction(_ metadata: TrackMetadata) throws {
        let sql = """
        INSERT INTO tracks (
            id, path, file_name, title, artist, album_artist, album, genre, year,
            track_number, disc_number, duration, codec, bitrate, sample_rate,
            replay_gain_track, replay_gain_album,
            artwork, lyrics, mb_recording_id, mb_release_id, acoustid,
            added_at, modified_at, file_size
        ) VALUES (lower(hex(randomblob(16))), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            file_name=excluded.file_name, title=excluded.title, artist=excluded.artist,
            album_artist=excluded.album_artist, album=excluded.album, genre=excluded.genre,
            year=excluded.year, track_number=excluded.track_number, disc_number=excluded.disc_number,
            duration=excluded.duration, codec=excluded.codec, bitrate=excluded.bitrate,
            sample_rate=excluded.sample_rate, replay_gain_track=excluded.replay_gain_track,
            replay_gain_album=excluded.replay_gain_album,
            artwork=COALESCE(excluded.artwork, tracks.artwork),
            lyrics=excluded.lyrics, mb_recording_id=excluded.mb_recording_id,
            mb_release_id=excluded.mb_release_id, acoustid=excluded.acoustid,
            modified_at=excluded.modified_at, file_size=excluded.file_size
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(metadata.url.path, to: statement, index: 1)
        bind(metadata.fileName, to: statement, index: 2)
        bind(metadata.title, to: statement, index: 3)
        bind(metadata.artist, to: statement, index: 4)
        bind(metadata.albumArtist, to: statement, index: 5)
        bind(metadata.album, to: statement, index: 6)
        bind(metadata.genre, to: statement, index: 7)
        bind(metadata.year, to: statement, index: 8)
        bind(metadata.trackNumber, to: statement, index: 9)
        bind(metadata.discNumber, to: statement, index: 10)
        bind(metadata.duration, to: statement, index: 11)
        bind(metadata.codec, to: statement, index: 12)
        bind(metadata.bitrate, to: statement, index: 13)
        bind(metadata.sampleRate, to: statement, index: 14)
        bind(metadata.replayGainTrackDB, to: statement, index: 15)
        bind(metadata.replayGainAlbumDB, to: statement, index: 16)
        bind(metadata.artworkData, to: statement, index: 17)
        bind(metadata.lyrics, to: statement, index: 18)
        bind(metadata.musicBrainzRecordingID, to: statement, index: 19)
        bind(metadata.musicBrainzReleaseID, to: statement, index: 20)
        bind(metadata.acoustID, to: statement, index: 21)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 22)
        bind(metadata.modifiedAt.timeIntervalSince1970, to: statement, index: 23)
        bind(metadata.fileSize, to: statement, index: 24)
        try step(statement)

        let id = try scalarString("SELECT id FROM tracks WHERE path = ?", bindings: [metadata.url.path])
        try rebuildSearchIndex(for: id)
    }

    func fetchTracks(
        search: String? = nil,
        recentlyAdded: Bool = false,
        favoritesOnly: Bool = false,
        mostPlayedSince: Date? = nil
    ) throws -> [Track] {
        var sql = mostPlayedSince == nil
            ? "SELECT \(Self.effectiveTrackColumns) FROM tracks t LEFT JOIN track_metadata_overrides o ON o.track_id = t.id"
            : "SELECT \(Self.effectiveTrackColumns), COUNT(ph.id) AS play_count FROM tracks t LEFT JOIN track_metadata_overrides o ON o.track_id = t.id JOIN play_history ph ON ph.track_id = t.id"
        var bindings: [String] = []
        var conditions: [String] = []
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append("t.id IN (SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH ?)")
            let terms = search
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "_" } }
                .filter { !$0.isEmpty }
            bindings.append(terms.map { "\($0)*" }.joined(separator: " AND "))
        }
        if favoritesOnly { conditions.append("t.is_favorite = 1") }
        if let mostPlayedSince {
            conditions.append("ph.played_at >= ?")
            bindings.append(String(mostPlayedSince.timeIntervalSince1970))
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if mostPlayedSince != nil {
            sql += " GROUP BY t.id ORDER BY COUNT(ph.id) DESC, COALESCE(o.title, t.title) COLLATE NOCASE"
        } else if recentlyAdded {
            sql += " ORDER BY t.added_at DESC"
        } else {
            sql += " ORDER BY COALESCE(o.album, t.album) COLLATE NOCASE, "
                + "CASE WHEN o.track_number_overridden = 1 THEN o.track_number ELSE t.track_number END, "
                + "COALESCE(o.title, t.title) COLLATE NOCASE"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, to: statement, index: Int32(index + 1)) }
        var tracks: [Track] = []
        var artworkPool: [Data: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            tracks.append(readTrack(
                statement,
                playCountIndex: mostPlayedSince == nil ? nil : 26,
                artworkPool: &artworkPool
            ))
        }
        return tracks
    }

    @discardableResult
    func recordPlay(trackID: String) throws -> Bool {
        let statement = try prepare("""
            INSERT INTO play_history(track_id, played_at)
            SELECT id, ? FROM tracks WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(Date.now.timeIntervalSince1970, to: statement, index: 1)
        bind(trackID, to: statement, index: 2)
        try step(statement)
        return sqlite3_changes(connection) > 0
    }

    func fetchRecentlyPlayedArtists(since: Date, limit: Int = 16) throws -> [RecentArtistPlay] {
        let statement = try prepare("""
            SELECT COALESCE(o.artist, t.artist) AS effective_artist, COUNT(ph.id), MAX(ph.played_at)
            FROM play_history ph
            JOIN tracks t ON t.id = ph.track_id
            LEFT JOIN track_metadata_overrides o ON o.track_id = t.id
            WHERE ph.played_at >= ? AND TRIM(COALESCE(o.artist, t.artist)) <> ''
            GROUP BY effective_artist COLLATE NOCASE
            ORDER BY MAX(ph.played_at) DESC, COUNT(ph.id) DESC, effective_artist COLLATE NOCASE
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(since.timeIntervalSince1970, to: statement, index: 1)
        bind(max(1, limit), to: statement, index: 2)
        var artists: [RecentArtistPlay] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameValue = sqlite3_column_text(statement, 0) else { continue }
            artists.append(RecentArtistPlay(
                name: String(cString: nameValue),
                playCount: Int(sqlite3_column_int64(statement, 1)),
                lastPlayedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return artists
    }

    func recordListeningHistory(_ event: ListeningHistoryEvent) throws {
        let queueData: Data
        do {
            queueData = try JSONEncoder().encode(event.queueItem)
        } catch {
            throw UziqError.database("Could not encode listening history: \(error.localizedDescription)")
        }
        let statement = try prepare("""
            INSERT INTO listening_history(
                item_key, source, source_id, title, artist, album,
                artwork_url, queue_item, played_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(event.itemKey, to: statement, index: 1)
        bind(event.source.rawValue, to: statement, index: 2)
        bind(event.sourceID, to: statement, index: 3)
        bind(event.title, to: statement, index: 4)
        bind(event.artist, to: statement, index: 5)
        bind(event.album, to: statement, index: 6)
        bind(event.artworkURL?.absoluteString, to: statement, index: 7)
        bind(queueData, to: statement, index: 8)
        bind(event.playedAt.timeIntervalSince1970, to: statement, index: 9)
        try step(statement)
    }

    func fetchRecentListeningHistory(limit: Int = 24) throws -> [ListeningHistoryItem] {
        let statement = try prepare("""
            SELECT h.item_key, h.source, h.source_id, h.title, h.artist, h.album,
                   h.artwork_url, h.queue_item, h.played_at,
                   (SELECT COUNT(*) FROM listening_history counts WHERE counts.item_key = h.item_key),
                   t.path
            FROM listening_history h
            LEFT JOIN tracks t ON h.source = 'local' AND t.id = h.source_id
            WHERE h.id = (
                SELECT latest.id FROM listening_history latest
                WHERE latest.item_key = h.item_key
                ORDER BY latest.played_at DESC, latest.id DESC
                LIMIT 1
            )
            ORDER BY h.played_at DESC, h.id DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(max(1, limit), to: statement, index: 1)
        return readListeningHistory(statement)
    }

    func fetchMostPlayedListeningHistory(
        since: Date,
        limit: Int = 100
    ) throws -> [ListeningHistoryItem] {
        let statement = try prepare("""
            SELECT h.item_key, h.source, h.source_id, h.title, h.artist, h.album,
                   h.artwork_url, h.queue_item, totals.last_played, totals.play_count,
                   t.path
            FROM (
                SELECT item_key, COUNT(*) AS play_count, MAX(played_at) AS last_played
                FROM listening_history
                WHERE played_at >= ?
                GROUP BY item_key
            ) totals
            JOIN listening_history h ON h.id = (
                SELECT latest.id FROM listening_history latest
                WHERE latest.item_key = totals.item_key
                ORDER BY latest.played_at DESC, latest.id DESC
                LIMIT 1
            )
            LEFT JOIN tracks t ON h.source = 'local' AND t.id = h.source_id
            ORDER BY totals.play_count DESC, totals.last_played DESC, h.title COLLATE NOCASE
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(since.timeIntervalSince1970, to: statement, index: 1)
        bind(max(1, limit), to: statement, index: 2)
        return readListeningHistory(statement)
    }

    func fetchRediscoveryListeningHistory(
        notPlayedSince cutoff: Date,
        limit: Int = 100
    ) throws -> [ListeningHistoryItem] {
        let statement = try prepare("""
            SELECT h.item_key, h.source, h.source_id, h.title, h.artist, h.album,
                   h.artwork_url, h.queue_item, totals.last_played, totals.play_count,
                   t.path
            FROM (
                SELECT item_key, COUNT(*) AS play_count, MAX(played_at) AS last_played
                FROM listening_history
                GROUP BY item_key
                HAVING MAX(played_at) < ?
            ) totals
            JOIN listening_history h ON h.id = (
                SELECT latest.id FROM listening_history latest
                WHERE latest.item_key = totals.item_key
                ORDER BY latest.played_at DESC, latest.id DESC
                LIMIT 1
            )
            LEFT JOIN tracks t ON h.source = 'local' AND t.id = h.source_id
            ORDER BY totals.play_count DESC, totals.last_played ASC, h.title COLLATE NOCASE
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(cutoff.timeIntervalSince1970, to: statement, index: 1)
        bind(max(1, limit), to: statement, index: 2)
        return readListeningHistory(statement)
    }

    func fetchArtistArtwork() throws -> [String: Data] {
        let statement = try prepare("SELECT artist, artwork FROM artist_artwork")
        defer { sqlite3_finalize(statement) }
        var artwork: [String: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let artistPointer = sqlite3_column_text(statement, 0),
                  let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let artist = String(cString: artistPointer)
            artwork[artist] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        }
        return artwork
    }

    func updateArtistArtwork(artist: String, artworkData: Data) throws {
        let statement = try prepare("""
            INSERT INTO artist_artwork(artist, artwork, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(artist) DO UPDATE SET artwork = excluded.artwork, updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(artist, to: statement, index: 1)
        bind(artworkData, to: statement, index: 2)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 3)
        try step(statement)
    }

    func removeArtistArtwork(artist: String) throws {
        try withTransaction {
            try execute("DELETE FROM artist_artwork WHERE artist = ?", bindings: [artist])
            try execute("DELETE FROM artist_artwork_attempts WHERE artist = ?", bindings: [artist])
        }
    }

    func fetchArtistProfiles() throws -> [String: ArtistProfile] {
        let statement = try prepare("SELECT artist, summary, source FROM artist_profiles")
        defer { sqlite3_finalize(statement) }
        var profiles: [String: ArtistProfile] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let artistValue = sqlite3_column_text(statement, 0),
                  let summaryValue = sqlite3_column_text(statement, 1),
                  let sourceValue = sqlite3_column_text(statement, 2),
                  let source = ArtistProfileSource(rawValue: String(cString: sourceValue)) else { continue }
            profiles[String(cString: artistValue)] = ArtistProfile(
                summary: String(cString: summaryValue),
                source: source
            )
        }
        return profiles
    }

    func updateArtistProfile(artist: String, profile: ArtistProfile) throws {
        let statement = try prepare("""
            INSERT INTO artist_profiles(artist, summary, source, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(artist) DO UPDATE SET
                summary = excluded.summary,
                source = excluded.source,
                updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(artist, to: statement, index: 1)
        bind(profile.summary, to: statement, index: 2)
        bind(profile.source.rawValue, to: statement, index: 3)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 4)
        try step(statement)
    }

    func recentlyAttemptedArtistProfiles(since date: Date) throws -> Set<String> {
        let statement = try prepare("SELECT artist FROM artist_profile_attempts WHERE attempted_at >= ?")
        defer { sqlite3_finalize(statement) }
        bind(date.timeIntervalSince1970, to: statement, index: 1)
        var artists = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            artists.insert(String(cString: value))
        }
        return artists
    }

    func recordArtistProfileAttempt(artist: String) throws {
        let statement = try prepare("""
            INSERT INTO artist_profile_attempts(artist, attempted_at)
            VALUES (?, ?)
            ON CONFLICT(artist) DO UPDATE SET attempted_at = excluded.attempted_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(artist, to: statement, index: 1)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 2)
        try step(statement)
    }

    func recentlyAttemptedArtistArtwork(since date: Date) throws -> Set<String> {
        let statement = try prepare("SELECT artist FROM artist_artwork_attempts WHERE attempted_at >= ?")
        defer { sqlite3_finalize(statement) }
        bind(date.timeIntervalSince1970, to: statement, index: 1)
        var artists = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            artists.insert(String(cString: value))
        }
        return artists
    }

    func recordArtistArtworkAttempt(artist: String) throws {
        let statement = try prepare("""
            INSERT INTO artist_artwork_attempts(artist, attempted_at)
            VALUES (?, ?)
            ON CONFLICT(artist) DO UPDATE SET attempted_at = excluded.attempted_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(artist, to: statement, index: 1)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 2)
        try step(statement)
    }

    func recentlyAttemptedAlbumArtwork(since date: Date) throws -> Set<String> {
        let statement = try prepare("SELECT album_key FROM album_artwork_attempts WHERE attempted_at >= ?")
        defer { sqlite3_finalize(statement) }
        bind(date.timeIntervalSince1970, to: statement, index: 1)
        var albumKeys = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            albumKeys.insert(String(cString: value))
        }
        return albumKeys
    }

    func recordAlbumArtworkAttempt(key: String) throws {
        let statement = try prepare("""
            INSERT INTO album_artwork_attempts(album_key, attempted_at)
            VALUES (?, ?)
            ON CONFLICT(album_key) DO UPDATE SET attempted_at = excluded.attempted_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, index: 1)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 2)
        try step(statement)
    }

    func applyMetadataOverrides(trackIDs: [String], changes: MetadataOverrideChanges) throws {
        guard !trackIDs.isEmpty, !changes.isEmpty else { return }
        try withTransaction {
            for trackID in trackIDs {
                try execute(
                    "INSERT OR IGNORE INTO track_metadata_overrides(track_id, updated_at) VALUES (?, ?)",
                    bindings: [trackID, String(Date.now.timeIntervalSince1970)]
                )
                let statement = try prepare("""
                    UPDATE track_metadata_overrides SET
                        title = CASE WHEN ? = 1 THEN ? ELSE title END,
                        artist = CASE WHEN ? = 1 THEN ? ELSE artist END,
                        album_artist = CASE WHEN ? = 1 THEN ? ELSE album_artist END,
                        album = CASE WHEN ? = 1 THEN ? ELSE album END,
                        genre = CASE WHEN ? = 1 THEN ? ELSE genre END,
                        year = CASE WHEN ? = 1 THEN ? ELSE year END,
                        track_number = CASE WHEN ? = 1 THEN ? ELSE track_number END,
                        track_number_overridden = CASE WHEN ? = 1 THEN 1 ELSE track_number_overridden END,
                        disc_number = CASE WHEN ? = 1 THEN ? ELSE disc_number END,
                        disc_number_overridden = CASE WHEN ? = 1 THEN 1 ELSE disc_number_overridden END,
                        artwork = CASE WHEN ? = 1 THEN ? ELSE artwork END,
                        artwork_overridden = CASE WHEN ? = 1 THEN 1 ELSE artwork_overridden END,
                        updated_at = ?
                    WHERE track_id = ?
                    """)
                var index: Int32 = 1
                bindOverride(changes.title, to: statement, index: &index)
                bindOverride(changes.artist, to: statement, index: &index)
                bindOverride(changes.albumArtist, to: statement, index: &index)
                bindOverride(changes.album, to: statement, index: &index)
                bindOverride(changes.genre, to: statement, index: &index)
                bindOverride(changes.year, to: statement, index: &index)
                bind(changes.overridesTrackNumber ? Int64(1) : Int64(0), to: statement, index: index); index += 1
                bind(changes.trackNumber, to: statement, index: index); index += 1
                bind(changes.overridesTrackNumber ? Int64(1) : Int64(0), to: statement, index: index); index += 1
                bind(changes.overridesDiscNumber ? Int64(1) : Int64(0), to: statement, index: index); index += 1
                bind(changes.discNumber, to: statement, index: index); index += 1
                bind(changes.overridesDiscNumber ? Int64(1) : Int64(0), to: statement, index: index); index += 1
                bind(changes.overridesArtwork ? Int64(1) : Int64(0), to: statement, index: index); index += 1
                bind(changes.artworkData, to: statement, index: index); index += 1
                bind(changes.overridesArtwork ? Int64(1) : Int64(0), to: statement, index: index); index += 1
                bind(Date.now.timeIntervalSince1970, to: statement, index: index); index += 1
                bind(trackID, to: statement, index: index)
                let updateResult = sqlite3_step(statement)
                guard updateResult == SQLITE_DONE else {
                    let message = errorMessage
                    sqlite3_finalize(statement)
                    throw UziqError.database(message)
                }
                sqlite3_finalize(statement)
                try rebuildSearchIndex(for: trackID)
            }
        }
    }

    func clearMetadataOverrides(trackIDs: [String]) throws {
        guard !trackIDs.isEmpty else { return }
        try withTransaction {
            for trackID in trackIDs {
                try execute("DELETE FROM track_metadata_overrides WHERE track_id = ?", bindings: [trackID])
                try rebuildSearchIndex(for: trackID)
            }
        }
    }

    func fetchCachedLyrics(key: String) throws -> CachedLyrics? {
        let statement = try prepare("SELECT lyrics, synced_lyrics, is_instrumental, fetched_at FROM lyrics_cache WHERE lookup_key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let lyrics = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        return CachedLyrics(
            lyrics: lyrics,
            syncedLyrics: sqlite3_column_text(statement, 1).map { String(cString: $0) },
            isInstrumental: sqlite3_column_int(statement, 2) != 0,
            fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    func cacheLyrics(key: String, result: LRCLIBLookup) throws {
        let statement = try prepare("""
            INSERT INTO lyrics_cache(lookup_key, lyrics, synced_lyrics, is_instrumental, fetched_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(lookup_key) DO UPDATE SET
                lyrics = excluded.lyrics,
                synced_lyrics = excluded.synced_lyrics,
                is_instrumental = excluded.is_instrumental,
                fetched_at = excluded.fetched_at
            """)
        defer { sqlite3_finalize(statement) }
        switch result {
        case .lyrics(let lyrics):
            bind(lyrics.plain, to: statement, index: 2)
            bind(lyrics.synced, to: statement, index: 3)
            bind(Int64(0), to: statement, index: 4)
        case .instrumental:
            bind(nil as String?, to: statement, index: 2)
            bind(nil as String?, to: statement, index: 3)
            bind(Int64(1), to: statement, index: 4)
        case .notFound:
            bind(nil as String?, to: statement, index: 2)
            bind(nil as String?, to: statement, index: 3)
            bind(Int64(0), to: statement, index: 4)
        }
        bind(key, to: statement, index: 1)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 5)
        try step(statement)
    }

    func toggleFavorite(trackID: String) throws {
        try execute("""
            UPDATE tracks SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END
            WHERE id = ?
            """, bindings: [trackID])
    }

    func fetchPlaylists() throws -> [PlaylistSummary] {
        let statement = try prepare("""
            SELECT p.id, p.name, p.created_at, COUNT(pt.track_id)
            FROM playlists p
            LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
            GROUP BY p.id
            ORDER BY p.created_at DESC
            """)
        defer { sqlite3_finalize(statement) }
        var playlists: [PlaylistSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            playlists.append(PlaylistSummary(
                id: String(cString: id),
                name: String(cString: name),
                trackCount: Int(sqlite3_column_int(statement, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return playlists
    }

    func createPlaylist(name: String) throws -> PlaylistSummary {
        let id = UUID().uuidString
        let statement = try prepare("INSERT INTO playlists(id, name, created_at) VALUES (?, ?, strftime('%s','now'))")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, index: 1)
        bind(name, to: statement, index: 2)
        try step(statement)
        return PlaylistSummary(id: id, name: name, trackCount: 0, createdAt: .now)
    }

    func deletePlaylist(id: String) throws {
        try execute("DELETE FROM playlist_tracks WHERE playlist_id = ?", bindings: [id])
        try execute("DELETE FROM playlists WHERE id = ?", bindings: [id])
    }

    func fetchPlaylistTracks(playlistID: String) throws -> [Track] {
        let statement = try prepare("""
            SELECT \(Self.effectiveTrackColumns) FROM tracks t
            LEFT JOIN track_metadata_overrides o ON o.track_id = t.id
            JOIN playlist_tracks pt ON pt.track_id = t.id
            WHERE pt.playlist_id = ?
            ORDER BY pt.position, t.title COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }
        bind(playlistID, to: statement, index: 1)
        var tracks: [Track] = []
        var artworkPool: [Data: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            tracks.append(readTrack(statement, artworkPool: &artworkPool))
        }
        return tracks
    }

    func addTrack(trackID: String, toPlaylist playlistID: String) throws {
        let statement = try prepare("""
            INSERT OR IGNORE INTO playlist_tracks(playlist_id, track_id, position)
            VALUES (?, ?, COALESCE((SELECT MAX(position) + 1 FROM playlist_tracks WHERE playlist_id = ?), 0))
            """)
        defer { sqlite3_finalize(statement) }
        bind(playlistID, to: statement, index: 1)
        bind(trackID, to: statement, index: 2)
        bind(playlistID, to: statement, index: 3)
        try step(statement)
    }

    func removeTrack(trackID: String, fromPlaylist playlistID: String) throws {
        let statement = try prepare("DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(playlistID, to: statement, index: 1)
        bind(trackID, to: statement, index: 2)
        try step(statement)
    }

    func fetchSmartPlaylists() throws -> [SmartPlaylistSummary] {
        let statement = try prepare("""
            SELECT id, name, configuration, created_at
            FROM smart_playlists
            ORDER BY created_at DESC
            """)
        defer { sqlite3_finalize(statement) }
        var playlists: [SmartPlaylistSummary] = []
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idValue = sqlite3_column_text(statement, 0),
                  let nameValue = sqlite3_column_text(statement, 1),
                  let configurationData = data(statement, column: 2),
                  let configuration = try? decoder.decode(SmartPlaylistConfiguration.self, from: configurationData),
                  configuration.isValid else { continue }
            playlists.append(SmartPlaylistSummary(
                id: String(cString: idValue),
                name: String(cString: nameValue),
                configuration: configuration,
                trackCount: try smartPlaylistTrackCount(configuration: configuration),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return playlists
    }

    func createSmartPlaylist(
        name: String,
        configuration: SmartPlaylistConfiguration
    ) throws -> SmartPlaylistSummary {
        guard configuration.isValid else {
            throw UziqError.database("The smart playlist contains an invalid rule")
        }
        let trackCount = try smartPlaylistTrackCount(configuration: configuration)
        let id = UUID().uuidString
        let encoded = try JSONEncoder().encode(configuration)
        let statement = try prepare("""
            INSERT INTO smart_playlists(id, name, configuration, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        let now = Date.now
        bind(id, to: statement, index: 1)
        bind(name, to: statement, index: 2)
        bind(encoded, to: statement, index: 3)
        bind(now.timeIntervalSince1970, to: statement, index: 4)
        bind(now.timeIntervalSince1970, to: statement, index: 5)
        try step(statement)
        return SmartPlaylistSummary(
            id: id,
            name: name,
            configuration: configuration,
            trackCount: trackCount,
            createdAt: now
        )
    }

    func updateSmartPlaylist(
        id: String,
        name: String,
        configuration: SmartPlaylistConfiguration
    ) throws -> SmartPlaylistSummary {
        guard configuration.isValid else {
            throw UziqError.database("The smart playlist contains an invalid rule")
        }
        let createdAt = try smartPlaylistCreatedAt(id: id)
        let trackCount = try smartPlaylistTrackCount(configuration: configuration)
        let statement = try prepare("""
            UPDATE smart_playlists
            SET name = ?, configuration = ?, updated_at = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, index: 1)
        bind(try JSONEncoder().encode(configuration), to: statement, index: 2)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 3)
        bind(id, to: statement, index: 4)
        try step(statement)
        return SmartPlaylistSummary(
            id: id,
            name: name,
            configuration: configuration,
            trackCount: trackCount,
            createdAt: createdAt
        )
    }

    func deleteSmartPlaylist(id: String) throws {
        try execute("DELETE FROM smart_playlists WHERE id = ?", bindings: [id])
    }

    func fetchSmartPlaylistTracks(configuration: SmartPlaylistConfiguration) throws -> [Track] {
        guard configuration.isValid else {
            throw UziqError.database("The smart playlist contains an invalid rule")
        }
        let query = try SmartPlaylistSQLQuery.build(configuration: configuration, includeOrder: true)
        let statement = try prepare("""
            SELECT \(Self.effectiveTrackColumns), COUNT(ph.id) AS play_count
            FROM tracks t
            LEFT JOIN track_metadata_overrides o ON o.track_id = t.id
            LEFT JOIN play_history ph ON ph.track_id = t.id
            GROUP BY t.id
            \(query.havingClause)
            \(query.orderClause)
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        let bindings = query.bindings + [String(configuration.limit ?? -1)]
        for (index, value) in bindings.enumerated() {
            bind(value, to: statement, index: Int32(index + 1))
        }
        var tracks: [Track] = []
        var artworkPool: [Data: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            tracks.append(readTrack(statement, playCountIndex: 26, artworkPool: &artworkPool))
        }
        return tracks
    }

    func removeMissingFiles() throws -> [String] {
        let statement = try prepare("SELECT id, path FROM tracks")
        defer { sqlite3_finalize(statement) }
        var missing: [(id: String, path: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 1) else { continue }
            let string = String(cString: path)
            if !FileManager.default.fileExists(atPath: string) {
                if let id = sqlite3_column_text(statement, 0) {
                    missing.append((String(cString: id), string))
                }
            }
        }
        try withTransaction {
            for item in missing {
                try execute("DELETE FROM tracks_fts WHERE track_id = ?", bindings: [item.id])
                try execute("DELETE FROM tracks WHERE id = ?", bindings: [item.id])
            }
        }
        return missing.map(\.path)
    }

    func updateMatch(trackID: String, result: MetadataMatchResult) throws {
        let statement = try prepare("""
            UPDATE tracks SET acoustid = ?, mb_recording_id = ?, mb_release_id = ?,
                title = CASE WHEN title = '' THEN COALESCE(?, title) ELSE title END,
                artist = CASE WHEN artist = '' THEN COALESCE(?, artist) ELSE artist END,
                album = CASE WHEN album = '' THEN COALESCE(?, album) ELSE album END,
                album_artist = CASE WHEN album_artist = '' THEN COALESCE(?, album_artist) ELSE album_artist END,
                year = CASE WHEN year = '' THEN COALESCE(?, year) ELSE year END,
                artwork = COALESCE(?, artwork) WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(result.match.acoustID, to: statement, index: 1)
        bind(result.match.recordingID, to: statement, index: 2)
        bind(result.recording?.releaseID, to: statement, index: 3)
        bind(result.recording?.title, to: statement, index: 4)
        bind(result.recording?.artist, to: statement, index: 5)
        bind(result.recording?.album, to: statement, index: 6)
        bind(result.recording?.albumArtist, to: statement, index: 7)
        bind(result.recording?.year, to: statement, index: 8)
        bind(result.artworkData, to: statement, index: 9)
        bind(trackID, to: statement, index: 10)
        try step(statement)
        try rebuildSearchIndex(for: trackID)
    }

    func updateArtwork(trackIDs: [String], artworkData: Data) throws {
        guard !trackIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ", ")
        let statement = try prepare("""
            UPDATE tracks SET artwork = COALESCE(artwork, ?)
            WHERE id IN (\(placeholders))
            """)
        defer { sqlite3_finalize(statement) }
        bind(artworkData, to: statement, index: 1)
        for (offset, trackID) in trackIDs.enumerated() {
            bind(trackID, to: statement, index: Int32(offset + 2))
        }
        try step(statement)
    }

    func health() throws -> LibraryDatabaseHealth {
        try ensureReady()
        return LibraryDatabaseHealth(
            schemaVersion: try Self.pragmaInt(connection, name: "user_version"),
            foreignKeysEnabled: try Self.pragmaInt(connection, name: "foreign_keys") == 1,
            journalMode: try Self.pragmaText(connection, name: "journal_mode")
        )
    }

    private nonisolated static func configureAndMigrate(
        _ connection: OpaquePointer,
        usesPersistentStorage: Bool
    ) throws {
        try executeRaw(connection, "PRAGMA foreign_keys = ON")
        guard try pragmaInt(connection, name: "foreign_keys") == 1 else {
            throw UziqError.database("SQLite foreign-key enforcement could not be enabled")
        }
        if usesPersistentStorage {
            try executeRaw(connection, "PRAGMA journal_mode = WAL")
            guard try pragmaText(connection, name: "journal_mode").lowercased() == "wal" else {
                throw UziqError.database("SQLite WAL mode could not be enabled")
            }
            try executeRaw(connection, "PRAGMA synchronous = NORMAL")
        }

        let existingVersion = try pragmaInt(connection, name: "user_version")
        guard existingVersion <= currentSchemaVersion else {
            throw UziqError.database(
                "Library schema version \(existingVersion) is newer than this version of Uziq supports"
            )
        }

        try executeRaw(connection, "BEGIN IMMEDIATE")
        do {
            if existingVersion < 1 { try migrateCoreSchema(connection) }
            if existingVersion < 2 { try migrateMetadataCacheSchema(connection) }
            if existingVersion < 3 { try migrateSearchSchema(connection) }
            if existingVersion < 4 { try removeOrphanedRows(connection) }
            if existingVersion < 5 { try migrateListeningHistorySchema(connection) }
            if existingVersion < 6 { try migrateLyricsCacheSchema(connection) }
            if existingVersion < 7 { try migrateSyncedLyricsCacheSchema(connection) }
            if existingVersion < 8 { try migrateMetadataOverridesSchema(connection) }
            if existingVersion < 9 { try migrateReplayGainSchema(connection) }
            if existingVersion < 10 { try migrateSmartPlaylistSchema(connection) }

            // Older development builds created tables without recording a schema
            // version. These checks make that migration safe and idempotent.
            if !tableContainsColumn(on: connection, table: "tracks", column: "is_favorite") {
                try executeRaw(
                    connection,
                    "ALTER TABLE tracks ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0"
                )
            }
            if !ftsContainsFileName(on: connection) {
                try rebuildSearchTable(connection)
            }
            try executeRaw(connection, "PRAGMA user_version = \(currentSchemaVersion)")
            try executeRaw(connection, "COMMIT")
        } catch {
            try? executeRaw(connection, "ROLLBACK")
            throw error
        }

        guard try hasRows(connection, sql: "PRAGMA foreign_key_check") == false else {
            throw UziqError.database("The library database contains invalid foreign-key references")
        }
    }

    private nonisolated static func migrateCoreSchema(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, file_name TEXT NOT NULL,
            title TEXT NOT NULL, artist TEXT NOT NULL, album_artist TEXT NOT NULL,
            album TEXT NOT NULL, genre TEXT NOT NULL, year TEXT NOT NULL,
            track_number INTEGER, disc_number INTEGER, duration REAL NOT NULL,
            codec TEXT NOT NULL, bitrate INTEGER, sample_rate REAL, artwork BLOB,
            lyrics TEXT, mb_recording_id TEXT, mb_release_id TEXT, acoustid TEXT,
            added_at REAL NOT NULL, modified_at REAL NOT NULL, file_size INTEGER NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playlist_tracks (
            playlist_id TEXT NOT NULL, track_id TEXT NOT NULL, position INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, track_id),
            FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
            FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS play_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id TEXT NOT NULL,
            played_at REAL NOT NULL,
            FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS tracks_artist_idx ON tracks(artist COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS tracks_album_idx ON tracks(album COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS play_history_track_date_idx ON play_history(track_id, played_at);
        """)
    }

    private nonisolated static func migrateMetadataCacheSchema(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        CREATE TABLE IF NOT EXISTS artist_artwork (
            artist TEXT PRIMARY KEY, artwork BLOB NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS artist_artwork_attempts (
            artist TEXT PRIMARY KEY, attempted_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS artist_profiles (
            artist TEXT PRIMARY KEY, summary TEXT NOT NULL,
            source TEXT NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS artist_profile_attempts (
            artist TEXT PRIMARY KEY, attempted_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS album_artwork_attempts (
            album_key TEXT PRIMARY KEY, attempted_at REAL NOT NULL
        );
        """)
    }

    private nonisolated static func migrateReplayGainSchema(_ connection: OpaquePointer) throws {
        if !tableContainsColumn(on: connection, table: "tracks", column: "replay_gain_track") {
            try executeRaw(connection, "ALTER TABLE tracks ADD COLUMN replay_gain_track REAL")
        }
        if !tableContainsColumn(on: connection, table: "tracks", column: "replay_gain_album") {
            try executeRaw(connection, "ALTER TABLE tracks ADD COLUMN replay_gain_album REAL")
        }
    }

    private nonisolated static func migrateSmartPlaylistSchema(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        CREATE TABLE IF NOT EXISTS smart_playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            configuration BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
    }

    private nonisolated static func migrateSearchSchema(_ connection: OpaquePointer) throws {
        if !tableContainsColumn(on: connection, table: "tracks", column: "is_favorite") {
            try executeRaw(
                connection,
                "ALTER TABLE tracks ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0"
            )
        }
        try rebuildSearchTable(connection)
    }

    private nonisolated static func rebuildSearchTable(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        DROP TABLE IF EXISTS tracks_fts;
        CREATE VIRTUAL TABLE tracks_fts USING fts5(
            track_id UNINDEXED, file_name, title, artist, album, album_artist, genre
        );
        INSERT INTO tracks_fts(track_id, file_name, title, artist, album, album_artist, genre)
        SELECT id, file_name, title, artist, album, album_artist, genre FROM tracks;
        """)
    }

    private nonisolated static func removeOrphanedRows(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        DELETE FROM playlist_tracks
        WHERE playlist_id NOT IN (SELECT id FROM playlists)
           OR track_id NOT IN (SELECT id FROM tracks);
        DELETE FROM play_history WHERE track_id NOT IN (SELECT id FROM tracks);
        """)
    }

    private nonisolated static func migrateListeningHistorySchema(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        CREATE TABLE IF NOT EXISTS listening_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_key TEXT NOT NULL,
            source TEXT NOT NULL,
            source_id TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            artwork_url TEXT,
            queue_item BLOB,
            legacy_play_id INTEGER UNIQUE,
            played_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS listening_history_date_idx
            ON listening_history(played_at DESC);
        CREATE INDEX IF NOT EXISTS listening_history_item_date_idx
            ON listening_history(item_key, played_at DESC);
        INSERT OR IGNORE INTO listening_history(
            item_key, source, source_id, title, artist, album,
            artwork_url, queue_item, legacy_play_id, played_at
        )
        SELECT 'local:' || t.id, 'local', t.id,
               CASE WHEN TRIM(t.title) = '' THEN t.file_name ELSE t.title END,
               CASE WHEN TRIM(t.artist) = '' THEN 'Unknown Artist' ELSE t.artist END,
               CASE WHEN TRIM(t.album) = '' THEN 'Unknown Album' ELSE t.album END,
               NULL, NULL, ph.id, ph.played_at
        FROM play_history ph
        JOIN tracks t ON t.id = ph.track_id;
        """)
    }

    private nonisolated static func migrateLyricsCacheSchema(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        CREATE TABLE IF NOT EXISTS lyrics_cache (
            lookup_key TEXT PRIMARY KEY,
            lyrics TEXT,
            synced_lyrics TEXT,
            is_instrumental INTEGER NOT NULL DEFAULT 0,
            fetched_at REAL NOT NULL
        );
        """)
    }

    private nonisolated static func migrateSyncedLyricsCacheSchema(_ connection: OpaquePointer) throws {
        if !tableContainsColumn(on: connection, table: "lyrics_cache", column: "synced_lyrics") {
            try executeRaw(connection, "ALTER TABLE lyrics_cache ADD COLUMN synced_lyrics TEXT")
            // Version 6 discarded LRCLIB's synchronized payload. Refresh those
            // positive entries once when they are next displayed.
            try executeRaw(connection, "DELETE FROM lyrics_cache WHERE lyrics IS NOT NULL")
        }
    }

    private nonisolated static func migrateMetadataOverridesSchema(_ connection: OpaquePointer) throws {
        try executeRaw(connection, """
        CREATE TABLE IF NOT EXISTS track_metadata_overrides (
            track_id TEXT PRIMARY KEY,
            title TEXT,
            artist TEXT,
            album_artist TEXT,
            album TEXT,
            genre TEXT,
            year TEXT,
            track_number INTEGER,
            track_number_overridden INTEGER NOT NULL DEFAULT 0,
            disc_number INTEGER,
            disc_number_overridden INTEGER NOT NULL DEFAULT 0,
            artwork BLOB,
            artwork_overridden INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
        );
        """)
    }

    private nonisolated static func executeRaw(_ connection: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorPointer)
            throw UziqError.database(message)
        }
    }

    private nonisolated static func pragmaInt(_ connection: OpaquePointer?, name: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw UziqError.database("Could not read SQLite PRAGMA \(name)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UziqError.database("SQLite PRAGMA \(name) returned no value")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private nonisolated static func pragmaText(_ connection: OpaquePointer?, name: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw UziqError.database("Could not read SQLite PRAGMA \(name)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw UziqError.database("SQLite PRAGMA \(name) returned no value")
        }
        return String(cString: value)
    }

    private nonisolated static func hasRows(_ connection: OpaquePointer, sql: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw UziqError.database(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private nonisolated static func ftsContainsFileName(on connection: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(tracks_fts)", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == "file_name" { return true }
        }
        return false
    }

    private nonisolated static func tableContainsColumn(on connection: OpaquePointer?, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(connection, pragma, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
    }

    private func rebuildSearchIndex(for id: String) throws {
        try execute("DELETE FROM tracks_fts WHERE track_id = ?", bindings: [id])
        try execute("""
            INSERT INTO tracks_fts(track_id, file_name, title, artist, album, album_artist, genre)
            SELECT t.id, t.file_name, COALESCE(o.title, t.title), COALESCE(o.artist, t.artist),
                   COALESCE(o.album, t.album), COALESCE(o.album_artist, t.album_artist),
                   COALESCE(o.genre, t.genre)
            FROM tracks t
            LEFT JOIN track_metadata_overrides o ON o.track_id = t.id
            WHERE t.id = ?
        """, bindings: [id])
    }

    private func bindOverride(_ value: String?, to statement: OpaquePointer, index: inout Int32) {
        bind(value == nil ? Int64(0) : Int64(1), to: statement, index: index)
        index += 1
        bind(value, to: statement, index: index)
        index += 1
    }

    private func readTrack(
        _ statement: OpaquePointer,
        playCountIndex: Int32? = nil,
        artworkPool: inout [Data: Data]
    ) -> Track {
        func text(_ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }
        func optionalText(_ index: Int32) -> String? { text(index).isEmpty ? nil : text(index) }
        func optionalInt(_ index: Int32) -> Int? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, index)) }
        func optionalDouble(_ index: Int32) -> Double? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index) }
        func artworkData(_ index: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            let loaded = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
            if let shared = artworkPool[loaded] { return shared }
            artworkPool[loaded] = loaded
            return loaded
        }

        return Track(
            id: text(0), url: URL(fileURLWithPath: text(1)), fileName: text(2), title: text(3),
            artist: text(4), albumArtist: text(5), album: text(6), genre: text(7), year: text(8),
            trackNumber: optionalInt(9), discNumber: optionalInt(10), duration: sqlite3_column_double(statement, 11),
            codec: text(12), bitrate: optionalInt(13), sampleRate: optionalDouble(14),
            replayGainTrackDB: optionalDouble(15), replayGainAlbumDB: optionalDouble(16),
            artworkData: artworkData(17), lyrics: optionalText(18),
            musicBrainzRecordingID: optionalText(19), musicBrainzReleaseID: optionalText(20),
            acoustID: optionalText(21), addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 22)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 23)),
            isFavorite: sqlite3_column_int(statement, 25) != 0,
            playCount: playCountIndex.map { Int(sqlite3_column_int(statement, $0)) } ?? 0
        )
    }

    private func readListeningHistory(_ statement: OpaquePointer) -> [ListeningHistoryItem] {
        func text(_ statement: OpaquePointer, _ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }

        var history: [ListeningHistoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let itemKey = text(statement, 0)
            guard let source = PlaybackSource(rawValue: text(statement, 1)) else { continue }
            let sourceID = text(statement, 2)
            let title = text(statement, 3)
            let artist = text(statement, 4)
            let album = text(statement, 5)
            let artworkString = text(statement, 6)

            let decodedQueueItem: UnifiedQueueItem? = {
                guard sqlite3_column_type(statement, 7) != SQLITE_NULL,
                      let bytes = sqlite3_column_blob(statement, 7) else { return nil }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 7)))
                return try? JSONDecoder().decode(UnifiedQueueItem.self, from: data)
            }()
            let queueItem: UnifiedQueueItem?
            if let decodedQueueItem {
                queueItem = decodedQueueItem
            } else if source == .local {
                let path = text(statement, 10)
                queueItem = path.isEmpty ? nil : UnifiedQueueItem(
                    historyLocalID: sourceID,
                    url: URL(fileURLWithPath: path),
                    title: title,
                    artist: artist,
                    album: album
                )
            } else {
                queueItem = nil
            }
            guard let queueItem else { continue }

            history.append(ListeningHistoryItem(
                itemKey: itemKey,
                source: source,
                sourceID: sourceID,
                title: title,
                artist: artist,
                album: album,
                artworkURL: artworkString.isEmpty ? nil : URL(string: artworkString),
                queueItem: queueItem,
                lastPlayedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                playCount: Int(sqlite3_column_int64(statement, 9))
            ))
        }
        return history
    }

    private func smartPlaylistTrackCount(configuration: SmartPlaylistConfiguration) throws -> Int {
        let query = try SmartPlaylistSQLQuery.build(configuration: configuration, includeOrder: false)
        let statement = try prepare("""
            SELECT COUNT(*) FROM (
                SELECT t.id
                FROM tracks t
                LEFT JOIN track_metadata_overrides o ON o.track_id = t.id
                LEFT JOIN play_history ph ON ph.track_id = t.id
                GROUP BY t.id
                \(query.havingClause)
                LIMIT ?
            )
            """)
        defer { sqlite3_finalize(statement) }
        let bindings = query.bindings + [String(configuration.limit ?? -1)]
        for (index, value) in bindings.enumerated() {
            bind(value, to: statement, index: Int32(index + 1))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw UziqError.database(errorMessage) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func smartPlaylistCreatedAt(id: String) throws -> Date {
        let statement = try prepare("SELECT created_at FROM smart_playlists WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UziqError.database("The smart playlist no longer exists")
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        try ensureReady()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UziqError.database(errorMessage)
        }
        return statement
    }

    private func ensureReady() throws {
        if let initializationError { throw UziqError.database(initializationError) }
        guard connection != nil else { throw UziqError.database("The library database is not open") }
    }

    private func withTransaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, bindings: [String] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, to: statement, index: Int32(index + 1)) }
        try step(statement)
    }

    private func scalarString(_ sql: String, bindings: [String]) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, to: statement, index: Int32(index + 1)) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw UziqError.database("Expected a database result")
        }
        return String(cString: value)
    }

    private func optionalScalarString(_ sql: String, bindings: [String]) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, to: statement, index: Int32(index + 1)) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UziqError.database(errorMessage) }
    }

    private var errorMessage: String {
        connection.map { String(cString: sqlite3_errmsg($0)) } ?? "The library database is not open"
    }

    private func bind(_ value: String?, to statement: OpaquePointer, index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ value: Data?, to statement: OpaquePointer, index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
    }

    private func bind(_ value: Int?, to statement: OpaquePointer, index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, index: Int32) { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
    private func bind(_ value: Double, to statement: OpaquePointer, index: Int32) { sqlite3_bind_double(statement, index, value) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
