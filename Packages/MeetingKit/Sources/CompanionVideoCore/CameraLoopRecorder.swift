import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import os.log

/// Writes a 5-second 1080p30 H.264 loop from live camera frames.
/// Compose stays out of this file — callers pass raw (or already-normalized)
/// sample buffers; we only scale to 1080p BGRA if the camera dropped mid-stream.
public final class CameraLoopRecorder: @unchecked Sendable {
    public static let durationSeconds: Double = 5

    public enum RecorderError: LocalizedError {
        case alreadyStarted
        case notStarted
        case noFrames
        case writerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted: return "A loop is already being recorded."
            case .notStarted: return "Loop recorder was not started."
            case .noFrames: return "No camera frames arrived while recording the loop."
            case .writerFailed(let message): return message
            }
        }
    }

    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "loop-recorder")
    private static let width = 1920
    private static let height = 1080

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startPTS: CMTime?
    private var frameCount: Int = 0
    private var finished = false
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public var recordedFrameCount: Int {
        lock.withLock { frameCount }
    }

    public var elapsedSeconds: Double {
        lock.withLock {
            guard let startPTS, let writer, writer.status == .writing else { return 0 }
            return lastRelative?.seconds ?? 0
        }
    }

    private var lastRelative: CMTime?

    public func start(writingTo url: URL) throws {
        try lock.withLock {
            guard writer == nil else { throw RecorderError.alreadyStarted }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Self.width,
                AVVideoHeightKey: Self.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Self.width,
                    kCVPixelBufferHeightKey as String: Self.height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ]
            )
            guard writer.canAdd(input) else {
                throw RecorderError.writerFailed("Could not add video input to loop writer.")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "Loop writer failed to start.")
            }
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.startPTS = nil
            self.lastRelative = nil
            self.frameCount = 0
            self.finished = false
            Self.logger.info("recording loop to \(url.lastPathComponent, privacy: .public)")
        }
    }

    /// Appends one camera frame. Returns false once 5 seconds have been written
    /// or the writer is no longer accepting data.
    @discardableResult
    public func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        return append(pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let writer, let input, let adaptor, writer.status == .writing else {
            return false
        }

        if startPTS == nil {
            startPTS = presentationTime
            writer.startSession(atSourceTime: .zero)
        }
        guard let startPTS else { return false }

        let relative = CMTimeSubtract(presentationTime, startPTS)
        if relative.seconds >= Self.durationSeconds {
            finished = true
            return false
        }
        guard input.isReadyForMoreMediaData else { return true }

        let frame = normalize(pixelBuffer) ?? pixelBuffer
        guard adaptor.append(frame, withPresentationTime: relative) else {
            Self.logger.error("loop append failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        lastRelative = relative
        frameCount += 1
        return true
    }

    public func finish() async throws {
        let snapshot: (AVAssetWriter, AVAssetWriterInput, Int) = try lock.withLock {
            guard let currentWriter = self.writer, let currentInput = self.input else {
                throw RecorderError.notStarted
            }
            finished = true
            return (currentWriter, currentInput, frameCount)
        }
        let writer = snapshot.0
        let input = snapshot.1
        let count = snapshot.2
        guard count > 0 else {
            input.markAsFinished()
            await writer.finishWriting()
            throw RecorderError.noFrames
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "Loop writer failed.")
        }
        Self.logger.info("loop recorded \(count) frame(s)")
    }

    private func normalize(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let format = CVPixelBufferGetPixelFormatType(input)
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.width,
            Self.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        var image = CIImage(cvPixelBuffer: input)
        let scale = max(CGFloat(Self.width) / image.extent.width, CGFloat(Self.height) / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x - (image.extent.width - CGFloat(Self.width)) / 2,
            y: -image.extent.origin.y - (image.extent.height - CGFloat(Self.height)) / 2
        ))
        ciContext.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }
}
