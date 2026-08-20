#!/usr/bin/swift
// E5.1 acceptance probe: captures ~1.5 s from "Copper Camera" and
// verifies frames arrive and carry a non-uniform image. The current safe idle
// card is intentionally static, so frame-to-frame changes are not required.
import AVFoundation
import CoreVideo

final class Collector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var digests: [UInt64] = []
    var uniform = true

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)

        // Sample a sparse grid: digest for change detection, min/max for uniformity.
        var digest: UInt64 = 1469598103934665603
        var minByte: UInt8 = 255, maxByte: UInt8 = 0
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: height, by: max(1, height / 32)) {
            for x in stride(from: 0, to: width * 4, by: max(4, width / 32 * 4)) {
                let byte = pointer[y * bytesPerRow + x]
                digest = (digest ^ UInt64(byte)) &* 1099511628211
                minByte = min(minByte, byte); maxByte = max(maxByte, byte)
            }
        }
        digests.append(digest)
        if maxByte > minByte + 40 { uniform = false }
    }
}

let status = AVCaptureDevice.authorizationStatus(for: .video)
print("camera authorization: \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
if status == .notDetermined {
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { granted in
        print("access granted: \(granted)")
        semaphore.signal()
    }
    semaphore.wait()
} else if status != .authorized {
    print("FAIL: camera access \(status == .denied ? "denied" : "restricted") for this process")
    exit(1)
}

let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external], mediaType: .video, position: .unspecified
)
let copperUID = "6E7A3B2C-9F41-4C8A-B1D5-2A6C0E9F7D31"
guard let device = discovery.devices.first(where: { $0.uniqueID == copperUID }) else {
    print("FAIL: Copper Camera not found"); exit(1)
}

let session = AVCaptureSession()
let collector = Collector()
do {
    session.addInput(try AVCaptureDeviceInput(device: device))
    let output = AVCaptureVideoDataOutput()
    output.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "probe"))
    session.addOutput(output)
} catch {
    print("FAIL: \(error)"); exit(1)
}
session.startRunning()
Thread.sleep(forTimeInterval: 1.5)
session.stopRunning()

let unique = Set(collector.digests).count
print("frames=\(collector.digests.count) unique=\(unique) uniform=\(collector.uniform)")
if collector.digests.count >= 20, !collector.uniform {
    print("PASS: non-blank frames from the extension")
    exit(0)
}
print("FAIL: stream is missing or blank")
exit(1)
