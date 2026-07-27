import AppKit

/// A compact ring-and-dot mark tuned for the 18-point macOS menu bar canvas.
/// The monochrome template lets macOS preserve contrast across wallpapers,
/// appearances, and the highlighted state while the center dot stays visible.
@MainActor
enum MenuBarIcon {
    private static let idleImage = render(sessionActive: false)
    private static let activeImage = render(sessionActive: true)

    /// Reuse stable image identities. Creating a new `NSImage` during every
    /// SwiftUI status-item reconciliation makes AppKit resize the status item,
    /// which can feed another reconciliation and spin the main thread. The two
    /// states swap between the same two cached instances.
    ///
    /// `sessionActive` inverts the mark (filled disc, punched-out center) so a
    /// glance at the menu bar answers "is my Mac being kept awake?" without
    /// opening the menu — the check Amphetamine users make before closing the
    /// lid.
    static func make(sessionActive: Bool = false) -> NSImage {
        sessionActive ? activeImage : idleImage
    }

    private static func render(sessionActive: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.lockFocus()

        if sessionActive {
            NSColor.black.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: 2.1, y: 2.1, width: 13.8, height: 13.8)
            ).fill()
            // Punch the center out of the disc so active stays the exact
            // negative of idle and reads clearly as a template at 18 points.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(
                ovalIn: NSRect(x: 6.75, y: 6.75, width: 4.5, height: 4.5)
            ).fill()
        } else {
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
        }

        image.unlockFocus()
        return image
    }
}
