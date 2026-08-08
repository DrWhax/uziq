# Uziq

Uziq is a modern macOS SwiftUI music player for large local libraries, Bandcamp discovery, lightweight Spotify playback, and self-hosted Jellyfin music. It recursively scans persistent folder roots, reads embedded metadata, indexes titles/artists/albums with SQLite FTS5, and sends local, Bandcamp, and Jellyfin playback through an AVFoundation audio engine with a ten-band equalizer.

## Run

Open the repository in Xcode and run the `Uziq` executable target, or use:

```sh
swift run
```

The app targets macOS 15 or newer.

To build a normal, ad-hoc-signed macOS application using `Images/logo.png` as its icon:

```sh
./Scripts/build-app.sh
open dist/Uziq.app
```

The application bundle is written to `dist/Uziq.app`. A Developer ID signature and notarization can be added later for public distribution.

## Playback controls

- `Space` or `F8`: play/pause
- `⌘←` / `⌘→`: previous/next queue item
- `⇧⌘P`: open Now Playing and the universal queue
- `⌥⌘S`: toggle shuffle
- `⌥⌘R`: cycle repeat off/all/one

Use a track or result's context menu to choose **Play Next** or **Add to Queue**. The queue, selected item, playback position, shuffle/repeat mode, and volume are restored between launches.

## Current foundation

- SwiftUI + Observation UI architecture
- Persistent security-scoped folder bookmarks
- Recursive audio scanning
- SQLite library and full-text search
- Embedded metadata, artwork, and lyrics extraction
- AVAudioEngine playback with queue controls, waveform seeking, and equalization
- Persistent universal queue with Play Next, reordering, shuffle, repeat, and session restoration
- Bandcamp search, subscriptions, streaming, favorites, and expiring audio cache
- Spotify PKCE login, personal library, catalog search, and playback through librespot's native CoreAudio output
- Jellyfin account login, music-library browsing, artwork, playlists, search, queued playback, and expiring audio cache
- Local / Bandcamp / Spotify / Jellyfin global-search scopes
- Light/dark system appearance support

## Spotify setup

Spotify playback requires a Premium account and two one-time browser logins:

1. Create an app in the Spotify Developer Dashboard.
2. Add `http://127.0.0.1:8989/callback` to its Redirect URIs.
3. Enter the app's Client ID under Uziq Settings → Spotify and connect the account. Uziq uses PKCE and does not need the client secret.
4. When developing with `swift run`, install the playback helper with `cargo install librespot --version 0.8.0 --locked`. Packaged Uziq apps include it automatically.
5. Start the Spotify playback engine from Settings or the Spotify section. librespot opens its own login the first time and stores the reusable credential under Uziq's Application Support directory.

librespot is an unofficial, reverse-engineered Spotify client. Spotify may change its protocol, and its maintainers warn that its use may be forbidden by Spotify. Uziq disables librespot's audio cache and only retains its authentication credential. SpotifyAPI is pinned to a reviewed revision for reproducible builds.

## Jellyfin setup

1. Open Uziq Settings → Jellyfin.
2. Enter the full server address, including `http://` or `https://` and its port.
3. Enter the Jellyfin username and password, then connect.

The password is used only for sign-in and is never stored. The access token is saved in the macOS Keychain. Uziq downloads the current track into an expiring local cache so AVFoundation can provide stable playback, waveform seeking, and equalization; it prefetches only the next queue item near the end of playback. Files unused for seven days are removed automatically.

## Packaging

Run `Scripts/build-app.sh release` to create `dist/Uziq.app`. The script bundles the installed librespot executable and its MIT license, verifies that its architecture matches Uziq, and signs the complete app bundle. Set `UZIQ_LIBRESPOT_PATH=/path/to/librespot` to package a specific build.
