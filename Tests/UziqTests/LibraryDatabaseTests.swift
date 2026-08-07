import XCTest
@testable import Uziq

final class LibraryDatabaseTests: XCTestCase {
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
    }

    func testFLACVorbisCommentsAreRead() throws {
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

        var flac = Data("fLaC".utf8)
        flac.append(0x84) // last metadata block, Vorbis comment type
        flac.append(UInt8((block.count >> 16) & 0xFF))
        flac.append(UInt8((block.count >> 8) & 0xFF))
        flac.append(UInt8(block.count & 0xFF))
        flac.append(block)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uziq-tags.flac")
        try flac.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MetadataReader.read(url)
        XCTAssertEqual(metadata.title, "Tagged Track")
        XCTAssertEqual(metadata.artist, "Tagged Artist")
        XCTAssertEqual(metadata.album, "Tagged Album")
        XCTAssertEqual(metadata.genre, "Ambient")
        XCTAssertEqual(metadata.trackNumber, 2)
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

    private func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
