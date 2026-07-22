import Testing
@testable import OpenFind

@Suite("Clipboard Shortcut Cycle Tests")
struct ClipboardShortcutCycleTests {
    @Test func singleShortcutPressOpensAndStaysOpenAfterModifierRelease() {
        var state = ClipboardShortcutCycleState()

        #expect(state.press(panelIsVisible: false) == .show)
        #expect(state.phase == .opening)
        #expect(state.modifiersReleased() == .none)
        #expect(state.phase == .idle)
    }

    @Test func repeatedPressCyclesAndReleasePastesSelection() {
        var state = ClipboardShortcutCycleState()

        #expect(state.press(panelIsVisible: false) == .show)
        #expect(state.press(panelIsVisible: true) == .moveNext)
        #expect(state.press(panelIsVisible: true) == .moveNext)
        #expect(state.modifiersReleased() == .pasteSelected)
        #expect(state.phase == .idle)
    }

    @Test func shortcutClosesPanelOpenedOutsideShortcutCycle() {
        var state = ClipboardShortcutCycleState()

        #expect(state.press(panelIsVisible: true) == .close)
        #expect(state.phase == .idle)
    }
}
