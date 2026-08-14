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
            NavigationSplitView {
                List(selection: $section) {
                    Label("Calendar", systemImage: "calendar")
                        .tag(MainWindowSection.calendar)
                    Label("Library", systemImage: "waveform")
                        .tag(MainWindowSection.library)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
            } detail: {
                switch section {
                case .calendar:
                    CalendarRecordListView()
                case .library:
                    LibraryView(model: libraryModel)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .tint(Brand.accent)
        .onAppear { consumePendingSelection() }
        .onChange(of: appState.pendingLibraryMeetingId) { _, _ in
            consumePendingSelection()
        }
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
        if recording || live || claimed {
            HStack(spacing: 12) {
                if recording {
                    Text("● Recording")
                        .foregroundStyle(.red)
                    Button("Stop Recording") {
                        Task { await appState.stopRecording() }
                    }
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
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
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
                                Text("Starting camera…")
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
                Picker("Background", selection: Binding(
                    get: { appState.camera.backgroundMode },
                    set: { appState.camera.setBackgroundMode($0) }
                )) {
                    Text("None").tag(BackgroundMode.none)
                    Text("Blur").tag(BackgroundMode.blur)
                }
                .pickerStyle(.segmented)

                if appState.camera.backgroundMode == .blur {
                    Picker("Blur strength", selection: Binding(
                        get: { appState.camera.blurStrength },
                        set: { appState.camera.setBlurStrength($0) }
                    )) {
                        ForEach(BlurStrength.allCases, id: \.self) { strength in
                            Text(strength.label).tag(strength)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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

        nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }
}
