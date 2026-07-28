import AppKit
import OSLog
import QuartzCore

@MainActor
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    let store: ClipboardHistoryStore
    let frameAutosaveName: NSWindow.FrameAutosaveName
    let applicationActivator: @MainActor () -> Void
    let applicationDeactivator: @MainActor () -> Void
    let pasteService = ClipboardPasteService()
    let quickLook = QuickLookController()
    private let logger = Logger(subsystem: "com.openfind.app", category: "ClipboardWindow")
    var panel: NSPanel?
    var isPanelInteractionReady = false
    private var shouldCloseWhenApplicationResigns = false
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
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.frameAutosaveName = frameAutosaveName
        self.applicationActivator = applicationActivator
        self.applicationDeactivator = applicationDeactivator
        super.init()
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard store.isPanelPresented else { return }
        isPanelInteractionReady = true
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        // A shortcut presentation is deliberately non-activating. Secure
        // Input may leave OpenFind inactive, so an application-resign
        // notification must not tear down the newly opened clipboard panel.
        guard store.isPanelPresented, shouldCloseWhenApplicationResigns else {
            return
        }
        guard isPanelInteractionReady else { return }
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
        store.kindFilter = .all
        store.selectedIndex = 0
        store.clearMultiSelection()
        store.isSearchPresented = true
        let panel = makePanelIfNeeded()
        shouldCloseWhenApplicationResigns = !hideApplicationWindows
        activateForClipboardPanel(hideApplicationWindows: hideApplicationWindows)
        // The panel is non-activating by design. It can still become key and
        // accept search input while another app owns Secure Input, so opening
        // it never depends on NSApp becoming active.
        isPanelInteractionReady = true
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
        panel.orderFrontRegardless()
        panel.makeKey()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The pasteboard is written inside the closure, after target
                // activation has succeeded: an activation failure must not
                // overwrite what the user already had on the clipboard.
                try await pasteService.pasteIntoCapturedApplication {
                    try store.copy(entry, plainTextOnly: shouldPastePlainText)
                }
                close()
            } catch {
                store.reportError(error)
            }
        }
    }

    func close() {
        let shouldReturnApplicationFocus = store.isPanelPresented
        shouldCloseWhenApplicationResigns = false
        isPanelInteractionReady = false
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

    func reconcilePresentationBeforeShortcut() -> Bool {
        let isInteractive = store.isPanelPresented
            && panel?.isVisible == true
            && panel?.ignoresMouseEvents == false
        guard store.isPanelPresented, !isInteractive else { return isInteractive }
        logger.notice("Resetting a stale hidden clipboard presentation before shortcut handling")
        close()
        return false
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
        _ = panel.makeFirstResponder(nil)
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
