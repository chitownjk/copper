import Foundation
import CoreImage
import CoreVideo
import Vision
import os.log

/// Background treatment for the outgoing frames (E5.3). Image replacement
/// and color wash arrive in later slices.
public enum BackgroundMode: String, CaseIterable, Sendable {
    case none
    case blur
}

public enum BlurStrength: String, CaseIterable, Sendable {
    case light
    case medium
    case strong

    public var sigma: Double {
        switch self {
        case .light: return 8
        case .medium: return 16
        case .strong: return 28
        }
    }

    public var label: String { rawValue.capitalized }
}

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

    /// Live applies blur + mirror + logo. overlayOnly is the camera-off
    /// path for stills/cards/imported loops (normalize + logo). passthrough
    /// is a pre-composed recorded loop — normalize only, never stamp again.
    public enum Effects: Sendable {
        case live
        case overlayOnly
        case passthrough
    }

    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "frame-composer")

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool!

    // Read on the capture queue every frame, written from the main thread
    // when the user changes logo or mirror settings.
    private let stateLock = NSLock()
    private var logoImage: CIImage?
    private var mirrorOutput = false
    private var backgroundMode: BackgroundMode = .none
    private var blurStrength: BlurStrength = .medium

    // Used only on the capture queue (Vision runs synchronously per frame).
    // Balanced tier per TD-5; the quality/perf degrade ladder comes later.
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    private var loggedScaleEngaged = false
    private var loggedSegmentationFailure = false

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

    /// Selects the background treatment. Thread-safe; applies mid-stream.
    public func setBackgroundMode(_ mode: BackgroundMode) {
        stateLock.withLock { backgroundMode = mode }
        Self.logger.info("background mode \(mode.rawValue, privacy: .public)")
    }

    /// Selects the blur strength. Thread-safe; applies mid-stream.
    public func setBlurStrength(_ strength: BlurStrength) {
        stateLock.withLock { blurStrength = strength }
        Self.logger.info("blur strength \(strength.rawValue, privacy: .public)")
    }

    /// Returns a 1920×1080 BGRA buffer ready for the sink: the input itself
    /// when nothing needs doing, otherwise a rendered copy (scaled and/or
    /// logo-composited). nil if rendering fails.
    ///
    /// `effects: .overlayOnly` is the camera-off path — logo still stamps,
    /// blur and mirror do not. `.passthrough` never stamps a logo (the
    /// recorded 5s loop already has blur + mirror + logo baked in).
    public func compose(_ input: CVPixelBuffer, effects: Effects = .live) -> CVPixelBuffer? {
        let (logo, mirror, background, strength) = stateLock.withLock { (logoImage, mirrorOutput, backgroundMode, blurStrength) }
        let applyBlur = effects == .live && background == .blur
        let applyMirror = effects == .live && mirror
        let applyLogo = effects != .passthrough
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let matches = width == Self.width && height == Self.height
            && CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA
        // Never return the input. No-logo live used to take a fast path and
        // CMIO dropped those camera frames (bars). Always render into our
        // IOSurface pool.

        var base = CIImage(cvPixelBuffer: input)
        if !matches {
            if !loggedScaleEngaged {
                loggedScaleEngaged = true
                Self.logger.info("scaling engaged: \(width)x\(height) → \(Self.width)x\(Self.height)")
            }
            base = aspectFill(base)
        }
        if applyBlur {
            base = blurredBackground(base: base, input: input, sigma: strength.sigma)
        }
        let stamp = applyLogo ? logo : nil
        var composed = stamp.map { $0.composited(over: base) } ?? base
        if applyMirror {
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

    /// Scales any image to cover the 1080p frame fully, center-cropped.
    private func aspectFill(_ image: CIImage) -> CIImage {
        let scale = max(CGFloat(Self.width) / image.extent.width, CGFloat(Self.height) / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: -scaled.extent.origin.x - (scaled.extent.width - CGFloat(Self.width)) / 2,
            y: -scaled.extent.origin.y - (scaled.extent.height - CGFloat(Self.height)) / 2
        ))
    }

    /// Person-segmented blur: the person stays sharp, everything else gets a
    /// gaussian. Vision runs on the raw capture buffer (ANE, balanced tier);
    /// the mask is aspect-filled with the same geometry as the base image.
    /// Any failure degrades to the unblurred frame — never break the feed.
    private func blurredBackground(base: CIImage, input: CVPixelBuffer, sigma: Double) -> CIImage {
        let handler = VNImageRequestHandler(cvPixelBuffer: input, options: [:])
        do {
            try handler.perform([segmentationRequest])
            guard let maskBuffer = segmentationRequest.results?.first?.pixelBuffer else { return base }
            // The raw mask runs a little generous — a rim of background around
            // hands/head stays sharp (owner-observed halo). Erode the person
            // region inward a few mask-pixels, then feather the edge.
            var mask = CIImage(cvPixelBuffer: maskBuffer)
            let maskExtent = mask.extent
            mask = mask.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.5])
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: maskExtent)
            let scaledMask = aspectFill(mask)
            let frameRect = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
            let blurred = base.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: frameRect)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { return base }
            blend.setValue(base, forKey: kCIInputImageKey)
            blend.setValue(blurred, forKey: kCIInputBackgroundImageKey)
            blend.setValue(scaledMask, forKey: kCIInputMaskImageKey)
            return blend.outputImage ?? base
        } catch {
            if !loggedSegmentationFailure {
                loggedSegmentationFailure = true
                Self.logger.error("segmentation failed: \(error.localizedDescription, privacy: .public)")
            }
            return base
        }
    }
}
