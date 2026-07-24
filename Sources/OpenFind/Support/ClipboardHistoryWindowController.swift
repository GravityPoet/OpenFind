import AppKit
import QuartzCore

@MainActor
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    let store: ClipboardHistoryStore
    let frameAutosaveName: NSWindow.FrameAutosaveName
    let applicationActivator: @MainActor () -> Void
    let applicationDeactivator: @MainActor () -> Void
    let pasteService = ClipboardPasteService()
    let quickLook = QuickLookController()
    var panel: NSPanel?
    var shortcutCycleState = ClipboardShortcutCycleState()
    var shortcutFlagsMonitor: Any?
    var shortcutModifierFlags: NSEvent.ModifierFlags = []
    var pasteStackKeyMonitor: Any?
    var pasteStackPasteKeyIsDown = false
    var pasteStackAdvanceTask: Task<Void, Never>?
    var isUserMovingPanel = false
    var isUserResizingPanel = false

    init(
        store: ClipboardHistoryStore,
        frameAutosaveName: NSWindow.FrameAutosaveName = "OpenFindClipboardHistory",
        applicationActivator: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        applicationDeactivator: @escaping @MainActor () -> Void = {
            if NSApp.isActive { NSApp.hide(nil) }
        }
    ) {
        self.store = store
        self.frameAutosaveName = frameAutosaveName
        self.applicationActivator = applicationActivator
        self.applicationDeactivator = applicationDeactivator
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard store.isPanelPresented else { return }
        close()
    }

    func toggle() {
        if store.isPanelPresented {
            close()
        } else {
            show()
        }
    }

    func show() {
        shortcutCycleState.reset()
        removeShortcutFlagsMonitor()
        present(hideApplicationWindows: true)
    }

    func prepare() {
        let panel = makePanelIfNeeded()
        configureMinimumSize(panel, showingPreview: true)
        if !restoreSavedFrameIfNeeded(panel) {
            resize(panel, showingPreview: true, animated: false)
        }
        park(panel, keepCompositorWarm: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
    }

    func prepareForBackgroundResidence() {
        prepare()
        guard let panel,
              let searchField = firstTextField(in: panel.contentView) else { return }
        // Prepare the search target without claiming keyboard focus while the
        // panel is invisible. Presentation performs the real key-window handoff.
        panel.initialFirstResponder = searchField
    }

    func present(
        positionOverride: ClipboardPopupPosition? = nil,
        hideApplicationWindows: Bool = false
    ) {
        pasteService.captureTargetApplication()
        store.query = ""
        store.selectedIndex = 0
        store.clearMultiSelection()
        store.isSearchPresented = true
        let panel = makePanelIfNeeded()
        activateForClipboardPanel(hideApplicationWindows: hideApplicationWindows)
        configureMinimumSize(panel, showingPreview: store.isPreviewVisible)
        if !restoreSavedFrameIfNeeded(panel, override: positionOverride) {
            resize(panel, showingPreview: store.isPreviewVisible, animated: false)
            position(panel, override: positionOverride)
        }
        panel.alphaValue = 1
        panel.contentView?.alphaValue = 1
        panel.contentView?.setAccessibilityHidden(false)
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        if hideApplicationWindows {
            orderOutApplicationWindows(except: panel)
        }
        store.beginPresentation()
        if let searchField = firstTextField(in: panel.contentView) {
            panel.initialFirstResponder = searchField
            _ = panel.makeFirstResponder(searchField)
        }
    }

    func paste(_ entry: ClipboardEntry, plainTextOnly: Bool = false) {
        let shouldPastePlainText = plainTextOnly || store.pasteWithoutFormatting
        let cursorOffsetFromEnd: Int
        do {
            cursorOffsetFromEnd = try store.copy(
                entry,
                plainTextOnly: shouldPastePlainText
            )
        } catch {
            store.reportError(error)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pasteService.pasteIntoCapturedApplication(
                    cursorOffsetFromEnd: cursorOffsetFromEnd
                )
                close()
            } catch {
                store.reportError(error)
            }
        }
    }

    func close() {
        let shouldReturnApplicationFocus = store.isPanelPresented
        store.endPresentation()
        if let panel {
            park(panel, keepCompositorWarm: true)
        }
        shortcutCycleState.reset()
        removeShortcutFlagsMonitor()
        if shouldReturnApplicationFocus {
            applicationDeactivator()
        }
    }

    private func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let textField = view as? NSTextField { return textField }
        for subview in view.subviews {
            if let textField = firstTextField(in: subview) { return textField }
        }
        return nil
    }

    func park(_ panel: NSPanel, keepCompositorWarm: Bool) {
        panel.ignoresMouseEvents = true
        panel.contentView?.setAccessibilityHidden(true)
        if panel.isKeyWindow {
            panel.resignKey()
        }
        if keepCompositorWarm {
            // Keep WindowServer's surface resident while making its contents
            // visually imperceptible and non-interactive. A near-zero window
            // alpha is treated as hidden and makes the first invocation pay
            // the full surface creation cost again. Keep the panel centered:
            // macOS constrains off-screen panels back onto a display edge,
            // which can expose a visible sliver.
            panel.alphaValue = 0.49
            panel.contentView?.alphaValue = 0.001
            panel.hasShadow = false
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            CATransaction.flush()
        } else {
            panel.alphaValue = 0
            panel.contentView?.alphaValue = 0
            panel.hasShadow = false
            panel.orderOut(nil)
        }
    }

    func pasteSelected() {
        guard let entry = store.selectedEntry else { return }
        paste(entry)
    }
}
