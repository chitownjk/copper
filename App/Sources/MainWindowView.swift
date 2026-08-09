import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import CompanionVideoCore
import UniformTypeIdentifiers

/// The unified main window (E3.2): everything in one place, one click deep.
/// Sidebar sections reuse the existing Library and Settings views; Camera is
/// the new live-preview pane. The menu bar remains the quick-access surface.
enum MainSection: String, CaseIterable, Identifiable {
    case library
    case camera
    case general
    case transcription
    case summaries
    case storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: return "Library"
        case .camera: return "Camera"
        case .general: return "General"
        case .transcription: return "Transcription"
        case .summaries: return "Summaries"
        case .storage: return "Storage & Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "books.vertical"
        case .camera: return "video"
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .summaries: return "text.justify.left"
        case .storage: return "lock.shield"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var section: MainSection = .library
    @State private var libraryModel = LibraryModel()
    @State private var settingsModel = SettingsModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("App") {
                    sidebarRow(.library)
                }
                Section("Settings") {
                    sidebarRow(.camera)
                    sidebarRow(.general)
                    sidebarRow(.transcription)
                    sidebarRow(.summaries)
                    sidebarRow(.storage)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch section {
            case .library:
                LibraryView(model: libraryModel)
            case .camera:
                CameraPaneView()
            case .general:
                GeneralSettingsTab(model: settingsModel)
            case .transcription:
                TranscriptionSettingsTab(model: settingsModel)
            case .summaries:
                SummarizationSettingsTab(model: settingsModel)
            case .storage:
                StorageSettingsTab(model: settingsModel)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private func sidebarRow(_ section: MainSection) -> some View {
        Label(section.label, systemImage: section.symbol).tag(section)
    }
}

// MARK: - Camera pane

struct CameraPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var selfView = true

    var body: some View {
        VStack(spacing: 16) {
            CameraPreviewView(mirrored: selfView)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if !appState.camera.isLive {
                        VStack(spacing: 8) {
                            Image(systemName: "video.slash")
                                .font(.largeTitle)
                            Text("Camera is off")
                            Text("Go live to feed \"Meeting Companion Camera\" and see the preview.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            HStack {
                if appState.camera.isLive {
                    Button("Stop Virtual Camera") { appState.camera.stopLive() }
                } else {
                    Button("Go Live") { Task { await appState.camera.goLive() } }
                        .buttonStyle(.borderedProminent)
                }
                Picker("Preview", selection: $selfView) {
                    Text("Self view").tag(true)
                    Text("What others see").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
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
                        if let url = appState.camera.logoURL {
                            Text(url.lastPathComponent)
                                .foregroundStyle(.secondary)
                            Button("Change…") { chooseLogo() }
                            Button("Remove") { appState.camera.setLogo(url: nil) }
                        } else {
                            Button("Add Logo…") { chooseLogo() }
                        }
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
            appState.camera.setLogo(url: url)
        }
    }
}

// MARK: - Live preview

/// Hosts an AVSampleBufferDisplayLayer fed by the controller's preview tee.
/// "Self view" mirrors the layer (display-only) the way meeting apps mirror
/// your own tile; "what others see" shows the true outgoing orientation.
private struct CameraPreviewView: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        appState.camera.previewConsumer = { [weak view] sampleBuffer in
            view?.enqueue(sampleBuffer)
        }
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.setMirrored(mirrored)
    }

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) {
        // The tee outlives the pane harmlessly; cheapest correct cleanup.
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

        func setMirrored(_ mirrored: Bool) {
            displayLayer.sublayerTransform = CATransform3DIdentity
            displayLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }

        nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }
}
