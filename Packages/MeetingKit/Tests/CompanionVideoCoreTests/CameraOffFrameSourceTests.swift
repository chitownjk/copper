import CoreMedia
import CoreVideo
import XCTest
@testable import CompanionVideoCore

final class CameraOffFrameSourceTests: XCTestCase {
    func testValidLoopReturnsFallbackImmediatelyThenBeginsLooping() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-off-source-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = CameraLoopRecorder()
        try recorder.start(writingTo: url)
        guard let pixelBuffer = makePixelBuffer() else {
            return XCTFail("Could not create test pixel buffer")
        }
        XCTAssertTrue(recorder.append(pixelBuffer, presentationTime: .zero))
        try await recorder.finish()

        let source = CameraOffFrameSource(
            loopURL: url,
            stillURL: nil,
            cardTitle: "Camera off",
            cardSubtitle: "Back soon"
        )
        let clock = ContinuousClock()
        let start = clock.now
        XCTAssertNotNil(source.nextPixelBuffer())
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(200))

        let deadline = Date().addingTimeInterval(3)
        while !source.isServingLoop, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            _ = source.nextPixelBuffer()
        }
        XCTAssertTrue(source.isServingLoop)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            FrameComposer.width,
            FrameComposer.height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ] as CFDictionary,
            &buffer
        )
        return buffer
    }
}
