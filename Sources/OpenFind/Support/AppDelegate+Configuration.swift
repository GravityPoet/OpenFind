import Foundation

extension AppDelegate {
    func reloadPortableConfiguration() {
        // Release the entire shortcut set before loading replacements so
        // swapping two bindings cannot collide with the previous assignment.
        for id in ["toggleOpenFind", ClipboardController.hotKeyID, KeyboardLockController.hotKeyID] {
            hotKeyRegistry.unbind(id: id)
        }
        for action in AwakeHotKeyAction.allCases { hotKeyRegistry.unbind(id: "awake.\(action.rawValue)") }
        globalHotKey.reloadPreferences()
        clipboard.reloadPreferences()
        keyboardLock.reloadPreferences()
        awakeHotKeys.reloadPreferences()
        awakeSessionPreferences.reloadPreferences()
        awakeNotifications.reloadPreferences()
        driveAliveStore.reloadPreferences()
        triggerStore.reloadPreferences()
        viewModel.reloadPortableConfiguration()
    }
}
