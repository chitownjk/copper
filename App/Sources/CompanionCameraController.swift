import Foundation
import AVFoundation
import CoreMedia
import Observation
import CompanionVideoCore

/// Owns the persistent go-live feed: real camera → FrameComposer (normalize
/// + logo) → sink stream → virtual camera. This is the product path — the
/// timed `--camera-passthrough` probe remains only as a dev affordance.
///
/// Off by default at every launch: the camera never turns on without an
/// explicit user action.
@MainActor
@Observable
final class CompanionCameraController {
    enum State: Equatable {
        case off
        case live
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var logoURL: URL?

    private var capture: CameraCaptureService?
    private var sink: CameraSinkClient?
    private let composer = FrameComposer()

    nonisolated static let logoDefaultsKey = "videoLogoPath"

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.logoDefaultsKey) {
            let url = URL(fileURLWithPath: path)
            if composer.setLogo(url: url) {
                logoURL = url
            } else {
                // Logo file moved or deleted since last run — forget it.
                UserDefaults.standard.removeObject(forKey: Self.logoDefaultsKey)
            }
        }
    }

    var isLive: Bool { state == .live }

    func goLive() async {
        guard state != .live else { return }
        guard await CameraCaptureService.requestAccess() else {
            state = .failed("Camera access denied — enable it in System Settings > Privacy & Security > Camera")
            return
        }
        do {
            let sink = CameraSinkClient()
            try sink.connect()
            let capture = CameraCaptureService()
            let composer = self.composer
            capture.onFrame = { sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      let composed = composer.compose(pixelBuffer) else { return }
                sink.pushPixelBuffer(composed)
            }
            try capture.start(excludingUniqueID: CameraSinkClient.deviceUID)
            self.sink = sink
            self.capture = capture
            state = .live
        } catch {
            sink?.disconnect()
            sink = nil
            capture = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stopLive() {
        capture?.stop()
        capture = nil
        sink?.disconnect()
        sink = nil
        state = .off
    }

    /// Sets or clears the logo; persists across launches. Applies
    /// immediately, including mid-stream.
    func setLogo(url: URL?) {
        if let url {
            guard composer.setLogo(url: url) else {
                state = state == .live ? .live : .failed("Could not load logo image")
                return
            }
            UserDefaults.standard.set(url.path, forKey: Self.logoDefaultsKey)
            logoURL = url
        } else {
            composer.setLogo(url: nil)
            UserDefaults.standard.removeObject(forKey: Self.logoDefaultsKey)
            logoURL = nil
        }
    }
}
