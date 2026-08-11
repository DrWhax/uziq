import AppKit
import Combine
import Foundation
import Observation
import SpotifyWebAPI

extension SpotifyStore {
    nonisolated static func shouldPauseDirectHelper(
        supportsDirectControl: Bool,
        isSpotifyPlaybackSuppressed: Bool,
        isDirectPlaybackActive: Bool,
        isStartingPlayback: Bool,
        hasPendingItem: Bool
    ) -> Bool {
        // Treat provider handoff as idempotent. A late helper event can arrive
        // after suppression and leave the helper active while the store remains
        // marked suppressed; it still needs another pause command.
        _ = isSpotifyPlaybackSuppressed
        return supportsDirectControl &&
            (isDirectPlaybackActive || isStartingPlayback || hasPendingItem)
    }

    nonisolated static func shouldResuppressHelperEvent(
        _ event: String,
        isSpotifyPlaybackSuppressed: Bool
    ) -> Bool {
        isSpotifyPlaybackSuppressed && ["loading", "track_changed", "playing"].contains(event)
    }

    func suppressForNonSpotifyPlayback() {
        let pauseDirectHelper = Self.shouldPauseDirectHelper(
            supportsDirectControl: librespot.supportsDirectControl,
            isSpotifyPlaybackSuppressed: isSpotifyPlaybackSuppressed,
            isDirectPlaybackActive: librespot.isDirectPlaybackActive,
            isStartingPlayback: isStartingPlayback,
            hasPendingItem: helperPendingItem != nil
        )
        let pauseWebPlayback = !pauseDirectHelper && isUziqPlaybackActive

        // Send the transport command before suppression. `pause()` deliberately
        // ignores a suppressed helper, which previously allowed Spotify and a
        // newly selected local/streaming source to play at the same time.
        if pauseDirectHelper {
            _ = librespot.suppressPlayback()
        } else if pauseWebPlayback {
            pause()
        }
        playbackEngine?.endSpotifyPCMStream()

        playbackGeneration = UUID()
        isStartingPlayback = false
        playbackMessage = nil
        helperPendingItem = nil
        helperAdvancesWithUziqQueue = false
        isSpotifyPlaybackSuppressed = true
        playback = nil
    }

    nonisolated static func helperControlsPlaybackSequence(
        isDirectPlaybackActive: Bool,
        isSpotifyPlaybackSuppressed: Bool,
        helperAdvancesWithUziqQueue: Bool
    ) -> Bool {
        isDirectPlaybackActive && !isSpotifyPlaybackSuppressed && !helperAdvancesWithUziqQueue
    }

    nonisolated static func helperCompletionAction(
        isDirectPlaybackActive: Bool,
        isSpotifyPlaybackSuppressed: Bool,
        helperAdvancesWithUziqQueue: Bool
    ) -> SpotifyHelperCompletionAction {
        if helperAdvancesWithUziqQueue { return .advanceUziqQueue }
        if helperControlsPlaybackSequence(
            isDirectPlaybackActive: isDirectPlaybackActive,
            isSpotifyPlaybackSuppressed: isSpotifyPlaybackSuppressed,
            helperAdvancesWithUziqQueue: helperAdvancesWithUziqQueue
        ) {
            return .advanceHelperContext
        }
        return .stop
    }

    var helperControlsPlaybackSequence: Bool {
        Self.helperControlsPlaybackSequence(
            isDirectPlaybackActive: librespot.isDirectPlaybackActive,
            isSpotifyPlaybackSuppressed: isSpotifyPlaybackSuppressed,
            helperAdvancesWithUziqQueue: helperAdvancesWithUziqQueue
        )
    }

    var hasControllablePlayback: Bool {
        !isSpotifyPlaybackSuppressed &&
            (librespot.isDirectPlaybackActive || isUziqPlaybackActive)
    }

    var isPlaying: Bool {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed {
            return librespot.isDirectPlaybackPlaying
        }
        return playback?.isPlaying == true
    }

