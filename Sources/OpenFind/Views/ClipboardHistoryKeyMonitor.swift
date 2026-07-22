import AppKit
import SwiftUI

enum ClipboardQuickAction {
    case copy
    case paste
    case pastePlainText
}

struct ClipboardHistoryKeyMonitor: NSViewRepresentable {
    let isSearchPresented: Bool
    let pinShortcut: GlobalShortcut
    let deleteShortcut: GlobalShortcut
    let previewShortcut: GlobalShortcut
    let onMove: (Int) -> Void
    let onSelectBoundary: (Bool) -> Void
    let onExtend: (Int) -> Void
    let onExtendBoundary: (Bool) -> Void
    let onDefaultAction: () -> Void
    let onPaste: (Bool) -> Void
    let onCopyPlainText: () -> Void
    let onTogglePin: () -> Void
    let onTogglePreview: () -> Void
    let onDelete: () -> Void
    let onClear: (Bool) -> Void
    let onEscape: () -> Void
    let onBeginSearch: (String) -> Void
    let onQuickAction: (Int, ClipboardQuickAction) -> Void
    let onPinnedAction: (String, ClipboardQuickAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(hostView: view, handler: self)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(hostView: nsView, handler: self)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var handler: ClipboardHistoryKeyMonitor?
        var monitor: Any?

        func update(hostView: NSView, handler: ClipboardHistoryKeyMonitor) {
            self.hostView = hostView
            self.handler = handler
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
