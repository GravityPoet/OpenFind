import Foundation
import Observation

@MainActor
@Observable
final class TriggerCoordinator {
    @ObservationIgnored private let store: TriggerStore
    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let evaluator: TriggerEvaluator
    @ObservationIgnored private var sessionSubscription: AwakeSessionEventSubscription?

    private(set) var currentSnapshot = TriggerSnapshot()
    private(set) var activeTriggerID: UUID?
    private(set) var lastErrorMessage: String?

    var requiredCriteria: Set<TriggerCriterion.Kind> {
        guard store.isEnabled else { return [] }
        return Set(store.triggers.filter(\.isEnabled).flatMap { trigger in
            trigger.criteria.map(\.kind)
        })
    }

    init(
        store: TriggerStore,
        sessions: AwakeSessionController,
        evaluator: TriggerEvaluator = TriggerEvaluator()
    ) {
        self.store = store
        self.sessions = sessions
        self.evaluator = evaluator
        sessionSubscription = sessions.observeEvents { [weak self] event in
            self?.handleSessionEvent(event)
        }
    }

    func evaluate(snapshot: TriggerSnapshot) async {
        currentSnapshot = snapshot
        synchronizeCurrentTrigger()

        guard store.isEnabled else {
            await endActiveTriggerIfNeeded()
            return
        }

        let matchingTrigger = evaluator.firstMatching(in: store.triggers, snapshot: snapshot)
        guard let matchingTrigger else {
            await endActiveTriggerIfNeeded()
            return
        }

        if activeTriggerID == matchingTrigger.id { return }
        if let activeSession = sessions.activeSession,
           case .trigger = activeSession.source,
           activeTriggerID != nil {
            await startTrigger(matchingTrigger)
            return
        }
        guard sessions.activeSession == nil else { return }
        await startTrigger(matchingTrigger)
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func startTrigger(_ trigger: AwakeTrigger) async {
        let oldTriggerID = activeTriggerID
        do {
            try await sessions.startAsync(.init(
                endCondition: .indefinitely,
                options: trigger.sessionOptions,
                source: .trigger(trigger.id)
            ))
            activeTriggerID = trigger.id
            lastErrorMessage = nil
        } catch is CancellationError {
            activeTriggerID = oldTriggerID
        } catch {
            activeTriggerID = oldTriggerID
            lastErrorMessage = error.localizedDescription
        }
    }

    private func endActiveTriggerIfNeeded() async {
        guard activeTriggerID != nil else { return }
        do {
            try await sessions.endAsync(reason: .triggerCondition)
            activeTriggerID = nil
            lastErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func synchronizeCurrentTrigger() {
        guard let activeSession = sessions.activeSession else {
            activeTriggerID = nil
            return
        }
        guard case let .trigger(identifier) = activeSession.source else {
            activeTriggerID = nil
            return
        }
        activeTriggerID = identifier
    }

    private func handleSessionEvent(_ event: AwakeSessionEvent) {
        guard case let .ended(session, reason) = event,
              reason == .requested,
              case .trigger = session.source else { return }
        // A manual end must be durable. Otherwise the still-true criterion
        // would silently recreate the session on the next native event or
        // fallback poll. This mirrors Amphetamine's "disable Triggers and end"
        // behavior across the menu and hot keys. AppleScript has a distinct
        // end reason because Amphetamine's dictionary intentionally preserves
        // Triggers for its `end session` command.
        store.setEnabled(false)
        activeTriggerID = nil
    }
}
