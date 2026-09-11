import AppKit

@MainActor
final class ControlDoubleTapMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var gesture = ControlDoubleTap()
    private var action: (() -> Void)?

    func start(action: @escaping () -> Void) -> Bool {
        stop()
        self.action = action
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        guard globalMonitor != nil, localMonitor != nil else { stop(); return false }
        return true
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        action = nil
        gesture.reset()
    }

    private func handle(_ event: NSEvent) {
        if let recorder = NSApp.keyWindow?.firstResponder as? RecorderButton, recorder.isRecording {
            gesture.reset()
            return
        }
        if gesture.handle(event) { action?() }
    }
}
