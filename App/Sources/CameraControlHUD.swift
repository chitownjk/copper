import AppKit
import SwiftUI
import CompanionVideoCore
import UniformTypeIdentifiers
import Observation

enum MeetingHUDTab: String, CaseIterable, Identifiable {
    case camera
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: return "Camera"
        case .notes: return "Notes"
        }
    }
}

@MainActor
@Observable
final class MeetingHUDModel {
    var tab: MeetingHUDTab = .camera
    var notes: NotesController?
    var showsCamera = false

    var showsNotes: Bool { notes != nil }
    var showsTabs: Bool { showsCamera && showsNotes }
}

/// In-call camera + notes. One floating box, Camera / Notes tabs.
/// Shown while Meet/Zoom/Teams has Copper Camera claimed, a physical
/// camera is in use, or a recording is taking notes. Must not steal
/// key focus from the meeting app except when a field is being edited.
@MainActor
final class CameraControlHUD {
    private var panel: NonActivatingHUDPanel?
    private var host: NSHostingView<AnyView>?
    private weak var appState: AppState?
    private var hideGeneration = 0
    private let model = MeetingHUDModel()

    func show(appState: AppState) {
        hideGeneration += 1
        self.appState = appState
        model.showsCamera = true
        if !model.showsNotes {
            model.tab = .camera
        }
        present(appState: appState)
    }

    func showNotes(appState: AppState, meetingId: String, recordingStart: Date) {
        hideGeneration += 1
        self.appState = appState
        model.notes = NotesController(meetingId: meetingId, recordingStart: recordingStart)
        model.tab = .notes
        present(appState: appState)
    }

    func hideNotes() async {
        if let notes = model.notes {
            await notes.flush()
        }
        model.notes = nil
        if model.showsCamera {
            model.tab = .camera
            if let appState {
                present(appState: appState)
            }
        } else {
            hidePanel()
        }
    }

    /// Camera call ended. Keep the box if notes are still live.
    func hideCamera() {
        model.showsCamera = false
        if model.showsNotes {
            model.tab = .notes
            if let appState {
                present(appState: appState)
            }
        } else {
            hidePanel()
        }
    }

    func hide() {
        hideCamera()
    }

    private func present(appState: AppState) {
        let root = AnyView(MeetingHUDView(model: model).environment(appState))
        let size = panelSize(for: appState)
        if let host {
            host.rootView = root
            host.frame.size = size
            if let panel {
                growIfNeeded(panel, to: size)
                if panel.isVisible != true {
                    position(panel)
                    panel.orderFrontRegardless()
                }
            }
            return
        }

        let host = NSHostingView(rootView: root)
        host.frame.size = size
        let panel = NonActivatingHUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 320, height: 280)
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

    private func hidePanel() {
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
                self.model.showsCamera = false
                self.model.notes = nil
            }
        })
    }

    private func cameraBodyHeight(for appState: AppState) -> CGFloat {
        let recordOffer: CGFloat = appState.shouldOfferMeetingRecord ? 72 : 0
        let sourceWarning: CGFloat =
            (!appState.virtualCameraClaimed && appState.cameraUse.physicalCameraInUse) ? 56 : 0
        return 400 + recordOffer + sourceWarning
    }

    private func panelSize(for appState: AppState) -> NSSize {
        let tabs: CGFloat = model.showsTabs ? 36 : 0
        if model.tab == .notes {
            return NSSize(width: 360, height: 520 + tabs)
        }
        return NSSize(width: 360, height: cameraBodyHeight(for: appState) + tabs)
    }

    private func growIfNeeded(_ panel: NSPanel, to size: NSSize) {
        var frame = panel.frame
        var changed = false
        if frame.width < size.width {
            frame.size.width = size.width
            changed = true
        }
        if frame.height < size.height {
            let top = frame.maxY
            frame.size.height = size.height
            frame.origin.y = top - size.height
            changed = true
        }
        if changed {
            panel.setFrame(frame, display: true)
        }
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

struct MeetingHUDView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: MeetingHUDModel

    private var closeButton: some View {
        Button {
            appState.dismissCameraHUD()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showsTabs {
                tabBar
                Divider().opacity(0.35)
            }
            Group {
                if model.tab == .notes, let notes = model.notes {
                    NotesPanelView(controller: notes)
                } else {
                    CameraControlHUDView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.accent.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(MeetingHUDTab.allCases) { tab in
                let enabled = (tab == .camera && model.showsCamera) || (tab == .notes && model.showsNotes)
                Button {
                    if enabled { model.tab = tab }
                } label: {
                    Text(tab.label)
                        .font(.system(size: 12, weight: model.tab == tab ? .semibold : .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            model.tab == tab
                                ? Brand.accent.opacity(0.18)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct CameraControlHUDView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if showsPhysicalCameraWarning {
                physicalCameraWarning
            }
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
        .frame(maxWidth: .infinity, alignment: .top)
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
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            appState.dismissCameraHUD()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private var statusTitle: String {
        if appState.camera.isRecordingLoop {
            return "Recording loop"
        }
        if case .failed = appState.camera.state {
            return "Copper Camera unavailable"
        }
        switch appState.camera.outputMode {
        case .live: return appState.camera.isLive ? "Live" : "Standby"
        case .off: return "Camera off"
        }
    }

    private var showsPhysicalCameraWarning: Bool {
        !appState.virtualCameraClaimed && appState.cameraUse.physicalCameraInUse
    }

    private var physicalCameraWarning: some View {
        Label {
            Text("This call is using another camera. Select **Copper Camera** in Meet or Zoom to show this output.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "video.badge.exclamationmark")
                .foregroundStyle(Brand.accent)
        }
        .padding(8)
        .background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
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
