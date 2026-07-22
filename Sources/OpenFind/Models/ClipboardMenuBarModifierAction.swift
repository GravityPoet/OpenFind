import AppKit

enum ClipboardMenuBarModifierAction: Equatable {
    case toggleCapture
    case ignoreNextCapture

    init?(modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags.intersection([.command, .control, .option, .shift])
        switch flags {
        case .option:
            self = .toggleCapture
        case [.option, .shift]:
            self = .ignoreNextCapture
        default:
            return nil
        }
    }
}
