import AppKit
import SwiftUI

extension ClipboardHistoryWindowController {
    func activateForClipboardPanel(hideApplicationWindows: Bool) {
        guard hideApplicationWindows else {
            if NSApp.isHidden { NSApp.unhide(nil) }
            applicationActivator()
            return
        }

        // Clipboard history is a transient palette. Make OpenFind active so
        // clicking another app produces a reliable didResignActive callback,
        // while keeping every primary/companion OpenFind window out of view.
        // The paste target was captured before this handoff.
        orderOutApplicationWindows(except: panel)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        applicationActivator()
        orderOutApplicationWindows(except: panel)
    }

    func orderOutApplicationWindows(except panel: NSPanel?) {
        NSApp.windows.filter { $0 !== panel }.forEach { window in
            window.animationBehavior = .none
            window.orderOut(nil)
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
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 440)
        panel.setFrameAutosaveName(frameAutosaveName)
        panel.delegate = self
        panel.onToggleActions = { [weak self] in
            self?.store.isActionPanelPresented.toggle()
        }
        panel.onSaveForReuse = { [weak self] in
            guard let self, let selected = store.selectedEntry else { return }
            store.saveForReuse(selected)
        }
        panel.onUndo = { [weak self] in
            self?.store.undoLastDeletion()
        }
        panel.onClose = { [weak self] in
            self?.close()
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
                          !store.isActionPanelPresented,
                          let panel = self.panel,
                          store.isPanelPresented else { return }
                    panel.orderFrontRegardless()
                    panel.makeKey()
                }
            },
            onQuickLook: { [weak self] entry in
                guard let self else { return }
                do {
                    try quickLook.toggle(entry: entry)
                } catch {
                    store.reportError(error)
                }
            },
            onCancelPasteStack: { [weak self] in self?.cancelPasteStack() },
            onClose: { [weak self] in self?.close() }
        )
    }

    func position(_ panel: NSPanel, override: ClipboardPopupPosition? = nil) {
        let popupPosition = override ?? store.preferences.popupPosition
        if popupPosition == .lastPosition,
           panel.setFrameUsingName(frameAutosaveName) { return }
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

    func restoreSavedFrameIfNeeded(
        _ panel: NSPanel,
        override: ClipboardPopupPosition? = nil
    ) -> Bool {
        let popupPosition = override ?? store.preferences.popupPosition
        guard popupPosition == .lastPosition,
              panel.setFrameUsingName(frameAutosaveName) else { return false }
        ensurePanelFrameIsVisible(panel)
        return true
    }

    func ensurePanelFrameIsVisible(_ panel: NSPanel) {
        let matchingScreen = NSScreen.screens.first {
            $0.visibleFrame.intersects(panel.frame)
        }
        guard let visibleFrame = matchingScreen?.visibleFrame
            ?? selectedScreen(at: NSEvent.mouseLocation)?.visibleFrame else {
            panel.center()
            return
        }

        var frame = panel.frame
        frame.size.width = min(
            max(frame.width, panel.minSize.width),
            visibleFrame.width
        )
        frame.size.height = min(
            max(frame.height, panel.minSize.height),
            visibleFrame.height
        )
        frame.origin.x = min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        if frame != panel.frame {
            panel.setFrame(frame, display: false)
        }
    }

    func selectedScreen(at mouseLocation: NSPoint) -> NSScreen? {
        let preferred = store.preferences.popupScreen
        if preferred > 0, NSScreen.screens.indices.contains(preferred - 1) {
            return NSScreen.screens[preferred - 1]
        }
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    func resize(_ panel: NSPanel, showingPreview: Bool, animated: Bool) {
        configureMinimumSize(panel, showingPreview: showingPreview)
        let targetWidth = showingPreview
            ? min(960, max(720, 350 + store.preferences.previewWidth)) : 450
        guard abs(panel.frame.width - targetWidth) > 1 else { return }
        var frame = panel.frame
        frame.origin.x += (frame.width - targetWidth) / 2
        frame.size.width = targetWidth
        panel.setFrame(frame, display: true, animate: animated)
    }

    func configureMinimumSize(_ panel: NSPanel, showingPreview: Bool) {
        panel.minSize = NSSize(width: showingPreview ? 680 : 420, height: 440)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard store.isPanelPresented, !store.isActionPanelPresented else { return }
        close()
    }

    func windowWillMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        isUserMovingPanel = true
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedPanel = notification.object as? NSPanel,
              movedPanel === panel,
              isUserMovingPanel else { return }
        isUserMovingPanel = false
        persistUserAdjustedFrame(movedPanel)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        isUserResizingPanel = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSPanel,
              resizedPanel === panel,
              isUserResizingPanel else { return }
        isUserResizingPanel = false
        persistUserAdjustedFrame(resizedPanel)
    }

    private func persistUserAdjustedFrame(_ panel: NSPanel) {
        panel.saveFrame(usingName: frameAutosaveName)
        if store.preferences.popupPosition != .lastPosition {
            store.setPreference(\.popupPosition, to: .lastPosition)
        }
    }

}
