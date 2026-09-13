import AppKit
import Carbon

@MainActor
final class QuickSearchPanel: NSPanel {
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onFullSearch: (() -> Void)?
    var onNavigateForward: (() -> Bool)?
    var onNavigateBack: (() -> Bool)?
    var onQuickLook: ((_ explicitShortcut: Bool) -> Bool)?
    var onMoveSelection: ((Int) -> Void)?
    var onOpenNumber: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleCommand(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommand(event) || super.performKeyEquivalent(with: event)
    }

    /// IME candidate navigation and confirmation belong to the field editor.
    func handleCommand(_ event: NSEvent) -> Bool {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command,
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...9).contains(digit) {
            onOpenNumber?(digit - 1)
            return true
        }
        switch (Int(event.keyCode), flags) {
        case (kVK_Escape, []), (kVK_ANSI_W, .command): onClose?()
        case (kVK_DownArrow, []): onMoveSelection?(1)
        case (kVK_UpArrow, []): onMoveSelection?(-1)
        case (kVK_Tab, []): return onNavigateForward?() == true
        case (kVK_LeftArrow, .command), (kVK_Tab, .shift):
            return onNavigateBack?() == true
        case (kVK_RightArrow, []):
            if let editor = firstResponder as? NSTextView,
               editor.selectedRange() != NSRange(location: editor.string.utf16.count, length: 0) { return false }
            return onNavigateForward?() == true
        case (kVK_Space, []): return onQuickLook?(false) == true
        case (kVK_ANSI_Y, .command): return onQuickLook?(true) == true
        case (kVK_Return, .option), (kVK_ANSI_KeypadEnter, .option): onFullSearch?()
        case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command): onReveal?()
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): onOpen?()
        default: return false
        }
        return true
    }
}
