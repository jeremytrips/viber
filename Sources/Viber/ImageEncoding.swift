import AppKit
import ViberCore

/// Screenshots for Claude: scaled and encoded the way the model can use them.
enum ImageEncoding {
    /// Scales to at most 1280 points wide and about 1.15 megapixels, which is what the model can use, then encodes JPEG.
    static func jpeg(_ image: NSImage, maxWidth: CGFloat = 1280, maxPixels: CGFloat = 1_150_000) throws -> (data: Data, width: Int, height: Int) {
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { throw PreviewError.capture("The screenshot came back empty.") }
        var scale = min(1, maxWidth / size.width)
        if size.width * scale * size.height * scale > maxPixels { scale = (maxPixels / (size.width * size.height)).squareRoot() }
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw PreviewError.capture("Could not encode the screenshot.") }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw PreviewError.capture("Could not encode the screenshot.")
        }
        return (data, width, height)
    }
}
