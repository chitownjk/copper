import Foundation
import CoreMediaIO
import CoreVideo
import CoreGraphics
import CoreText
import IOKit.audio
import os.log

/// Fixed IDs so macOS treats reinstalls as the same camera (pickers remember
/// the selection by device ID).
private enum FixedID {
    static let device = UUID(uuidString: "6E7A3B2C-9F41-4C8A-B1D5-2A6C0E9F7D31")!
    static let stream = UUID(uuidString: "D4C2B8A1-5E63-4F7B-9C0D-8B1A2F3E4D57")!
    static let sinkStream = UUID(uuidString: "A9F0E1D2-7B34-4E5C-8D6A-1C2B3A4F5E60")!
}

private enum Video {
    static let width = 1920
    static let height = 1080
    static let fps: Int32 = 30
    static let pixelFormat = kCVPixelFormatType_32BGRA
}

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CameraStreamSource!
    private var sinkStreamSource: CameraSinkStreamSource!

    private let timerQueue = DispatchQueue(label: "com.strongrise.meetingcompanion.cameraextension.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var streamingCounter = 0
    private var frameIndex: UInt64 = 0

    private var formatDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!

    // Sink state — written from consume completions, read on the frame timer.
    // A frame older than `sinkStaleThreshold` means the app stalled or died;
    // the timer falls back to the test card on its own (TECH_PLAN R2:
    // auto-recover, never freeze a meeting).
    private let sinkLock = NSLock()
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame: CVPixelBuffer?
    private var lastSinkFrameSeconds: Double = 0
    private var sinkFramesConsumed: UInt64 = 0
    private let sinkStaleThreshold = 1.0
    /// Timer-queue only: last emitted mode, for transition logging.
    private var relayingSinkFrames = false

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: FixedID.device, legacyDeviceID: nil, source: self)

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: Video.pixelFormat,
            width: Int32(Video.width),
            height: Int32(Video.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        formatDescription = description

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Video.pixelFormat,
            kCVPixelBufferWidthKey as String: Video.width,
            kCVPixelBufferHeightKey as String: Video.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &bufferPool)

        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Video.fps),
            minFrameDuration: CMTime(value: 1, timescale: Video.fps),
            validFrameDurations: nil
        )
        streamSource = CameraStreamSource(
            localizedName: "Copper Camera Stream",
            streamID: FixedID.stream,
            streamFormat: format,
            device: device
        )
        sinkStreamSource = CameraSinkStreamSource(
            localizedName: "Copper Camera Sink",
            streamID: FixedID.sinkStream,
            streamFormat: format,
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Copper Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable device properties.
    }

    // MARK: - Streaming

    func startStreaming() {
        guard bufferPool != nil else { return }
        streamingCounter += 1
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(Video.fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        timer.resume()
        self.timer = timer
        extensionLogger.info("started streaming")
    }

    func stopStreaming() {
        streamingCounter = max(0, streamingCounter - 1)
        if streamingCounter == 0 {
            timer?.cancel()
            timer = nil
            extensionLogger.info("stopped streaming")
        }
    }

    // MARK: - Sink (app → extension)

    func startSinkStreaming(from client: CMIOExtensionClient) {
        sinkLock.withLock {
            sinkClient = client
            sinkFramesConsumed = 0
        }
        extensionLogger.info("sink started by \(client.signingID ?? "unknown", privacy: .public)")
        consumeNextSinkFrame()
    }

    func stopSinkStreaming() {
        let consumed = sinkLock.withLock {
            sinkClient = nil
            // Keep the final frame only for the short watchdog grace period.
            // emitFrame() falls back to the safe idle card if the app dies.
            return sinkFramesConsumed
        }
        extensionLogger.info("sink stopped after \(consumed) frames")
    }

    /// Self-perpetuating pull: each completion stores the frame and requests
    /// the next one, until the sink client stops streaming. Relay only — no
    /// inspection, no processing (hard rule 2).
    private func consumeNextSinkFrame() {
        guard let client = sinkLock.withLock({ sinkClient }) else { return }
        sinkStreamSource.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            if let sampleBuffer, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let count: UInt64 = self.sinkLock.withLock {
                    self.lastSinkFrame = frame
                    self.lastSinkFrameSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    self.sinkFramesConsumed &+= 1
                    return self.sinkFramesConsumed
                }
                let hostTimeNs = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
                self.sinkStreamSource.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: hostTimeNs)
                )
                if count == 1 || count % 300 == 0 {
                    extensionLogger.info("consumed sink frame \(count)")
                }
            }
            guard self.sinkLock.withLock({ self.sinkClient }) != nil else { return }
            if sampleBuffer == nil, error != nil {
                // Don't spin on a hard error; back off briefly and retry.
                self.timerQueue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    self.consumeNextSinkFrame()
                }
            } else {
                self.consumeNextSinkFrame()
            }
        }
    }

    private func emitFrame() {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let (sinkFrame, consumed): (CVPixelBuffer?, UInt64) = sinkLock.withLock {
            if let frame = lastSinkFrame,
               now - lastSinkFrameSeconds < sinkStaleThreshold {
                return (frame, sinkFramesConsumed)
            }
            return (nil, sinkFramesConsumed)
        }
        if (sinkFrame != nil) != relayingSinkFrames {
            relayingSinkFrames = (sinkFrame != nil)
            if relayingSinkFrames {
                extensionLogger.info("relaying app frames (\(consumed) consumed so far)")
            } else {
                extensionLogger.info("sink idle or stale — serving idle card")
            }
        }

        let pixelBuffer: CVPixelBuffer
        if let sinkFrame {
            pixelBuffer = sinkFrame
        } else {
            var fresh: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &fresh)
            guard let fresh else { return }
            TestCard.draw(into: fresh, frameIndex: frameIndex)
            pixelBuffer = fresh
        }
        frameIndex &+= 1

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Video.fps),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if let sampleBuffer {
            streamSource.stream.send(
                sampleBuffer,
                discontinuity: [],
                hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
            )
        }
    }
}

