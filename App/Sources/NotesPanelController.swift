import AppKit
import SwiftUI

@MainActor
final class NotesPanelController {
    private var panel: NSPanel?
    private var controller: NotesController?

    func show(meetingId: String, recordingStart: Date) {
        let notesController = NotesController(
            meetingId: meetingId,
            recordingStart: recordingStart
        )
        self.controller = notesController

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Meeting Notes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NotesPanelView(controller: notesController))

        // Anchor upper-right of the main screen.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 16,
                y: visible.maxY - panel.frame.height - 16
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() async {
        if let controller = controller {
            await controller.flush()
        }
        panel?.orderOut(nil)
        panel = nil
        controller = nil
    }
}
