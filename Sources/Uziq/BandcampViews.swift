import AppKit
import SwiftUI

struct BandcampLibraryView: View {
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(PlaybackEngine.self) private var playback
    @State private var showingSetup = false
    @State private var showingSavedOnly = false

    var body: some View {
        @Bindable var bandcamp = bandcamp
        let displayedResults = showingSavedOnly ? bandcamp.savedResults : bandcamp.results
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

            if !showingSavedOnly && !bandcamp.subscriptions.isEmpty {
                subscriptionStrip
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)

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

            if bandcamp.subscriptions.isEmpty && bandcamp.savedResults.isEmpty {
                BandcampWelcomeView { showingSetup = true }
            } else if displayedResults.isEmpty && !bandcamp.isLoading {
                ContentUnavailableView(
                    showingSavedOnly ? "No Bandcamp favorites" : "No Bandcamp results",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(showingSavedOnly
                        ? "Use the heart button on a track or release to add it here."
                        : "Try another search or edit your discovery subscriptions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedResults) { result in
                            BandcampResultRow(
                                result: result,
                                isSaved: bandcamp.isSaved(result),
                                isPlayDisabled: bandcamp.preparingPlaybackResultID != nil,
                                onToggleSaved: { bandcamp.toggleSaved(result) }
                            ) {
                                bandcamp.play(result, using: playback)
                            } onOpen: {
                                NSWorkspace.shared.open(result.openURL)
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
            if bandcamp.subscriptions.isEmpty && bandcamp.savedResults.isEmpty {
                showingSetup = true
            } else if !showingSavedOnly && bandcamp.results.isEmpty {
                bandcamp.refreshFeed()
            }
        }
    }

    private var subscriptionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bandcamp.subscriptions) { subscription in
                    Label(subscription.value, systemImage: subscription.kind == .artist ? "person.fill" : "tag.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
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
    let result: BandcampResult
    let isSaved: Bool
    let isPlayDisabled: Bool
    let onToggleSaved: () -> Void
    let onPlay: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: result.artworkURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [.indigo.opacity(0.55), .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: result.type == "b" ? "person.fill" : "music.note")
                            .foregroundStyle(.white.opacity(0.85))
                    }
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
            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button(isSaved ? "Remove from Favorites" : "Add to Favorites", action: onToggleSaved)
            Button("Open in Browser", action: onOpen)
            if result.isPlayable {
                Button("Play", action: onPlay)
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
    }
}
