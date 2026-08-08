import XCTest
@testable import Uziq

final class PlaybackQueueTests: XCTestCase {
    @MainActor
    func testVolumeClampingDoesNotReenterTheObservableSetter() {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-volume-test-\(UUID().uuidString).json")
        let queue = PlaybackQueueStore(sessionURL: sessionURL)

        queue.volume = 0.42
        XCTAssertEqual(queue.volume, 0.42, accuracy: 0.001)
        queue.volume = 2
        XCTAssertEqual(queue.volume, 1, accuracy: 0.001)
        queue.volume = -.infinity
        XCTAssertEqual(queue.volume, 1, accuracy: 0.001)
        queue.volume = 0.42

        let restoredQueue = PlaybackQueueStore(sessionURL: sessionURL)
        XCTAssertEqual(restoredQueue.volume, 0.42, accuracy: 0.001)

        try? FileManager.default.removeItem(at: sessionURL)
    }

    func testSpotifyQueueItemRoundTripsWithoutLosingPlaybackIdentity() throws {
        let spotifyItem = SpotifyCatalogItem(
            id: "track-123",
            name: "A Track",
            subtitle: "An Artist",
            uri: "spotify:track:track-123",
            kind: .track,
            artworkURL: URL(string: "https://example.com/cover.jpg"),
            durationMS: 241_000,
            itemCount: nil
        )
        let item = UnifiedQueueItem(spotify: spotifyItem)

        let restored = try JSONDecoder().decode(
            UnifiedQueueItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(restored, item)
        XCTAssertEqual(restored.spotifyItem?.uri, spotifyItem.uri)
        XCTAssertEqual(restored.source, .spotify)
    }

    func testBandcampQueueItemRoundTripsWithPlayableResult() throws {
        let result = BandcampResult(
            id: "bandcamp-42",
            title: "A Release",
            artist: "An Artist",
            url: URL(string: "https://artist.bandcamp.com/album/a-release")!,
            type: "a",
            bandID: 12,
            tralbumID: 42,
            artworkURL: URL(string: "https://example.com/art.jpg")
        )
        let item = UnifiedQueueItem(bandcamp: result)

        let restored = try JSONDecoder().decode(
            UnifiedQueueItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(restored, item)
        XCTAssertEqual(restored.bandcampResult, result)
        XCTAssertEqual(restored.source, .bandcamp)
    }
}
