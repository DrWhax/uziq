import AppKit
import SwiftUI

@main
struct UziqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    @State private var playback = PlaybackEngine()

    var body: some Scene {
        WindowGroup("Uziq") {
            ContentView()
                .environment(library)
                .environment(playback)
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
                Button("Play / Pause") { playback.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Previous Track") { playback.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Track") { playback.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

extension Notification.Name {
    static let uziqTogglePlayback = Notification.Name("uziq.togglePlayback")
    static let uziqTrackPlayed = Notification.Name("uziq.trackPlayed")
}
