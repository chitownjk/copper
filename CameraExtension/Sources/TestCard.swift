import Foundation
import CoreVideo
import CoreGraphics
import CoreText

/// Idle frame when the app is not pushing. Dark card only — no SMPTE bars.
/// Drawing in the extension is limited to this placeholder (hard rule 2).
enum TestCard {
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
        context.setFillColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        drawText("Camera off", at: CGPoint(x: 80, y: h / 2 + 20), size: 72, color: (0.77, 0.52, 0.35), in: context)
        drawText("Meeting Companion", at: CGPoint(x: 80, y: h / 2 - 50), size: 36, color: (0.85, 0.85, 0.86), in: context)
        _ = frameIndex
    }

    private static func drawText(
        _ string: String,
        at point: CGPoint,
        size: CGFloat,
        color: (CGFloat, CGFloat, CGFloat),
        in context: CGContext
    ) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let cgColor = CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
