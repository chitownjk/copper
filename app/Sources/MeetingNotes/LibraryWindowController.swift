import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController {
    private var window: NSWindow?
    private let model = LibraryModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Notes Library"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
