import SwiftUI
import AppKit

@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppState so launch and the dock icon can summon the main
    /// window (E3.2). Reopen is unconditional: the MenuBarExtra's status
    /// windows count as "visible windows", so the hasVisibleWindows flag is
    /// useless for deciding, and show() already fronts an existing window.
    static var onReopen: (() -> Void)?

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
}
