import AppKit
import SwiftUI

extension ClipboardHistoryWindowController {
    func activateForClipboardPanel(hideApplicationWindows: Bool) {
        let applicationWindows = NSApp.windows.filter {
            guard let identifier = $0.identifier?.rawValue else { return false }
            return identifier == "OpenFind.main" || identifier == "OpenFind.settings"
        }
        let shouldKeepApplicationWindowsHidden = hideApplicationWindows
            || NSApp.isHidden
            || applicationWindows.allSatisfy { !$0.isVisible }
        if shouldKeepApplicationWindowsHidden {
            applicationWindows.forEach { $0.orderOut(nil) }
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if shouldKeepApplicationWindowsHidden {
            applicationWindows.forEach { $0.orderOut(nil) }
        }
    }

    func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = ClipboardHistoryPanel(
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
        panel.onToggleActions = { [weak self] in
            self?.store.isActionPanelPresented.toggle()
        }
        panel.onSaveForReuse = { [weak self] in
            guard let self, let selected = store.selectedEntry else { return }
            store.saveForReuse(selected)
        }
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
            onActionPanelVisibilityChange: { [weak self] visible in
                guard !visible else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self,
                          NSApp.isActive,
                          !store.isActionPanelPresented,
                          let panel = self.panel,
                          panel.isVisible else { return }
                    panel.makeKeyAndOrderFront(nil)
                }
            },
            onQuickLook: { [weak self] urls in self?.quickLook.toggle(items: urls) },
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
        if store.isActionPanelPresented { return }
        close()
    }
}
