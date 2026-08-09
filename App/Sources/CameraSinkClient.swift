import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import CompanionVideoCore
import os.log

/// Connects to the camera extension's sink stream over the CoreMediaIO C API
/// and pushes BGRA frames into it (the E5.1 frame-transport step). This is
/// transport only — the real capture/compositing pipeline arrives with E5.2.
final class CameraSinkClient {
    /// Must match `FixedID.device` in the extension.
    static let deviceUID = "6E7A3B2C-9F41-4C8A-B1D5-2A6C0E9F7D31"

    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "camera-sink")

    enum SinkError: LocalizedError {
        case deviceNotFound
        case sinkStreamNotFound
        case queueUnavailable(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "Meeting Companion Camera not found (is the extension installed and approved?)"
            case .sinkStreamNotFound:
                return "The camera has no sink stream (older extension version still active?)"
            case .queueUnavailable(let status):
                return "CMIOStreamCopyBufferQueue failed (\(status))"
            case .startFailed(let status):
                return "CMIODeviceStartStream failed (\(status))"
            }
        }
    }

    private enum Video {
        static let width = 1920
        static let height = 1080
        static let fps: Int32 = 30
    }

    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private(set) var framesPushed: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0

    // MARK: - Lifecycle

    func connect() throws {
        guard let device = Self.findDevice(uid: Self.deviceUID) else {
            throw SinkError.deviceNotFound
        }
        deviceID = device

        // The sink is an output-scope stream (data flows out of this process).
        // Fall back to "any stream that isn't in the input scope" if the
        // output-scope query comes back empty.
        let inputStreams = Self.streams(of: device, scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput))
        let outputStreams = Self.streams(of: device, scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeOutput))
        Self.logger.info("device \(device): \(inputStreams.count) input stream(s), \(outputStreams.count) output stream(s)")
        if let sink = outputStreams.first {
            sinkStreamID = sink
        } else {
            let all = Self.streams(of: device, scope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal))
            guard let sink = all.first(where: { !inputStreams.contains($0) }) else {
                throw SinkError.sinkStreamNotFound
            }
            sinkStreamID = sink
        }

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(Video.width),
            height: Int32(Video.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        formatDescription = description

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Video.width,
            kCVPixelBufferHeightKey as String: Video.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &bufferPool)

        var queueUnmanaged: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sinkStreamID, { _, _, _ in }, nil, &queueUnmanaged)
        guard copyStatus == kCMIOHardwareNoError, let queueUnmanaged else {
            throw SinkError.queueUnavailable(copyStatus)
        }
        queue = queueUnmanaged.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(deviceID, sinkStreamID)
        guard startStatus == kCMIOHardwareNoError else {
            throw SinkError.startFailed(startStatus)
        }
        Self.logger.info("sink stream \(self.sinkStreamID) started on device \(self.deviceID)")
    }

    func disconnect() {
        if deviceID != 0, sinkStreamID != 0 {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        queue = nil
        Self.logger.info("sink disconnected — pushed \(self.framesPushed), dropped \(self.framesDropped)")
    }

    /// Wraps a pixel buffer in a sample buffer stamped with the sink's fixed
    /// 1080p format and enqueues it. Mismatched dimensions are dropped and
    /// counted — normalize upstream (FrameNormalizer) before pushing.
    @discardableResult
    func pushPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let queue else { return false }
        guard CVPixelBufferGetWidth(pixelBuffer) == Video.width,
              CVPixelBufferGetHeight(pixelBuffer) == Video.height else {
            if framesDropped == 0 {
                Self.logger.error("dropping frame: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) does not match \(Video.width)x\(Video.height)")
            }
            framesDropped &+= 1
            return false
        }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            framesDropped &+= 1
            return false
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Video.fps),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return false }

        let retained = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        if status == noErr {
            framesPushed &+= 1
            return true
        }
        retained.release()
        framesDropped &+= 1
        return false
    }

    /// Draws one frame via `render` and enqueues it. Returns false when the
    /// sink queue is full (frame dropped) — normal flow control, not an error.
    @discardableResult
    func pushFrame(render: (CVPixelBuffer, UInt64) -> Void) -> Bool {
        guard let queue else { return false }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            framesDropped &+= 1
            return false
        }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pixelBuffer)
        guard let pixelBuffer else { return false }
        render(pixelBuffer, framesPushed)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Video.fps),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return false }

        let retained = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        if status == noErr {
            framesPushed &+= 1
            return true
        }
        retained.release()
        framesDropped &+= 1
        return false
    }

    // MARK: - CMIO object discovery

    private static func findDevice(uid: String) -> CMIOObjectID? {
        var addr = address(kCMIOHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == kCMIOHardwareNoError, dataSize > 0 else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, dataSize, &dataUsed, &ids) == kCMIOHardwareNoError else {
            return nil
        }
        return ids.first { deviceUID(of: $0) == uid }
    }

    private static func deviceUID(of device: CMIOObjectID) -> String? {
        var addr = address(kCMIODevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var dataUsed: UInt32 = 0
        let dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, dataSize, &dataUsed, pointer)
        }
        guard status == kCMIOHardwareNoError, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func streams(of device: CMIOObjectID, scope: CMIOObjectPropertyScope) -> [CMIOStreamID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: scope,
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == kCMIOHardwareNoError, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var ids = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, dataSize, &dataUsed, &ids) == kCMIOHardwareNoError else {
            return []
        }
        return ids
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}

