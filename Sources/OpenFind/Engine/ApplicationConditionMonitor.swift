import AppKit
import Foundation

@MainActor
protocol SessionConditionObservation: AnyObject {
    func cancel()
}

@MainActor
protocol ApplicationConditionObservation: SessionConditionObservation {}

@MainActor
protocol ApplicationConditionMonitoring: AnyObject {
    func isRunning(bundleIdentifier: String) -> Bool
    func observe(
        bundleIdentifier: String,
        onChange: @escaping @MainActor (Bool) -> Void
    ) -> any ApplicationConditionObservation
}

@MainActor
final class WorkspaceApplicationConditionMonitor: ApplicationConditionMonitoring {
    private let workspace: NSWorkspace
    private let processNames: () -> Set<String>
    private let pollInterval: TimeInterval

    init(
        workspace: NSWorkspace = .shared,
        processNames: @escaping () -> Set<String> = { ProcessTriggerSignals.currentNames() },
        pollInterval: TimeInterval = 2
    ) {
        self.workspace = workspace
        self.processNames = processNames
        self.pollInterval = min(30, max(0.01, pollInterval))
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if workspace.runningApplications.contains(where: { application in
            [
                application.bundleIdentifier,
                application.localizedName,
                application.executableURL?.lastPathComponent,
                application.bundleURL?.deletingPathExtension().lastPathComponent,
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(normalized)
        }) {
            return true
        }
        // Amphetamine's process-discovery helper also accepts background
        // executables that have no NSRunningApplication/bundle identifier.
        return processNames().contains(normalized)
    }

    func observe(
        bundleIdentifier: String,
        onChange: @escaping @MainActor (Bool) -> Void
    ) -> any ApplicationConditionObservation {
        let center = workspace.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        let relay = ApplicationConditionChangeRelay(
            initialValue: isRunning(bundleIdentifier: bundleIdentifier),
            onChange: onChange
        )
        let tokens = names.map { name in
            center.addObserver(forName: name, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    relay.emit(self?.isRunning(bundleIdentifier: bundleIdentifier) == true)
                }
            }
        }
        let tokenBag = NotificationTokenBag(center: center, tokens: tokens)
        return WorkspaceApplicationConditionObservation(
            tokenBag: tokenBag,
            pollInterval: pollInterval,
            stateProvider: { [weak self] in
                self?.isRunning(bundleIdentifier: bundleIdentifier) == true
            },
            relay: relay
        )
    }
}

@MainActor
private final class WorkspaceApplicationConditionObservation: ApplicationConditionObservation {
    private let tokenBag: NotificationTokenBag
    private var pollTask: Task<Void, Never>?

    init(
        tokenBag: NotificationTokenBag,
        pollInterval: TimeInterval,
        stateProvider: @escaping @MainActor () -> Bool,
        relay: ApplicationConditionChangeRelay
    ) {
        self.tokenBag = tokenBag
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(pollInterval))
                } catch {
                    return
                }
                relay.emit(stateProvider())
            }
        }
    }

    func cancel() {
        tokenBag.cancel()
        pollTask?.cancel()
        pollTask = nil
    }

    deinit {
        pollTask?.cancel()
    }
}

@MainActor
private final class ApplicationConditionChangeRelay {
    private var lastValue: Bool
    private let onChange: @MainActor (Bool) -> Void

    init(initialValue: Bool, onChange: @escaping @MainActor (Bool) -> Void) {
        lastValue = initialValue
        self.onChange = onChange
    }

    func emit(_ value: Bool) {
        guard value != lastValue else { return }
        lastValue = value
        onChange(value)
    }
}

private final class NotificationTokenBag: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol]

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func cancel() {
        lock.lock()
        let tokensToRemove = tokens
        tokens.removeAll()
        lock.unlock()
        tokensToRemove.forEach(center.removeObserver)
    }

    deinit {
        cancel()
    }
}
