import Foundation
import SQLite3

actor LibraryDatabase {
    private var connection: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Uziq", isDirectory: true)
            try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            url = applicationSupport.appendingPathComponent("library.sqlite")
        }
        self.databaseURL = url
        var openedConnection: OpaquePointer?
        let sqlitePath = url.lastPathComponent == ":memory:" ? ":memory:" : url.path
        sqlite3_open(sqlitePath, &openedConnection)
        connection = openedConnection
        sqlite3_busy_timeout(openedConnection, 2_000)
        Self.initializeSchema(on: openedConnection)
    }

    deinit { sqlite3_close(connection) }

    func upsert(_ metadata: TrackMetadata) throws {
        let sql = """
        INSERT INTO tracks (
            id, path, file_name, title, artist, album_artist, album, genre, year,
            track_number, disc_number, duration, codec, bitrate, sample_rate,
            artwork, lyrics, mb_recording_id, mb_release_id, acoustid,
            added_at, modified_at, file_size
        ) VALUES (lower(hex(randomblob(16))), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            file_name=excluded.file_name, title=excluded.title, artist=excluded.artist,
            album_artist=excluded.album_artist, album=excluded.album, genre=excluded.genre,
            year=excluded.year, track_number=excluded.track_number, disc_number=excluded.disc_number,
            duration=excluded.duration, codec=excluded.codec, bitrate=excluded.bitrate,
            sample_rate=excluded.sample_rate, artwork=COALESCE(excluded.artwork, tracks.artwork),
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
        bind(metadata.artworkData, to: statement, index: 15)
        bind(metadata.lyrics, to: statement, index: 16)
        bind(metadata.musicBrainzRecordingID, to: statement, index: 17)
        bind(metadata.musicBrainzReleaseID, to: statement, index: 18)
        bind(metadata.acoustID, to: statement, index: 19)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 20)
        bind(metadata.modifiedAt.timeIntervalSince1970, to: statement, index: 21)
        bind(metadata.fileSize, to: statement, index: 22)
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
            ? "SELECT * FROM tracks"
            : "SELECT t.*, COUNT(ph.id) AS play_count FROM tracks t JOIN play_history ph ON ph.track_id = t.id"
        var bindings: [String] = []
        var conditions: [String] = []
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append("id IN (SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH ?)")
            let terms = search
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "_" } }
                .filter { !$0.isEmpty }
            bindings.append(terms.map { "\($0)*" }.joined(separator: " AND "))
        }
        if favoritesOnly { conditions.append("is_favorite = 1") }
        if let mostPlayedSince {
            conditions.append("ph.played_at >= ?")
            bindings.append(String(mostPlayedSince.timeIntervalSince1970))
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if mostPlayedSince != nil {
            sql += " GROUP BY t.id ORDER BY COUNT(ph.id) DESC, t.title COLLATE NOCASE"
        } else if recentlyAdded {
            sql += " ORDER BY added_at DESC"
        } else {
            sql += " ORDER BY album COLLATE NOCASE, track_number, title COLLATE NOCASE"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, to: statement, index: Int32(index + 1)) }
        var tracks: [Track] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            tracks.append(readTrack(statement, playCountIndex: mostPlayedSince == nil ? nil : 24))
        }
        return tracks
    }

    func recordPlay(trackID: String) throws {
        let statement = try prepare("INSERT INTO play_history(track_id, played_at) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(trackID, to: statement, index: 1)
        bind(Date.now.timeIntervalSince1970, to: statement, index: 2)
        try step(statement)
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
            SELECT t.* FROM tracks t
            JOIN playlist_tracks pt ON pt.track_id = t.id
            WHERE pt.playlist_id = ?
            ORDER BY pt.position, t.title COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }
        bind(playlistID, to: statement, index: 1)
        var tracks: [Track] = []
        while sqlite3_step(statement) == SQLITE_ROW { tracks.append(readTrack(statement)) }
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

    func removeMissingFiles() throws {
        let statement = try prepare("SELECT id, path FROM tracks")
        defer { sqlite3_finalize(statement) }
        var missing: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 1) else { continue }
            let string = String(cString: path)
            if !FileManager.default.fileExists(atPath: string) {
                if let id = sqlite3_column_text(statement, 0) { missing.append(String(cString: id)) }
            }
        }
        for id in missing {
            try execute("DELETE FROM tracks WHERE id = ?", bindings: [id])
            try execute("DELETE FROM tracks_fts WHERE track_id = ?", bindings: [id])
        }
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

    private nonisolated static func initializeSchema(on connection: OpaquePointer?) {
        let schema = """
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
        CREATE TABLE IF NOT EXISTS artist_artwork (
            artist TEXT PRIMARY KEY, artwork BLOB NOT NULL, updated_at REAL NOT NULL
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
        """
        sqlite3_exec(connection, schema, nil, nil, nil)
        if !Self.tableContainsColumn(on: connection, table: "tracks", column: "is_favorite") {
            sqlite3_exec(connection, "ALTER TABLE tracks ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }
        if !Self.ftsContainsFileName(on: connection) {
            sqlite3_exec(connection, """
            DROP TABLE IF EXISTS tracks_fts;
            CREATE VIRTUAL TABLE tracks_fts USING fts5(
                track_id UNINDEXED, file_name, title, artist, album, album_artist, genre
            );
            INSERT INTO tracks_fts(track_id, file_name, title, artist, album, album_artist, genre)
            SELECT id, file_name, title, artist, album, album_artist, genre FROM tracks;
            """, nil, nil, nil)
        }
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
            SELECT id, file_name, title, artist, album, album_artist, genre FROM tracks WHERE id = ?
        """, bindings: [id])
    }

    private func readTrack(_ statement: OpaquePointer, playCountIndex: Int32? = nil) -> Track {
        func text(_ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }
        func optionalText(_ index: Int32) -> String? { text(index).isEmpty ? nil : text(index) }
        func optionalInt(_ index: Int32) -> Int? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, index)) }
        func optionalDouble(_ index: Int32) -> Double? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index) }
        func data(_ index: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
        }

        return Track(
            id: text(0), url: URL(fileURLWithPath: text(1)), fileName: text(2), title: text(3),
            artist: text(4), albumArtist: text(5), album: text(6), genre: text(7), year: text(8),
            trackNumber: optionalInt(9), discNumber: optionalInt(10), duration: sqlite3_column_double(statement, 11),
            codec: text(12), bitrate: optionalInt(13), sampleRate: optionalDouble(14), artworkData: data(15),
            lyrics: optionalText(16), musicBrainzRecordingID: optionalText(17), musicBrainzReleaseID: optionalText(18),
            acoustID: optionalText(19), addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 20)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 21)),
            isFavorite: sqlite3_column_int(statement, 23) != 0,
            playCount: playCountIndex.map { Int(sqlite3_column_int(statement, $0)) } ?? 0
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UziqError.database(errorMessage)
        }
        return statement
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

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UziqError.database(errorMessage) }
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(connection)) }

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
