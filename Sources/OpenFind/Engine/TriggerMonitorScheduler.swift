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
        configureWakeEvents()
        observeTriggerConfiguration()
        refresh()
        let boundedInterval = min(300, max(1, interval))
        timer = Timer.scheduledTimer(withTimeInterval: boundedInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
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

    private func configureWakeEvents() {
        let requiredCriteria = coordinator.requiredCriteria
        guard requiredCriteria != configuredCriteria || !hasStarted else { return }
        configuredCriteria = requiredCriteria
        wakeEvents.start(requiredCriteria: requiredCriteria) { [weak self] in
            self?.refresh()
        }
    }

    private func observeTriggerConfiguration() {
        guard hasStarted else { return }
        withObservationTracking {
            _ = coordinator.requiredCriteria
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted else { return }
                self.configureWakeEvents()
                self.refresh()
                self.observeTriggerConfiguration()
            }
        }
    }
}
