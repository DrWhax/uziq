import XCTest
@testable import Uziq

final class PlaybackQueueTests: XCTestCase {
    func testRestoredSpotifyTrackQueueKeepsSequenceOwnership() {
        let track = SpotifyCatalogItem(
            id: "track-id",
            name: "Track",
            subtitle: "Artist",
            uri: "spotify:track:track-id",
            kind: .track,
            artworkURL: nil,
            durationMS: 180_000,
            itemCount: nil
        )
        let album = SpotifyCatalogItem(
            id: "album-id",
            name: "Album",
            subtitle: "Artist",
            uri: "spotify:album:album-id",
            kind: .album,
            artworkURL: nil,
            durationMS: nil,
            itemCount: 10
        )

        XCTAssertFalse(PlaybackQueueStore.shouldDelegateSpotifySequenceToHelper(
            currentItem: UnifiedQueueItem(spotify: track),
            helperControlsPlaybackSequence: true
        ))
        XCTAssertTrue(PlaybackQueueStore.shouldDelegateSpotifySequenceToHelper(
            currentItem: UnifiedQueueItem(spotify: album),
            helperControlsPlaybackSequence: true
        ))
    }

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

    @MainActor
    func testUpNextContainsOnlyItemsAfterTheCurrentTrack() {
        let sessionURL = temporarySessionURL("up-next-slice")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let queue = PlaybackQueueStore(sessionURL: sessionURL)
        let tracks = (1...4).map(spotifyTrack)

        queue.replace(with: tracks[1], context: tracks)

        XCTAssertEqual(queue.currentItem?.sourceID, "track-2")
        XCTAssertEqual(queue.upcomingItems.map(\.sourceID), ["track-3", "track-4"])
    }

    @MainActor
    func testClearingUpNextKeepsTheCurrentTrackAndHistory() {
        let sessionURL = temporarySessionURL("clear-up-next")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let queue = PlaybackQueueStore(sessionURL: sessionURL)
        let tracks = (1...4).map(spotifyTrack)
        queue.replace(with: tracks[1], context: tracks)

        queue.clearUpcoming()

        XCTAssertEqual(queue.items.map(\.sourceID), ["track-1", "track-2"])
        XCTAssertEqual(queue.currentItem?.sourceID, "track-2")
        XCTAssertTrue(queue.upcomingItems.isEmpty)
    }

    @MainActor
    func testReorderingAndRemovingUpNextUseFutureRelativeOffsets() {
        let sessionURL = temporarySessionURL("edit-up-next")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let queue = PlaybackQueueStore(sessionURL: sessionURL)
        let tracks = (1...4).map(spotifyTrack)
        queue.replace(with: tracks[0], context: tracks)

        queue.moveUpcoming(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(queue.items.map(\.sourceID), ["track-1", "track-3", "track-4", "track-2"])
        XCTAssertEqual(queue.currentItem?.sourceID, "track-1")

        queue.removeUpcoming(at: IndexSet([0, 2]))
        XCTAssertEqual(queue.items.map(\.sourceID), ["track-1", "track-4"])
        XCTAssertEqual(queue.upcomingItems.map(\.sourceID), ["track-4"])
    }

    private func spotifyTrack(_ number: Int) -> SpotifyCatalogItem {
        SpotifyCatalogItem(
            id: "track-\(number)",
            name: "Track \(number)",
            subtitle: "Artist",
            uri: "spotify:track:track-\(number)",
            kind: .track,
            artworkURL: nil,
            durationMS: 180_000,
            itemCount: nil
        )
    }

    private func temporarySessionURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-\(name)-\(UUID().uuidString).json")
    }
}
