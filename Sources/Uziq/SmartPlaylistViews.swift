import SwiftUI

enum SmartPlaylistDescription {
    static func summary(_ playlist: SmartPlaylistSummary) -> String {
        let configuration = playlist.configuration
        let match: String
        if configuration.rules.isEmpty {
            match = "All tracks"
        } else if configuration.rules.count == 1, let rule = configuration.rules.first {
            match = ruleSummary(rule)
        } else {
            match = "Matches \(configuration.matchMode.title) of \(configuration.rules.count) rules"
        }
        let limit = configuration.limit.map { " · up to \($0)" } ?? ""
        return "\(match) · \(configuration.sortOrder.title)\(limit)"
    }

    static func ruleSummary(_ rule: SmartPlaylistRule) -> String {
        if !rule.comparison.requiresValue {
            return "\(rule.field.title) \(rule.comparison.title)"
        }
        let suffix = switch rule.field {
        case .dateAdded, .lastPlayed: " days"
        case .playCount: " plays"
        default: ""
        }
        return "\(rule.field.title) \(rule.comparison.title) \(rule.value)\(suffix)"
    }
}

struct SmartPlaylistDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var playlist: SmartPlaylistSummary
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var showingEditor = false

    init(playlist: SmartPlaylistSummary) {
        _playlist = State(initialValue: playlist)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    LibraryHeading(
                        title: playlist.name,
                        subtitle: "\(tracks.count) tracks · updates automatically"
                    )
                    if let first = tracks.first {
                        Button("Play") { queue.replace(with: tracks, startingAt: first) }
                            .buttonStyle(.borderedProminent)
                        Button {
                            let shuffled = tracks.shuffled()
                            if let first = shuffled.first {
                                queue.replace(with: shuffled, startingAt: first)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Edit…") { showingEditor = true }
                        .buttonStyle(.bordered)
                }

                Label(SmartPlaylistDescription.summary(playlist), systemImage: "wand.and.stars")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isLoading && tracks.isEmpty {
                    ProgressView("Updating smart playlist…")
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else if tracks.isEmpty {
                    ContentUnavailableView(
                        "No Matching Tracks",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Edit the rules or add matching music to your library.")
                    )
                    .frame(minHeight: 220)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(tracks) { track in
                            TrackRow(
                                track: track,
                                play: { queue.replace(with: tracks, startingAt: track) }
                            )
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(playlist.name)
        .task { await reload() }
        .onChange(of: library.smartPlaylists) { _, playlists in
            guard let updated = playlists.first(where: { $0.id == playlist.id }) else { return }
            playlist = updated
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uziqTrackPlayed)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingEditor) {
            SmartPlaylistEditorView(playlist: playlist) { name, configuration in
                Task {
                    guard let updated = await library.updateSmartPlaylist(
                        playlist,
                        name: name,
                        configuration: configuration
                    ) else { return }
                    playlist = updated
                    await reload()
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        tracks = await library.smartPlaylistTracks(playlist)
        isLoading = false
    }
}

struct SmartPlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var configuration: SmartPlaylistConfiguration
    @State private var limitEnabled: Bool
    @State private var limitValue: Int
    let playlist: SmartPlaylistSummary?
    let save: (String, SmartPlaylistConfiguration) -> Void

    init(
        playlist: SmartPlaylistSummary? = nil,
        save: @escaping (String, SmartPlaylistConfiguration) -> Void
    ) {
        self.playlist = playlist
        self.save = save
        let configuration = playlist?.configuration ?? SmartPlaylistConfiguration(
            matchMode: .all,
            rules: [SmartPlaylistRule()],
            sortOrder: .title,
            limit: 100
        )
        _name = State(initialValue: playlist?.name ?? "")
        _configuration = State(initialValue: configuration)
        _limitEnabled = State(initialValue: configuration.limit != nil)
        _limitValue = State(initialValue: configuration.limit ?? 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist == nil ? "New Smart Playlist" : "Edit Smart Playlist")
                        .font(.title2.weight(.bold))
                    Text("The track list updates whenever your library or listening history changes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            Form {
                Section("Name") {
                    TextField("Smart playlist name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    Picker("Include tracks matching", selection: $configuration.matchMode) {
                        ForEach(SmartPlaylistMatchMode.allCases) { mode in
                            Text(mode.title.capitalized).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(configuration.rules.count < 2)

                    ForEach($configuration.rules) { $rule in
                        SmartPlaylistRuleEditorRow(rule: $rule) {
                            configuration.rules.removeAll { $0.id == rule.id }
                        }
                    }

                    Button {
                        configuration.rules.append(SmartPlaylistRule())
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Rules")
                } footer: {
                    if configuration.rules.isEmpty {
                        Text("With no rules, every track in the local library is included.")
                    }
                }

                Section("Order") {
                    Picker("Sort by", selection: $configuration.sortOrder) {
                        ForEach(SmartPlaylistSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    Toggle("Limit number of tracks", isOn: $limitEnabled)
                    if limitEnabled {
                        Stepper("Maximum: \(limitValue) tracks", value: $limitValue, in: 1...500)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(playlist == nil ? "Create" : "Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(18)
        }
        .frame(width: 760, height: 620)
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = configuration
        candidate.limit = limitEnabled ? limitValue : nil
        return !trimmed.isEmpty && candidate.isValid
    }

    private func commit() {
        guard canSave else { return }
        configuration.limit = limitEnabled ? limitValue : nil
        save(name.trimmingCharacters(in: .whitespacesAndNewlines), configuration)
        dismiss()
    }
}

private struct SmartPlaylistRuleEditorRow: View {
    @Binding var rule: SmartPlaylistRule
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Field", selection: $rule.field) {
                ForEach(SmartPlaylistRuleField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("Comparison", selection: $rule.comparison) {
                ForEach(rule.field.allowedOperators) { comparison in
                    Text(comparison.title).tag(comparison)
                }
            }
            .labelsHidden()
            .frame(width: 175)

            if rule.comparison.requiresValue {
                TextField(valuePrompt, text: $rule.value)
                    .textFieldStyle(.roundedBorder)
                if rule.field == .dateAdded || rule.field == .lastPlayed {
                    Text("days")
                        .foregroundStyle(.secondary)
                }
            } else {
                Spacer()
            }

            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Remove rule")
        }
        .onChange(of: rule.field) { _, field in
            if !field.allowedOperators.contains(rule.comparison) {
                rule.comparison = field.allowedOperators[0]
            }
            rule.value = field.defaultValue
        }
    }

    private var valuePrompt: String {
        switch rule.field {
        case .playCount: "Number of plays"
        case .dateAdded, .lastPlayed: "Number"
        case .year: "Year"
        default: "Value"
        }
    }
}
