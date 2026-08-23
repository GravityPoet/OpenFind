import Foundation
import Observation

@MainActor
final class TriggerMonitorScheduler {
    private let coordinator: TriggerCoordinator
    private let provider: any TriggerSnapshotProviding
    private let wakeEvents: any TriggerWakeEventSourcing
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var generation = 0
    private var hasStarted = false
    private var configuredCriteria: Set<TriggerCriterion.Kind> = []
    private var pollInterval: TimeInterval = 5

    init(
        coordinator: TriggerCoordinator,
        provider: any TriggerSnapshotProviding = LocalTriggerSnapshotProvider(),
        wakeEvents: any TriggerWakeEventSourcing = SystemTriggerWakeEventSource()
    ) {
        self.coordinator = coordinator
        self.provider = provider
        self.wakeEvents = wakeEvents
    }

    func start(interval: TimeInterval = 5) {
        stop()
        hasStarted = true
        pollInterval = min(300, max(1, interval))
        observeTriggerConfiguration()
        reconcileMonitoring(refreshOnChange: false)
    }

    func stop() {
        hasStarted = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        configuredCriteria = []
        pollInterval = 5
        wakeEvents.stop()
    }

    func refresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        let currentGeneration = generation
        let snapshot = provider.snapshot(requiredCriteria: coordinator.requiredCriteria)
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration {
                    self.refreshTask = nil
                    if self.refreshPending {
                        self.refreshPending = false
                        self.refresh()
                    }
                }
            }
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            await self.coordinator.evaluate(snapshot: snapshot)
        }
    }

    @discardableResult
    private func configureWakeEvents() -> Bool {
        let requiredCriteria = coordinator.requiredCriteria
        guard requiredCriteria != configuredCriteria else { return false }
        configuredCriteria = requiredCriteria
        wakeEvents.start(requiredCriteria: requiredCriteria) { [weak self] in
            self?.refresh()
        }
        return true
    }

    private func reconcileMonitoring(refreshOnChange: Bool) {
        guard hasStarted else { return }
        let criteriaChanged = configureWakeEvents()
        let hasCriteria = !coordinator.requiredCriteria.isEmpty
        if hasCriteria {
            if timer == nil {
                refresh()
                timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            } else if refreshOnChange {
                refresh()
            }
        } else {
            timer?.invalidate()
            timer = nil
            // A transition to no criteria must still give the coordinator a
            // chance to end a trigger session that was previously active.
            if criteriaChanged, refreshOnChange { refresh() }
        }
    }

    private func observeTriggerConfiguration() {
        guard hasStarted else { return }
        withObservationTracking {
            _ = coordinator.requiredCriteria
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted else { return }
                self.reconcileMonitoring(refreshOnChange: true)
                self.observeTriggerConfiguration()
            }
        }
    }
}
