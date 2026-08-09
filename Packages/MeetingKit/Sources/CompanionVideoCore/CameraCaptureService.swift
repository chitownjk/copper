import Foundation
import AVFoundation
import CoreMedia
import os.log

/// E5.2 capture front end: a real camera in, BGRA sample buffers out.
///
/// This is the first slice of the TD-5 pipeline — capture only, no
/// segmentation, no compositing. Frames are delivered on a private queue via
/// `onFrame`; the caller decides what to do with them (for the E5.2 tracer,
/// the app pushes them straight into the camera extension's sink stream).
public final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public enum CaptureError: LocalizedError {
        case cameraAccessDenied
        case deviceNotFound
        case cannotAddInput
        case cannotAddOutput

        public var errorDescription: String? {
            switch self {
            case .cameraAccessDenied:
                return "Camera access is denied. Grant it in System Settings > Privacy & Security > Camera."
            case .deviceNotFound: return "No camera found."
            case .cannotAddInput: return "The camera could not be attached to the capture session."
            case .cannotAddOutput: return "Video output could not be attached to the capture session."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "camera-capture")

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.strongrise.meetingcompanion.capture", qos: .userInteractive)
    private(set) public var framesCaptured: UInt64 = 0

    /// Called on the capture queue for every frame.
    public var onFrame: ((CMSampleBuffer) -> Void)?

    /// Requests camera permission if needed. Returns false when denied —
    /// callers surface `CaptureError.cameraAccessDenied`.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Starts capturing from `deviceUniqueID`, or the default camera when nil.
    /// 1080p BGRA to match the virtual camera's fixed stream format.
    ///
    /// `excludingUniqueID` must be set to the app's own virtual camera when
    /// feeding it: macOS may make the virtual camera the *system default*
    /// (measured live — "Go Live" captured our own extension's test card and
    /// fed it back to itself, a video feedback loop). Capture from it is
    /// refused even when requested explicitly.
    public func start(deviceUniqueID: String? = nil, excludingUniqueID: String? = nil) throws {
        let device: AVCaptureDevice?
        if let deviceUniqueID {
            device = AVCaptureDevice(uniqueID: deviceUniqueID)
        } else if let systemDefault = AVCaptureDevice.default(for: .video),
                  systemDefault.uniqueID != excludingUniqueID {
            device = systemDefault
        } else {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
            device = discovery.devices.first { $0.uniqueID != excludingUniqueID }
        }
        guard let device, device.uniqueID != excludingUniqueID else { throw CaptureError.deviceNotFound }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()
        Self.logger.info("capturing from \(device.localizedName, privacy: .public)")
    }

    public func stop() {
        session.stopRunning()
        Self.logger.info("capture stopped after \(self.framesCaptured) frames")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        framesCaptured &+= 1
        onFrame?(sampleBuffer)
    }
}
