import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var session: SettingsSession?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show(tab: SettingsTab = .general) {
        if let session, let window {
            session.tab = tab
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if tab == .camera {
                Task { await appState.camera.goLive() }
            }
            return
        }

        let session = SettingsSession(tab: tab)
        self.session = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(session: session).environment(appState)
        )
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Hidden windows keep their hosting view, so SwiftUI onDisappear is
    /// not reliable here. Stop the settings-started feed on close.
    func windowWillClose(_ notification: Notification) {
        if session?.tab == .camera {
            appState.camera.stopLive()
        }
    }
}
