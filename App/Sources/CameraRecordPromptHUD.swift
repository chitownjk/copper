import AppKit
import SwiftUI

/// Dictation-style tray. Yes is a one-off mic+system start. Never auto-starts.
@MainActor
final class CameraRecordPromptHUD {
    var onYes: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var host: NSHostingView<CameraRecordPromptView>?

    func show() {
        let view = CameraRecordPromptView(
            onYes: { [weak self] in self?.onYes?() },
            onDismiss: { [weak self] in self?.onDismiss?() }
        )
        if let host {
            host.rootView = view
            if panel?.isVisible != true {
                position(panel)
                panel?.orderFrontRegardless()
            }
            return
        }

        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 320, height: 88)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        self.host = host
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            Task { @MainActor in
                self.panel = nil
                self.host = nil
            }
        })
    }

    private func position(_ panel: NSPanel?) {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 48
        ))
    }
}

struct CameraRecordPromptView: View {
    let onYes: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Record this?")
                    .font(.system(size: 13, weight: .semibold))
                Text("A meeting app turned a camera on. Companion will not start unless you say yes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Not now", action: onDismiss)
                .controlSize(.small)
            Button("Yes", action: onYes)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Brand.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320, height: 88)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.accent.opacity(0.35), lineWidth: 0.8)
        )
    }
}
