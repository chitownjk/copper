import Foundation
import CoreImage
import CoreVideo
import os.log

/// The app-side frame pipeline (TD-5, first real node): normalizes capture
/// frames to the virtual camera's fixed 1080p BGRA format and composites the
/// optional logo overlay — in a single GPU render pass.
///
/// Normalization is required because macOS renegotiates a shared camera
/// between processes (measured: Chrome/Meet attaching dropped our capture
/// from 1920×1080 to 1280×720 mid-stream). The logo is baked into the
/// outgoing frames here, in our process, so it survives anything downstream
/// — macOS system video effects, Meet backgrounds, all of it. That is the
/// product requirement: the logo persists with or without filters.
public final class FrameComposer {
    public static let width = 1920
    public static let height = 1080

    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "frame-composer")

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool!

    // Read on the capture queue every frame, written from the main thread
    // when the user changes logo or mirror settings.
    private let stateLock = NSLock()
    private var logoImage: CIImage?
    private var mirrorOutput = false

    private var loggedScaleEngaged = false

    public init() {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pool)
    }

    /// Sets (or clears, with nil) the logo overlay. PNG with alpha is the
    /// expected input. `heightFraction` of the frame height, anchored
    /// bottom-right with a 48 px margin — drag-to-place arrives with E5.4
    /// proper. Returns false when the image cannot be loaded. Thread-safe.
    @discardableResult
    public func setLogo(url: URL?, heightFraction: CGFloat = 0.10) -> Bool {
        guard let url else {
            stateLock.withLock { logoImage = nil }
            Self.logger.info("logo cleared")
            return true
        }
        guard let image = CIImage(contentsOf: url) else {
            Self.logger.error("logo failed to load from \(url.path, privacy: .public)")
            return false
        }
        let targetHeight = CGFloat(Self.height) * heightFraction
        let scale = targetHeight / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: CGFloat(Self.width) - 48 - scaled.extent.width - scaled.extent.origin.x,
            y: 48 - scaled.extent.origin.y
        ))
        stateLock.withLock { logoImage = positioned }
        Self.logger.info("logo set from \(url.lastPathComponent, privacy: .public) (\(Int(scaled.extent.width))x\(Int(scaled.extent.height)))")
        return true
    }

    /// Flips the entire outgoing frame horizontally — logo included. Note
    /// this changes what remote participants receive: meeting apps mirror
    /// only your local self-view, so with this OFF remote viewers already
    /// see everything (text, logo) the right way round. Thread-safe.
    public func setMirrorOutput(_ enabled: Bool) {
        stateLock.withLock { mirrorOutput = enabled }
        Self.logger.info("mirror output \(enabled ? "on" : "off")")
    }

    /// Returns a 1920×1080 BGRA buffer ready for the sink: the input itself
    /// when nothing needs doing, otherwise a rendered copy (scaled and/or
    /// logo-composited). nil if rendering fails.
    public func compose(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let (logo, mirror) = stateLock.withLock { (logoImage, mirrorOutput) }
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let matches = width == Self.width && height == Self.height
            && CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA
        if matches, logo == nil, !mirror {
            return input
        }

        var base = CIImage(cvPixelBuffer: input)
        if !matches {
            if !loggedScaleEngaged {
                loggedScaleEngaged = true
                Self.logger.info("scaling engaged: \(width)x\(height) → \(Self.width)x\(Self.height)")
            }
            // Aspect-fill: cover 1080p fully, center-crop the overflow.
            let scale = max(CGFloat(Self.width) / CGFloat(width), CGFloat(Self.height) / CGFloat(height))
            let scaled = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            base = scaled.transformed(by: CGAffineTransform(
                translationX: -scaled.extent.origin.x - (scaled.extent.width - CGFloat(Self.width)) / 2,
                y: -scaled.extent.origin.y - (scaled.extent.height - CGFloat(Self.height)) / 2
            ))
        }
        var composed = logo.map { $0.composited(over: base) } ?? base
        if mirror {
            // x' = width - x: horizontal flip of the full frame.
            composed = composed.transformed(by: CGAffineTransform(-1, 0, 0, 1, CGFloat(Self.width), 0))
        }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }
        context.render(composed, to: output,
                       bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
}
