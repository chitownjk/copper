import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import os.log

/// Camera-off source frames: a looping movie, else a still, else the drawn
/// card. The 30fps pump pulls one video frame per tick. Decoding as fast
/// as possible made a 5s loop finish in a few frames (~50x).
///
/// Every video frame is copied into a 1080p IOSurface buffer. Raw
/// AVAssetReader frames are not IOSurface-backed and the virtual camera
/// drops them (bars, while the card — which has an IOSurface — works).
public final class CameraOffFrameSource: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "camera-off")

    private let lock = NSLock()
    private let loopURL: URL?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var asset: AVAsset?
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var lastVideoBuffer: CVPixelBuffer?
    private var stillBuffer: CVPixelBuffer?
    private var fallbackCard: CVPixelBuffer?
    private var loopFailed = false
    private var loopLoadStarted = false
    private var stopped = false

    public init(loopURL: URL?, stillURL: URL?, cardTitle: String = "", cardSubtitle: String = "") {
        self.loopURL = loopURL
        fallbackCard = CameraOffCard.makePixelBuffer(title: cardTitle, subtitle: cardSubtitle)
        stillBuffer = Self.renderStill(url: stillURL)
    }

    public var isServingLoop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastVideoBuffer != nil
    }

    public func nextPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if asset == nil, !loopFailed, !loopLoadStarted, !stopped, let loopURL {
            loopLoadStarted = true
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loadLoop(at: loopURL)
            }
        }
        if asset != nil, let frame = pullOneLoopFrame() {
            lastVideoBuffer = frame
            return frame
        }
        // Never block Camera Off on AVAsset track discovery. The card/still is
        // served immediately while the loop loads in a detached task.
        return lastVideoBuffer ?? stillBuffer ?? fallbackCard
    }

    public func updateCard(title: String, subtitle: String) {
        let card = CameraOffCard.makePixelBuffer(title: title, subtitle: subtitle)
        lock.lock()
        fallbackCard = card
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        asset = nil
        videoTrack = nil
        lastVideoBuffer = nil
        lock.unlock()
    }

    deinit { stop() }

    private func pullOneLoopFrame() -> CVPixelBuffer? {
        guard asset != nil else { return nil }
        if let buffer = copyNextSurface() {
            return buffer
        }
        // End of clip — rewind and take the first frame.
        guard openReader() else { return nil }
        return copyNextSurface()
    }

    private func loadLoop(at loopURL: URL) async {
        guard FileManager.default.fileExists(atPath: loopURL.path) else {
            lock.withLock { loopFailed = true }
            return
        }
        let asset = AVURLAsset(url: loopURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            Self.logger.error("could not load loop tracks: \(error.localizedDescription, privacy: .public)")
            lock.withLock { loopFailed = true }
            return
        }
        guard let track = tracks.first else {
            Self.logger.error("loop has no video track \(loopURL.lastPathComponent, privacy: .public)")
            lock.withLock { loopFailed = true }
            return
        }

        lock.withLock {
            guard !stopped else { return }
            self.asset = asset
            self.videoTrack = track
            if openReader() {
                Self.logger.info("looping \(loopURL.lastPathComponent, privacy: .public) at pump rate")
            } else {
                Self.logger.error("could not open loop reader \(loopURL.lastPathComponent, privacy: .public)")
                self.asset = nil
                self.videoTrack = nil
                loopFailed = true
            }
        }
    }

    @discardableResult
    private func openReader() -> Bool {
        guard let asset, let track = videoTrack else { return false }
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading() else {
                Self.logger.error("reader start failed: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
                return false
            }
            self.reader = reader
            self.readerOutput = output
            return true
        } catch {
            Self.logger.error("reader init failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func copyNextSurface() -> CVPixelBuffer? {
        guard let output = readerOutput,
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        return copyToIOSurface(buffer)
    }

    private func copyToIOSurface(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        var dest: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: FrameComposer.width,
            kCVPixelBufferHeightKey as String: FrameComposer.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            FrameComposer.width,
            FrameComposer.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &dest
        )
        guard status == kCVReturnSuccess, let dest else { return nil }
        var image = CIImage(cvPixelBuffer: src)
        let srcW = CGFloat(CVPixelBufferGetWidth(src))
        let srcH = CGFloat(CVPixelBufferGetHeight(src))
        if Int(srcW) != FrameComposer.width || Int(srcH) != FrameComposer.height {
            let scale = max(CGFloat(FrameComposer.width) / srcW, CGFloat(FrameComposer.height) / srcH)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x - (image.extent.width - CGFloat(FrameComposer.width)) / 2,
                y: -image.extent.origin.y - (image.extent.height - CGFloat(FrameComposer.height)) / 2
            ))
        }
        ciContext.render(
            image,
            to: dest,
            bounds: CGRect(x: 0, y: 0, width: FrameComposer.width, height: FrameComposer.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return dest
    }

    private static func renderStill(url: URL?) -> CVPixelBuffer? {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let image = CIImage(contentsOf: url) else { return nil }
        let width = FrameComposer.width
        let height = FrameComposer.height
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        let scale = max(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
        var filled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        filled = filled.transformed(by: CGAffineTransform(
            translationX: -filled.extent.origin.x - (filled.extent.width - CGFloat(width)) / 2,
            y: -filled.extent.origin.y - (filled.extent.height - CGFloat(height)) / 2
        ))
        CIContext(options: [.cacheIntermediates: false]).render(
            filled,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }
}
