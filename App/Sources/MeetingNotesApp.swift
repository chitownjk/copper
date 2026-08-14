import SwiftUI
import AppKit

@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var appState = AppState()

    var body: some Scene {
        // SwiftUI requires a Scene. The extra itself is an AppKit NSStatusItem
        // (StatusItemController) so the system cannot tear it down with a
        // MenuBarExtra scene. This Settings host is unused; ⌘, is rebound below.
        Settings {
            EmptyView()
                .environment(appState)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.openSettings()
                }
                .keyboardShortcut(",")
            }
            CommandMenu("Meeting") {
                if appState.status == .recording {
                    Button("Stop Recording") {
                        Task { await appState.stopRecording() }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .control, .option])
                } else {
                    Button("Start Recording") {
                        Task { await appState.startRecording() }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .control, .option])
                }
                if appState.camera.isLive {
                    Button("Stop Virtual Camera") {
                        appState.camera.stopLive()
                    }
                } else {
                    Button("Go Live") {
                        Task { await appState.camera.goLive() }
                    }
                }
                Divider()
                Button("Open Meeting Companion") {
                    appState.mainWindow.show()
                }
                .keyboardShortcut("l")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppState so launch and the dock icon can summon the main
    /// window (E3.2). Reopen is unconditional: status-item popovers and
    /// utility panels count as "visible windows", so the hasVisibleWindows
    /// flag is useless for deciding, and show() already fronts an existing window.
    static var onReopen: (() -> Void)?
    static var dockMenuBuilder: (() -> NSMenu)?
    static var onBecomeActive: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let headless = arguments.contains {
            $0.hasPrefix("--recover-orphans")
                || $0.hasPrefix("--install-camera-extension") || $0.hasPrefix("--uninstall-camera-extension")
                || $0.hasPrefix("--push-camera-frames") || $0.hasPrefix("--camera-passthrough")
        }
        if !headless {
            showWhenReady(attempts: 15)
        }
    }

    /// SwiftUI materializes AppState (which installs onReopen) lazily —
    /// possibly after didFinishLaunching. Retry briefly instead of racing it.
    private func showWhenReady(attempts: Int) {
        if let onReopen = Self.onReopen {
            onReopen()
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.showWhenReady(attempts: attempts - 1)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.onReopen?()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.onBecomeActive?()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        Self.dockMenuBuilder?()
    }
}
