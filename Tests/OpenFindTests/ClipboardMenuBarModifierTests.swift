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
}
