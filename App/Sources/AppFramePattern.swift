import Foundation
import CoreVideo
import CompanionVideoCore

/// Headless `--push-camera-frames` fill. Same charcoal card as camera-off.
/// The old indigo/orange sweep was a transport tracer; do not bring it back.
enum AppFramePattern {
    static func draw(into pixelBuffer: CVPixelBuffer, frameIndex: UInt64) {
        _ = frameIndex
        CameraOffCard.draw(into: pixelBuffer, title: "", subtitle: "")
    }
}
