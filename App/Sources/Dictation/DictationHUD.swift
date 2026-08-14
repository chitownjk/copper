import AppKit
import SwiftUI

enum DictationHUDPhase: Equatable {
    case listening(handsFree: Bool)
    case transcribing
    case inserted(String)
    case copied(String)
    case blocked(String)
}

/// Small non-activating HUD. Must not steal key focus or the insert lands
/// in the wrong app.
@MainActor
final class DictationHUDController {
    var onStop: (() -> Void)?

    private var panel: NSPanel?
    private var host: NSHostingView<DictationHUDView>?

    func show(_ phase: DictationHUDPhase) {
        let view = DictationHUDView(phase: phase, onStop: { [weak self] in
            self?.onStop?()
        })
        if let host {
            host.rootView = view
            if panel?.isVisible != true {
                position(panel)
                panel?.orderFrontRegardless()
            }
            return
        }

        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        let size = NSSize(width: 260, height: 72)
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
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 48
        )
        panel.setFrameOrigin(origin)
    }
}

struct DictationHUDView: View {
    let phase: DictationHUDPhase
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isListening {
                Button("Stop", action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 260, height: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.accent.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    private var icon: String {
        switch phase {
        case .listening: return "mic.fill"
        case .transcribing: return "text.badge.waveform"
        case .inserted: return "checkmark.circle.fill"
        case .copied: return "doc.on.clipboard"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .listening: return Brand.accent
        case .transcribing: return Brand.accent
        case .inserted: return .green
        case .copied: return .orange
        case .blocked: return .orange
        }
    }

    private var title: String {
        switch phase {
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .inserted:
            return "Inserted"
        case .copied:
            return "Copied — press ⌘V"
        case .blocked:
            return "Can’t dictate"
        }
    }

    private var subtitle: String {
        switch phase {
        case .listening(let handsFree):
            return handsFree
                ? "Control-Option, Esc, or Stop"
                : "Release to paste · Esc cancels"
        case .transcribing:
            return "On this Mac — not sent anywhere"
        case .inserted(let method):
            return method
        case .copied(let method):
            return method
        case .blocked(let message):
            return message
        }
    }
}
