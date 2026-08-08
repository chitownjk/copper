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

    private let timerQueue = DispatchQueue(label: "com.strongrise.meetingcompanion.cameraextension.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var streamingCounter = 0
    private var frameIndex: UInt64 = 0

    private var formatDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!

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
            localizedName: "Meeting Companion Camera Stream",
            streamID: FixedID.stream,
            streamFormat: format,
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
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
            deviceProperties.model = "Meeting Companion Camera"
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

    private func emitFrame() {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pixelBuffer)
        guard let pixelBuffer else { return }

        TestCard.draw(into: pixelBuffer, frameIndex: frameIndex)
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
