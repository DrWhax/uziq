import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case localLibrary
    case bandcamp
    case spotify
    case jellyfin
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .localLibrary: "Local Music"
        case .bandcamp: "Bandcamp"
        case .spotify: "Spotify"
        case .jellyfin: "Jellyfin"
        case .ready: "Ready"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "music.note.house.fill"
        case .localLibrary: "externaldrive.fill.badge.plus"
        case .bandcamp: "dot.radiowaves.left.and.right"
        case .spotify: "music.note.house.fill"
        case .jellyfin: "server.rack"
        case .ready: "checkmark.circle.fill"
        }
    }
}

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(BandcampStore.self) private var bandcamp
    @Environment(SpotifyStore.self) private var spotify
    @Environment(JellyfinStore.self) private var jellyfin
    @State private var step: OnboardingStep = .welcome
    @State private var bandcampPassword = ""
    @State private var bandcampCode = ""
    @State private var jellyfinPassword = ""
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .localLibrary: localLibraryStep
                    case .bandcamp: bandcampStep
                    case .spotify: spotifyStep
                    case .jellyfin: jellyfinStep
                    case .ready: readyStep
                    }
                }
                .frame(maxWidth: 650, alignment: .leading)
                .padding(.horizontal, 42)
                .padding(.vertical, 34)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 650)
        .interactiveDismissDisabled()
        .onChange(of: bandcamp.isAuthenticated) { _, connected in
            if connected { bandcampPassword = ""; bandcampCode = "" }
        }
        .onChange(of: jellyfin.isConnected) { _, connected in
            if connected { jellyfinPassword = "" }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Set Up Uziq").font(.headline)
                        Text(step.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Set Up Later") { finish() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
                        .accessibilityLabel(item.title)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack {
            Button("Back") { move(by: -1) }
                .disabled(step == .welcome)
            Spacer()
            Text("All services are optional and can be changed later in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            if step == .ready {
                Button("Start Listening", action: finish).buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { move(by: 1) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 24) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uziq")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("Your all-in-one music app.")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Stream from Spotify with a Premium account. Stream Bandcamp without an account, or sign in to stream high-quality audio for music you own. Lastly, stream music from your Jellyfin server.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localLibraryStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeading("Add music from this Mac", "Choose one or more folders. Uziq scans their subfolders and keeps access between launches.", "folder.fill.badge.plus")
            if !library.isInitialLoadComplete && library.folderRoots.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking for an existing local library…").foregroundStyle(.secondary)
                }
                .padding(18)
            } else if library.folderRoots.isEmpty && library.tracks.isEmpty {
                setupEmpty("No music folders added yet", "You can skip this if you only stream music.", "music.note.list")
            } else if library.folderRoots.isEmpty {
                connectedCard(
                    "Local library found",
                    "\(library.tracks.count) indexed track\(library.tracks.count == 1 ? "" : "s")",
                    "checkmark.circle.fill"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(library.folderRoots, id: \.self) { url in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.headline)
                                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { library.removeFolder(url) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(13)
                        Divider()
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
            Button(action: chooseMusicFolders) {
                Label("Choose Music Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            if library.isScanning {
                ProgressView("Indexing in the background…")
            }
        }
    }

    private var bandcampStep: some View {
        @Bindable var bandcamp = bandcamp
        return VStack(alignment: .leading, spacing: 20) {
            stepHeading("Connect Bandcamp", "See music you own, followed artists, discovery results, and authenticated streams.", "dot.radiowaves.left.and.right")
            if bandcamp.isAuthenticated {
                connectedCard("Bandcamp connected", bandcamp.authStatusMessage ?? bandcamp.accountEmail, "checkmark.circle.fill")
            } else {
                TextField("Bandcamp email", text: $bandcamp.accountEmail)
                    .textContentType(.emailAddress).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $bandcampPassword).textFieldStyle(.roundedBorder)
                SecureField("Two-factor code, if enabled", text: $bandcampCode).textFieldStyle(.roundedBorder)
                HStack {
                    Button(bandcamp.authRequiresRetry ? "Connect Again" : "Connect Bandcamp") {
                        bandcamp.signIn(password: bandcampPassword, authCode: bandcampCode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        bandcamp.isAuthenticating || bandcamp.accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bandcampPassword.isEmpty
                    )
                    if bandcamp.isAuthenticating { ProgressView().controlSize(.small) }
                }
                if bandcamp.authRequiresRetry {
                    Label("Approve the login from Bandcamp’s email, then click Connect Again.", systemImage: "envelope.badge")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let error = bandcamp.authError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            Text("Your password is sent directly to Bandcamp for sign-in and is never saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var spotifyStep: some View {
        @Bindable var spotify = spotify
        return VStack(alignment: .leading, spacing: 20) {
            stepHeading("Connect Spotify", "Load your personal library and play through Uziq’s bundled Spotify Connect engine.", "music.note.house.fill")
            if spotify.isAuthorized {
                connectedCard("Spotify catalog connected", spotify.profileName ?? "Account connected", "checkmark.circle.fill")
            } else {
                if spotify.isUsingBundledClientID {
                    connectedCard("Spotify app configuration included", "Ready for account login", "checkmark.seal.fill")
                } else {
                    TextField("Spotify Client ID", text: $spotify.clientID).textFieldStyle(.roundedBorder)
                    Text("Development builds need a Spotify Client ID. Packaged family builds can include this automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Connect Spotify Account") { spotify.logIn() }
                    .buttonStyle(.borderedProminent).disabled(!spotify.isConfigured)
            }

            Divider()
            HStack(spacing: 12) {
                Image(systemName: spotify.librespot.status.isRunning ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                    .font(.title2).foregroundStyle(spotify.librespot.status == .ready ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify playback engine").font(.headline)
                    Text(spotify.librespot.status.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !spotify.librespot.status.isRunning {
                    Button("Start Player") { spotify.startPlaybackEngine() }
                        .disabled(spotify.librespot.resolvedExecutableURL == nil)
                }
            }
            if spotify.librespot.resolvedExecutableURL == nil {
                Label("This development build could not find librespot. Packaged Uziq apps include it automatically.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var jellyfinStep: some View {
        @Bindable var jellyfin = jellyfin
        return VStack(alignment: .leading, spacing: 20) {
            stepHeading("Connect Jellyfin", "Browse artists, albums, playlists, favorites, and music from your own server.", "server.rack")
            if jellyfin.isConnected {
                connectedCard(
                    "Jellyfin connected",
                    "\(jellyfin.serverName ?? "Server") · \(jellyfin.profileName ?? jellyfin.username)",
                    "checkmark.circle.fill"
                )
            } else {
                TextField("Server URL, such as http://jellyfin.local:8096", text: $jellyfin.serverAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $jellyfin.username).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $jellyfinPassword).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect Jellyfin") { jellyfin.connect(password: jellyfinPassword) }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            jellyfin.isConnecting || jellyfin.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            jellyfin.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jellyfinPassword.isEmpty
                        )
                    if jellyfin.isConnecting { ProgressView().controlSize(.small) }
                }
                if let error = jellyfin.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            Text("Your password is never stored. The resulting access token is kept in macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeading("Uziq is ready", "You can revisit this assistant or adjust individual connections from Settings at any time.", "checkmark.circle.fill")
            VStack(spacing: 10) {
                statusRow("Local Library", localLibraryStatus, hasLocalLibrary)
                statusRow("Bandcamp", bandcamp.isAuthenticated ? "Connected" : "Not connected", bandcamp.isAuthenticated)
                statusRow("Spotify", spotify.isAuthorized ? "Connected" : "Not connected", spotify.isAuthorized)
                statusRow("Jellyfin", jellyfin.isConnected ? "Connected" : "Not connected", jellyfin.isConnected)
            }
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            Text("Press Space or F8 to play and pause anywhere in Uziq. The bottom player shows which service each track comes from.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func move(by offset: Int) {
        let next = min(OnboardingStep.allCases.count - 1, max(0, step.rawValue + offset))
        step = OnboardingStep(rawValue: next) ?? step
    }

    private func chooseMusicFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Music"
        guard panel.runModal() == .OK else { return }
        library.importFolders(panel.urls)
    }

    private func stepHeading(_ title: String, _ detail: String, _ systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(detail).font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private func setupEmpty(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func connectedCard(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(_ title: String, _ detail: String, _ connected: Bool) -> some View {
        HStack {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
            Text(title).font(.headline)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private var hasLocalLibrary: Bool {
        !library.folderRoots.isEmpty || !library.tracks.isEmpty
    }

    private var localLibraryStatus: String {
        if !library.folderRoots.isEmpty {
            return "\(library.folderRoots.count) folder\(library.folderRoots.count == 1 ? "" : "s")"
        }
        if !library.tracks.isEmpty {
            return "\(library.tracks.count) indexed track\(library.tracks.count == 1 ? "" : "s")"
        }
        return library.isInitialLoadComplete ? "Not configured" : "Checking…"
    }
}
