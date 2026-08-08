# Uziq

Uziq is a modern macOS SwiftUI music player for large local libraries, Bandcamp discovery, and lightweight Spotify playback. It recursively scans persistent folder roots, reads embedded metadata, indexes titles/artists/albums with SQLite FTS5, and sends playback through an AVFoundation audio engine with a ten-band equalizer.

## Run

Open the repository in Xcode and run the `Uziq` executable target, or use:

```sh
swift run
```

The app targets macOS 15 or newer.

## Current foundation

- SwiftUI + Observation UI architecture
- Persistent security-scoped folder bookmarks
- Recursive audio scanning
- SQLite library and full-text search
- Embedded metadata, artwork, and lyrics extraction
- AVAudioEngine playback with queue controls, waveform seeking, and equalization
- Bandcamp search, subscriptions, streaming, favorites, and expiring audio cache
- Spotify PKCE login, personal library, catalog search, and playback through librespot's native CoreAudio output
- Local / Bandcamp / Spotify global-search scopes
- Light/dark system appearance support

## Spotify setup

Spotify playback requires a Premium account and two one-time browser logins:

1. Create an app in the Spotify Developer Dashboard.
2. Add `http://127.0.0.1:8989/callback` to its Redirect URIs.
3. Enter the app's Client ID under Uziq Settings → Spotify and connect the account. Uziq uses PKCE and does not need the client secret.
4. Install the playback helper with `cargo install librespot --version 0.8.0 --locked`.
5. Start the Spotify playback engine from Settings or the Spotify section. librespot opens its own login the first time and stores the reusable credential under Uziq's Application Support directory.

librespot is an unofficial, reverse-engineered Spotify client. Spotify may change its protocol, and its maintainers warn that its use may be forbidden by Spotify. Uziq disables librespot's audio cache and only retains its authentication credential. SpotifyAPI is pinned to a reviewed revision for reproducible builds.
