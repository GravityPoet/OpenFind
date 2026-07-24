import AppKit
import OSLog

@MainActor
final class MenuBarPresentationController {
    typealias MenuPresenter = (NSMenu, NSPoint, NSView) -> Bool

    private let logger = Logger(subsystem: "com.openfind.app", category: "MenuBarPresentation")
    private let menuPresenter: MenuPresenter
    private weak var statusItem: NSStatusItem?
    private var clickMonitor: Any?
    private var onClipboardModifierAction: ((ClipboardMenuBarModifierAction) -> Void)?

    init(
        menuPresenter: @escaping MenuPresenter = { menu, point, view in
            menu.popUp(positioning: nil, at: point, in: view)
        }
    ) {
        self.menuPresenter = menuPresenter
    }

    func attach(
        _ statusItem: NSStatusItem,
        onClipboardModifierAction: @escaping (ClipboardMenuBarModifierAction) -> Void
    ) {
        self.statusItem = statusItem
        self.onClipboardModifierAction = onClipboardModifierAction
        installClickMonitorIfNeeded()
        logger.notice("Menu bar status item attached")
    }

    @discardableResult
    func present() -> Bool {
        guard let statusItem, let button = statusItem.button else {
            logger.error("Menu bar presentation failed because no status item is attached")
            return false
        }
        guard button.isEnabled else {
            logger.error("Menu bar presentation failed because the status item is disabled")
            return false
        }
        logger.notice("Menu bar presentation requested with button state \(button.state.rawValue)")
        guard button.state == .off else { return true }
        return presentMenu(statusItem.menu, anchoredTo: button)
    }

    private func installClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  let statusItem,
                  let button = statusItem.button,
                  event.window === button.window else { return event }
            if let action = ClipboardMenuBarModifierAction(
                modifierFlags: event.modifierFlags
            ) {
                onClipboardModifierAction?(action)
                return nil
            }
            return presentMenu(statusItem.menu, anchoredTo: button) ? nil : event
        }
    }

    private func presentMenu(_ menu: NSMenu?, anchoredTo button: NSStatusBarButton) -> Bool {
        guard let menu else {
            logger.notice("Menu is not attached yet; falling back to the status button action")
            button.performClick(button)
            return true
        }
        if button.state != .off {
            menu.cancelTracking()
            button.state = .off
            button.isHighlighted = false
            return true
        }

        button.state = .on
        button.isHighlighted = true
        defer {
            button.state = .off
            button.isHighlighted = false
        }
        let point = NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4)
        _ = menuPresenter(menu, point, button)
        return true
    }
}
