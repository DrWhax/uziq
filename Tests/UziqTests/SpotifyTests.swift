import XCTest
@testable import Uziq

final class SpotifyTests: XCTestCase {
    func testArtistCatalogRequestsRespectDevelopmentModeLimits() {
        XCTAssertEqual(SpotifyStore.artistAlbumsPageLimit, 10)
        XCTAssertEqual(
            SpotifyStore.artistRadioSearchQuery(for: "Artist \"Name\""),
            "artist:\"Artist \\\"Name\\\"\""
        )
    }

    func testSpotifyPCMIsDeinterleavedIntoStableChannelBuffers() throws {
        let samples: [Float] = [0.1, -0.1, 0.25, -0.25, 0.75, -0.75]
        var data = samples.withUnsafeBytes { Data($0) }
        data.append(contentsOf: [0xAA, 0xBB, 0xCC])

        let converted = try XCTUnwrap(SpotifyPCMConverter.makeBuffer(from: data))
        let channels = try XCTUnwrap(converted.buffer.floatChannelData)

        XCTAssertFalse(converted.buffer.format.isInterleaved)
        XCTAssertEqual(converted.buffer.frameLength, 3)
        XCTAssertEqual(converted.consumedBytes, samples.count * MemoryLayout<Float>.size)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[0], count: 3)), [0.1, 0.25, 0.75])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[1], count: 3)), [-0.1, -0.25, -0.75])
    }

    @MainActor
    func testPlaybackEngineCanRenderSpotifyPCMWithoutInvalidChannelMemory() {
        let playback = PlaybackEngine()
        let silence = [Float](
            repeating: 0,
            count: 4 * 4_096 * SpotifyPCMConverter.channelCount
        )

        playback.beginSpotifyPCMStream()
        playback.enqueueSpotifyPCM(silence.withUnsafeBytes { Data($0) })
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        playback.endSpotifyPCMStream()
    }

    @MainActor
    func testSpotifyTrackChangeFlushesPreviouslyQueuedPCM() {
        let playback = PlaybackEngine()
        let samples = [Float](repeating: 0.25, count: 1_024 * SpotifyPCMConverter.channelCount)

        playback.beginSpotifyPCMStream()
        playback.enqueueSpotifyPCM(samples.withUnsafeBytes { Data($0) })
        XCTAssertGreaterThan(playback.spotifyReceivedByteCount, 0)

        playback.prepareForSpotifyTransition()
        XCTAssertEqual(playback.spotifyReceivedByteCount, 0)

        playback.handleSpotifyPlayerEvent(.trackChanged)
        playback.enqueueSpotifyPCM(samples.withUnsafeBytes { Data($0) })
        XCTAssertGreaterThan(playback.spotifyReceivedByteCount, 0)
        playback.endSpotifyPCMStream()
    }

    func testSpotifySearchScopesAreExplicit() {
        XCTAssertEqual(SearchProvider.allCases.map(\.title), ["Local", "Bandcamp", "Spotify"])
    }

    func testSpotifyPlaybackProgressAdvancesFromObservationTime() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = SpotifyPlaybackSnapshot(
            itemID: "track",
            title: "Title",
            artist: "Artist",
            album: "Album",
            artworkURL: nil,
            duration: 180,
            progress: 30,
            isPlaying: true,
            deviceName: "Uziq",
            observedAt: observedAt
        )

        XCTAssertEqual(
            snapshot.effectiveProgress(at: observedAt.addingTimeInterval(2.5)),
            32.5,
            accuracy: 0.001
        )
    }

    @MainActor
    func testPlaylistTrackPlaybackKeepsPlaylistContextForNextCommand() throws {
        let request = SpotifyStore.playlistPlaybackRequest(
            trackURI: "spotify:track:track-id",
            playlistURI: "spotify:playlist:playlist-id"
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let offset = try XCTUnwrap(json["offset"] as? [String: Any])

        XCTAssertEqual(json["context_uri"] as? String, "spotify:playlist:playlist-id")
        XCTAssertEqual(offset["uri"] as? String, "spotify:track:track-id")
        XCTAssertNil(json["uris"])
    }

    func testSpotifyLoopbackRedirectUsesExplicitIPv4Address() {
        XCTAssertEqual(
            SpotifyLoopbackServer.callbackURL.absoluteString,
            "http://127.0.0.1:8989/callback"
        )
    }

    func testDevelopmentModePlaylistWithoutItemsStillDecodes() throws {
        let response = #"""
        {
          "playlists": {
            "items": [
              null,
              {
                "id": "playlist-id",
                "name": "A Playlist",
                "uri": "spotify:playlist:playlist-id",
                "owner": { "display_name": "Listener" },
                "images": [{ "url": "https://i.scdn.co/image/example" }]
              }
            ]
          }
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(RawPlaylistSearchEnvelope.self, from: response)
        let item = try XCTUnwrap(decoded.playlists.items.compactMap { $0?.catalogItem }.first)

        XCTAssertEqual(item.name, "A Playlist")
        XCTAssertEqual(item.subtitle, "Listener")
        XCTAssertEqual(item.kind, .playlist)
        XCTAssertNil(item.itemCount)
    }
}
