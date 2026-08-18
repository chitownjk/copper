import XCTest
import CoreVideo
import CoreGraphics
import ImageIO
@testable import CompanionVideoCore

final class CameraOffCardTests: XCTestCase {
    func testCardIs1080pBGRA() throws {
        let buffer = try XCTUnwrap(CameraOffCard.makePixelBuffer())
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 1080)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
    }

    func testCardCornersAreWarmCharcoalNotColorBars() throws {
        let buffer = try XCTUnwrap(CameraOffCard.makePixelBuffer(title: "Jay", subtitle: "Camera off"))
        assertCharcoalCorners(buffer)
    }

    func testEmptyTitleIsBlankCharcoalCard() throws {
        let buffer = try XCTUnwrap(CameraOffCard.makePixelBuffer())
        assertCharcoalCorners(buffer)
        // Center must stay charcoal too — no locked "Meeting Companion" wordmark.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let center = base.advanced(by: 540 * bytesPerRow + 960 * 4)
        XCTAssertLessThan(center[2], 50)
        XCTAssertLessThan(center[1], 50)
        XCTAssertLessThan(center[0], 50)
    }

    func testPassthroughSkipsLogoBlurAndMirror() throws {
        let composer = FrameComposer()
        composer.setMirrorOutput(true)
        composer.setBackgroundMode(.blur)
        let logoURL = try writeSolidPNG()
        defer { try? FileManager.default.removeItem(at: logoURL) }
        XCTAssertTrue(composer.setLogo(url: logoURL, heightFraction: 0.16))

        let input = try XCTUnwrap(makeSplitBuffer(leftRed: true))
        let output = try XCTUnwrap(composer.compose(input, effects: .passthrough))

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
        let left = base.advanced(by: 540 * bytesPerRow + 40 * 4)
        XCTAssertGreaterThan(left[2], left[0])
        let right = base.advanced(by: 540 * bytesPerRow + 1880 * 4)
        XCTAssertGreaterThan(right[0], right[2])
        // Logo is bottom-right; passthrough must not stamp green over the blue field.
        let logoAnchor = base.advanced(by: 1000 * bytesPerRow + 1850 * 4)
        XCTAssertGreaterThan(logoAnchor[0], logoAnchor[1])
        XCTAssertGreaterThan(logoAnchor[0], logoAnchor[2])
    }

    func testOverlayOnlyDoesNotMirror() throws {
        let composer = FrameComposer()
        composer.setMirrorOutput(true)
        composer.setBackgroundMode(.blur)

        let input = try XCTUnwrap(makeSplitBuffer(leftRed: true))
        let output = try XCTUnwrap(composer.compose(input, effects: .overlayOnly))

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
        // Left-center should still be red-dominant (B,G,R,A).
        let left = base.advanced(by: 540 * bytesPerRow + 40 * 4)
        XCTAssertGreaterThan(left[2], left[0])
        let right = base.advanced(by: 540 * bytesPerRow + 1880 * 4)
        XCTAssertGreaterThan(right[0], right[2])
    }

    private func assertCharcoalCorners(_ buffer: CVPixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let raw = CVPixelBufferGetBaseAddress(buffer) else {
            XCTFail("no base address", file: file, line: line)
            return
        }
        let base = raw.assumingMemoryBound(to: UInt8.self)

        // BGRA. Charcoal is R=28 G=25 B=22 — a corner must be that dark field,
        // not a yellow/cyan SMPTE bar.
        func sample(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            return (pixel[0], pixel[1], pixel[2])
        }

        for (x, y) in [(8, 8), (1911, 8), (8, 1071), (1911, 1071)] {
            let px = sample(x, y)
            XCTAssertLessThan(px.r, 50, "corner (\(x),\(y)) too bright to be charcoal", file: file, line: line)
            XCTAssertLessThan(px.g, 50, file: file, line: line)
            XCTAssertLessThan(px.b, 50, file: file, line: line)
            XCTAssertGreaterThan(px.r, px.b, "corner (\(x),\(y)) not warm", file: file, line: line)
        }
    }

    private func writeSolidPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-logo-\(UUID().uuidString).png")
        let color = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "CameraOffCardTests", code: 1)
        }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "CameraOffCardTests", code: 2)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "CameraOffCardTests", code: 3)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "CameraOffCardTests", code: 4)
        }
        return url
    }

    private func makeSplitBuffer(leftRed: Bool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<1080 {
            for x in 0..<1920 {
                let p = base.advanced(by: y * bytesPerRow + x * 4)
                let redSide = leftRed ? x < 960 : x >= 960
                if redSide {
                    p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255
                } else {
                    p[0] = 255; p[1] = 0; p[2] = 0; p[3] = 255
                }
            }
        }
        return buffer
    }
}
