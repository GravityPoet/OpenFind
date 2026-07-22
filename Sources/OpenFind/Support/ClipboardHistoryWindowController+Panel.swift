import AppKit
import SwiftUI

extension ClipboardHistoryWindowController {
    func activateForClipboardPanel(hideMainWindow: Bool) {
        let mainWindows = NSApp.windows.filter {
            $0.identifier?.rawValue == "OpenFind.main"
        }
        let shouldKeepMainWindowHidden = hideMainWindow
            || NSApp.isHidden
            || mainWindows.allSatisfy { !$0.isVisible }
        if shouldKeepMainWindowHidden { mainWindows.forEach { $0.orderOut(nil) } }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if shouldKeepMainWindowHidden { mainWindows.forEach { $0.orderOut(nil) } }
    }

    func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Clipboard History")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 440)
        panel.setFrameAutosaveName("OpenFindClipboardHistory")
        panel.delegate = self
        let hostingView = NSHostingView(rootView: makeHistoryView())
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    func makeHistoryView() -> ClipboardHistoryView {
        ClipboardHistoryView(
            store: store,
            onPaste: { [weak self] entry, plainTextOnly in
                self?.paste(entry, plainTextOnly: plainTextOnly)
            },
            onStartPasteStack: { [weak self] plainTextOnly in
                self?.startPasteStack(plainTextOnly: plainTextOnly)
            },
            onPreviewVisibilityChange: { [weak self] visible in
                guard let self, let panel = self.panel else { return }
                self.resize(panel, showingPreview: visible, animated: true)
            },
            onCancelPasteStack: { [weak self] in self?.cancelPasteStack() },
            onClose: { [weak self] in self?.close() }
        )
    }

    func position(_ panel: NSPanel, override: ClipboardPopupPosition? = nil) {
        let popupPosition = override ?? store.preferences.popupPosition
        if popupPosition == .lastPosition,
           panel.setFrameUsingName("OpenFindClipboardHistory") { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = selectedScreen(at: mouseLocation) else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let origin: NSPoint
        if popupPosition == .cursor {
            origin = NSPoint(
                x: min(max(mouseLocation.x - 24, visible.minX), visible.maxX - panel.frame.width),
                y: min(max(mouseLocation.y - panel.frame.height + 24, visible.minY),
                       visible.maxY - panel.frame.height)
            )
        } else {
            origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2
            )
        }
        panel.setFrameOrigin(origin)
    }

    func selectedScreen(at mouseLocation: NSPoint) -> NSScreen? {
        let preferred = store.preferences.popupScreen
        if preferred > 0, NSScreen.screens.indices.contains(preferred - 1) {
            return NSScreen.screens[preferred - 1]
        }
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    func resize(_ panel: NSPanel, showingPreview: Bool, animated: Bool) {
        let targetWidth = showingPreview
            ? min(960, max(720, 350 + store.preferences.previewWidth)) : 450
        panel.minSize = NSSize(width: showingPreview ? 680 : 420, height: 440)
        guard abs(panel.frame.width - targetWidth) > 1 else { return }
        var frame = panel.frame
        frame.origin.x += (frame.width - targetWidth) / 2
        frame.size.width = targetWidth
        panel.setFrame(frame, display: true, animate: animated)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
