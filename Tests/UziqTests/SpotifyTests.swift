import Combine
import XCTest
@testable import Uziq

final class SpotifyTests: XCTestCase {
    @MainActor
    func testOneShotSubscriptionsReleaseWhenPublishersComplete() {
        let store = OneShotCancellableStore()
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []

        store.sink(subject, receiveCompletion: { _ in }, receiveValue: { received.append($0) })
        XCTAssertEqual(store.count, 1)

        subject.send(7)
        subject.send(completion: .finished)

        XCTAssertEqual(received, [7])
        XCTAssertEqual(store.count, 0)

        store.sink(Just(9), receiveCompletion: { _ in }, receiveValue: { received.append($0) })
        XCTAssertEqual(received, [7, 9])
        XCTAssertEqual(store.count, 0, "Synchronous completion must not be inserted after finishing")
    }

    func testArtistCatalogRequestsRespectDevelopmentModeLimits() {
        XCTAssertEqual(SpotifyStore.artistAlbumsPageLimit, 10)
        XCTAssertEqual(SpotifyStore.artistAlbumsMaximum, 50)
        XCTAssertEqual(SpotifyStore.albumTracksPageLimit, 50)
        XCTAssertEqual(
            SpotifyStore.artistRadioSearchQuery(for: "Artist \"Name\""),
            "artist:\"Artist \\\"Name\\\"\""
        )
    }

