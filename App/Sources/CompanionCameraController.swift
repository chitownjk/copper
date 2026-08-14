import Foundation
import AVFoundation
import CoreMedia
import Observation
import CompanionVideoCore

/// Owns the persistent go-live feed: real camera → FrameComposer (normalize
/// + logo) → sink stream → virtual camera. This is the product path — the
/// timed `--camera-passthrough` probe remains only as a dev affordance.
///
/// Off at every launch. Opening the Camera settings pane starts the feed
/// (preview + sink). Stop stays on the menu extra, dock menu, and banner.
@MainActor
@Observable
final class CompanionCameraController {
    enum State: Equatable {
        case off
        case live
        case failed(String)
    }

    enum LogoSize: String, CaseIterable {
        case small, medium, large

        var fraction: CGFloat {
            switch self {
            case .small: return 0.06
            case .medium: return 0.10
            case .large: return 0.16
            }
        }

        var label: String { rawValue.capitalized }
    }

    private(set) var state: State = .off
    private(set) var logoURL: URL?
    private(set) var logoSize: LogoSize = .medium
    private(set) var mirrorsOutput = false
    private(set) var backgroundMode: BackgroundMode = .none
    private(set) var blurStrength: BlurStrength = .medium

    private var capture: CameraCaptureService?
    private var sink: CameraSinkClient?
    private let composer = FrameComposer()

    /// Preview tee: receives every composed sample buffer that reached the
    /// sink. Called on the capture queue — consumers must be thread-safe
    /// (AVSampleBufferDisplayLayer's renderer is).
    nonisolated(unsafe) var previewConsumer: ((CMSampleBuffer) -> Void)?

    nonisolated static let logoDefaultsKey = "videoLogoPath"
    nonisolated static let logoSizeDefaultsKey = "videoLogoSize"
    nonisolated static let mirrorDefaultsKey = "videoMirrorOutput"
    nonisolated static let backgroundDefaultsKey = "videoBackgroundMode"
    nonisolated static let blurStrengthDefaultsKey = "videoBlurStrength"

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.logoSizeDefaultsKey), let size = LogoSize(rawValue: raw) {
            logoSize = size
        }
        mirrorsOutput = defaults.bool(forKey: Self.mirrorDefaultsKey)
        composer.setMirrorOutput(mirrorsOutput)
        if let raw = defaults.string(forKey: Self.backgroundDefaultsKey), let mode = BackgroundMode(rawValue: raw) {
            backgroundMode = mode
            composer.setBackgroundMode(mode)
        }
        if let raw = defaults.string(forKey: Self.blurStrengthDefaultsKey), let strength = BlurStrength(rawValue: raw) {
            blurStrength = strength
            composer.setBlurStrength(strength)
        }
        if let path = defaults.string(forKey: Self.logoDefaultsKey) {
            let url = URL(fileURLWithPath: path)
            if composer.setLogo(url: url, heightFraction: logoSize.fraction) {
                logoURL = url
            } else {
                // Logo file moved or deleted since last run — forget it.
                defaults.removeObject(forKey: Self.logoDefaultsKey)
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
            capture.onFrame = { [weak self] sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      let composed = composer.compose(pixelBuffer) else { return }
                if let pushed = sink.pushPixelBuffer(composed) {
                    self?.previewConsumer?(pushed)
                }
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
            guard composer.setLogo(url: url, heightFraction: logoSize.fraction) else {
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

    func setLogoSize(_ size: LogoSize) {
        logoSize = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.logoSizeDefaultsKey)
        if let logoURL {
            composer.setLogo(url: logoURL, heightFraction: size.fraction)
        }
    }

    /// Flips the outgoing frames horizontally — including for remote
    /// participants. Meeting apps mirror only your local self-view, so most
    /// people want this OFF; it exists for those who want their self-view
    /// to read correctly and don't mind the flip on the far side.
    func setMirrorOutput(_ enabled: Bool) {
        mirrorsOutput = enabled
        UserDefaults.standard.set(enabled, forKey: Self.mirrorDefaultsKey)
        composer.setMirrorOutput(enabled)
    }

    func setBackgroundMode(_ mode: BackgroundMode) {
        backgroundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.backgroundDefaultsKey)
        composer.setBackgroundMode(mode)
    }

    func setBlurStrength(_ strength: BlurStrength) {
        blurStrength = strength
        UserDefaults.standard.set(strength.rawValue, forKey: Self.blurStrengthDefaultsKey)
        composer.setBlurStrength(strength)
    }
}
