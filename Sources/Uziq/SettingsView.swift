import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var playback
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    @Environment(PlaybackQueueStore.self) private var queue
    @State private var bandcampPassword = ""
    @State private var bandcampAuthCode = ""
    @State private var jellyfinPassword = ""
    @State private var diagnosticsMessage: String?

    var body: some View {
        Form {
            Section("Setup") {
                Button {
                    NotificationCenter.default.post(name: .uziqShowOnboarding, object: nil)
                } label: {
                    Label("Run Setup Assistant…", systemImage: "wand.and.stars")
                }
                Text("Configure local folders and streaming accounts in one guided flow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library folders") {
                if library.folderRoots.isEmpty {
                    if library.tracks.isEmpty {
                        Text("No folders added")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "The index contains \(library.tracks.count) tracks, but Uziq no longer has an active folder root. Re-add the parent music folders to enable rescanning.",
                            systemImage: "folder.badge.questionmark"
                        )
                        .foregroundStyle(.orange)
                    }
                } else {
                    ForEach(library.folderRoots, id: \.self) { url in
                        HStack {
                            Label(url.lastPathComponent, systemImage: "folder")
                            Spacer()
                            Button(role: .destructive) { library.removeFolder(url) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button("Add Folder…") { library.presentFolderImporter() }
                    Button("Rescan All") { library.scan() }
                        .disabled(library.folderRoots.isEmpty)
                }
            }
            Section("Equalizer") {
                Toggle("Enable equalizer", isOn: Binding(
                    get: { playback.equalizerEnabled },
                    set: { playback.equalizerEnabled = $0 }
                ))
                Picker("Preset", selection: Binding(
                    get: { playback.equalizerPreset },
                    set: { playback.applyEqualizerPreset($0) }
                )) {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(PlaybackEngine.equalizerFrequencies.enumerated()), id: \.offset) { index, frequency in
                        HStack(spacing: 10) {
                            Text(equalizerFrequencyLabel(frequency))
                                .font(.caption.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                            Slider(
                                value: Binding(
                                    get: { Double(playback.equalizerGains[index]) },
                                    set: { playback.setEqualizerGain(Float($0), at: index) }
                                ),
                                in: -12...12,
                                step: 0.5
                            )
                            Text(String(format: "%+.1f", playback.equalizerGains[index]))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                .disabled(!playback.equalizerEnabled)
                Text("Ten-band equalization is applied to local files and cached Bandcamp and Jellyfin playback. Spotify uses librespot’s native CoreAudio output for stable streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Jellyfin") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Self-hosted music", systemImage: "server.rack")
                        .font(.headline)
                    Text("Connect a Jellyfin account to browse, search, and play music from your server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Server URL (for example, http://jellyfin.local:8096)", text: Binding(
                    get: { jellyfin.serverAddress },
                    set: { jellyfin.serverAddress = $0 }
                ))
                .disabled(jellyfin.isConnected || jellyfin.isConnecting)
                if jellyfin.isUsingInsecureHTTP {
                    Label(
                        "This server uses plain HTTP. Your Jellyfin username, password, and stream traffic are not encrypted; continue only on a network you trust.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                TextField("Username", text: Binding(
                    get: { jellyfin.username },
                    set: { jellyfin.username = $0 }
                ))
                .disabled(jellyfin.isConnected || jellyfin.isConnecting)

                if jellyfin.isConnected {
                    HStack {
                        Label(
                            "Connected to \(jellyfin.serverName ?? "Jellyfin") as \(jellyfin.profileName ?? jellyfin.username)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) { jellyfin.disconnect() }
                    }
                } else {
                    SecureField("Password", text: $jellyfinPassword)
                        .disabled(jellyfin.isConnecting)
                    HStack {
                        Button("Connect Jellyfin") { jellyfin.connect(password: jellyfinPassword) }
                            .disabled(
                                jellyfin.isConnecting || jellyfin.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                jellyfin.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jellyfinPassword.isEmpty
                            )
                        if jellyfin.isConnecting { ProgressView().controlSize(.small) }
                    }
                }
                if let error = jellyfin.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Your password is never stored. Jellyfin’s access token is kept in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Bandcamp") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Fan account", systemImage: "person.crop.circle")
                        .font(.headline)
                    Text("Connect your Bandcamp account to use authenticated high-quality streams for music you own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Bandcamp email", text: Binding(
                    get: { bandcamp.accountEmail },
                    set: { bandcamp.accountEmail = $0 }
                ))
                .textContentType(.emailAddress)
                .disabled(bandcamp.isAuthenticated || bandcamp.isAuthenticating)

                if bandcamp.isAuthenticated {
                    HStack {
                        Label(
                            bandcamp.authStatusMessage ?? "Connected as \(bandcamp.accountEmail)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) { bandcamp.signOut() }
                    }
                } else {
                    SecureField("Bandcamp password", text: $bandcampPassword)
                        .textContentType(.password)
                        .disabled(bandcamp.isAuthenticating)
                    SecureField("Two-factor code (if enabled)", text: $bandcampAuthCode)
                        .disabled(bandcamp.isAuthenticating)
                    HStack {
                        Button(bandcamp.authRequiresRetry ? "Connect Again" : "Connect Bandcamp Account") {
                            bandcamp.signIn(password: bandcampPassword, authCode: bandcampAuthCode)
                        }
                        .disabled(
                            bandcamp.isAuthenticating ||
                            bandcamp.accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            bandcampPassword.isEmpty
                        )
                        if bandcamp.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let error = bandcamp.authError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if bandcamp.authRequiresRetry {
                    Label(
                        "Bandcamp may have emailed you to approve this login. Open that email and confirm the sign-in, then return here and click Connect Again.",
                        systemImage: "envelope.badge"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("Your password is sent directly to Bandcamp for login and is never stored. OAuth access and refresh tokens are kept in the macOS Keychain. Unowned releases continue using their normal artist-enabled preview streams.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cache") {
                HStack {
                    Label("Bandcamp audio", systemImage: "internaldrive")
                    Spacer()
                    Text(cacheSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Button("Clean Up Now") { bandcamp.cleanUpCache() }
                        .disabled(bandcamp.isCleaningCache)
                    if bandcamp.isCleaningCache {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let message = bandcamp.cacheMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Bandcamp audio that has not been played for seven days is removed automatically. Cleanup runs when Uziq starts and once per day while it remains open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Label("Spotify audio", systemImage: "music.note.house.fill")
                    Spacer()
                    Text("Not cached")
                        .foregroundStyle(.secondary)
                }
                Text("Spotify streams directly through librespot. Audio caching is disabled, so there is nothing to clean up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Label("Jellyfin audio", systemImage: "server.rack")
                    Spacer()
                    Text(jellyfinCacheSummary).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Button("Clean Up Jellyfin Cache") { jellyfin.cleanUpCache() }
                        .disabled(jellyfin.isCleaningCache)
                    if jellyfin.isCleaningCache { ProgressView().controlSize(.small) }
                }
                if let message = jellyfin.cacheMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text("Jellyfin tracks are cached for AVFoundation playback and equalization, then removed after seven days without use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotify") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Catalog and playlists", systemImage: "rectangle.stack.badge.play")
                        .font(.headline)
                    Text("This Web API connection supplies the Spotify page, search results, playlists, and playback controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Spotify Client ID", text: Binding(
                    get: { spotify.clientID },
                    set: { spotify.clientID = $0 }
                ))
                Text("Add \(SpotifyStore.redirectURI.absoluteString) as a Redirect URI in your Spotify developer app. PKCE is used, so Uziq never needs your client secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !spotify.isConfigured {
                    Label("Enter a Client ID above before connecting. Librespot’s login cannot provide playlists or catalog search.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Link("Open Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }

                HStack {
                    if spotify.isAuthorized {
                        Label(spotify.profileName ?? "Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) { spotify.logOut() }
                    } else {
                        Button("Connect Spotify Account") { spotify.logIn() }
                            .disabled(!spotify.isConfigured)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Label("Audio playback engine", systemImage: "waveform")
                        .font(.headline)
                    Text("The Uziq librespot helper provides Spotify Connect playback and local transport controls through its native CoreAudio backend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if spotify.librespot.isUsingBundledExecutable {
                    Label("Playback engine bundled with Uziq", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else if let executable = spotify.librespot.resolvedExecutableURL {
                    Label("Playback engine found automatically", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(executable.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Label("Playback engine not found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                DisclosureGroup("Use a custom Spotify helper") {
                    HStack {
                        TextField("Spotify helper executable", text: Binding(
                            get: { spotify.librespot.executablePath },
                            set: { spotify.librespot.executablePath = $0 }
                        ))
                        Button("Choose…") { chooseLibrespotExecutable() }
                    }
                }
                HStack {
                    Label(spotify.librespot.status.title, systemImage: spotify.librespot.status.isRunning ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                        .foregroundStyle(spotify.librespot.status == .ready ? .green : .secondary)
                    Spacer()
                    if spotify.librespot.status.isRunning {
                        Button("Stop Engine") { spotify.librespot.stop() }
                    } else {
                        Button("Start Engine") { spotify.startPlaybackEngine() }
                            .disabled(spotify.librespot.resolvedExecutableURL == nil)
                    }
                }
                Text(spotify.librespot.isUsingBundledExecutable
                    ? "No separate installation is needed. Its first start opens a separate Spotify login; afterward Uziq reuses the credential from Application Support. Playback commands do not depend on the Spotify Web API, and audio caching is disabled."
                    : "Development builds prefer Helpers/uziq-librespot/target/debug/uziq-librespot, then fall back to stock librespot or the custom path above. Packaged Uziq builds include the helper automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("Metadata") {
                Text("Embedded tags and artwork are used first. Missing album covers are looked up from MusicBrainz and the Cover Art Archive in the background.")
                    .foregroundStyle(.secondary)
                SecureField("AcoustID API key", text: Binding(
                    get: { library.acoustIDAPIKey },
                    set: { library.acoustIDAPIKey = $0 }
                ))
                Text("Install Chromaprint's fpcalc and add your AcoustID application key to enable track identification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Artist artwork") {
                SecureField("Last.fm API key", text: Binding(
                    get: { library.lastFMAPIKey },
                    set: { library.lastFMAPIKey = $0 }
                ))
                Button("Fetch Artist Images") { library.fetchArtistArtwork() }
                    .disabled(library.isEnrichingArtistArtwork)
                Text("Artist images are cached locally and fetched from Last.fm using the artist name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export Diagnostics…", systemImage: "doc.badge.arrow.up")
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Exports app, library, connection, cache, playback, and recent event information. Passwords, tokens, full home paths, raw librespot output, and complete music file paths are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720)
        .onChange(of: bandcamp.isAuthenticated) { _, connected in
            guard connected else { return }
            bandcampPassword = ""
            bandcampAuthCode = ""
        }
        .onChange(of: jellyfin.isConnected) { _, connected in
            if connected { jellyfinPassword = "" }
        }
    }

    private func equalizerFrequencyLabel(_ frequency: Float) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000))k"
            : "\(Int(frequency))"
    }

    private var cacheSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: bandcamp.cacheBytes, countStyle: .file)
        return "\(size) · \(bandcamp.cachedFileCount) \(bandcamp.cachedFileCount == 1 ? "file" : "files")"
    }

    private var jellyfinCacheSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: jellyfin.cacheBytes, countStyle: .file)
        return "\(size) · \(jellyfin.cachedFileCount) \(jellyfin.cachedFileCount == 1 ? "file" : "files")"
    }

    private func chooseLibrespotExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Helper"
        if panel.runModal() == .OK, let url = panel.url {
            spotify.librespot.executablePath = url.path
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Uziq Diagnostics"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Uziq-Diagnostics-\(formatter.string(from: .now)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let report = DiagnosticsReport.make(
            library: library,
            playback: playback,
            bandcamp: bandcamp,
            spotify: spotify,
            jellyfin: jellyfin,
            queue: queue
        )
        do {
            try report.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            diagnosticsMessage = "Exported \(url.lastPathComponent)"
            DiagnosticsLog.shared.record("diagnostics", "Export completed")
        } catch {
            diagnosticsMessage = "Export failed: \(error.localizedDescription)"
            DiagnosticsLog.shared.record("diagnostics", "Export failed: \(error.localizedDescription)")
        }
    }
}
