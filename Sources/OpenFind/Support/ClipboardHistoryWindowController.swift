import AppKit

@MainActor
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    let store: ClipboardHistoryStore
    let pasteService = ClipboardPasteService()
    let quickLook = QuickLookController()
    var panel: NSPanel?
    var shortcutCycleState = ClipboardShortcutCycleState()
    var shortcutFlagsMonitor: Any?
    var shortcutModifierFlags: NSEvent.ModifierFlags = []
    var pasteStackKeyMonitor: Any?
    var pasteStackPasteKeyIsDown = false
    var pasteStackAdvanceTask: Task<Void, Never>?

    init(store: ClipboardHistoryStore) {
        self.store = store
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
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        shortcutCycleState.reset()
        removeShortcutFlagsMonitor()
        present()
    }

    func present(
        positionOverride: ClipboardPopupPosition? = nil,
        hideMainWindow: Bool = false
    ) {
        pasteService.captureTargetApplication()
        store.beginPresentation()
        store.query = ""
        store.selectedIndex = 0
        store.clearMultiSelection()
        store.isSearchPresented = true
        let panel = makePanelIfNeeded()
        activateForClipboardPanel(hideMainWindow: hideMainWindow)
        resize(panel, showingPreview: store.isPreviewVisible, animated: false)
        position(panel, override: positionOverride)
        panel.makeKeyAndOrderFront(nil)
    }

    func paste(_ entry: ClipboardEntry, plainTextOnly: Bool = false) {
        let shouldPastePlainText = plainTextOnly || store.pasteWithoutFormatting
        do {
            try store.copy(entry, plainTextOnly: shouldPastePlainText)
        } catch {
            store.reportError(error)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pasteService.pasteIntoCapturedApplication()
                close()
            } catch {
                store.reportError(error)
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        store.endPresentation()
        shortcutCycleState.reset()
        removeShortcutFlagsMonitor()
    }

    func pasteSelected() {
        guard let entry = store.selectedEntry else { return }
        paste(entry)
    }
}
