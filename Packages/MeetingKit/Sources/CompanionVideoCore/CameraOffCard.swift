import Foundation
import CoreVideo
import CoreGraphics
import CoreText

/// Product camera-off fallback: a warm charcoal card with a copper title.
/// Drawn in-process (no PNG) so the extension's color-bar TestCard is never
/// the intentional off-state. Title and subtitle are user-editable; an empty
/// title is a blank charcoal field, not a locked product billboard.
public enum CameraOffCard {
    public static let width = 1920
    public static let height = 1080

    /// Warm charcoal `#1C1916` (Brand.darkSurface).
    private static let charcoal = (r: CGFloat(28) / 255, g: CGFloat(25) / 255, b: CGFloat(22) / 255)
    /// Copper `#C4845A`.
    private static let copper = (r: CGFloat(196) / 255, g: CGFloat(132) / 255, b: CGFloat(90) / 255)
    private static let subtitleColor = (r: CGFloat(196) / 255, g: CGFloat(180) / 255, b: CGFloat(168) / 255)

    public static func makePixelBuffer(title: String = "", subtitle: String = "") -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        draw(into: buffer, title: title, subtitle: subtitle)
        return buffer
    }

    public static func draw(into pixelBuffer: CVPixelBuffer, title: String = "", subtitle: String = "") {
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

        context.setFillColor(red: charcoal.r, green: charcoal.g, blue: charcoal.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitleText = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleText.isEmpty || !subtitleText.isEmpty else { return }

        let maxWidth = w * 0.88
        let titleSize = fittedSize(titleText, preferred: 72, floor: 28, maxWidth: maxWidth)
        let subtitleSize: CGFloat = 34
        let gap: CGFloat = 28

        let titleLine = titleText.isEmpty ? nil : makeLine(titleText, size: titleSize, color: copper)
        let subtitleLine = subtitleText.isEmpty ? nil : makeLine(subtitleText, size: subtitleSize, color: subtitleColor)

        let titleWidth = titleLine.map { CTLineGetTypographicBounds($0, nil, nil, nil) } ?? 0
        let subtitleWidth = subtitleLine.map { CTLineGetTypographicBounds($0, nil, nil, nil) } ?? 0

        // Optical center: title sits a little above mid-frame, subtitle below.
        let titleY = h * 0.52
        let subtitleY = titleY - titleSize - gap + 16

        if let titleLine {
            context.textPosition = CGPoint(x: (w - titleWidth) / 2, y: titleY)
            CTLineDraw(titleLine, context)
        }
        if let subtitleLine {
            let y = titleText.isEmpty ? h * 0.48 : subtitleY
            context.textPosition = CGPoint(x: (w - subtitleWidth) / 2, y: y)
            CTLineDraw(subtitleLine, context)
        }
    }

    private static func fittedSize(_ string: String, preferred: CGFloat, floor: CGFloat, maxWidth: CGFloat) -> CGFloat {
        var size = preferred
        while size > floor {
            let line = makeLine(string, size: size, color: copper)
            if CTLineGetTypographicBounds(line, nil, nil, nil) <= Double(maxWidth) {
                return size
            }
            size -= 4
        }
        return floor
    }

    private static func makeLine(
        _ string: String,
        size: CGFloat,
        color: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> CTLine {
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        let cgColor = CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }
}
