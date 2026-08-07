# Uziq

Uziq is a modern macOS SwiftUI music player focused on large local libraries. It recursively scans persistent folder roots, reads embedded metadata, indexes titles/artists/albums with SQLite FTS5, and plays local audio through AVFoundation.

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
- AVQueuePlayer playback with queue controls
- Light/dark system appearance support

The external MusicBrainz/AcoustID and lyrics provider adapters are intentionally isolated for the next implementation slice. Bandcamp does not provide a general public catalog/streaming API; the app should use official integrations only and may link out to Bandcamp while that provider is researched.
