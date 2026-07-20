import AppKit
import Foundation

@MainActor
protocol ClosedDisplayStateMonitoring: AnyObject {
    func start(handler: @escaping @MainActor (ClosedDisplayHardwareState) -> Void)
    func stop()
    func currentState() -> ClosedDisplayHardwareState
}

/// Re-reads the IOPM root-domain clamshell property on the native workspace
/// notifications that accompany lid and display topology transitions. This
/// avoids treating an ordinary display timeout as a physical lid close.
@MainActor
final class SystemClosedDisplayStateMonitor: ClosedDisplayStateMonitoring {
    private let hardware: any ClosedDisplayHardwareInspecting
    private let workspaceCenter: NotificationCenter
    private let applicationCenter: NotificationCenter
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var fallbackTimer: Timer?
    private var handler: (@MainActor (ClosedDisplayHardwareState) -> Void)?
    private var lastState: ClosedDisplayHardwareState = .unknown

    init(
        hardware: any ClosedDisplayHardwareInspecting = SystemClosedDisplayHardwareInspector(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default
    ) {
        self.hardware = hardware
        self.workspaceCenter = workspaceCenter
        self.applicationCenter = applicationCenter
    }

    func start(handler: @escaping @MainActor (ClosedDisplayHardwareState) -> Void) {
        stop()
        self.handler = handler
        lastState = currentState()
        if lastState == .closed { handler(.closed) }

        for name in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ] {
            let token = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observations.append((workspaceCenter, token))
        }
        let token = applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observations.append((applicationCenter, token))
        // Some hardware/OS combinations do not emit every workspace display
        // notification while SleepDisabled is active. The I/O Registry read is
        // cheap and non-privileged, so retain a low-frequency correctness
        // fallback without mistaking ordinary display sleep for a lid close.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        handler = nil
        lastState = .unknown
    }

    func currentState() -> ClosedDisplayHardwareState {
        hardware.clamshellState()
    }

    func refresh() {
        let state = currentState()
        guard state != lastState else { return }
        lastState = state
        handler?(state)
    }
}
