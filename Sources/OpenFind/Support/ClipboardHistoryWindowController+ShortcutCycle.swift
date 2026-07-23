import AppKit

extension ClipboardHistoryWindowController {
    func handleShortcutInvocation(shortcut: GlobalShortcut) {
        let action = shortcutCycleState.press(panelIsVisible: panel?.isVisible == true)
        switch action {
        case .show:
            shortcutModifierFlags = shortcut.eventModifierFlags
            installShortcutFlagsMonitor()
            present(positionOverride: .center, hideApplicationWindows: true)
        case .close:
            close()
        case .moveNext:
            store.moveSelection(by: 1)
        case .pasteSelected:
            pasteSelected()
        case .none:
            break
        }
    }

    func installShortcutFlagsMonitor() {
        guard shortcutFlagsMonitor == nil else { return }
        shortcutFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleShortcutFlagsChanged(event)
            return event
        }
    }

    func handleShortcutFlagsChanged(_ event: NSEvent) {
        let activeFlags = event.modifierFlags.intersection(shortcutModifierFlags)
        guard activeFlags.isEmpty else { return }
        let action = shortcutCycleState.modifiersReleased()
        removeShortcutFlagsMonitor()
        if action == .pasteSelected { pasteSelected() }
    }

    func removeShortcutFlagsMonitor() {
        if let shortcutFlagsMonitor {
            NSEvent.removeMonitor(shortcutFlagsMonitor)
            self.shortcutFlagsMonitor = nil
        }
    }
}
