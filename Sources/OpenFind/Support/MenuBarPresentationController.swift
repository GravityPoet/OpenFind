import AppKit
import OSLog

@MainActor
final class MenuBarPresentationController {
    private let logger = Logger(subsystem: "com.openfind.app", category: "MenuBarPresentation")
    private weak var statusItem: NSStatusItem?

    func attach(_ statusItem: NSStatusItem) {
        self.statusItem = statusItem
        logger.notice("Menu bar status item attached")
    }

    @discardableResult
    func present() -> Bool {
        guard let button = statusItem?.button else {
            logger.error("Menu bar presentation failed because no status item is attached")
            return false
        }
        guard button.isEnabled else {
            logger.error("Menu bar presentation failed because the status item is disabled")
            return false
        }
        logger.notice("Menu bar presentation requested with button state \(button.state.rawValue)")
        guard button.state == .off else { return true }
        button.performClick(nil)
        return true
    }
}
