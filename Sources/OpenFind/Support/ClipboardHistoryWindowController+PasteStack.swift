import AppKit
import Carbon

extension ClipboardHistoryWindowController {
    func startPasteStack(plainTextOnly: Bool = false) {
        let shouldPastePlainText = plainTextOnly || store.pasteWithoutFormatting
        do {
            guard try store.startPasteStack(
                plainTextOnly: shouldPastePlainText
            ) != nil else { return }
            try installPasteStackKeyMonitor()
            close()
        } catch {
            store.cancelPasteStack()
            removePasteStackKeyMonitor()
            store.reportError(error)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pasteService.activateCapturedApplication()
            } catch {
                store.cancelPasteStack()
                removePasteStackKeyMonitor()
                store.reportError(error)
            }
        }
    }

    func cancelPasteStack() {
        store.cancelPasteStack()
        removePasteStackKeyMonitor()
    }

    func installPasteStackKeyMonitor() throws {
        guard pasteStackKeyMonitor == nil else { return }
        pasteStackPasteKeyIsDown = false
        pasteStackKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            Task { @MainActor in self?.handlePasteStackKeyEvent(event) }
        }
        guard pasteStackKeyMonitor != nil else {
            throw ClipboardHistoryError.pasteStackMonitorUnavailable
        }
    }

    func handlePasteStackKeyEvent(_ event: NSEvent) {
        guard Int(event.keyCode) == kVK_ANSI_V else { return }
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection([
                .command, .control, .option, .shift,
            ])
            pasteStackPasteKeyIsDown = flags == .command
        case .keyUp where pasteStackPasteKeyIsDown:
            pasteStackPasteKeyIsDown = false
            schedulePasteStackAdvance()
        default:
            break
        }
    }

    func schedulePasteStackAdvance() {
        guard let stackID = store.pasteStack?.id else { return }
        pasteStackAdvanceTask?.cancel()
        pasteStackAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let self,
                  store.pasteStack?.id == stackID else { return }
            pasteStackAdvanceTask = nil
            advancePasteStackAfterPaste()
        }
    }

    func advancePasteStackAfterPaste() {
        do {
            if try store.advancePasteStack() == false { removePasteStackKeyMonitor() }
        } catch {
            store.reportError(error)
            cancelPasteStack()
        }
    }

    func removePasteStackKeyMonitor() {
        pasteStackAdvanceTask?.cancel()
        pasteStackAdvanceTask = nil
        if let pasteStackKeyMonitor {
            NSEvent.removeMonitor(pasteStackKeyMonitor)
            self.pasteStackKeyMonitor = nil
        }
        pasteStackPasteKeyIsDown = false
    }
}
