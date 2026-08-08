import AppKit
import Combine
import Foundation
import Observation
import SpotifyWebAPI

extension SpotifyStore {
    func completeLogin(_ callbackURL: URL) {
        guard let codeVerifier, let authorizationState else {
            error = "Spotify returned a login response after the authorization session expired."
            return
        }
        api.authorizationManager.requestAccessAndRefreshTokens(
            redirectURIWithQuery: callbackURL,
            codeVerifier: codeVerifier,
            state: authorizationState
        )
        .receive(on: DispatchQueue.main)
        .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
            guard let self else { return }
            self.codeVerifier = nil
            self.authorizationState = nil
            if case .failure(let error) = completion { self.error = error.localizedDescription }
        } receiveValue: { [weak self] in
            self?.isAuthorized = true
            self?.loadAccount()
        }
    }

    func rebuildAPI(clientID: String) {
        playbackRefreshCancellable?.cancel()
        playbackRefreshCancellable = nil
        accountLoadCancellable?.cancel()
        accountLoadCancellable = nil
        isLoadingAccount = false
        isLoading = false
        oneShotSubscriptions.cancelAll()
        persistentCancellables.removeAll()
        api = SpotifyAPI(
            authorizationManager: UziqSpotifyAuthorizationManager(
                backend: UziqSpotifyPKCEBackend(clientId: clientID)
            )
        )
        isAuthorized = false
        profileName = nil
        playlists = []
        likedSongs = []
        likedSongsTotal = 0
        topArtists = []
        librarySnapshotDate = nil
        libraryCache.remove()
        clearSearch()
        configureAPISubscriptions()
        restoreAuthorization()
    }

    func configureAPISubscriptions() {
        api.authorizationManagerDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                isAuthorized = api.authorizationManager.isAuthorized()
                needsPersonalLibraryPermission = isAuthorized &&
                    !api.authorizationManager.isAuthorized(for: requiredScopes)
                if let data = try? JSONEncoder().encode(api.authorizationManager) {
                    do {
                        try SpotifyKeychain.write(data, account: authorizationKey)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .store(in: &persistentCancellables)
        api.authorizationManagerDidDeauthorize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                SpotifyKeychain.remove(authorizationKey)
                isAuthorized = false
            }
            .store(in: &persistentCancellables)
    }

    func restoreAuthorization() {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = SpotifyKeychain.read(authorizationKey),
              let manager = try? JSONDecoder().decode(UziqSpotifyAuthorizationManager.self, from: data),
              manager.clientId == clientID.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        api.authorizationManager = manager
        isAuthorized = manager.isAuthorized()
        needsPersonalLibraryPermission = isAuthorized && !manager.isAuthorized(for: requiredScopes)
        if isAuthorized {
            loadAccount()
        } else if manager.refreshToken != nil {
            refreshRestoredAuthorization(using: manager)
        }
    }

    func refreshRestoredAuthorization(using manager: UziqSpotifyAuthorizationManager) {
        isLoading = true
        error = nil
        manager.refreshTokens(onlyIfExpired: true)
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self else { return }
                if case .failure(let error) = completion {
                    isLoading = false
                    isAuthorized = false
                    self.error = "Could not refresh the Spotify session: \(error.localizedDescription)"
                }
            } receiveValue: { [weak self] in
                guard let self else { return }
                isLoading = false
                isAuthorized = manager.isAuthorized()
                needsPersonalLibraryPermission = isAuthorized && !manager.isAuthorized(for: requiredScopes)
                if isAuthorized { loadAccount() }
            }
    }

    func loadPersonalLibrary() {
        guard spotifyRequestsAllowed() else { return }
        personalLibraryTracksFinished = false
        personalLibraryArtistsFinished = false
        loadSavedTracks(offset: 0, accumulated: [])
        api.currentUserTopArtists(.mediumTerm, offset: 0, limit: 12)
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self else { return }
                if case .failure(let error) = completion {
                    handleAPIError(error)
                    personalLibraryArtistsFinished = true
                    finishPersonalLibraryLoadingIfReady()
                }
            } receiveValue: { [weak self] page in
                guard let self else { return }
                topArtists = page.items.map(Self.catalogItem)
                personalLibraryArtistsFinished = true
                finishPersonalLibraryLoadingIfReady()
            }
    }

    func finishPersonalLibraryLoadingIfReady() {
        guard personalLibraryTracksFinished && personalLibraryArtistsFinished else { return }
        persistLibrarySnapshot(markFresh: !isRateLimited)
    }

    func persistLibrarySnapshot(markFresh: Bool) {
        let savedAt = markFresh ? Date.now : (librarySnapshotDate ?? .distantPast)
        if markFresh { librarySnapshotDate = savedAt }
        let snapshot = SpotifyLibrarySnapshot(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            savedAt: savedAt,
            profileName: profileName,
            playlists: playlists,
            likedSongs: likedSongs,
            likedSongsTotal: likedSongsTotal,
            topArtists: topArtists
        )
        let libraryCache = libraryCache
        Task.detached(priority: .utility) {
            try? libraryCache.save(snapshot)
        }
    }

    func loadSavedTracks(offset: Int, accumulated: [SpotifyCatalogItem]) {
        guard spotifyRequestsAllowed(reportError: offset == 0) else {
            personalLibraryTracksFinished = true
            finishPersonalLibraryLoadingIfReady()
            return
        }
        api.currentUserSavedTracks(limit: 50, offset: offset)
            .receive(on: DispatchQueue.main)
            .sinkOneShot(in: oneShotSubscriptions) { [weak self] completion in
                guard let self else { return }
                if case .failure(let error) = completion {
                    handleAPIError(error)
                    personalLibraryTracksFinished = true
                    finishPersonalLibraryLoadingIfReady()
                }
            } receiveValue: { [weak self] page in
                guard let self else { return }
                let combined = accumulated + page.items.map { Self.catalogItem($0.item) }
                likedSongsTotal = page.total
                likedSongs = combined
                if selectedPlaylist?.id == Self.likedSongsID {
                    playlistTracks = combined
                }
                if !page.items.isEmpty, combined.count < page.total {
                    loadSavedTracks(offset: offset + page.items.count, accumulated: combined)
                } else {
                    personalLibraryTracksFinished = true
                    finishPersonalLibraryLoadingIfReady()
                }
            }
    }

}

