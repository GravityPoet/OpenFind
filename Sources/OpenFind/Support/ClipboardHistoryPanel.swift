import AppKit
import Carbon

@MainActor
final class ClipboardHistoryPanel: NSPanel {
    var onToggleActions: (() -> Void)?
    var onSaveForReuse: (() -> Void)?
    var onUndo: (() -> Void)?
    var onClose: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, performClipboardCommand(with: event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performClipboardCommand(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func performClipboardCommand(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
            onClose?()
            return true
        }
        guard flags == .command else { return false }
        switch Int(event.keyCode) {
        case kVK_ANSI_K:
            onToggleActions?()
            return true
        case kVK_ANSI_S:
            onSaveForReuse?()
            return true
        case kVK_ANSI_Z:
            onUndo?()
            return true
        default:
            return false
        }
    }
}
