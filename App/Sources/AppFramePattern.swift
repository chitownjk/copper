import Foundation
import CoreVideo
import CoreGraphics
import CoreText

/// The sink-transport verification pattern. Deliberately looks nothing like
/// the extension's test card (color bars): dark indigo field, orange sweep,
/// its own counter — so a human can tell at a glance which process rendered
/// the frame they're looking at.
enum AppFramePattern {
    static func draw(into pixelBuffer: CVPixelBuffer, frameIndex: UInt64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)

        // Indigo field.
        context.setFillColor(red: 0.12, green: 0.10, blue: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Orange block sweeping vertically, one pass every 5 s at 30 fps.
        let sweep = CGFloat(frameIndex % 150) / 150.0
        context.setFillColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1)
        context.fill(CGRect(x: w / 2 - 60, y: sweep * (h - 120), width: 120, height: 120))

        drawText("LIVE FROM MEETING COMPANION APP", at: CGPoint(x: 64, y: h - 140), size: 64, in: context)
        drawText(String(format: "app frame %llu", frameIndex), at: CGPoint(x: 64, y: h - 220), size: 40, in: context)
    }

    private static func drawText(_ string: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
