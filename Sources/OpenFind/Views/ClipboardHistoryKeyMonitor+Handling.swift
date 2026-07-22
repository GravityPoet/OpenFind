import AppKit
import Carbon

extension ClipboardHistoryKeyMonitor.Coordinator {
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let handler, hostView?.window?.isVisible == true else { return event }
        if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText() { return event }

        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if Int(event.keyCode) == kVK_ANSI_F, flags == .command {
            handler.onBeginSearch("")
            return nil
        }
        if Int(event.keyCode) == kVK_Delete, flags == [.command, .option] {
            handler.onClear(false)
            return nil
        }
        if Int(event.keyCode) == kVK_Delete, flags == [.command, .option, .shift] {
            handler.onClear(true)
            return nil
        }
        if let index = quickIndex(for: event.keyCode) {
            if flags == .command {
                handler.onQuickAction(index, .copy)
                return nil
            }
            if flags == .option {
                handler.onQuickAction(index, .paste)
                return nil
            }
            if flags == [.option, .shift] {
                handler.onQuickAction(index, .pastePlainText)
                return nil
            }
        }
        if handler.pinShortcut.matches(event) {
            handler.onTogglePin()
            return nil
        }
        if handler.previewShortcut.matches(event) {
            handler.onTogglePreview()
            return nil
        }
        if handler.deleteShortcut.matches(event) {
            handler.onDelete()
            return nil
        }
        if let pin = pinnedKey(for: event), flags == .command {
            handler.onPinnedAction(pin, .copy)
            return nil
        }
        if let pin = pinnedKey(for: event), flags == .option {
            handler.onPinnedAction(pin, .paste)
            return nil
        }
        if let pin = pinnedKey(for: event), flags == [.option, .shift] {
            handler.onPinnedAction(pin, .pastePlainText)
            return nil
        }
        if handleNavigation(event, flags: flags, handler: handler) { return nil }
        if handleAction(event, flags: flags, handler: handler) { return nil }
        if shouldBeginSearch(with: event, flags: flags, handler: handler) {
            if NSApp.keyWindow?.firstResponder is NSTextInputClient {
                handler.onBeginSearch("")
                return event
            }
            handler.onBeginSearch(event.characters ?? "")
            return nil
        }
        return event
    }

    private func handleNavigation(
        _ event: NSEvent,
        flags: NSEvent.ModifierFlags,
        handler: ClipboardHistoryKeyMonitor
    ) -> Bool {
        switch (Int(event.keyCode), flags) {
        case (kVK_UpArrow, []): handler.onMove(-1)
        case (kVK_DownArrow, []): handler.onMove(1)
        case (kVK_UpArrow, .shift): handler.onExtend(-1)
        case (kVK_DownArrow, .shift): handler.onExtend(1)
        case (kVK_PageUp, []): handler.onMove(-8)
        case (kVK_PageDown, []): handler.onMove(8)
        case (kVK_Home, []): handler.onSelectBoundary(true)
        case (kVK_End, []): handler.onSelectBoundary(false)
        case (kVK_Home, .shift): handler.onExtendBoundary(true)
        case (kVK_End, .shift): handler.onExtendBoundary(false)
        default: return false
        }
        return true
    }

    private func handleAction(
        _ event: NSEvent,
        flags: NSEvent.ModifierFlags,
        handler: ClipboardHistoryKeyMonitor
    ) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            switch flags {
            case []: handler.onDefaultAction()
            case .option: handler.onPaste(false)
            case [.option, .shift]: handler.onPaste(true)
            case .shift: handler.onCopyPlainText()
            default: return false
            }
        case kVK_Escape where flags.isEmpty:
            handler.onEscape()
        case kVK_ANSI_W where flags == .command:
            handler.onEscape()
        default:
            return false
        }
        return true
    }

    private func shouldBeginSearch(
        with event: NSEvent,
        flags: NSEvent.ModifierFlags,
        handler: ClipboardHistoryKeyMonitor
    ) -> Bool {
        guard !handler.isSearchPresented,
              flags.isEmpty || flags == .shift,
              let characters = event.characters,
              characters.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        return characters.contains { !$0.isWhitespace }
    }

    private func quickIndex(for keyCode: UInt16) -> Int? {
        let keyCodes = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
            kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
            kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        return keyCodes.firstIndex(of: Int(keyCode))
    }

    private func pinnedKey(for event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1 else { return nil }
        return ClipboardPinKey.normalize(characters)
    }
}
