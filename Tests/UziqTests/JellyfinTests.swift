import JellyfinAPI
import XCTest
@testable import Uziq

final class JellyfinTests: XCTestCase {
    func testPlainHTTPServerAddressesAreFlaggedWithoutBeingRejected() {
        XCTAssertTrue(JellyfinStore.isPlainHTTPAddress("http://192.168.1.10:8096/"))
        XCTAssertFalse(JellyfinStore.isPlainHTTPAddress("https://music.example.com"))
    }

    func testAudioMetadataMapsToPlayableCatalogTrack() throws {
        let dto = BaseItemDto(
            album: "A Test Album",
            albumArtist: "A Test Artist",
            albumID: "album-42",
            albumPrimaryImageTag: "cover-tag",
            artistItems: [NameIDPair(id: "artist-7", name: "A Test Artist")],
            artists: ["A Test Artist"],
            container: "flac",
            genres: ["Electronic"],
            id: "track-99",
            indexNumber: 4,
            name: "A Test Track",
            parentIndexNumber: 1,
            productionYear: 2026,
            runTimeTicks: 2_450_000_000,
            type: .audio
        )

        let item = try XCTUnwrap(JellyfinCatalogItem(dto: dto))

        XCTAssertEqual(item.kind, .track)
        XCTAssertEqual(item.name, "A Test Track")
        XCTAssertEqual(item.subtitle, "A Test Artist")
        XCTAssertEqual(item.album, "A Test Album")
        XCTAssertEqual(item.duration, 245, accuracy: 0.001)
        XCTAssertEqual(item.trackNumber, 4)
        XCTAssertEqual(item.imageItemID, "album-42")
        XCTAssertEqual(item.imageTag, "cover-tag")
    }

    func testJellyfinQueueItemRoundTripsWithServerIdentity() throws {
        let dto = BaseItemDto(
            album: "Queue Album", albumArtist: "Queue Artist", artists: ["Queue Artist"],
            container: "mp3", id: "queue-track", name: "Queue Track",
            runTimeTicks: 1_800_000_000, type: .audio
        )
        let catalogItem = try XCTUnwrap(JellyfinCatalogItem(dto: dto))
        let queueItem = UnifiedQueueItem(jellyfin: catalogItem)

        let restored = try JSONDecoder().decode(
            UnifiedQueueItem.self,
            from: JSONEncoder().encode(queueItem)
        )

        XCTAssertEqual(restored, queueItem)
        XCTAssertEqual(restored.source, .jellyfin)
        XCTAssertEqual(restored.jellyfinItem?.id, "queue-track")
    }

    func testJellyfinCacheUsesStableExtensionAndSevenDayCleanup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-jellyfin-cache-test-\(UUID().uuidString)", isDirectory: true)
        let cache = JellyfinCacheManager(directory: directory)
        try cache.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stale = cache.audioURL(itemID: "server/item:1", container: "FLAC")
        let recent = cache.audioURL(itemID: "item-2", container: "mp3")
        try Data(repeating: 1, count: 13).write(to: stale)
        try Data(repeating: 2, count: 21).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: stale.path
        )

        XCTAssertEqual(stale.lastPathComponent, "server_item_1.flac")
        XCTAssertEqual(
            try cache.clean(olderThan: .now.addingTimeInterval(-JellyfinCacheManager.retentionInterval)),
            1
        )
        XCTAssertEqual(try cache.stats(), JellyfinCacheStats(fileCount: 1, totalBytes: 21))
    }
}
