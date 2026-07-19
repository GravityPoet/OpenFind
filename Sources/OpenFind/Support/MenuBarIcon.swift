import AppKit

/// A compact, template-rendered version of the OpenFind mark for the menu bar.
/// The rounded-square application background is intentionally omitted so the
/// status item stays as quiet and legible as the native system icons.
enum MenuBarIcon {
    @MainActor
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
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
