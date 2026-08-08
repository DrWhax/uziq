import XCTest
@testable import Uziq

final class BandcampTests: XCTestCase {
    func testBandcampDMChallengeMatchesReversedAndroidClient() throws {
        let body = Data("grant_type=password&username=test%40example.com".utf8)
        let fixtures = [
            (
                "0123456789abc1ef0123456789abcdef01234567d",
                "5b82951e0d3405fa867a48bb1ec40097a85aabea"
            ),
            (
                "0123456789abc3ef0123456789abcdef01234567d",
                "b4de4e79b30c91ab0a1a89a0f35108d1dd6d252a4375ba3de87a1f6e821fee88"
            ),
            (
                "0123456789abc4ef0123456789abcdef01234567d",
                "85a23fd9d5a03ab1873376555cb7f78822222e80a54738a9e7a768748515cc0dd7ae0e49fb0ed46f036781b2d7d13c9374185ac5a1ff95481d2275a33e510ebf"
            )
        ]

        for (challenge, expected) in fixtures {
            XCTAssertEqual(
                try BandcampAuthClient.dmValue(challenge: challenge, body: body),
                expected
            )
        }
    }

    func testBandcampOAuthFormEncodingIsStable() {
        let body = BandcampAuthClient.formEncoded([
            ("username", "test listener@example.com"),
            ("password", "a+b/c=")
        ])
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "username=test+listener%40example.com&password=a%2Bb%2Fc%3D"
        )
    }

    func testRejectedBandcampLoginIsMarkedAsRetryable() {
        let error = BandcampAuthError.loginRejected("invalid_grant")

        XCTAssertTrue(error.isLoginRejection)
        XCTAssertEqual(error.localizedDescription, "invalid_grant")
    }

    func testAuthenticatedCollectionParsingBuildsPlayableOwnedReleases() throws {
        let data = Data(#"""
        {
          "sync_date": 1786200000000,
          "next_offset": "opaque-next-page",
          "items": [
            {
              "band_id": 42,
              "tralbum_id": 101,
              "tralbum_type": "a",
              "title": "Night Music",
              "artist": "The Listener",
              "page_url": "https://listener.bandcamp.com/album/night-music",
              "art_id": 987654,
              "token": "private-item-token",
              "tracks": []
            },
            {
              "band_id": "43",
              "tralbum_id": "102",
              "tralbum_type": "album",
              "title": "Morning Music",
              "page_url": "//morning.bandcamp.com/album/morning-music",
              "band_info": { "name": "Morning Band" },
              "art_id": "123456",
              "tracks": []
            }
          ]
        }
        """#.utf8)

        let page = try BandcampAuthClient.parseCollectionPage(data, pageSize: 2)

        XCTAssertEqual(page.nextOffset, "opaque-next-page")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].title, "Night Music")
        XCTAssertEqual(page.items[0].artist, "The Listener")
        XCTAssertEqual(page.items[0].type, "a")
        XCTAssertEqual(page.items[0].bandID, 42)
        XCTAssertEqual(page.items[0].tralbumID, 101)
        XCTAssertTrue(page.items[0].isPlayable)
        XCTAssertEqual(page.items[0].artworkURL?.absoluteString, "https://f4.bcbits.com/img/a987654_16.jpg")
        XCTAssertEqual(page.items[1].artist, "Morning Band")
        XCTAssertEqual(page.items[1].openURL.absoluteString, "https://morning.bandcamp.com/album/morning-music")
    }

    func testCollectionParserUsesLastItemTokenOnlyWhenPageIsFull() throws {
        let data = Data(#"""
        {
          "items": [{
            "band_id": 42,
            "tralbum_id": 101,
            "tralbum_type": "a",
            "title": "Night Music",
            "artist": "The Listener",
            "token": "last-item-token"
          }]
        }
        """#.utf8)

        let fullPage = try BandcampAuthClient.parseCollectionPage(data, pageSize: 1)
        let partialPage = try BandcampAuthClient.parseCollectionPage(data, pageSize: 2)

        XCTAssertEqual(fullPage.nextOffset, "last-item-token")
        XCTAssertNil(partialPage.nextOffset)
    }

    func testDuplicatedMalformedBandcampURLIsCanonicalized() throws {
        let malformed = try XCTUnwrap(URL(
            string: "https://dkfmshoegaze.bandcamp.comhttps//dkfmshoegaze.bandcamp.com/album/alternative-f-acts-a-shoegaze-resistance-compilation"
        ))
        let result = BandcampResult(
            id: "album-1",
            title: "Alternative F-Acts",
            artist: "Various Artists",
            url: malformed,
            type: "a"
        )

        XCTAssertEqual(
            result.openURL.absoluteString,
            "https://dkfmshoegaze.bandcamp.com/album/alternative-f-acts-a-shoegaze-resistance-compilation"
        )
    }

    func testCacheCleanupOnlyRemovesFilesUnusedForSevenDays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-cache-test-\(UUID().uuidString)", isDirectory: true)
        let cache = BandcampCacheManager(directory: directory)
        try cache.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stale = directory.appendingPathComponent("stale.mp3")
        let recent = directory.appendingPathComponent("recent.mp3")
        try Data(repeating: 1, count: 12).write(to: stale)
        try Data(repeating: 2, count: 20).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: stale.path
        )

        let removed = try cache.removeFilesNotUsed(
            since: Date.now.addingTimeInterval(-BandcampCacheManager.retentionInterval)
        )
        let stats = try cache.stats()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(stats, BandcampCacheStats(fileCount: 1, totalBytes: 20))
    }

    func testPlayingCachedFileUpdatesItsLastUsedDate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-cache-touch-test-\(UUID().uuidString)", isDirectory: true)
        let cache = BandcampCacheManager(directory: directory)
        try cache.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("track.mp3")
        try Data([1]).write(to: file)
        let oldDate = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        try cache.markUsed(file)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey])

        XCTAssertGreaterThan(try XCTUnwrap(values.contentModificationDate), oldDate)
    }
}