    func playDirectInput(using queue: PlaybackQueueStore) {
        guard let parsed = Self.directPlaybackItem(from: directPlaybackInput) else {
            error = "Paste a Spotify track, album, artist, or playlist link or URI."
            return
        }
        directPlaybackInput = parsed.uri
        // Keep every playback source on the shared queue path. Calling
        // `play(_:)` directly starts librespot successfully, but leaves the
        // bottom player without a current Spotify item to present or control.
        queue.replace(with: parsed)
    }

    nonisolated static func directPlaybackItem(from input: String) -> SpotifyCatalogItem? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let components: [String]
        if normalized.lowercased().hasPrefix("spotify:") {
            components = normalized.split(separator: ":").map(String.init)
        } else if let url = URL(string: normalized),
                  url.host?.lowercased() == "open.spotify.com" {
            let path = url.pathComponents.filter { $0 != "/" }
            guard let kindIndex = path.firstIndex(where: {
                ["track", "album", "artist", "playlist"].contains($0.lowercased())
            }), path.indices.contains(kindIndex + 1) else { return nil }
            components = ["spotify", path[kindIndex].lowercased(), path[kindIndex + 1]]
        } else {
            return nil
        }

        guard components.count == 3,
              components[0].lowercased() == "spotify",
              let kind = SpotifyItemKind(rawValue: components[1].lowercased()),
              !components[2].isEmpty,
              components[2].allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let uri = "spotify:\(kind.rawValue):\(components[2])"
        return SpotifyCatalogItem(
            id: components[2],
            name: "Spotify \(kind.title)",
            subtitle: "Loading metadata…",
            uri: uri,
            kind: kind,
            artworkURL: nil,
            durationMS: nil,
            itemCount: nil
        )
    }

    func playCollection(_ collection: SpotifyCatalogItem) {
        if collection.id == Self.likedSongsID {
            playLikedSongs(startingAt: nil)
        } else {
            play(collection)
        }
    }

    func startPlaybackEngine() {
        guard let playbackEngine else {
            error = "The audio engine is not ready yet."
            return
        }
        librespot.start(using: playbackEngine)
    }

    func play(_ item: SpotifyCatalogItem) {
        guard item.kind != .artist || item.uri.hasPrefix("spotify:artist:") else { return }
        if item.kind == .track {
            if startDirectHelperPlayback(item, queueManaged: true, command: {
                librespot.loadTracks([item.uri], offsetURI: item.uri)
            }) { return }
        } else if startDirectHelperPlayback(item, queueManaged: false, command: {
            librespot.loadContext(item.uri)
        }) {
            return
        }
        let request: PlaybackRequest
        if item.kind == .track {
            request = PlaybackRequest(item.uri)
        } else {
            request = PlaybackRequest(context: .contextURI(item.uri), offset: nil)
        }
        startPlayback(request)
    }

    func play(_ track: SpotifyCatalogItem, in playlist: SpotifyCatalogItem) {
        if playlist.id == Self.likedSongsID {
            playLikedSongs(startingAt: track)
            return
        }
        guard track.kind == .track,
              playlist.kind == .playlist,
              !track.uri.isEmpty,
              !playlist.uri.isEmpty else {
            play(track)
            return
        }
        if startDirectHelperPlayback(track, queueManaged: false, command: {
            librespot.loadContext(playlist.uri, offsetURI: track.uri)
        }) { return }
        startPlayback(Self.playlistPlaybackRequest(trackURI: track.uri, playlistURI: playlist.uri))
    }

    static func playlistPlaybackRequest(trackURI: String, playlistURI: String) -> PlaybackRequest {
        PlaybackRequest(
            context: .contextURI(playlistURI),
            offset: .uri(trackURI)
        )
    }

    func reconnectForPersonalLibrary() {
        api.authorizationManager.deauthorize()
        SpotifyKeychain.remove(authorizationKey)
        isAuthorized = false
        needsPersonalLibraryPermission = false
        DispatchQueue.main.async { [weak self] in self?.logIn() }
    }

    func startPlayback(_ request: PlaybackRequest) {
        guard isAuthorized else {
            error = "Connect your Spotify account before playing."
            return
        }
        guard spotifyRequestsAllowed() else { return }
        guard let playbackEngine else {
            error = "The audio engine is not ready yet."
            return
        }
        isSpotifyPlaybackSuppressed = false
        playbackEngine.stopForExternalSpotifyPlayback()
        librespot.start(using: playbackEngine)
        isStartingPlayback = true
        playbackMessage = librespot.status == .ready
            ? "Connecting to the Uziq Spotify device…"
            : "Starting the Uziq Spotify device…"
        error = nil
        let generation = UUID()
        playbackGeneration = generation
        play(request, attemptsRemaining: 8, generation: generation)
    }

    func togglePlayback() {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed {
            if librespot.togglePlayback() {
                updateHelperPlayback(
                    position: playback?.effectiveProgress(at: .now),
                    isPlaying: librespot.isDirectPlaybackPlaying
                )
            }
            return
        }
        guard isAuthorized else { return }
        playback?.isPlaying == true ? pause() : resume()
    }

    func pause() {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed, librespot.pause() {
            updateHelperPlayback(position: playback?.effectiveProgress(at: .now), isPlaying: false)
            return
        }
        performPlayerCommand(api.pausePlayback(deviceId: uziqDeviceID))
    }

    func resume() {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed, librespot.play() {
            updateHelperPlayback(position: playback?.effectiveProgress(at: .now), isPlaying: true)
            return
        }
        performPlayerCommand(api.resumePlayback(deviceId: uziqDeviceID))
    }

    func next() {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed, librespot.next() { return }
        performPlayerCommand(api.skipToNext(deviceId: uziqDeviceID))
    }

    func previous() {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed, librespot.previous() { return }
        performPlayerCommand(api.skipToPrevious(deviceId: uziqDeviceID))
    }

    func seek(to seconds: Double) {
        if librespot.isDirectPlaybackActive, !isSpotifyPlaybackSuppressed, librespot.seek(to: seconds) {
            updateHelperPlayback(position: seconds, isPlaying: playback?.isPlaying ?? true)
            return
        }
        performPlayerCommand(
            api.seekToPosition(max(0, Int(seconds * 1_000)), deviceId: uziqDeviceID)
        )
    }

    func setVolume(_ normalizedVolume: Float) {
        desiredVolume = min(1, max(0, normalizedVolume))
        if librespot.isDirectPlaybackActive, librespot.setVolume(desiredVolume) { return }
        guard isAuthorized, isUziqPlaybackActive, spotifyRequestsAllowed(reportError: false) else { return }
        api.setVolume(to: Int((desiredVolume * 100).rounded()), deviceId: uziqDeviceID)
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                if case .failure(let error) = completion { self?.handleAPIError(error) }
            } receiveValue: { }
    }

    func refreshPlayback() {
        guard isAuthorized,
              !(librespot.isDirectPlaybackActive && !isSpotifyPlaybackSuppressed),
              playbackRefreshCancellable == nil,
              spotifyRequestsAllowed(reportError: false) else { return }
        playbackRefreshCancellable = api.currentPlayback()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                // Defer release so a synchronously failing publisher cannot be
                // assigned back into the property after its completion runs.
                DispatchQueue.main.async { [weak self] in
                    self?.playbackRefreshCancellable = nil
                }
                if case .failure(let error) = completion {
                    self?.handleAPIError(error)
                }
            } receiveValue: { [weak self] context in
                self?.updatePlayback(context)
            }
    }

    func playLikedSongs(startingAt track: SpotifyCatalogItem?) {
        guard !likedSongs.isEmpty else {
            error = "Your Liked Songs collection is still loading."
            return
        }
        let startIndex = track.flatMap { likedSongs.firstIndex(of: $0) } ?? 0
        let uris = likedSongs[startIndex...]
            .prefix(100)
            .map(\.uri)
            .filter { !$0.isEmpty }
        guard !uris.isEmpty else { return }
        let pendingItem = track ?? likedSongs[startIndex]
        if startDirectHelperPlayback(pendingItem, queueManaged: false, command: {
            librespot.loadTracks(uris, offsetURI: pendingItem.uri)
        }) { return }
        startPlayback(PlaybackRequest(context: .uris(uris), offset: nil))
    }

    func play(_ request: PlaybackRequest, attemptsRemaining: Int, generation: UUID) {
        guard playbackGeneration == generation, spotifyRequestsAllowed() else {
            isStartingPlayback = false
            playbackMessage = nil
            return
        }
        if let uziqDeviceID {
            sendPlaybackRequest(request, deviceID: uziqDeviceID, generation: generation)
            return
        }
        api.availableDevices()
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self else { return }
                if case .failure(let error) = completion {
                    isStartingPlayback = false
                    playbackMessage = nil
                    handleAPIError(error, prefix: "Spotify could not find the Uziq player")
                }
            } receiveValue: { [weak self] devices in
                guard let self else { return }
                guard playbackGeneration == generation else { return }
                availableDeviceNames = devices.map(\.name)
                if let device = devices.first(where: {
                    $0.name.caseInsensitiveCompare("Uziq") == .orderedSame && !$0.isRestricted
                }), let deviceID = device.id {
                    uziqDeviceID = deviceID
                    sendPlaybackRequest(request, deviceID: deviceID, generation: generation)
                } else if attemptsRemaining > 0, librespot.status.isRunning {
                    playbackMessage = "Waiting for Spotify to discover the Uziq device…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard self?.playbackGeneration == generation else { return }
                        self?.play(request, attemptsRemaining: attemptsRemaining - 1, generation: generation)
                    }
                } else {
                    isStartingPlayback = false
                    playbackMessage = nil
                    if availableDeviceNames.isEmpty {
                        error = "Spotify cannot see any playback devices. Make sure librespot and the Web API are signed into the same Spotify account, then restart the playback engine."
                    } else {
                        error = "Spotify can see \(availableDeviceNames.joined(separator: ", ")), but not an unrestricted Uziq device. Make sure both Spotify connections use the same account, then restart the playback engine."
                    }
                }
            }
    }

    func sendPlaybackRequest(
        _ request: PlaybackRequest,
        deviceID: String,
        generation: UUID
    ) {
        guard playbackGeneration == generation, spotifyRequestsAllowed() else {
            isStartingPlayback = false
            playbackMessage = nil
            return
        }
        playbackMessage = "Starting playback in Uziq…"
        api.play(request, deviceId: deviceID)
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self, playbackGeneration == generation else { return }
                isStartingPlayback = false
                playbackMessage = nil
                if case .failure(let error) = completion {
                    handleAPIError(error, prefix: "Spotify could not start playback")
                }
            } receiveValue: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.refreshPlayback()
                    self.setVolume(self.desiredVolume)
                }
            }
    }

    func performPlayerCommand(_ publisher: AnyPublisher<Void, Error>) {
        guard spotifyRequestsAllowed() else { return }
        error = nil
        publisher
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                if case .failure(let error) = completion { self?.handleAPIError(error) }
            } receiveValue: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self?.refreshPlayback() }
            }
    }

    func playbackTimerFired() {
        guard isAuthorized,
              !(librespot.isDirectPlaybackActive && !isSpotifyPlaybackSuppressed),
              (isStartingPlayback || isUziqPlaybackActive),
              spotifyRequestsAllowed(reportError: false) else { return }
        playbackTick += 1
        if playbackTick.isMultiple(of: 30) { refreshPlayback() }
    }

    func updatePlayback(_ context: CurrentlyPlayingContext?) {
        guard !isSpotifyPlaybackSuppressed else {
            playback = nil
            return
        }
        guard let context, let item = context.item else {
            playback = nil
            return
        }
        if context.device.name.caseInsensitiveCompare("Uziq") == .orderedSame {
            uziqDeviceID = context.device.id
        }
        switch item {
        case .track(let track):
            playback = SpotifyPlaybackSnapshot(
                itemID: track.id ?? track.uri ?? UUID().uuidString,
                title: track.name,
                artist: track.artists?.map(\.name).joined(separator: ", ") ?? "Unknown Artist",
                album: track.album?.name ?? "",
                artworkURL: track.album?.images?.first?.url,
                duration: Double(track.durationMS ?? 0) / 1_000,
                progress: Double(context.progressMS ?? 0) / 1_000,
                isPlaying: context.isPlaying,
                deviceName: context.device.name,
                observedAt: Date()
            )
        case .episode(let episode):
            playback = SpotifyPlaybackSnapshot(
                itemID: episode.id ?? episode.uri ?? UUID().uuidString,
                title: episode.name ?? "Spotify episode",
                artist: episode.show?.name ?? "Spotify",
                album: episode.show?.name ?? "",
                artworkURL: episode.images?.first?.url,
                duration: Double(episode.durationMS ?? 0) / 1_000,
                progress: Double(context.progressMS ?? 0) / 1_000,
                isPlaying: context.isPlaying,
                deviceName: context.device.name,
                observedAt: Date()
            )
        }
    }

    @discardableResult
    func startDirectHelperPlayback(
        _ item: SpotifyCatalogItem,
        queueManaged: Bool,
        command: () -> Bool
    ) -> Bool {
        guard librespot.supportsDirectControl, let playbackEngine else { return false }
        isSpotifyPlaybackSuppressed = false
        playbackEngine.stopForExternalSpotifyPlayback()
        playbackGeneration = UUID()
        helperPendingItem = item
        helperAdvancesWithUziqQueue = queueManaged
        isStartingPlayback = true
        playbackMessage = librespot.status == .ready
            ? "Starting playback through Uziq…"
            : "Starting the Uziq Spotify helper…"
        error = nil
        playback = SpotifyPlaybackSnapshot(
            itemID: item.id,
            title: item.name,
            artist: item.subtitle,
            album: item.kind == .album ? item.name : "",
            artworkURL: item.artworkURL,
            duration: Double(item.durationMS ?? 0) / 1_000,
            progress: 0,
            isPlaying: false,
            deviceName: "Uziq",
            observedAt: .now
        )
        guard command() else {
            isStartingPlayback = false
            playbackMessage = nil
            helperPendingItem = nil
            helperAdvancesWithUziqQueue = false
            return false
        }
        _ = librespot.setVolume(desiredVolume)
        return true
    }

    func handleLibrespotEvent(_ event: LibrespotIPCEvent) {
        if Self.shouldResuppressHelperEvent(
            event.event,
            isSpotifyPlaybackSuppressed: isSpotifyPlaybackSuppressed
        ) {
            // Random/context playback can publish a queued transition after a
            // Jellyfin, Bandcamp, or local selection has taken over. Reassert
            // the pause instead of allowing that stale transition to restart.
            _ = librespot.suppressPlayback()
            playbackEngine?.endSpotifyPCMStream()
            return
        }
        switch event.event {
        case "status":
            if event.state == "ready", isStartingPlayback {
                playbackMessage = "Starting playback through Uziq…"
            }
        case "track_changed":
            let fallback = helperPendingItem
            let uri = event.uri ?? fallback?.uri ?? ""
            let identifier = uri.split(separator: ":").last.map(String.init) ?? fallback?.id ?? uri
            playback = SpotifyPlaybackSnapshot(
                itemID: identifier,
                title: event.title ?? fallback?.name ?? "Spotify",
                artist: event.artist ?? fallback?.subtitle ?? "Unknown Artist",
                album: event.album ?? "",
                artworkURL: event.artworkURL ?? fallback?.artworkURL,
                duration: Double(event.durationMS ?? UInt32(max(0, fallback?.durationMS ?? 0))) / 1_000,
                progress: 0,
                isPlaying: playback?.isPlaying ?? false,
                deviceName: "Uziq",
                observedAt: .now
            )
            isStartingPlayback = false
            playbackMessage = nil
        case "loading":
            isStartingPlayback = true
            playbackMessage = "Loading Spotify audio…"
            updateHelperPlayback(
                uri: event.uri,
                position: event.positionMS.map { Double($0) / 1_000 },
                isPlaying: false
            )
        case "playing":
            isStartingPlayback = false
            playbackMessage = nil
            updateHelperPlayback(
                uri: event.uri,
                position: event.positionMS.map { Double($0) / 1_000 },
                isPlaying: true
            )
        case "paused":
            updateHelperPlayback(
                uri: event.uri,
                position: event.positionMS.map { Double($0) / 1_000 },
                isPlaying: false
            )
        case "position", "seeked":
            updateHelperPlayback(
                uri: event.uri,
                position: event.positionMS.map { Double($0) / 1_000 },
                isPlaying: playback?.isPlaying ?? true
            )
        case "end_of_track":
            updateHelperPlayback(
                uri: event.uri,
                position: playback?.duration,
                isPlaying: false
            )
            advanceAfterHelperTrackCompletion()
        case "unavailable":
            isStartingPlayback = false
            playbackMessage = nil
            error = "Spotify skipped a track that the Uziq helper could not stream."
            advanceAfterHelperTrackCompletion()
        case "error":
            isStartingPlayback = false
            playbackMessage = nil
            if let message = event.message { error = message }
        default:
            break
        }
    }

    private func advanceAfterHelperTrackCompletion() {
        let action = Self.helperCompletionAction(
            isDirectPlaybackActive: librespot.isDirectPlaybackActive,
            isSpotifyPlaybackSuppressed: isSpotifyPlaybackSuppressed,
            helperAdvancesWithUziqQueue: helperAdvancesWithUziqQueue
        )
        helperPendingItem = nil
        switch action {
        case .advanceUziqQueue:
            // Keep queue ownership set until PlaybackQueueStore handles the
            // asynchronous completion notification. Clearing it here makes
            // `next()` mistake a multi-track Uziq queue for a helper context.
            NotificationCenter.default.post(name: .uziqPlaybackItemFinished, object: nil)
        case .advanceHelperContext:
            if !librespot.next() {
                error = "Spotify finished the track but could not advance the current context."
            }
        case .stop:
            helperAdvancesWithUziqQueue = false
        }
    }

    func updateHelperPlayback(
        uri: String? = nil,
        position: Double? = nil,
        isPlaying: Bool
    ) {
        guard let current = playback else { return }
        let eventIdentifier = uri?
            .split(separator: ":")
            .last
            .map(String.init)
        guard eventIdentifier == nil || eventIdentifier == current.itemID else { return }
        let identifier = eventIdentifier ?? current.itemID
        playback = SpotifyPlaybackSnapshot(
            itemID: identifier,
            title: current.title,
            artist: current.artist,
            album: current.album,
            artworkURL: current.artworkURL,
            duration: current.duration,
            progress: min(current.duration > 0 ? current.duration : .greatestFiniteMagnitude,
                          max(0, position ?? current.effectiveProgress(at: .now))),
            isPlaying: isPlaying,
            deviceName: "Uziq",
            observedAt: .now
        )
    }

    @discardableResult
    func spotifyRequestsAllowed(reportError: Bool = true) -> Bool {
        if let rateLimitedUntil {
            if rateLimitedUntil > .now {
                if reportError, let rateLimitMessage { error = rateLimitMessage }
                return false
            }
            self.rateLimitedUntil = nil
            UserDefaults.standard.removeObject(forKey: rateLimitUntilKey)
        }
        return true
    }

    @discardableResult
    func handleAPIError(_ apiError: Error, prefix: String? = nil) -> String {
        let message: String
        if let rateLimitedError = apiError as? RateLimitedError {
            let deadline = Self.rateLimitDeadline(
                now: .now,
                current: rateLimitedUntil,
                retryAfter: rateLimitedError.retryAfter
            )
            rateLimitedUntil = deadline
            UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: rateLimitUntilKey)
            playbackRefreshCancellable?.cancel()
            playbackRefreshCancellable = nil
            message = rateLimitMessage ?? "Spotify API requests are temporarily paused."
        } else if let rateLimitedError = apiError as? SpotifyRateLimitResponseError {
            let deadline = Self.rateLimitDeadline(
                now: .now,
                current: rateLimitedUntil,
                retryAfter: rateLimitedError.retryAfter
            )
            rateLimitedUntil = deadline
            UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: rateLimitUntilKey)
            playbackRefreshCancellable?.cancel()
            playbackRefreshCancellable = nil
            message = rateLimitMessage ?? "Spotify API requests are temporarily paused."
        } else {
            message = apiError.localizedDescription
        }
        let presentedMessage = prefix.map { "\($0): \(message)" } ?? message
        error = presentedMessage
        return presentedMessage
    }

}