// MARK: - Capture passthrough probe

/// `--camera-passthrough[=seconds]` support (E5.2 tracer): real camera →
/// CameraCaptureService → sink stream → virtual camera. Needs the camera TCC
/// grant, so it can only be verified with a user present.
final class CameraPassthroughProbe {
    struct Stats {
        var captured: UInt64
        var pushed: UInt64
        var dropped: UInt64
    }

    func run(seconds: Double) async throws -> Stats {
        guard await CameraCaptureService.requestAccess() else {
            throw CameraCaptureService.CaptureError.cameraAccessDenied
        }
        let sink = CameraSinkClient()
        try sink.connect()
        let capture = CameraCaptureService()
        let composer = FrameComposer()
        // Mirror the go-live pipeline exactly, logo included, so the probe
        // is a faithful preview of the product path.
        if let path = UserDefaults.standard.string(forKey: CompanionCameraController.logoDefaultsKey) {
            composer.setLogo(url: URL(fileURLWithPath: path))
        }
        capture.onFrame = { sampleBuffer in
            // The camera's delivery format can change mid-stream when another
            // process shares it (measured: Meet attaching dropped us from
            // 1080p to 720p) — normalize every frame before pushing.
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let composed = composer.compose(pixelBuffer) else { return }
            sink.pushPixelBuffer(composed)
        }
        try capture.start()
        try await Task.sleep(for: .seconds(seconds))
        capture.stop()
        sink.disconnect()
        return Stats(captured: capture.framesCaptured, pushed: sink.framesPushed, dropped: sink.framesDropped)
    }
}

// MARK: - Headless push probe

/// `--push-camera-frames[=seconds]` support: pushes the app pattern at 30 fps
/// for a fixed duration so the transport can be verified from logs alone.
final class CameraSinkPushProbe {
    struct Stats {
        var pushed: UInt64
        var dropped: UInt64
    }

    func run(seconds: Double) async throws -> Stats {
        let client = CameraSinkClient()
        try client.connect()
        defer { client.disconnect() }

        let timerQueue = DispatchQueue(label: "com.strongrise.meetingcompanion.sink-push")
        return await withCheckedContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            let deadline = DispatchTime.now() + seconds
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(2))
            timer.setEventHandler {
                if DispatchTime.now() >= deadline {
                    timer.cancel()
                    continuation.resume(returning: Stats(pushed: client.framesPushed, dropped: client.framesDropped))
                    return
                }
                client.pushFrame { pixelBuffer, index in
                    AppFramePattern.draw(into: pixelBuffer, frameIndex: index)
                }
            }
            timer.resume()
        }
    }
}