// MARK: - Stream source

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                extensionLogger.error("invalid format index \(self.activeFormatIndex)")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Video.fps)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Any client that can see the device may stream from it.
        true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? CameraDeviceSource else {
            fatalError("Unexpected device source")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? CameraDeviceSource else {
            fatalError("Unexpected device source")
        }
        deviceSource.stopStreaming()
    }
}

// MARK: - Sink stream source

/// The app-facing half of the frame transport: the main app connects to this
/// stream via CoreMediaIO and pushes composited frames; the device source
/// relays them out the source stream. Only our own app may start it.
final class CameraSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    private static let allowedSigningID = "com.strongrise.meetingcompanion"

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: 30)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 30
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // Format is fixed; nothing settable.
    }

    /// Best-effort client gate. Strict verification is not achievable here,
    /// measured on macOS 26.5: `signingID` arrives nil for C-API sink clients
    /// (terminal and LaunchServices launches alike), and a SecCode check on
    /// the pid is blocked by our own sandbox (deny file-read-data on the
    /// client bundle — the certificate evaluation needs the file). OBS ships
    /// exactly this shape: store the client, return true. So: refuse only a
    /// client that positively identifies as someone else; log the rest.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // CMIO reports C-API sink clients as the literal string "unknown"
        // (measured on macOS 26.5) — not nil. Both mean "unidentifiable".
        let signingID = client.signingID
        if let signingID, signingID != "unknown", signingID != Self.allowedSigningID {
            extensionLogger.error("sink refused for '\(signingID, privacy: .public)' pid=\(client.pid)")
            return false
        }
        extensionLogger.info("sink authorized for '\(signingID ?? "nil", privacy: .public)' pid=\(client.pid)")
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? CameraDeviceSource, let client else {
            fatalError("Sink started without an authorized client")
        }
        deviceSource.startSinkStreaming(from: client)
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? CameraDeviceSource else {
            fatalError("Unexpected device source")
        }
        deviceSource.stopSinkStreaming()
        client = nil
    }
}
