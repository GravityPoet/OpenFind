import AppKit
import SwiftUI

@MainActor
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    private let store: ClipboardHistoryStore
    private let pasteService = ClipboardPasteService()
    private var panel: NSPanel?

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        pasteService.captureTargetApplication()
        let panel = makePanelIfNeeded()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func paste(_ entry: ClipboardEntry, plainTextOnly: Bool = false) {
        let shouldPastePlainText = plainTextOnly || store.pasteWithoutFormatting
        do {
            try store.copy(entry, plainTextOnly: shouldPastePlainText)
        } catch {
            store.reportError(error)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pasteService.pasteIntoCapturedApplication()
                close()
            } catch {
                // The item remains copied even if automatic paste is
                // unavailable; expose a safe explanation and keep the panel
                // open so the user can use ordinary Command-V.
                store.reportError(error)
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: ClipboardHistoryView(
                store: store,
                onPaste: { [weak self] entry, plainTextOnly in
                    self?.paste(entry, plainTextOnly: plainTextOnly)
                }
            ) { [weak self] in
                self?.close()
            }
        )
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
