import XCTest
@testable import Uziq

final class PlaybackQueueTests: XCTestCase {
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
