# Uziq

Uziq is a modern macOS SwiftUI music player for large local libraries, Bandcamp discovery, lightweight Spotify playback, and self-hosted Jellyfin music. It recursively scans persistent folder roots, reads embedded metadata, indexes titles/artists/albums with SQLite FTS5, and sends local, Bandcamp, and Jellyfin playback through an AVFoundation audio engine with a ten-band equalizer.

## Run

Open the repository in Xcode and run the `Uziq` executable target, or use:

```sh
swift run
```

The app targets macOS 15 or newer.

To build a normal, ad-hoc-signed macOS application with hardened runtime enabled, using `Images/logo.png` as its icon:

```sh
./Scripts/build-app.sh
open dist/Uziq.app
```

The application bundle is written to `dist/Uziq.app`. A Developer ID signature and notarization can be added later for public distribution.

To create family-distribution artifacts without an Apple signing certificate:

```sh
./Scripts/package-release.sh release
```

This creates a versioned DMG, ZIP, and SHA-256 checksum file in `dist/`. On the destination Mac, drag Uziq into Applications, then Control-click it and choose **Open** for the first launch. This one-time approval is required because an ad-hoc-signed app is not Apple-notarized.

## Playback controls

- `Space` or `F8`: play/pause
- `⌘←` / `⌘→`: previous/next queue item
- `⇧⌘P`: open Now Playing and the universal queue
- `⌥⌘S`: toggle shuffle
- `⌥⌘R`: cycle repeat off/all/one

Use a track or result's context menu to choose **Play Next** or **Add to Queue**. The queue, selected item, playback position, shuffle/repeat mode, and volume are restored between launches.

Uziq also publishes the current title, artist, album, artwork, duration, and playback state to macOS Now Playing. Control Center and compatible media keys can play, pause, seek, and move through the universal queue.

## Current foundation

- SwiftUI + Observation UI architecture
- Persistent security-scoped folder bookmarks
- Recursive audio scanning
- SQLite library and full-text search
- Embedded metadata, artwork, and lyrics extraction
- AVAudioEngine playback with queue controls, waveform seeking, and equalization
- Persistent universal queue with Play Next, reordering, shuffle, repeat, and session restoration
- macOS Now Playing and Control Center metadata, seeking, and transport controls
- Privacy-conscious diagnostics report export with a small rotating event log
- Bandcamp search, subscriptions, streaming, favorites, and expiring audio cache
- Spotify PKCE login, personal library, catalog search, and playback through Uziq's locally controlled librespot helper
- Jellyfin account login, music-library browsing, artwork, playlists, search, queued playback, and expiring audio cache
- Local / Bandcamp / Spotify / Jellyfin global-search scopes
- Light/dark system appearance support

## Spotify setup

Spotify playback requires a Premium account and two one-time browser logins:

1. Create an app in the Spotify Developer Dashboard.
2. Add `http://127.0.0.1:8989/callback` to its Redirect URIs.
3. Enter the app's Client ID under Uziq Settings → Spotify and connect the account. Uziq uses PKCE and does not need the client secret.
4. For `swift run`, build the helper once with `cargo build --manifest-path Helpers/uziq-librespot/Cargo.toml`. Packaged Uziq apps build and include it automatically.
5. Start the Spotify playback engine from Settings or the Spotify section. The helper opens its own login the first time and stores the reusable credential under Uziq's Application Support directory.

librespot is an unofficial, reverse-engineered Spotify client. Spotify may change its protocol, and its maintainers warn that its use may be forbidden by Spotify. Uziq's helper uses librespot 0.8.0 and a private stdin/stdout protocol for playback commands and events. This lets known Spotify URIs keep playing during Web API rate limits; catalog search and library refreshes still use Spotify's Web API. Uziq disables librespot's audio cache and only retains its authentication credential. SpotifyAPI is pinned to a reviewed revision for reproducible builds.

## Jellyfin setup

1. Open Uziq Settings → Jellyfin.
2. Enter the full server address, including `http://` or `https://` and its port.
3. Enter the Jellyfin username and password, then connect.

The password is used only for sign-in and is never stored. The access token is saved in the macOS Keychain. Uziq downloads the current track into an expiring local cache so AVFoundation can provide stable playback, waveform seeking, and equalization; it prefetches only the next queue item near the end of playback. Files unused for seven days are removed automatically.

## Packaging

Run `Scripts/build-app.sh release` to create `dist/Uziq.app`. The script builds and bundles `uziq-librespot`, its MIT license, the app icon, and runtime resources; verifies that the helper architecture matches Uziq; and ad-hoc signs the complete app and helper with hardened runtime enabled. Set `UZIQ_LIBRESPOT_PATH=/path/to/helper` only when testing a specific helper build.

Run `Scripts/package-release.sh release` to additionally create a compressed DMG, ZIP fallback, and checksum file. The DMG includes an Applications shortcut and first-launch instructions. The artifact filename records the Uziq version and supported architecture, such as `Uziq-1.0.0-macOS-arm64.dmg`.

For a family build that requires no Spotify developer configuration on the destination Mac, package the non-secret Client ID into the app:

```sh
UZIQ_SPOTIFY_CLIENT_ID=your_client_id ./Scripts/build-app.sh release
```

The Spotify developer app must include `http://127.0.0.1:8989/callback` as a Redirect URI. The first-run assistant then asks the recipient only to connect their Spotify account.
