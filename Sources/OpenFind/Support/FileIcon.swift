import AppKit

/// Cached file icons so the results list doesn't ask the system on every redraw.
/// Cached by path with a bounded count that evicts least-recently-used entries.
enum FileIcon {
    @MainActor
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4000
        return cache
    }()

    @MainActor
    static func icon(for url: URL, size: CGFloat = 16) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: size, height: size)
        cache.setObject(image, forKey: key)
        return image
    }
}
