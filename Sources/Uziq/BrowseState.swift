import SwiftUI
import Observation

enum LocalBrowseRoute: Hashable {
    case artist(String)
    case album(String)
}

enum BandcampBrowseRoute: Hashable {
    case artist(BandcampResult)
    case release(BandcampResult)
}

@MainActor @Observable
final class BrowseState {
    var paths: [LibrarySection: NavigationPath] = [:]
    var filters: [LibrarySection: String] = [:]
    var offsets: [String: CGPoint] = [:]
    var bandcampSavedOnly = false
    var spotifyArtistSections: [String: SpotifyArtistPageSection] = [:]

    func path(for section: LibrarySection) -> Binding<NavigationPath> {
        Binding(get: { self.paths[section] ?? NavigationPath() }, set: { self.paths[section] = $0 })
    }

    func filter(for section: LibrarySection) -> Binding<String> {
        Binding(get: { self.filters[section] ?? "" }, set: { self.filters[section] = $0 })
    }

}

private struct BrowseScrollGeometry: Equatable {
    let offset: CGPoint
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

private struct RememberBrowsePosition: ViewModifier {
    @Environment(LibraryStore.self) private var library
    let key: String
    @State private var position = ScrollPosition(edge: .top)
    @State private var restoreTarget: CGPoint?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear { restore() }
            .onDisappear { isVisible = false }
            .onChange(of: key) { _, _ in restore() }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking { restoreTarget = nil }
            }
            .onScrollGeometryChange(for: BrowseScrollGeometry.self) { geometry in
                BrowseScrollGeometry(
                    offset: CGPoint(x: max(0, geometry.contentOffset.x + geometry.contentInsets.leading),
                                    y: max(0, geometry.contentOffset.y + geometry.contentInsets.top)),
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            } action: { _, geometry in
                guard isVisible else { return }
                if let target = restoreTarget {
                    if abs(geometry.offset.y - target.y) < 1 {
                        restoreTarget = nil
                    } else if geometry.contentHeight >= target.y + geometry.containerHeight {
                        position.scrollTo(x: target.x, y: target.y)
                    }
                    // Remote pages can initially contain only a loading spinner.
                    // Do not replace their saved position with that short layout.
                    return
                }
                library.browsing.offsets[key] = geometry.offset
            }
    }

    private func restore() {
        isVisible = true
        restoreTarget = library.browsing.offsets[key] ?? .zero
        if let target = restoreTarget { position.scrollTo(x: target.x, y: target.y) }
    }
}

extension View {
    func rememberBrowsePosition(_ key: String) -> some View {
        modifier(RememberBrowsePosition(key: key))
    }

    func localBrowseDestinations(library: LibraryStore) -> some View {
        navigationDestination(for: LocalBrowseRoute.self) { route in
            switch route {
            case .artist(let id):
                if let artist = library.browseSnapshot.artists.first(where: { $0.id == id }) {
                    ArtistDetailView(artist: artist)
                } else {
                    ContentUnavailableView("Artist unavailable", systemImage: "person.crop.circle.badge.questionmark")
                }
            case .album(let id):
                if let album = library.browseSnapshot.albums.first(where: { $0.id == id }) {
                    AlbumDetailView(album: album)
                } else {
                    ContentUnavailableView("Album unavailable", systemImage: "square.stack")
                }
            }
        }
    }
}
