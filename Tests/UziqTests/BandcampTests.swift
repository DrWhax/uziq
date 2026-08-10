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

    func testAuthenticatedWishlistParsingBuildsPlayableReleases() throws {
        let data = Data(#"""
        {
          "items": [{
            "token": "wishlist-next-token",
            "tralbum_type": "track",
            "tralbum_id": "303",
            "band_id": 77,
            "title": "Soft Focus",
            "artist": "The Dreamers",
            "art_id": 456789
          }]
        }
        """#.utf8)

        let page = try BandcampAuthClient.parseWishlistPage(data, pageSize: 1)

        XCTAssertEqual(page.nextOffset, "wishlist-next-token")
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].id, "wishlist-t-77-303")
        XCTAssertEqual(page.items[0].title, "Soft Focus")
        XCTAssertEqual(page.items[0].artist, "The Dreamers")
        XCTAssertTrue(page.items[0].isPlayable)
    }

    func testEmptyBandcampWishlistIsAValidAccountSection() throws {
        let page = try BandcampAuthClient.parseWishlistPage(Data("{}".utf8))

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextOffset)
    }

    func testBandcampAccountOverviewParsesProfileAndNewReleaseFeed() throws {
        let data = Data(#"""
        {
          "fan_info": {
            "fan_id": 9001,
            "username": "uziq-listener",
            "name": "Uziq Listener",
            "bio": "Always looking for the next record.",
            "image_id": 12345
          },
          "feed_content": {
            "band_info": {
              "42": {
                "band_id": 42,
                "name": "Night Listener",
                "url": "https://listener.bandcamp.com",
                "latest_art_id": 555
              }
            },
            "stories": {
              "feed": [
                {
                  "story_type": "nr",
                  "band_id": 42,
                  "tralbum_id": 101,
                  "tralbum_type": "album",
                  "item_title": "Night Music",
                  "item_artist": "Night Listener",
                  "item_url": "/album/night-music",
                  "item_art_id": 987654
                },
                {
                  "story_type": "nr",
                  "band_id": 42,
                  "tralbum_id": 101,
                  "tralbum_type": "a",
                  "item_title": "Duplicate"
                },
                { "story_type": "nf", "band_id": 42 }
              ]
            }
          }
        }
        """#.utf8)

        let overview = try BandcampAuthClient.parseAccountOverview(data)

        XCTAssertEqual(overview.profile.fanID, 9001)
        XCTAssertEqual(overview.profile.displayName, "Uziq Listener")
        XCTAssertEqual(overview.profile.profileURL.absoluteString, "https://bandcamp.com/uziq-listener")
        XCTAssertEqual(overview.profile.artworkURL?.absoluteString, "https://f4.bcbits.com/img/0000012345_9.jpg")
        XCTAssertEqual(overview.knownBandURLs[42]?.absoluteString, "https://listener.bandcamp.com")
        XCTAssertEqual(overview.newReleases.count, 1)
        XCTAssertEqual(overview.newReleases[0].title, "Night Music")
        XCTAssertEqual(overview.newReleases[0].openURL.absoluteString, "https://listener.bandcamp.com/album/night-music")
        XCTAssertEqual(overview.newReleases[0].artworkURL?.absoluteString, "https://f4.bcbits.com/img/a987654_16.jpg")
    }

    func testBandcampFollowedArtistsUseKnownArtistURLs() throws {
        let data = Data(#"""
        {
          "following_bands": [
            {
              "band_id": 42,
              "name": "Night Listener",
              "location": "Lisbon, Portugal",
              "image_id": "12345",
              "followed_by_fan": true
            }
          ]
        }
        """#.utf8)
        let knownURL = try XCTUnwrap(URL(string: "https://listener.bandcamp.com"))

        let artists = try BandcampAuthClient.parseFollowedArtists(data, knownBandURLs: [42: knownURL])

        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists[0].id, "followed-band-42")
        XCTAssertEqual(artists[0].title, "Night Listener")
        XCTAssertEqual(artists[0].artist, "Lisbon, Portugal")
        XCTAssertEqual(artists[0].openURL, knownURL)
        XCTAssertEqual(artists[0].artworkURL?.absoluteString, "https://f4.bcbits.com/img/0000012345_21.jpg")
    }

    func testEmptyBandcampFollowListIsAValidAccountSection() throws {
        let artists = try BandcampAuthClient.parseFollowedArtists(Data("{}".utf8))

        XCTAssertTrue(artists.isEmpty)
    }

    func testBandcampAccountCacheOnlyLoadsMatchingAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-bandcamp-account-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = BandcampAccountCache(fileURL: directory.appendingPathComponent("account.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileURL = try XCTUnwrap(URL(string: "https://bandcamp.com/listener"))
        let snapshot = BandcampAccountSnapshot(
            accountIdentifier: "listener@example.com",
            profile: BandcampAccountProfile(
                fanID: 7,
                username: "listener",
                displayName: "Listener",
                bio: nil,
                artworkURL: nil,
                profileURL: profileURL
            ),
            ownedResults: [],
            wishlistResults: [],
            followedArtists: [],
            newReleases: [],
            savedAt: .now
        )

        try cache.save(snapshot)

        XCTAssertEqual(cache.load(accountIdentifier: "LISTENER@example.com")?.profile?.fanID, 7)
        XCTAssertNil(cache.load(accountIdentifier: "someone-else@example.com"))
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
