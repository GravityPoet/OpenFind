import AppKit

/// A compact ring-and-dot mark tuned for the 18-point macOS menu bar canvas.
/// The monochrome template lets macOS preserve contrast across wallpapers,
/// appearances, and the highlighted state while the center dot stays visible.
@MainActor
enum MenuBarIcon {
    private static let menuBarImage = render()

    /// Reuse a stable image identity. Creating a new `NSImage` during every
    /// SwiftUI status-item reconciliation makes AppKit resize the status item,
    /// which can feed another reconciliation and spin the main thread.
    static func make() -> NSImage {
        menuBarImage
    }

    private static func render() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.lockFocus()

        NSColor.black.setStroke()
        let ring = NSBezierPath(
            ovalIn: NSRect(x: 3.0, y: 3.0, width: 12.0, height: 12.0)
        )
        ring.lineWidth = 1.8
        ring.stroke()

        NSColor.black.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: 6.75, y: 6.75, width: 4.5, height: 4.5)
        ).fill()

        image.unlockFocus()
        return image
    }
}
