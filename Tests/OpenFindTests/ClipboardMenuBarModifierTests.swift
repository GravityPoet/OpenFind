import AppKit
import Testing
@testable import OpenFind

@Suite("Clipboard Menu Bar Modifier Tests")
struct ClipboardMenuBarModifierTests {
    @Test func optionTogglesCaptureAndOptionShiftIgnoresNext() {
        #expect(ClipboardMenuBarModifierAction(modifierFlags: .option) == .toggleCapture)
        #expect(ClipboardMenuBarModifierAction(
            modifierFlags: [.option, .shift]
        ) == .ignoreNextCapture)
    }

    @Test func ordinaryAndUnrelatedModifiersOpenTheNormalMenu() {
        #expect(ClipboardMenuBarModifierAction(modifierFlags: []) == nil)
        #expect(ClipboardMenuBarModifierAction(modifierFlags: .command) == nil)
        #expect(ClipboardMenuBarModifierAction(modifierFlags: [.option, .control]) == nil)
    }

    @MainActor
    @Test func normalMenuPresentationUsesTheStatusItemAsItsAnchor() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 36)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        menu.addItem(withTitle: "OpenFind", action: nil, keyEquivalent: "")
        statusItem.menu = menu
        let button = try #require(statusItem.button)
        var presentedMenu: NSMenu?
        var anchorPoint: NSPoint?
        weak var anchorView: NSView?
        let controller = MenuBarPresentationController { menu, point, view in
            presentedMenu = menu
            anchorPoint = point
            anchorView = view
            return false
        }
        controller.attach(statusItem) { _ in }

        #expect(controller.present())

        #expect(presentedMenu === menu)
        #expect(anchorView === button)
        #expect(anchorPoint == NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4))
        #expect(button.state == .off)
    }
}
