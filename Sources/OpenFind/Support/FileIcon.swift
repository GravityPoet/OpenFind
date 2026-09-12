import AppKit

/// Cached file icons so the results list doesn't ask the system on every redraw.
/// Cache only display-sized bitmaps so full-resolution icon representations
/// cannot outlive the results that requested them.
enum FileIcon {
    @MainActor
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    @MainActor
    static func icon(for url: URL, size: CGFloat = 16) -> NSImage {
        let key = "\(size):\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let pointSize = NSSize(width: size, height: size)
        let pixels = Int(ceil(size * 2))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                    from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(bitmap)
        cache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return image
    }
}
