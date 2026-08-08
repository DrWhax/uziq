import AppKit
import Darwin
import SwiftUI

@main
struct UziqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    @State private var playback = PlaybackEngine()
    @State private var bandcamp = BandcampStore()
    @State private var spotify = SpotifyStore()

    var body: some Scene {
        WindowGroup("Uziq") {
            ContentView()
                .environment(library)
                .environment(playback)
                .environment(bandcamp)
                .environment(spotify)
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
                    spotify.isUziqPlaybackActive ? spotify.togglePlayback() : playback.toggle()
                }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Previous Track") {
                    spotify.isUziqPlaybackActive ? spotify.previous() : playback.previous()
                }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Track") {
                    spotify.isUziqPlaybackActive ? spotify.next() : playback.next()
                }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(playback)
                .environment(bandcamp)
                .environment(spotify)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM launches an executable rather than a packaged .app. Explicitly
        // opt into the regular application policy so WindowGroup is visible and
        // receives a Dock/menu-bar presence when started with `swift run`.
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "logo", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        installTerminationSignalHandlers()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            if event.keyCode == 49 { // Space
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSTextField || responder is NSTextView { return event }
                NotificationCenter.default.post(name: .uziqTogglePlayback, object: nil)
                return nil
            }

            if event.keyCode == 100 { // F8 on Apple keyboards
                NotificationCenter.default.post(name: .uziqTogglePlayback, object: nil)
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .uziqWillTerminate, object: nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
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
}
