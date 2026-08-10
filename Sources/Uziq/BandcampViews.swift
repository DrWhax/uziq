import AppKit
import SwiftUI

struct BandcampLibraryView: View {
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var showingSetup = false
    @State private var showingSavedOnly = false
    @State private var selectedOwnedRelease: BandcampResult?
    @State private var selectedArtist: BandcampResult?

    var body: some View {
        @Bindable var bandcamp = bandcamp
        let displayedResults = showingSavedOnly ? bandcamp.savedResults : bandcamp.results
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bandcamp")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(showingSavedOnly
                        ? "Liked Bandcamp tracks and releases"
                        : bandcamp.subscriptions.isEmpty
                        ? "Subscribe to sounds and artists you want to discover"
                        : "Your discovery feed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bandcamp.isAuthenticated {
                    Label("Account connected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                if !bandcamp.savedResults.isEmpty {
                    Button {
                        showingSavedOnly.toggle()
                    } label: {
                        Label(
                            showingSavedOnly ? "Feed" : "Favorites \(bandcamp.savedResults.count)",
                            systemImage: showingSavedOnly ? "dot.radiowaves.left.and.right" : "heart.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                Button("Edit subscriptions") { showingSetup = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 18)

            if !showingSavedOnly && bandcamp.isAuthenticated {
                BandcampAccountHeaderView(
                    profile: bandcamp.accountProfile,
                    collectionCount: bandcamp.ownedResults.count,
                    wishlistCount: bandcamp.wishlistResults.count,
                    followedCount: bandcamp.followedArtists.count,
                    lastUpdated: bandcamp.accountLastUpdated,
                    isRefreshing: bandcamp.isLoadingCollection,
                    onRefresh: { bandcamp.loadCollection(force: true) }
                )
                .padding(.bottom, 22)

                accountCollectionSection
                    .padding(.bottom, 22)

                BandcampAccountArtistCarousel(
                    artists: bandcamp.followedArtists,
                    onOpen: { selectedArtist = $0 }
                )
                .padding(.bottom, 22)

                BandcampAccountReleaseCarousel(
                    title: "New From Artists You Follow",
                    subtitle: "Recent releases from your Bandcamp feed",
                    emptyMessage: "No new followed-artist releases were returned yet.",
                    releases: bandcamp.accountNewReleases,
                    onOpen: { selectedOwnedRelease = $0 }
                )
                .padding(.bottom, 22)

                BandcampAccountReleaseCarousel(
                    title: "Wishlist",
                    subtitle: "\(bandcamp.wishlistResults.count) release\(bandcamp.wishlistResults.count == 1 ? "" : "s") saved to your Bandcamp account",
                    emptyMessage: "Your Bandcamp wishlist is empty.",
                    releases: bandcamp.wishlistResults,
                    onOpen: { selectedOwnedRelease = $0 }
                )
                .padding(.bottom, 22)
            }

            if !showingSavedOnly {
                if artistSubscriptionCount > 0 {
                    artistSubscriptionSection
                        .padding(.bottom, 18)
                }

                if !keywordSubscriptions.isEmpty {
                    keywordStrip
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Bandcamp", text: $bandcamp.query)
                        .textFieldStyle(.plain)
                        .onSubmit { bandcamp.search() }
                    if !bandcamp.query.isEmpty {
                        Button { bandcamp.query = ""; bandcamp.refreshFeed() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Search") { bandcamp.search() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }

            if bandcamp.isLoading {
                ProgressView(bandcamp.loadingMessage)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }

            if let error = bandcamp.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }

            if !bandcamp.isAuthenticated && bandcamp.subscriptions.isEmpty && bandcamp.savedResults.isEmpty {
                BandcampWelcomeView { showingSetup = true }
            } else if displayedResults.isEmpty && !bandcamp.isLoading {
                ContentUnavailableView(
                    showingSavedOnly
                        ? "No Bandcamp favorites"
                        : bandcamp.ownedResults.isEmpty ? "No Bandcamp results" : "Your discovery feed is empty",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(showingSavedOnly
                        ? "Use the heart button on a track or release to add it here."
                        : "Search Bandcamp or add discovery subscriptions below your collection.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedResults) { result in
                        BandcampResultRow(
                            result: result,
                            isSaved: bandcamp.isSaved(result),
                            isPlayDisabled: bandcamp.preparingPlaybackResultID != nil,
                            onToggleSaved: { bandcamp.toggleSaved(result) }
                        ) {
                            queue.replace(with: result)
                        } onOpen: {
                            switch result.type {
                            case "b":
                                selectedArtist = result
                            case "a", "t":
                                selectedOwnedRelease = result
                            default:
                                NSWorkspace.shared.open(result.openURL)
                            }
                        }
                        Divider()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
                }
            }
            .sheet(isPresented: $showingSetup) {
                BandcampSubscriptionSheet()
            }
            .task {
                if bandcamp.isAuthenticated && bandcamp.accountLastUpdated == nil && !bandcamp.isLoadingCollection {
                    bandcamp.loadCollection()
                }
                if !bandcamp.isAuthenticated && bandcamp.subscriptions.isEmpty && bandcamp.savedResults.isEmpty {
                    showingSetup = true
                } else if !showingSavedOnly && bandcamp.results.isEmpty {
                    bandcamp.refreshFeed()
                }
            }
            .navigationDestination(item: $selectedOwnedRelease) { result in
                BandcampReleaseDetailView(result: result)
            }
            .navigationDestination(item: $selectedArtist) { artist in
                BandcampArtistDetailView(artist: artist)
            }
        }
    }

    private var keywordStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keywordSubscriptions) { subscription in
                    Label(subscription.value, systemImage: "tag.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .mouseDraggableHorizontalScroll()
    }

    private var keywordSubscriptions: [BandcampSubscription] {
        bandcamp.subscriptions.filter { $0.kind == .keyword }
    }

    private var artistSubscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bandcamp.isAuthenticated ? "Uziq Discovery Artists" : "Artist Subscriptions")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 4) {
                        Text("\(artistSubscriptionCount) artist\(artistSubscriptionCount == 1 ? "" : "s") saved in Uziq")
                        if let checkedAt = bandcamp.artistSubscriptionsCheckedAt {
                            Text("· checked")
                            Text(checkedAt, style: .relative)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    bandcamp.refreshFeed()
                } label: {
                    Label("Check releases", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(bandcamp.isLoading || artistSubscriptionCount == 0)

                Button {
                    showingSetup = true
                } label: {
                    Label("Add artists", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 28)

            if bandcamp.subscribedArtists.isEmpty {
                HStack(spacing: 12) {
                    if bandcamp.isLoading && artistSubscriptionCount > 0 {
                        ProgressView().controlSize(.small)
                        Text("Finding your artists on Bandcamp…")
                    } else {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Add favorite artists to keep their pages and new releases close.")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(height: 64)
                .padding(.horizontal, 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(bandcamp.subscribedArtists) { artist in
                            BandcampArtistSubscriptionCard(
                                artist: artist,
                                onOpenBrowser: { NSWorkspace.shared.open(artist.openURL) },
                                onSearch: {
                                    bandcamp.query = artist.title
                                    bandcamp.search()
                                },
                                onRemove: { bandcamp.removeArtistSubscription(artist) }
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .mouseDraggableHorizontalScroll()
                .frame(height: 166)
            }
        }
    }

    private var artistSubscriptionCount: Int {
        bandcamp.subscriptions.lazy.filter { $0.kind == .artist }.count
    }

    private var accountCollectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Bandcamp Collection")
                        .font(.title3.weight(.semibold))
                    Text(collectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)

            if let collectionError = bandcamp.collectionError {
                Label(collectionError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 28)
            }

            if bandcamp.ownedResults.isEmpty {
                HStack(spacing: 10) {
                    if bandcamp.isLoadingCollection { ProgressView().controlSize(.small) }
                    Text(bandcamp.isLoadingCollection
                        ? "Loading your purchases…"
                        : "No purchases were returned for this account.")
                        .foregroundStyle(.secondary)
                }
                .frame(height: 44)
                .padding(.horizontal, 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(bandcamp.ownedResults) { result in
                            BandcampCollectionCard(
                                result: result,
                                isPreparing: bandcamp.preparingPlaybackResultID == result.id,
                                isPlayDisabled: bandcamp.preparingPlaybackResultID != nil,
                                onPlay: { queue.replace(with: result) },
                                onShowDetails: { selectedOwnedRelease = result },
                                onOpenBrowser: { NSWorkspace.shared.open(result.openURL) }
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .mouseDraggableHorizontalScroll()
                .frame(height: 190)
            }
        }
    }

    private var collectionSubtitle: String {
        let owner = bandcamp.accountProfile?.displayName
            ?? (bandcamp.accountEmail.isEmpty ? "Connected account" : bandcamp.accountEmail)
        let count = bandcamp.ownedResults.count
        guard count > 0 else { return owner }
        return "\(owner) · \(count) \(count == 1 ? "release" : "releases")"
    }
}

struct BandcampArtistSubscriptionCard: View {
    let artist: BandcampResult
    let onOpenBrowser: () -> Void
    let onSearch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        NavigationLink {
            BandcampArtistDetailView(artist: artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    CachedRemoteArtwork(url: artist.artworkURL) {
                        ZStack {
                            LinearGradient(
                                colors: [.pink.opacity(0.7), .indigo.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "person.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white.opacity(0.88))
                        }
                    }
                    .frame(width: 118, height: 118)
                    .clipShape(Circle())

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.65), in: Circle())
                        .padding(5)
                }

                Text(artist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("View artist")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.72))
            }
            .frame(width: 118, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open Artist in Browser", action: onOpenBrowser)
            Button("Search Releases in Uziq", action: onSearch)
            Divider()
            Button("Remove Subscription", role: .destructive, action: onRemove)
        }
    }
}

struct BandcampCollectionCard: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let result: BandcampResult
    let isPreparing: Bool
    let isPlayDisabled: Bool
    let onPlay: () -> Void
    let onShowDetails: () -> Void
    let onOpenBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: onShowDetails) {
                    CachedRemoteArtwork(url: result.artworkURL) {
                        ZStack {
                            LinearGradient(
                                colors: [.indigo.opacity(0.55), .purple.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: result.type == "a" ? "square.stack.fill" : "music.note")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: 142, height: 142)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onPlay) {
                    Group {
                        if isPreparing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.65), in: Circle())
                .padding(8)
                .disabled(isPlayDisabled)
                .help("Play album")
            }

            Button(action: onShowDetails) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(result.artist)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.72))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 142, alignment: .leading)
        .contextMenu {
            Button("View Track List", action: onShowDetails)
            Button("Open in Browser", action: onOpenBrowser)
            Button("Play", action: onPlay)
            Button("Play Next") { queue.playNext(result) }
            Button("Add to Queue") { queue.add(result) }
        }
    }
}

struct BandcampArtistDetailView: View {
    @Environment(BandcampStore.self) private var bandcamp
    let artist: BandcampResult
    @State private var page: BandcampArtistPage?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    CachedRemoteArtwork(url: artist.artworkURL) {
                        ZStack {
                            LinearGradient(
                                colors: [.pink.opacity(0.7), .indigo.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "person.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.white.opacity(0.88))
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 7)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Bandcamp artist")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(artist.title)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("Artist on Bandcamp")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                Task { await loadPage() }
                            } label: {
                                Label("Check Releases", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading)

                            if bandcamp.isAuthenticated, artist.bandID != nil {
                                Button {
                                    bandcamp.toggleFollowing(artist)
                                } label: {
                                    Label(
                                        bandcamp.isFollowing(artist) ? "Following" : "Follow",
                                        systemImage: bandcamp.isFollowing(artist) ? "person.fill.checkmark" : "person.badge.plus"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .disabled(bandcamp.isUpdatingFollow(artist))
                            }

                            Button("Open in Bandcamp") {
                                NSWorkspace.shared.open(artist.openURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if let summary = page?.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.title2.weight(.bold))
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Releases")
                            .font(.title2.weight(.bold))
                        if let count = page?.releases.count {
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if isLoading && page == nil {
                        ProgressView("Loading \(artist.title)…")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let error, page == nil {
                        ContentUnavailableView(
                            "Couldn’t load this artist",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else if page?.releases.isEmpty != false {
                        ContentUnavailableView(
                            "No releases found",
                            systemImage: "square.stack.3d.up.slash",
                            description: Text("Bandcamp did not return releases for this artist yet.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let releases = page?.releases {
                        LazyVStack(spacing: 0) {
                            ForEach(releases) { release in
                                BandcampArtistReleaseRow(release: release)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: artist.id) {
            await loadPage()
        }
    }

    private func loadPage() async {
        isLoading = true
        error = nil
        do {
            page = try await bandcamp.artistPage(for: artist)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

private struct BandcampArtistReleaseRow: View {
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(BandcampStore.self) private var bandcamp
    let release: BandcampResult

    var body: some View {
        HStack(spacing: 14) {
            NavigationLink {
                BandcampReleaseDetailView(result: release)
            } label: {
                HStack(spacing: 14) {
                    CachedRemoteArtwork(url: release.artworkURL) {
                        ZStack {
                            LinearGradient(
                                colors: [.indigo.opacity(0.55), .purple.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: release.type == "a" ? "square.stack.fill" : "music.note")
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(release.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(release.artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(release.type == "a" ? "Album" : "Track")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if release.isPlayable {
                Button {
                    queue.replace(with: release)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(bandcamp.preparingPlaybackResultID != nil)
            }
        }
        .padding(.vertical, 9)
        .contextMenu {
            if release.isPlayable {
                Button("Play", action: { queue.replace(with: release) })
                Button("Play Next", action: { queue.playNext(release) })
                Button("Add to Queue", action: { queue.add(release) })
            }
            Button("Open in Browser", action: { NSWorkspace.shared.open(release.openURL) })
        }
    }
}

struct BandcampReleaseDetailView: View {
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(PlaybackQueueStore.self) private var queue
    let result: BandcampResult
    @State private var details: BandcampAlbumDetails?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 22) {
                    CachedRemoteArtwork(url: details?.artworkURL ?? result.artworkURL) {
                        ZStack {
                            LinearGradient(
                                colors: [.indigo.opacity(0.55), .purple.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "square.stack.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: 190, height: 190)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 7)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bandcamp release")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(details?.title ?? result.title)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text(details?.artist ?? result.artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(releaseSummary)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        HStack {
                            Button {
                                queue.replace(with: result)
                            } label: {
                                Label("Play Album", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(bandcamp.preparingPlaybackResultID != nil)

                            if bandcamp.isAuthenticated,
                               result.bandID != nil,
                               result.tralbumID != nil {
                                Button {
                                    bandcamp.toggleWishlist(result)
                                } label: {
                                    Label(
                                        bandcamp.isWishlisted(result) ? "Wishlisted" : "Wishlist",
                                        systemImage: bandcamp.isWishlisted(result) ? "heart.fill" : "heart"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(bandcamp.isWishlisted(result) ? .pink : nil)
                                .disabled(bandcamp.isUpdatingWishlist(result))
                            }

                            Button("Open in Browser") {
                                NSWorkspace.shared.open(result.openURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if isLoading {
                    ProgressView("Loading tracks…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let error {
                    ContentUnavailableView(
                        "Couldn’t load this release",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if let details, details.tracks.isEmpty {
                    ContentUnavailableView(
                        "No tracks found",
                        systemImage: "music.note.slash",
                        description: Text("Bandcamp did not return a track list for this release.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if let details {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                            let trackResult = result(for: track, details: details)
                            HStack(spacing: 12) {
                                Text("\(track.number ?? index + 1)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    if !details.artist.isEmpty {
                                        Text(details.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Text(formattedDuration(track.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)

                                Button {
                                    queue.replace(with: trackResult)
                                } label: {
                                    Image(systemName: "play.fill")
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .disabled(!track.isStreamable || bandcamp.preparingPlaybackResultID != nil)
                                .help(track.isStreamable ? "Play track" : "This track is unavailable")
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if track.isStreamable && bandcamp.preparingPlaybackResultID == nil {
                                    queue.replace(with: trackResult)
                                }
                            }
                            .contextMenu {
                                if track.isStreamable {
                                    Button("Play") { queue.replace(with: trackResult) }
                                    Button("Play Next") { queue.playNext(trackResult) }
                                    Button("Add to Queue") { queue.add(trackResult) }
                                }
                                if let pageURL = track.pageURL {
                                    Button("Open Track in Browser") { NSWorkspace.shared.open(pageURL) }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: result.id) {
            isLoading = true
            error = nil
            do {
                details = try await bandcamp.releaseDetails(for: result)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private var releaseSummary: String {
        guard let details else { return isLoading ? "Loading track list…" : "Bandcamp album" }
        let count = details.tracks.count
        let duration = details.tracks.map(\.duration).filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        let countText = "\(count) track\(count == 1 ? "" : "s")"
        guard duration > 0 else { return countText }
        return "\(countText) · \(Int(duration) / 60) min"
    }

    private func result(for track: BandcampTrackDetails, details: BandcampAlbumDetails) -> BandcampResult {
        BandcampResult(
            id: "owned-track-\(details.bandID)-\(track.id)",
            title: track.title,
            artist: details.artist,
            url: track.pageURL ?? result.openURL,
            type: "t",
            bandID: details.bandID,
            tralbumID: track.id,
            artworkURL: details.artworkURL ?? result.artworkURL
        )
    }

    private func formattedDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "—" }
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct BandcampWelcomeView: View {
    let onSubscribe: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Build your Bandcamp feed")
                .font(.title2.weight(.semibold))
            Text("Follow the sounds you love with a few keywords and favorite artists. Uziq will search Bandcamp for new releases and stream available tracks.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button("Choose subscriptions…", action: onSubscribe)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct BandcampResultRow: View {
    @Environment(PlaybackQueueStore.self) private var queue
    let result: BandcampResult
    let isSaved: Bool
    let isPlayDisabled: Bool
    let onToggleSaved: () -> Void
    let onPlay: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CachedRemoteArtwork(url: result.artworkURL) {
                ZStack {
                    LinearGradient(colors: [.indigo.opacity(0.55), .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: result.type == "b" ? "person.fill" : "music.note")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(result.artist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(resultType)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button(action: onToggleSaved) {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .foregroundStyle(isSaved ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help(isSaved ? "Remove from Bandcamp favorites" : "Add to Bandcamp favorites")

            if result.isPlayable {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPlayDisabled)
            }
            Button(result.type == "b" ? "View Artist" : "Open", action: onOpen)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button(isSaved ? "Remove from Favorites" : "Add to Favorites", action: onToggleSaved)
            if result.type == "b" || result.type == "a" || result.type == "t" {
                Button(result.type == "b" ? "View Artist in Uziq" : "View Release in Uziq", action: onOpen)
                Button("Open in Browser") { NSWorkspace.shared.open(result.openURL) }
            } else {
                Button("Open in Browser", action: onOpen)
            }
            if result.isPlayable {
                Button("Play", action: onPlay)
                Button("Play Next") { queue.playNext(result) }
                Button("Add to Queue") { queue.add(result) }
            }
        }
    }

    private var resultType: String {
        switch result.type {
        case "a": "Album"
        case "t": "Track"
        case "b": "Artist"
        default: "Bandcamp result"
        }
    }
}

struct BandcampSubscriptionSheet: View {
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(\.dismiss) private var dismiss
    @State private var keywords: [String]
    @State private var artists: [String]
    @State private var keyword = ""
    @State private var artist = ""

    private let suggestions = ["ambient", "experimental", "shoegaze", "electronic", "jazz", "metal", "soundtrack"]

    init() {
        _keywords = State(initialValue: [])
        _artists = State(initialValue: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Bandcamp subscriptions")
                        .font(.title2.weight(.bold))
                    Text("Choose keywords for a style or favorite artists to keep close.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { save() }
                    .buttonStyle(.borderedProminent)
            }

            subscriptionEditor(
                title: "Sounds and keywords",
                placeholder: "e.g. ambient techno",
                value: $keyword,
                values: $keywords,
                kind: .keyword
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions")
                    .font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                add(suggestion, kind: .keyword)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .mouseDraggableHorizontalScroll()
            }

            subscriptionEditor(
                title: "Favorite artists",
                placeholder: "e.g. Deerhunter",
                value: $artist,
                values: $artists,
                kind: .artist
            )

            Spacer()
            Text("Search and streaming use Bandcamp's public app-facing endpoints. Some artists may only allow a preview or may not expose a stream.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 620, height: 560)
        .onAppear {
            keywords = bandcamp.subscriptions.filter { $0.kind == .keyword }.map(\.value)
            artists = bandcamp.subscriptions.filter { $0.kind == .artist }.map(\.value)
        }
    }

    @ViewBuilder
    private func subscriptionEditor(
        title: String,
        placeholder: String,
        value: Binding<String>,
        values: Binding<[String]>,
        kind: BandcampSubscriptionKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack {
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(value.wrappedValue, kind: kind) }
                Button("Add") { add(value.wrappedValue, kind: kind) }
                    .buttonStyle(.bordered)
            }
            if !values.wrappedValue.isEmpty {
                FlowingChips(values: values.wrappedValue) { item in
                    values.wrappedValue.removeAll { $0 == item }
                }
            }
        }
    }

    private func add(_ value: String, kind: BandcampSubscriptionKind) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if kind == .keyword {
            guard !keywords.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else { keyword = ""; return }
            keywords.append(normalized)
            keyword = ""
        } else {
            guard !artists.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else { artist = ""; return }
            artists.append(normalized)
            artist = ""
        }
    }

    private func save() {
        bandcamp.saveSubscriptions(keywords: keywords, artists: artists)
        dismiss()
    }
}

struct FlowingChips: View {
    let values: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 5) {
                        Text(value)
                        Button { onRemove(value) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
        .mouseDraggableHorizontalScroll()
    }
}
