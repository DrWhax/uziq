import AppKit
import Darwin
import SwiftUI

@main
struct UziqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: LibraryStore
    @State private var playback: PlaybackEngine
    @State private var bandcamp: BandcampStore
    @State private var spotify: SpotifyStore
    @State private var jellyfin: JellyfinStore
    @State private var queue: PlaybackQueueStore

    init() {
        Self.migrateSwiftRunPreferencesIfNeeded()
        _library = State(initialValue: LibraryStore())
        _playback = State(initialValue: PlaybackEngine())
        _bandcamp = State(initialValue: BandcampStore())
        _spotify = State(initialValue: SpotifyStore())
        _jellyfin = State(initialValue: JellyfinStore())
        _queue = State(initialValue: PlaybackQueueStore())
    }

    var body: some Scene {
        WindowGroup("Uziq") {
            ContentView()
                .environment(library)
                .environment(playback)
                .environment(bandcamp)
                .environment(spotify)
                .environment(jellyfin)
                .environment(queue)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") {
                    library.presentFolderImporter()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    queue.toggle()
                }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Previous Track") {
                    queue.previous()
                }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Track") {
                    queue.next()
                }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Replay Current Track") {
                    queue.replay()
                }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Show Now Playing") {
                    NotificationCenter.default.post(name: .uziqShowNowPlaying, object: nil)
                }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Up Next") {
                    NotificationCenter.default.post(name: .uziqShowQueue, object: nil)
                }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(queue.shuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On") {
                    queue.shuffleEnabled.toggle()
                }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button(queue.repeatMode.title) { queue.cycleRepeatMode() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Volume Up") { queue.volume = min(1, queue.volume + 0.05) }
                Button("Volume Down") { queue.volume = max(0, queue.volume - 0.05) }
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(playback)
                .environment(bandcamp)
                .environment(spotify)
                .environment(jellyfin)
                .environment(queue)
        }
    }

    private static func migrateSwiftRunPreferencesIfNeeded() {
        guard Bundle.main.bundleIdentifier == "com.crambledeggs.uziq" else { return }
        let defaults = UserDefaults.standard
        let migrationKey = "did-migrate-swift-run-preferences"
        guard !defaults.bool(forKey: migrationKey),
              let legacy = defaults.persistentDomain(forName: "Uziq") else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migrationKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM launches an executable rather than a packaged .app. Explicitly
        // opt into the regular application policy so WindowGroup is visible and
        // receives a Dock/menu-bar presence when started with `swift run`.
        NSApp.setActivationPolicy(.regular)
        if let iconURL = applicationIconURL,
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        DiagnosticsLog.shared.record("app", "Uziq launched")
        installWorkspaceObservers()
        installTerminationSignalHandlers()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            if event.keyCode == 49 { // Space
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSTextField || responder is NSTextView { return event }
                NotificationCenter.default.post(name: .uziqToggleQueuePlayback, object: nil)
                return nil
            }

            if event.keyCode == 100 { // F8 on Apple keyboards
                NotificationCenter.default.post(name: .uziqToggleQueuePlayback, object: nil)
                return nil
            }
            return event
        }
    }

    private var applicationIconURL: URL? {
#if DEBUG
        // `swift run` is not a packaged app. Read the repository's canonical
        // artwork directly so replacing Images/logo.png takes effect on the
        // next launch without maintaining a second copied resource by hand.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentIcon = projectRoot.appendingPathComponent("Images/logo.png")
        if FileManager.default.fileExists(atPath: developmentIcon.path) {
            return developmentIcon
        }
#endif
        return Bundle.main.url(forResource: "logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "logo", withExtension: "png")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLog.shared.record("app", "Uziq terminating")
        NotificationCenter.default.post(name: .uziqWillTerminate, object: nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                DiagnosticsLog.shared.record("system", "Mac will sleep")
                NotificationCenter.default.post(name: .uziqWillSleep, object: nil)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                DiagnosticsLog.shared.record("system", "Mac woke from sleep")
                NotificationCenter.default.post(name: .uziqDidWake, object: nil)
            }
        ]
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task { @MainActor in NSApp.terminate(nil) }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }
}

extension Notification.Name {
    static let uziqTogglePlayback = Notification.Name("uziq.togglePlayback")
    static let uziqTrackPlayed = Notification.Name("uziq.trackPlayed")
    static let uziqLocalPlaybackStarted = Notification.Name("uziq.localPlaybackStarted")
    static let uziqWillTerminate = Notification.Name("uziq.willTerminate")
    static let uziqPlaybackItemFinished = Notification.Name("uziq.playbackItemFinished")
    static let uziqToggleQueuePlayback = Notification.Name("uziq.toggleQueuePlayback")
    static let uziqShowNowPlaying = Notification.Name("uziq.showNowPlaying")
    static let uziqShowQueue = Notification.Name("uziq.showQueue")
    static let uziqShowOnboarding = Notification.Name("uziq.showOnboarding")
    static let uziqWillSleep = Notification.Name("uziq.willSleep")
    static let uziqDidWake = Notification.Name("uziq.didWake")
}
