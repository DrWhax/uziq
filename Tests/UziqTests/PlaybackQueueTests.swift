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

    @MainActor
    func testDirectSpotifySelectionBecomesTheVisibleQueueItem() throws {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-direct-spotify-test-\(UUID().uuidString).json")
        let queue = PlaybackQueueStore(sessionURL: sessionURL)
        let item = try XCTUnwrap(
            SpotifyStore.directPlaybackItem(
                from: "https://open.spotify.com/track/0123456789ABCDEFGHIJKL"
            )
        )

        queue.replace(with: item)

        XCTAssertEqual(queue.currentItem?.source, .spotify)
        XCTAssertEqual(queue.currentItem?.sourceID, item.id)
        XCTAssertEqual(queue.currentItem?.spotifyItem?.uri, item.uri)

        try? FileManager.default.removeItem(at: sessionURL)
    }

    func testSpotifyQueueDetectsEndOfSingleTrackPlaybackRequest() {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = SpotifyPlaybackSnapshot(
            itemID: "track-123",
            title: "A Track",
            artist: "An Artist",
            album: "An Album",
            artworkURL: nil,
            duration: 10,
            progress: 8,
            isPlaying: true,
            deviceName: "Uziq",
            observedAt: observedAt
        )

        XCTAssertFalse(PlaybackQueueStore.spotifyPlaybackReachedEnd(
            snapshot,
            at: observedAt.addingTimeInterval(1)
        ))
        XCTAssertTrue(PlaybackQueueStore.spotifyPlaybackReachedEnd(
            snapshot,
            at: observedAt.addingTimeInterval(2)
        ))
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
