import AppKit
import SwiftUI
import CompanionVideoCore
import UniformTypeIdentifiers

/// In-call camera controls. Shown while Meet/Zoom/Teams has Meeting
/// Companion Camera claimed, or a physical camera is in use the way the
/// old "Record this?" prompt used to fire. Must not steal key focus from
/// the meeting app except when a text field is actually being edited.
@MainActor
final class CameraControlHUD {
    private var panel: NonActivatingHUDPanel?
    private var host: NSHostingView<AnyView>?
    private weak var appState: AppState?
    private var hideGeneration = 0

    func show(appState: AppState) {
        hideGeneration += 1
        self.appState = appState
        let root = AnyView(CameraControlHUDView().environment(appState))
        if let host {
            host.rootView = root
            let size = NSSize(width: 348, height: appState.shouldOfferMeetingRecord ? 472 : 400)
            host.frame.size = size
            if let panel, panel.frame.size != size {
                var frame = panel.frame
                let top = frame.maxY
                frame.size = size
                frame.origin.y = top - size.height
                panel.setFrame(frame, display: true)
            }
            if panel?.isVisible != true {
                position(panel)
                panel?.orderFrontRegardless()
            }
            return
        }

        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 348, height: appState.shouldOfferMeetingRecord ? 472 : 400)
        let panel = NonActivatingHUDPanel(
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
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            Task { @MainActor in
                guard self.hideGeneration == generation else { return }
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
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 12
        ))
    }
}

private final class NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CameraControlHUDView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if appState.shouldOfferMeetingRecord {
                meetingRecordRow
                Divider().opacity(0.35)
            }
            modeToggle
            loopRow
            Divider().opacity(0.35)
            offCardBlock
            Divider().opacity(0.35)
            liveControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 348, height: appState.shouldOfferMeetingRecord ? 472 : 400, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.accent.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusTitle)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("Meeting camera")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if appState.camera.isRecordingLoop {
            return "Recording loop"
        }
        switch appState.camera.outputMode {
        case .live: return appState.camera.isLive ? "Live" : "Standby"
        case .off: return "Camera off"
        }
    }

    private var statusColor: Color {
        if appState.camera.isRecordingLoop { return Brand.accent }
        if appState.camera.outputMode == .live, appState.camera.isLive { return .green }
        return Brand.accent
    }

    private var meetingRecordRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(Brand.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Record this meeting")
                    .font(.system(size: 13, weight: .semibold))
                Text("Companion will not start unless you say yes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Not now") { appState.dismissMeetingRecord() }
                .controlSize(.small)
            Button("Yes") { appState.acceptMeetingRecord() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Brand.accent)
        }
    }

    private var modeToggle: some View {
        Picker("Output", selection: Binding(
            get: { appState.camera.outputMode },
            set: { appState.camera.applyOutputMode($0) }
        )) {
            Text("Live camera").tag(CompanionCameraController.OutputMode.live)
            Text("Camera off").tag(CompanionCameraController.OutputMode.off)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(appState.camera.isRecordingLoop)
        .controlSize(.small)
    }

    private var loopRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let remaining = appState.camera.loopRecordSecondsLeft {
                    Text("Recording — \(remaining)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Record loop (5s)") {
                        Task { await appState.camera.recordLoop() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    Spacer()
                    Button("Clear") { appState.camera.clearLoop() }
                        .controlSize(.small)
                        .disabled(appState.camera.loopDisplayName == nil)
                }
            }
            if let err = appState.camera.lastLoopError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(appState.camera.loopDisplayName ?? "No loop yet — record one from this camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var offCardBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Off card")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Title", text: Binding(
                get: { appState.camera.offCardTitle },
                set: { appState.camera.offCardTitle = $0 }
            ), prompt: Text(NSFullUserName()))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            TextField("Subtitle", text: Binding(
                get: { appState.camera.offCardSubtitle },
                set: { appState.camera.offCardSubtitle = $0 }
            ), prompt: Text("Optional"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            HStack {
                Text(appState.camera.stillDisplayName ?? "No still")
                    .font(.caption)
                    .foregroundStyle(appState.camera.stillDisplayName == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Button("Choose…") { chooseStill() }
                    .controlSize(.small)
                Button("Clear") { appState.camera.clearStill() }
                    .controlSize(.small)
                    .disabled(appState.camera.stillDisplayName == nil)
            }
        }
    }

    private var liveControls: some View {
        let off = appState.camera.outputMode == .off
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Blur", selection: Binding(
                get: { appState.camera.liveBlur },
                set: { appState.camera.setLiveBlur($0) }
            )) {
                ForEach(CompanionCameraController.LiveBlur.allCases) { blur in
                    Text(blur.label).tag(blur)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(off)
            .opacity(off ? 0.45 : 1)

            HStack(spacing: 8) {
                Text("Logo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Logo", selection: Binding(
                    get: { appState.camera.selectedLogoID ?? "" },
                    set: { appState.camera.selectLogo(id: $0.isEmpty ? nil : $0) }
                )) {
                    Text("None").tag("")
                    ForEach(appState.camera.savedLogos) { logo in
                        Text(logo.displayName).tag(logo.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Button("Add…") { chooseLogo() }
                    .controlSize(.small)
            }

            Toggle("Mirror", isOn: Binding(
                get: { appState.camera.mirrorsOutput },
                set: { appState.camera.setMirrorOutput($0) }
            ))
            .controlSize(.small)
            .disabled(off)
            .opacity(off ? 0.45 : 1)
        }
    }

    private func chooseStill() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a still image (PNG or JPEG)."
        if panel.runModal() == .OK, let url = panel.url {
            appState.camera.setStill(from: url)
        }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .heic, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image (PNG with transparency works best)."
        if panel.runModal() == .OK, let url = panel.url {
            appState.camera.addLogo(from: url)
        }
    }
}
