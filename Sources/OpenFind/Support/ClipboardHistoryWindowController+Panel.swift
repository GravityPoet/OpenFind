import AppKit
import SwiftUI

enum ClipboardHistoryPanelMetrics {
    static let compactDefaultSize = NSSize(width: 520, height: 560)
    static let expandedDefaultSize = NSSize(width: 1080, height: 680)
    static let compactMinimumSize = NSSize(width: 460, height: 480)
    static let expandedMinimumSize = NSSize(width: 760, height: 520)
}

enum ClipboardHistoryPanelGeometryMigration {
    static let defaultsKey = "OpenFind.clipboardPanelGeometryMigrationVersionV1"
    static let currentVersion = 1
}

extension ClipboardHistoryWindowController {
    func activateForClipboardPanel(hideApplicationWindows: Bool) {
        guard hideApplicationWindows else {
            if NSApp.isHidden { NSApp.unhide(nil) }
            applicationActivator()
            return
        }

        // Clipboard history is a transient non-activating palette. Do not ask
        // macOS to switch away from a password field: Secure Input can reject
        // that activation request even though the global Carbon hot key has
        // already fired. The panel itself remains key and interactive.
        orderOutApplicationWindows(except: panel)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
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
            contentRect: NSRect(
                origin: .zero,
                size: ClipboardHistoryPanelMetrics.expandedDefaultSize
            ),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
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
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = ClipboardHistoryPanelMetrics.expandedMinimumSize
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
        hostingView.layer?.cornerRadius = 18
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
                    try quickLook.toggle(entry: try store.materializedEntry(for: entry))
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
           withProgrammaticPanelFrameChange({
               panel.setFrameUsingName(frameAutosaveName)
           }) { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = selectedScreen(at: mouseLocation) else {
            withProgrammaticPanelFrameChange {
                panel.center()
            }
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
        withProgrammaticPanelFrameChange {
            panel.setFrameOrigin(origin)
        }
    }

    func restoreSavedFrameIfNeeded(
        _ panel: NSPanel,
        override: ClipboardPopupPosition? = nil
    ) -> Bool {
        let popupPosition = override ?? store.preferences.popupPosition
        guard popupPosition == .lastPosition,
              withProgrammaticPanelFrameChange({
                  panel.setFrameUsingName(frameAutosaveName)
              }) else { return false }
        ensurePanelFrameIsVisible(panel)
        return true
    }

    /// The split preview needs more horizontal room than the pre-v1.1.2
    /// single-column panel. Upgrade an existing autosaved frame once, while
    /// keeping its top-left placement and all later user adjustments intact.
    func migrateSavedPanelFrameIfNeeded(_ panel: NSPanel) {
        guard store.defaults.integer(
            forKey: ClipboardHistoryPanelGeometryMigration.defaultsKey
        ) < ClipboardHistoryPanelGeometryMigration.currentVersion else { return }

        defer {
            store.defaults.set(
                ClipboardHistoryPanelGeometryMigration.currentVersion,
                forKey: ClipboardHistoryPanelGeometryMigration.defaultsKey
            )
        }

        guard store.preferences.popupPosition == .lastPosition,
              withProgrammaticPanelFrameChange({
                  panel.setFrameUsingName(frameAutosaveName)
              }) else { return }

        let oldFrame = panel.frame
        let visibleFrame = NSScreen.screens.first {
            $0.visibleFrame.intersects(oldFrame)
        }?.visibleFrame ?? selectedScreen(at: NSEvent.mouseLocation)?.visibleFrame
        guard let visibleFrame else { return }

        var frame = oldFrame
        frame.size.width = min(
            max(frame.width, ClipboardHistoryPanelMetrics.expandedDefaultSize.width),
            visibleFrame.width
        )
        frame.size.height = min(
            max(frame.height, ClipboardHistoryPanelMetrics.expandedDefaultSize.height),
            visibleFrame.height
        )
        // Preserve the user's visual anchor while the panel grows.
        frame.origin.y = oldFrame.maxY - frame.height
        frame.origin.x = oldFrame.minX
        frame.origin.x = min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        guard frame != oldFrame else { return }
        withProgrammaticPanelFrameChange {
            panel.setFrame(frame, display: false)
            panel.saveFrame(usingName: frameAutosaveName)
        }
    }

    func ensurePanelFrameIsVisible(_ panel: NSPanel) {
        let matchingScreen = NSScreen.screens.first {
            $0.visibleFrame.intersects(panel.frame)
        }
        guard let visibleFrame = matchingScreen?.visibleFrame
            ?? selectedScreen(at: NSEvent.mouseLocation)?.visibleFrame else {
            withProgrammaticPanelFrameChange {
                panel.center()
            }
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
            withProgrammaticPanelFrameChange {
                panel.setFrame(frame, display: false)
            }
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

        // Once a user has moved or resized the panel, preserve that exact
        // personalized frame on every wake and across the compact/expanded
        // transition. Only enforce the minimum needed to render the split
        // view if their saved frame is narrower than it.
        if store.preferences.popupPosition == .lastPosition {
            ensurePanelFrameIsVisible(panel)
            return
        }

        let targetSize = showingPreview
            ? ClipboardHistoryPanelMetrics.expandedDefaultSize
            : ClipboardHistoryPanelMetrics.compactDefaultSize
        guard abs(panel.frame.width - targetSize.width) > 1
            || abs(panel.frame.height - targetSize.height) > 1 else { return }
        var frame = panel.frame
        let leftEdge = frame.minX
        let topEdge = frame.maxY
        frame.size = targetSize
        // Keep the list's left edge and the panel's top edge stable while the
        // layout mode changes, so the current selection does not jump.
        frame.origin.x = leftEdge
        frame.origin.y = topEdge - targetSize.height
        withProgrammaticPanelFrameChange {
            panel.setFrame(frame, display: true, animate: animated)
        }
        ensurePanelFrameIsVisible(panel)
    }

    func configureMinimumSize(_ panel: NSPanel, showingPreview: Bool) {
        panel.minSize = showingPreview
            ? ClipboardHistoryPanelMetrics.expandedMinimumSize
            : ClipboardHistoryPanelMetrics.compactMinimumSize
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard store.isPanelPresented,
              !store.isActionPanelPresented,
              isPanelInteractionReady else { return }
        close()
    }

    func windowWillMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel,
              !isApplyingProgrammaticPanelFrame else { return }
        isUserMovingPanel = true
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedPanel = notification.object as? NSPanel,
              movedPanel === panel,
              !isApplyingProgrammaticPanelFrame,
              isUserMovingPanel else { return }
        isUserMovingPanel = false
        persistUserAdjustedFrame(movedPanel)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel,
              !isApplyingProgrammaticPanelFrame else { return }
        isUserResizingPanel = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSPanel,
              resizedPanel === panel,
              !isApplyingProgrammaticPanelFrame,
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
