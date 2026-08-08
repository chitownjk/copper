import Foundation
import CoreVideo
import CoreGraphics
import CoreText

/// The tracer-bullet test card: SMPTE-ish color bars, a product wordmark, and
/// a moving block + frame counter so a human can tell live from frozen at a
/// glance. Placeholder rendering is the one kind of drawing the extension is
/// allowed to do (hard rule 2).
enum TestCard {
    private static let barColors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.75, 0.75, 0.75), // gray
        (0.75, 0.75, 0.00), // yellow
        (0.00, 0.75, 0.75), // cyan
        (0.00, 0.75, 0.00), // green
        (0.75, 0.00, 0.75), // magenta
        (0.75, 0.00, 0.00), // red
        (0.00, 0.00, 0.75)  // blue
    ]

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

        // Bars over the top two thirds.
        let barWidth = w / CGFloat(barColors.count)
        for (index, color) in barColors.enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: h / 3, width: barWidth + 1, height: h * 2 / 3))
        }

        // Dark lower third.
        context.setFillColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h / 3))

        // Moving block: one sweep across the screen every 5 seconds at 30 fps.
        let sweep = CGFloat(frameIndex % 150) / 150.0
        context.setFillColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 1)
        context.fill(CGRect(x: sweep * (w - 80), y: h / 3 - 24, width: 80, height: 24))

        // Wordmark + live frame counter.
        drawText("Meeting Companion — test pattern", at: CGPoint(x: 64, y: h / 3 - 110), size: 64, in: context)
        drawText(String(format: "frame %llu", frameIndex), at: CGPoint(x: 64, y: h / 3 - 180), size: 40, in: context)
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
