import AppKit
import SwiftUI

enum ToastKind {
    case info, success, error

    var icon: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:    return .blue
        case .success: return .green
        case .error:   return .red
        }
    }
}

@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private var queue: [(ToastKind, String, String?)] = []
    private var current: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ kind: ToastKind, title: String, subtitle: String? = nil) {
        queue.append((kind, title, subtitle))
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let (kind, title, subtitle) = queue.removeFirst()
        present(kind: kind, title: title, subtitle: subtitle)
    }

    private func present(kind: ToastKind, title: String, subtitle: String?) {
        let view = ToastView(kind: kind, title: title, subtitle: subtitle)
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        let fitting = host.fittingSize
        let width = max(280, min(420, fitting.width + 24))
        let height = max(56, fitting.height + 16)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.contentView = host

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - width - 16,
                y: visible.maxY - height - 16
            )
            panel.setFrameOrigin(origin)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        current = panel

        dismissTask?.cancel()
        let duration: UInt64 = kind == .error ? 6_000_000_000 : 3_500_000_000
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            await MainActor.run { self?.dismiss() }
        }
    }

    private func dismiss() {
        guard let panel = current else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            Task { @MainActor in
                self?.current = nil
                self?.presentNextIfIdle()
            }
        })
    }
}

private struct ToastView: View {
    let kind: ToastKind
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.icon)
                .foregroundStyle(kind.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .frame(maxWidth: 400, alignment: .leading)
    }
}