    func testRateLimitDeadlineHonorsRetryAfterAndNeverShortensCooldown() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            SpotifyStore.rateLimitDeadline(now: now, current: nil, retryAfter: 120),
            now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            SpotifyStore.rateLimitDeadline(
                now: now,
                current: now.addingTimeInterval(300),
                retryAfter: 120
            ),
            now.addingTimeInterval(300)
        )
        XCTAssertEqual(
            SpotifyStore.rateLimitDeadline(now: now, current: nil, retryAfter: nil),
            now.addingTimeInterval(60)
        )
    }

    func testSpotifyLibraryCacheRoundTripsOnlyForMatchingClient() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-spotify-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = SpotifyLibraryCache(fileURL: directory.appendingPathComponent("library.json"))
        let savedAt = Date(timeIntervalSince1970: 1_000)
        let track = SpotifyCatalogItem(
            id: "track-id",
            name: "Track",
            subtitle: "Artist",
            uri: "spotify:track:track-id",
            kind: .track,
            artworkURL: URL(string: "https://example.com/art.jpg"),
            durationMS: 123_000,
            itemCount: nil
        )
        let snapshot = SpotifyLibrarySnapshot(
            clientID: "matching-client",
            savedAt: savedAt,
            profileName: "Listener",
            playlists: [],
            likedSongs: [track],
            likedSongsTotal: 1,
            topArtists: []
        )

        try cache.save(snapshot)
        let restored = try XCTUnwrap(cache.load(clientID: "matching-client"))

        XCTAssertEqual(restored.profileName, "Listener")
        XCTAssertEqual(restored.likedSongs, [track])
        XCTAssertEqual(restored.savedAt, savedAt)
        XCTAssertNil(cache.load(clientID: "different-client"))
        XCTAssertTrue(restored.isFresh(at: savedAt.addingTimeInterval(60)))
        XCTAssertFalse(restored.isFresh(at: savedAt.addingTimeInterval(SpotifyLibrarySnapshot.refreshInterval)))

        cache.remove()
        try? FileManager.default.removeItem(at: directory)
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
        XCTAssertEqual(SearchProvider.allCases.map(\.title), ["My Library", "Bandcamp", "Spotify", "Jellyfin"])
    }

    func testLibrespotHelperProtocolEncodesPlaybackContextAndDecodesEvents() throws {
        let command = LibrespotIPCCommand.loadContext(
            "spotify:playlist:playlist-id",
            offsetURI: "spotify:track:track-id",
            positionMS: 12_500
        )
        let commandData = try JSONEncoder().encode(command)
        let commandJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: commandData) as? [String: Any]
        )

        XCTAssertEqual(commandJSON["command"] as? String, "load_context")
        XCTAssertEqual(commandJSON["uri"] as? String, "spotify:playlist:playlist-id")
        XCTAssertEqual(commandJSON["offset_uri"] as? String, "spotify:track:track-id")
        XCTAssertEqual(commandJSON["position_ms"] as? Int, 12_500)

        let toggleData = try JSONEncoder().encode(LibrespotIPCCommand.transport("toggle"))
        let toggleJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: toggleData) as? [String: Any]
        )
        XCTAssertEqual(toggleJSON["command"] as? String, "toggle")

        let eventData = #"{"event":"track_changed","uri":"spotify:track:track-id","title":"Track","artist":"Artist","album":"Album","artwork_url":"https://i.scdn.co/image/cover","duration_ms":123000}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(LibrespotIPCEvent.self, from: eventData)

        XCTAssertEqual(event.event, "track_changed")
        XCTAssertEqual(event.uri, "spotify:track:track-id")
        XCTAssertEqual(event.artist, "Artist")
        XCTAssertEqual(event.durationMS, 123_000)
        XCTAssertEqual(event.artworkURL?.absoluteString, "https://i.scdn.co/image/cover")
    }

    func testDirectSpotifyPlaybackInputAcceptsURIsAndWebLinks() throws {
        let track = try XCTUnwrap(
            SpotifyStore.directPlaybackItem(from: "spotify:track:0123456789ABCDEFGHIJKL")
        )
        XCTAssertEqual(track.kind, .track)
        XCTAssertEqual(track.uri, "spotify:track:0123456789ABCDEFGHIJKL")

        let playlist = try XCTUnwrap(
            SpotifyStore.directPlaybackItem(
                from: "https://open.spotify.com/intl-pt/playlist/ABCDEFGHIJKLMNOPQRSTUV?si=example"
            )
        )
        XCTAssertEqual(playlist.kind, .playlist)
        XCTAssertEqual(playlist.uri, "spotify:playlist:ABCDEFGHIJKLMNOPQRSTUV")

        XCTAssertNil(SpotifyStore.directPlaybackItem(from: "https://example.com/track/not-spotify"))
        XCTAssertNil(SpotifyStore.directPlaybackItem(from: "spotify:show:not-supported"))
    }

    func testHelperControlsSequenceOnlyForHelperManagedContexts() {
        XCTAssertTrue(SpotifyStore.helperControlsPlaybackSequence(
            isDirectPlaybackActive: true,
            isSpotifyPlaybackSuppressed: false,
            helperAdvancesWithUziqQueue: false
        ))
        XCTAssertFalse(SpotifyStore.helperControlsPlaybackSequence(
            isDirectPlaybackActive: true,
            isSpotifyPlaybackSuppressed: false,
            helperAdvancesWithUziqQueue: true
        ))
        XCTAssertFalse(SpotifyStore.helperControlsPlaybackSequence(
            isDirectPlaybackActive: true,
            isSpotifyPlaybackSuppressed: true,
            helperAdvancesWithUziqQueue: false
        ))
        XCTAssertFalse(SpotifyStore.helperControlsPlaybackSequence(
            isDirectPlaybackActive: false,
            isSpotifyPlaybackSuppressed: false,
            helperAdvancesWithUziqQueue: false
        ))
    }

    func testCompletedSpotifyTrackPreservesItsSequenceOwner() {
        XCTAssertEqual(SpotifyStore.helperCompletionAction(
            isDirectPlaybackActive: true,
            isSpotifyPlaybackSuppressed: false,
            helperAdvancesWithUziqQueue: false
        ), .advanceHelperContext)
        XCTAssertEqual(SpotifyStore.helperCompletionAction(
            isDirectPlaybackActive: true,
            isSpotifyPlaybackSuppressed: false,
            helperAdvancesWithUziqQueue: true
        ), .advanceUziqQueue)
        XCTAssertEqual(SpotifyStore.helperCompletionAction(
            isDirectPlaybackActive: true,
            isSpotifyPlaybackSuppressed: true,
            helperAdvancesWithUziqQueue: false
        ), .stop)
    }

    func testDirectHelperIsPausedWhenAnotherPlaybackSourceTakesOver() {
        XCTAssertTrue(SpotifyStore.shouldPauseDirectHelper(
            supportsDirectControl: true,
            isSpotifyPlaybackSuppressed: false,
            isDirectPlaybackActive: true,
            isStartingPlayback: false,
            hasPendingItem: false
        ))
        XCTAssertTrue(SpotifyStore.shouldPauseDirectHelper(
            supportsDirectControl: true,
            isSpotifyPlaybackSuppressed: false,
            isDirectPlaybackActive: false,
            isStartingPlayback: true,
            hasPendingItem: true
        ))
        XCTAssertTrue(SpotifyStore.shouldPauseDirectHelper(
            supportsDirectControl: true,
            isSpotifyPlaybackSuppressed: true,
            isDirectPlaybackActive: true,
            isStartingPlayback: false,
            hasPendingItem: false
        ))
        XCTAssertFalse(SpotifyStore.shouldPauseDirectHelper(
            supportsDirectControl: false,
            isSpotifyPlaybackSuppressed: false,
            isDirectPlaybackActive: true,
            isStartingPlayback: false,
            hasPendingItem: false
        ))
        XCTAssertTrue(SpotifyStore.shouldResuppressHelperEvent(
            "playing",
            isSpotifyPlaybackSuppressed: true
        ))
        XCTAssertTrue(SpotifyStore.shouldResuppressHelperEvent(
            "track_changed",
            isSpotifyPlaybackSuppressed: true
        ))
        XCTAssertFalse(SpotifyStore.shouldResuppressHelperEvent(
            "paused",
            isSpotifyPlaybackSuppressed: true
        ))
        XCTAssertFalse(SpotifyStore.shouldResuppressHelperEvent(
            "playing",
            isSpotifyPlaybackSuppressed: false
        ))
    }

    func testPKCERefreshKeepsExistingRefreshTokenWhenSpotifyOmitsReplacement() throws {
        let response = #"{"access_token":"new-access","expires_in":3600}"#.data(using: .utf8)!
        let normalized = UziqSpotifyPKCEBackend.retainingRefreshToken(
            in: response,
            fallback: "existing-refresh"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: normalized) as? [String: Any])

        XCTAssertEqual(json["access_token"] as? String, "new-access")
        XCTAssertEqual(json["refresh_token"] as? String, "existing-refresh")
    }

    func testPKCERefreshPreservesRotatedRefreshToken() throws {
        let response = #"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.data(using: .utf8)!
        let normalized = UziqSpotifyPKCEBackend.retainingRefreshToken(
            in: response,
            fallback: "existing-refresh"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: normalized) as? [String: Any])

        XCTAssertEqual(json["refresh_token"] as? String, "rotated-refresh")
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
