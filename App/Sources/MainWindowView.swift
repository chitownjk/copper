import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import CompanionVideoCore
import UniformTypeIdentifiers

enum MainWindowSection: String, Hashable {
    case calendar
    case library
}

/// Calendar above Library. Settings live in the Settings window (⌘,).
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var libraryModel = LibraryModel()
    @State private var section: MainWindowSection = .library

    var body: some View {
        VStack(spacing: 0) {
            sessionBanner
            HSplitView {
                navColumn
                    .frame(minWidth: 150, idealWidth: 168, maxWidth: 188)
                Group {
                    switch section {
                    case .calendar:
                        CalendarRecordListView()
                    case .library:
                        LibraryView(model: libraryModel)
                    }
                }
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.accent)
        .onAppear { consumePendingSelection() }
        .onChange(of: appState.pendingLibraryMeetingId) { _, _ in
            consumePendingSelection()
        }
    }

    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            navRow("Calendar", systemImage: "calendar", section: .calendar)
            navRow("Library", systemImage: "waveform", section: .library)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func navRow(_ title: String, systemImage: String, section: MainWindowSection) -> some View {
        Button {
            self.section = section
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    self.section == section ? Brand.accent.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func consumePendingSelection() {
        guard let id = appState.pendingLibraryMeetingId else { return }
        section = .library
        libraryModel.selectMeeting(id)
        appState.pendingLibraryMeetingId = nil
    }

    /// Reachable from the main window / dock even if the extra is gone —
    /// including the test-card path, when Zoom/Meet has claimed the virtual
    /// camera without a Go Live.
    @ViewBuilder
    private var sessionBanner: some View {
        let recording = appState.status == .recording
        let live = appState.camera.isLive
        let claimed = appState.virtualCameraClaimed && !live
        HStack(spacing: 12) {
            if recording {
                Text("● Recording")
                    .foregroundStyle(.red)
                Button("Stop Recording") {
                    Task { await appState.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Record now") {
                    Task { await appState.startRecording(.instant) }
                }
                .buttonStyle(.borderedProminent)
                .help("Start a walk-in meeting. No calendar needed. Microphone only.")
            }
            if live {
                Text("● Camera Live")
                Button("Stop Virtual Camera") {
                    appState.camera.stopLive()
                }
            } else {
                if claimed {
                    Text("Virtual camera in use (test card)")
                        .foregroundStyle(.secondary)
                }
                Button("Go Live") {
                    Task { await appState.camera.goLive() }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Camera pane

struct CameraPaneView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            CameraPreviewView()
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if !appState.camera.isLive {
                        VStack(spacing: 8) {
                            if case .failed = appState.camera.state {
                                Image(systemName: "video.slash")
                                    .font(.largeTitle)
                                Text("Camera could not start")
                            } else {
                                ProgressView()
                                Text("Starting…")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }

            if case .failed(let message) = appState.camera.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Form {
                Picker("Output", selection: Binding(
                    get: { appState.camera.outputMode },
                    set: { appState.camera.applyOutputMode($0) }
                )) {
                    Text("Live camera").tag(CompanionCameraController.OutputMode.live)
                    Text("Camera off").tag(CompanionCameraController.OutputMode.off)
                }
                .pickerStyle(.segmented)
                .disabled(appState.camera.isRecordingLoop)

                LabeledContent("Loop") {
                    HStack {
                        if let remaining = appState.camera.loopRecordSecondsLeft {
                            Text("Recording — \(remaining)")
                                .foregroundStyle(Brand.accent)
                            ProgressView().controlSize(.small)
                        } else {
                            Text(appState.camera.loopDisplayName ?? "None")
                                .foregroundStyle(appState.camera.loopDisplayName == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(maxWidth: 140, alignment: .leading)
                            Button("Record 5s") {
                                Task { await appState.camera.recordLoop() }
                            }
                            Button("File…") { chooseLoop() }
                                .help("Use a file as a fallback. A just-recorded loop looks current.")
                            Button("Clear") { appState.camera.clearLoop() }
                                .disabled(appState.camera.loopDisplayName == nil)
                        }
                    }
                }

                Text("Record a 5-second loop from this camera, then flip to Camera off to play it. Meet's own camera toggle is not this — leave Meet's camera ON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Off-card title", text: Binding(
                    get: { appState.camera.offCardTitle },
                    set: { appState.camera.offCardTitle = $0 }
                ), prompt: Text(NSFullUserName()))

                TextField("Off-card subtitle", text: Binding(
                    get: { appState.camera.offCardSubtitle },
                    set: { appState.camera.offCardSubtitle = $0 }
                ), prompt: Text("Optional"))

                LabeledContent("Still") {
                    HStack {
                        Text(appState.camera.stillDisplayName ?? "None")
                            .foregroundStyle(appState.camera.stillDisplayName == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: 180, alignment: .leading)
                        Button("Choose…") { chooseStill() }
                        Button("Clear") { appState.camera.clearStill() }
                            .disabled(appState.camera.stillDisplayName == nil)
                    }
                }

                Text("Off-state order: recorded loop, then still, then the off card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Blur", selection: Binding(
                    get: { appState.camera.liveBlur },
                    set: { appState.camera.setLiveBlur($0) }
                )) {
                    ForEach(CompanionCameraController.LiveBlur.allCases) { blur in
                        Text(blur.label).tag(blur)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appState.camera.outputMode == .off)

                LabeledContent("Logo") {
                    HStack {
                        Picker("Saved logo", selection: Binding(
                            get: { appState.camera.selectedLogoID ?? "" },
                            set: { appState.camera.selectLogo(id: $0.isEmpty ? nil : $0) }
                        )) {
                            Text("None").tag("")
                            ForEach(appState.camera.savedLogos) { logo in
                                Text(logo.displayName).tag(logo.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        Button("Add…") { chooseLogo() }
                        Button("Remove") {
                            if let id = appState.camera.selectedLogoID {
                                appState.camera.removeLogo(id: id)
                            }
                        }
                        .disabled(appState.camera.selectedLogoID == nil)
                    }
                }

                if appState.camera.logoURL != nil {
                    Picker("Logo size", selection: Binding(
                        get: { appState.camera.logoSize },
                        set: { appState.camera.setLogoSize($0) }
                    )) {
                        ForEach(CompanionCameraController.LogoSize.allCases, id: \.self) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("Mirror output (flips what others see too)", isOn: Binding(
                    get: { appState.camera.mirrorsOutput },
                    set: { appState.camera.setMirrorOutput($0) }
                ))
                .disabled(appState.camera.outputMode == .off)
            }
            .formStyle(.grouped)
        }
        .padding()
        .navigationTitle("Camera")
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

    private func chooseLoop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a short loop (mp4 or mov). Prefer Record 5s so it matches what you are wearing."
        if panel.runModal() == .OK, let url = panel.url {
            appState.camera.setLoop(from: url)
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
}

// MARK: - Live preview

/// Hosts an AVSampleBufferDisplayLayer fed by the controller's preview tee.
/// One preview: the composed outgoing frames (what others see). Self-view
/// was dropped — see IMPLEMENTATION_LOG for why it rendered black.
private struct CameraPreviewView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        appState.camera.previewConsumer = { [weak view] sampleBuffer in
            view?.enqueue(sampleBuffer)
        }
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {}

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) {
        // Leaving Camera settings now stops goLive (test card may return
        // if a meeting client still holds the virtual camera). The tee
        // is cleared with stopLive; nothing to do here.
    }

    final class PreviewNSView: NSView {
        private let displayLayer = AVSampleBufferDisplayLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            displayLayer.videoGravity = .resizeAspect
            layer = displayLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func enqueue(_ sampleBuffer: CMSampleBuffer) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }
}
