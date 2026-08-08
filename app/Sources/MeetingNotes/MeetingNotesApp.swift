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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pure menu-bar app — no dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
