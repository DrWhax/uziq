import JellyfinAPI
import SpotifyWebAPI
import SwiftUI
import XCTest
@testable import Uziq

final class PlayerLibraryNavigationTests: XCTestCase {
    @MainActor
    func testSpotifyResolvesAlbumAndPrimaryArtistFromActualTrackMetadata() throws {
        let track = SpotifyWebAPI.Track(
            name: "Playing Track",
            album: Album(name: "Album", uri: "spotify:album:actual-album", id: "actual-album"),
            artists: [Artist(name: "Primary", uri: "spotify:artist:primary", id: "primary"),
                      Artist(name: "Guest", uri: "spotify:artist:guest", id: "guest")],
            uri: "spotify:track:actual-track", id: "actual-track", isLocal: false, isExplicit: false
        )
        XCTAssertEqual(try SpotifyStore.playerLibraryDestination(.album, track: track).uri, "spotify:album:actual-album")
        XCTAssertEqual(try SpotifyStore.playerLibraryDestination(.artist, track: track).uri, "spotify:artist:primary")
        let missing = SpotifyWebAPI.Track(name: "Unavailable", isLocal: false, isExplicit: false)
        XCTAssertThrowsError(try SpotifyStore.playerLibraryDestination(.album, track: missing))
        XCTAssertThrowsError(try SpotifyStore.playerLibraryDestination(.artist, track: missing))
        let noURI = SpotifyWebAPI.Track(name: "No URI", album: Album(name: "Album"),
                                       artists: [Artist(name: "Artist")], isLocal: true, isExplicit: false)
        XCTAssertThrowsError(try SpotifyStore.playerLibraryDestination(.album, track: noURI))
        XCTAssertThrowsError(try SpotifyStore.playerLibraryDestination(.artist, track: noURI))
    }

    func testLocalDestinationsUseTrackIdentityNotAlbumTitleOrAlbumArtist() {
        let first = track("first", artist: "Performer", albumArtist: "Compilation")
        let second = track("second", artist: "Other Artist", albumArtist: "Other Artist")
        let snapshot = LocalLibraryBrowseSnapshot.grouped([first, second])
        let album = snapshot.albums.first { $0.tracks.contains(first) }!
        XCTAssertEqual(PlayerLibraryTarget.album.localRoute(trackID: first.id, snapshot: snapshot), .album(album.id))
        XCTAssertEqual(PlayerLibraryTarget.artist.localRoute(trackID: first.id, snapshot: snapshot), .artist("Performer"))
        XCTAssertNotEqual(PlayerLibraryTarget.album.localRoute(trackID: second.id, snapshot: snapshot), .album(album.id))
        XCTAssertNil(PlayerLibraryTarget.album.localRoute(trackID: "removed-track", snapshot: snapshot))
        XCTAssertNil(PlayerLibraryTarget.artist.localRoute(trackID: "removed-track", snapshot: snapshot))
    }

    func testSplitReleaseUsesExistingGroupedAlbumIdentity() {
        let first = track("first", album: "Album")
        let second = track("second", album: "Album / Bonus")
        let snapshot = LocalLibraryBrowseSnapshot.grouped([first, second])
        XCTAssertEqual(snapshot.albums.count, 1)
        XCTAssertEqual(PlayerLibraryTarget.album.localRoute(trackID: second.id, snapshot: snapshot), .album(snapshot.albums[0].id))
    }

    @MainActor
    func testJumpReplacesOnlyDestinationPathAndPreservesSearchAndOtherNavigation() {
        let state = BrowseState()
        state.paths[.albums] = NavigationPath([LocalBrowseRoute.album("old")])
        state.paths[.artists] = NavigationPath([LocalBrowseRoute.artist("artist"), .album("nested")])
        state.filters[.albums] = "unrelated search"
        state.offsets["albums"] = CGPoint(x: 0, y: 500)
        state.show(LocalBrowseRoute.album("new"), in: .albums)
        XCTAssertEqual(state.paths[.albums], NavigationPath([LocalBrowseRoute.album("new")]))
        XCTAssertEqual(state.paths[.artists]?.count, 2)
        XCTAssertEqual(state.filters[.albums], "unrelated search")
        XCTAssertEqual(state.offsets["albums"]?.y, 500)
    }

    func testJellyfinUsesRelationshipIDsAndDoesNotGuessFromNames() throws {
        let item = try XCTUnwrap(JellyfinCatalogItem(dto: BaseItemDto(
            album: "Same Name", albumID: "album-id",
            artistItems: [NameIDPair(id: "artist-id", name: "Artist")],
            id: "track-id", name: "Track", type: .audio
        )))
        XCTAssertEqual(PlayerLibraryTarget.album.jellyfinID(for: item), "album-id")
        XCTAssertEqual(PlayerLibraryTarget.artist.jellyfinID(for: item), "artist-id")
        let missing = try XCTUnwrap(JellyfinCatalogItem(dto: BaseItemDto(
            album: "Same Name", artists: ["Artist"], id: "missing", name: "Track", type: .audio
        )))
        XCTAssertNil(PlayerLibraryTarget.album.jellyfinID(for: missing))
        XCTAssertNil(PlayerLibraryTarget.artist.jellyfinID(for: missing))
    }

    func testBandcampArtistUsesCanonicalHomepageAndStripsQuery() throws {
        let release = BandcampResult(id: "release", title: "Album", artist: "Artist",
                                     url: URL(string: "https://artist.bandcamp.com/album/album?from=search#track")!, type: "a", bandID: 42)
        let artist = try XCTUnwrap(PlayerLibraryTarget.bandcampArtist(for: release))
        XCTAssertEqual(artist.url.absoluteString, "https://artist.bandcamp.com")
        XCTAssertEqual(artist.bandID, 42)
        XCTAssertEqual(artist.type, "b")
        for host in ["bandcamp.com", "www.bandcamp.com", "notbandcamp.com", "artist.bandcamp.com.example.org"] {
            let unknown = BandcampResult(id: "unknown", title: "Track", artist: "Artist", url: URL(string: "https://\(host)/track/song")!)
            XCTAssertNil(PlayerLibraryTarget.bandcampArtist(for: unknown))
        }
    }

    private func track(_ id: String, artist: String = "Artist", albumArtist: String = "Artist", album: String = "Same Album") -> Uziq.Track {
        Uziq.Track(id: id, url: URL(fileURLWithPath: "/tmp/\(id).flac"), fileName: id, title: id,
              artist: artist, albumArtist: albumArtist, album: album, genre: "", year: "",
              trackNumber: 1, discNumber: 1, duration: 180, codec: "FLAC", bitrate: nil,
              sampleRate: 44_100, artworkData: nil, lyrics: nil, musicBrainzRecordingID: nil,
              musicBrainzReleaseID: nil, acoustID: nil, addedAt: .now, modifiedAt: .now,
              isFavorite: false, playCount: 0)
    }
}
