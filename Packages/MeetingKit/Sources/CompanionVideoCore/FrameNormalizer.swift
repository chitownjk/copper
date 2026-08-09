import Foundation
import CoreImage
import CoreVideo
import os.log

/// Normalizes capture frames to the virtual camera's fixed 1080p BGRA format.
///
/// Needed because macOS renegotiates a shared camera between processes —
/// measured live: Chrome/Meet attaching to the same camera dropped our
/// AVCaptureSession from 1920×1080 to 1280×720 mid-stream. Frames that
/// already match pass through untouched; everything else is aspect-fill
/// scaled (centered, cropped) on the GPU.
public final class FrameNormalizer {
    public static let width = 1920
    public static let height = 1080

    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "frame-normalizer")

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool!
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

    /// Returns a 1920×1080 BGRA buffer: the input itself when it already
    /// matches, otherwise a scaled copy. nil if rendering fails.
    public func normalize(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width == Self.width, height == Self.height,
           CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            return pixelBuffer
        }

        if !loggedScaleEngaged {
            loggedScaleEngaged = true
            Self.logger.info("scaling engaged: \(width)x\(height) → \(Self.width)x\(Self.height)")
        }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }

        // Aspect-fill: scale so the frame covers 1080p fully, center-crop.
        let scale = max(CGFloat(Self.width) / CGFloat(width), CGFloat(Self.height) / CGFloat(height))
        let scaled = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let originX = (scaled.extent.width - CGFloat(Self.width)) / 2
        let originY = (scaled.extent.height - CGFloat(Self.height)) / 2
        let centered = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x - originX,
                                                                y: -scaled.extent.origin.y - originY))
        context.render(centered, to: output,
                       bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
}
