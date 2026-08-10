import SwiftUI

struct BandcampAccountHeaderView: View {
    let profile: BandcampAccountProfile?
    let collectionCount: Int
    let wishlistCount: Int
    let followedCount: Int
    let lastUpdated: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            CachedRemoteArtwork(url: profile?.artworkURL) {
                ZStack {
                    LinearGradient(
                        colors: [.pink.opacity(0.72), .indigo.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.displayName ?? "Your Bandcamp")
                    .font(.title2.weight(.bold))
                if let username = profile?.username, !username.isEmpty {
                    Text("@\(username)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(isRefreshing ? "Loading your fan profile…" : "Fan profile unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }

            Spacer(minLength: 18)

            accountStat(collectionCount, title: "Collection", systemImage: "square.stack.fill")
            accountStat(wishlistCount, title: "Wishlist", systemImage: "heart.fill")
            accountStat(followedCount, title: "Following", systemImage: "person.2.fill")

            VStack(alignment: .trailing, spacing: 7) {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                .overlay {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .offset(x: 22)
                    }
                }

                if let lastUpdated {
                    Text("Updated \(lastUpdated, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 28)
    }

    private func accountStat(_ value: Int, title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Label(String(value), systemImage: systemImage)
                .font(.headline.monospacedDigit())
                .labelStyle(.titleAndIcon)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72)
    }
}

struct BandcampAccountArtistCarousel: View {
    @Environment(BandcampStore.self) private var bandcamp
    let artists: [BandcampResult]
    let onOpen: (BandcampResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Artists You Follow")
                    .font(.title3.weight(.semibold))
                Text(artists.isEmpty
                    ? "Artists followed with your Bandcamp account will appear here"
                    : "\(artists.count) artist\(artists.count == 1 ? "" : "s") from your Bandcamp account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            if artists.isEmpty {
                Label("You aren’t following any artists on Bandcamp yet.", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(.secondary)
                    .frame(height: 52)
                    .padding(.horizontal, 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(artists) { artist in
                            Button { onOpen(artist) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottomTrailing) {
                                        CachedRemoteArtwork(url: artist.artworkURL) {
                                            ZStack {
                                                LinearGradient(
                                                    colors: [.pink.opacity(0.7), .indigo.opacity(0.78)],
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
                                    Text(artist.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 118, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("View Artist in Uziq") { onOpen(artist) }
                                Divider()
                                Button("Unfollow on Bandcamp", role: .destructive) {
                                    bandcamp.toggleFollowing(artist)
                                }
                                .disabled(bandcamp.isUpdatingFollow(artist))
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .mouseDraggableHorizontalScroll()
                .frame(height: 166)
            }
        }
    }
}

struct BandcampAccountReleaseCarousel: View {
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(PlaybackQueueStore.self) private var queue
    @Environment(\.openURL) private var openURL
    let title: String
    let subtitle: String
    let emptyMessage: String
    let releases: [BandcampResult]
    let onOpen: (BandcampResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            if releases.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(height: 44)
                    .padding(.horizontal, 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(releases) { result in
                            ZStack(alignment: .topLeading) {
                                BandcampCollectionCard(
                                    result: result,
                                    isPreparing: bandcamp.preparingPlaybackResultID == result.id,
                                    isPlayDisabled: bandcamp.preparingPlaybackResultID != nil,
                                    onPlay: { queue.replace(with: result) },
                                    onShowDetails: { onOpen(result) },
                                    onOpenBrowser: { openURL(result.openURL) }
                                )

                                Button {
                                    bandcamp.toggleWishlist(result)
                                } label: {
                                    Group {
                                        if bandcamp.isUpdatingWishlist(result) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .tint(.white)
                                        } else {
                                            Image(systemName: bandcamp.isWishlisted(result) ? "heart.fill" : "heart")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(bandcamp.isWishlisted(result) ? .pink : .white)
                                        }
                                    }
                                    .frame(width: 30, height: 30)
                                    .background(.black.opacity(0.65), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(8)
                                .disabled(bandcamp.isUpdatingWishlist(result))
                                .help(bandcamp.isWishlisted(result) ? "Remove from Bandcamp wishlist" : "Add to Bandcamp wishlist")
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .mouseDraggableHorizontalScroll()
                .frame(height: 190)
            }
        }
    }
}
