import Foundation
import Observation

@MainActor
@Observable
final class DriveAliveController {
    @ObservationIgnored private let store: DriveAliveStore
    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let resolver: any DriveAliveBookmarkResolving
    @ObservationIgnored private let writer: any DriveAliveWriting
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var hasStarted = false

    private(set) var statuses: [UUID: DriveAliveTargetStatus] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var lastSucceededAt: [UUID: Date] = [:]
    private(set) var lastFailedAt: [UUID: Date] = [:]
    private(set) var lastFailureByTarget: [UUID: DriveAliveFailure] = [:]
    private(set) var wakingTargetIDs: Set<UUID> = []

    init(
        store: DriveAliveStore,
        sessions: AwakeSessionController,
        resolver: any DriveAliveBookmarkResolving = SecurityScopedDriveAliveBookmarkResolver(),
        writer: any DriveAliveWriting = POSIXDriveAliveWriter()
    ) {
        self.store = store
        self.sessions = sessions
        self.resolver = resolver
        self.writer = writer
        observeSessionChanges()
    }

    var isRunning: Bool { loopTask != nil }

    var activeTargetCount: Int {
        statuses.values.reduce(into: 0) { count, status in
            if case .healthy = status { count += 1 }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observeStoreChanges()
        reconcileLoop()
    }

    func stop() {
        hasStarted = false
        loopTask?.cancel()
        loopTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        for target in store.targets { statuses[target.id] = .inactive }
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        if refreshGeneration == generation { refreshTask = nil }
    }

    private func performRefresh() async {
        let targets = store.targets
        let configuredIDs = Set(targets.map(\.id))
        for id in statuses.keys where !configuredIDs.contains(id) {
            statuses.removeValue(forKey: id)
        }
        for id in Array(lastSucceededAt.keys) where !configuredIDs.contains(id) {
            lastSucceededAt.removeValue(forKey: id)
        }
        for id in Array(lastFailedAt.keys) where !configuredIDs.contains(id) {
            lastFailedAt.removeValue(forKey: id)
        }
        for id in Array(lastFailureByTarget.keys) where !configuredIDs.contains(id) {
            lastFailureByTarget.removeValue(forKey: id)
        }
        wakingTargetIDs = wakingTargetIDs.intersection(configuredIDs)
        guard store.isEnabled else {
            for target in targets { statuses[target.id] = .inactive }
            return
        }

        let eligible = targets.filter { target in
            target.policy == .whileOpenFindRuns || activeSessionIsRunning
        }
        let eligibleIDs = Set(eligible.map(\.id))
        for target in targets where !eligibleIDs.contains(target.id) {
            statuses[target.id] = .inactive
        }

        var resolved: [(target: DriveAliveTarget, resource: DriveAliveResolvedResource)] = []
        for target in eligible {
            do {
                let resource = try resolver.resolve(target.bookmarkData)
                if let refreshed = resource.refreshedBookmarkData {
                    try? store.replaceBookmark(refreshed, id: target.id)
                }
                resolved.append((target, resource))
                statuses[target.id] = .writing
            } catch {
                let failure = failure(for: error)
                let now = Date()
                statuses[target.id] = .failed(failure)
                lastFailedAt[target.id] = now
                lastFailureByTarget[target.id] = failure
            }
        }

        guard !resolved.isEmpty else { return }
        let writer = self.writer
        let outcomes = await withTaskGroup(
            of: (UUID, Result<Void, DriveAliveFailure>).self,
            returning: [(UUID, Result<Void, DriveAliveFailure>)].self
        ) { group in
            for item in resolved {
                group.addTask {
                    defer { item.resource.close() }
                    do {
                        try await writer.write(
                            to: item.resource.url,
                            timeout: POSIXDriveAliveWriter.defaultTimeout
                        )
                        return (item.target.id, .success(()))
                    } catch let error as DriveAliveFailure {
                        return (item.target.id, .failure(error))
                    } catch is CancellationError {
                        return (item.target.id, .failure(.timedOut))
                    } catch {
                        return (item.target.id, .failure(.targetUnavailable))
                    }
                }
            }
            var results: [(UUID, Result<Void, DriveAliveFailure>)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard !Task.isCancelled else { return }
        guard store.isEnabled else { return }
        for (id, result) in outcomes {
            guard store.target(id: id) != nil else { continue }
            switch result {
            case .success:
                let now = Date()
                statuses[id] = .healthy(now)
                lastSucceededAt[id] = now
            case let .failure(error):
                let now = Date()
                statuses[id] = .failed(error)
                lastFailedAt[id] = now
                lastFailureByTarget[id] = error
            }
        }
    }

    /// One-time wake for a single target. Never starts the continuous loop.
    /// Works even when continuous mode is disabled so users can pre-warm a disk on demand.
    func wake(targetID: UUID) async {
        guard let target = store.target(id: targetID) else { return }
        guard !wakingTargetIDs.contains(targetID) else { return }
        wakingTargetIDs.insert(targetID)
        defer { wakingTargetIDs.remove(targetID) }
        statuses[targetID] = .writing
        do {
            let resource = try resolver.resolve(target.bookmarkData)
            defer { resource.close() }
            if let refreshed = resource.refreshedBookmarkData {
                try? store.replaceBookmark(refreshed, id: target.id)
            }
            try await writer.write(
                to: resource.url,
                timeout: POSIXDriveAliveWriter.defaultTimeout
            )
            guard store.target(id: targetID) != nil else { return }
            let now = Date()
            statuses[targetID] = .healthy(now)
            lastSucceededAt[targetID] = now
        } catch let failure as DriveAliveFailure {
            guard store.target(id: targetID) != nil else { return }
            let now = Date()
            statuses[targetID] = .failed(failure)
            lastFailedAt[targetID] = now
            lastFailureByTarget[targetID] = failure
        } catch is CancellationError {
            guard store.target(id: targetID) != nil else { return }
            let now = Date()
            statuses[targetID] = .failed(.timedOut)
            lastFailedAt[targetID] = now
            lastFailureByTarget[targetID] = .timedOut
        } catch {
            guard store.target(id: targetID) != nil else { return }
            let failure = failure(for: error)
            let now = Date()
            statuses[targetID] = .failed(failure)
            lastFailedAt[targetID] = now
            lastFailureByTarget[targetID] = failure
        }
    }

    func removeTarget(id: UUID) async throws {
        if let refreshTask { await refreshTask.value }
        guard let target = store.target(id: id) else {
            throw DriveAliveStoreError.targetNotFound
        }
        var cleanupFailure: DriveAliveFailure?
        do {
            let resource = try resolver.resolve(target.bookmarkData)
            defer { resource.close() }
            try await writer.removeMarker(
                from: resource.url,
                timeout: POSIXDriveAliveWriter.defaultTimeout
            )
        } catch {
            // A disconnected/read-only target must never become impossible to
            // remove from configuration. Preserve the cleanup diagnostic, but
            // remove the saved bookmark so Drive Alive stops retrying it.
            cleanupFailure = failure(for: error)
        }
        _ = try store.remove(id: id)
        statuses.removeValue(forKey: id)
        lastSucceededAt.removeValue(forKey: id)
        lastFailedAt.removeValue(forKey: id)
        lastFailureByTarget.removeValue(forKey: id)
        wakingTargetIDs.remove(id)
        lastErrorMessage = cleanupFailure?.localizedDescription
        reconcileLoop()
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func observeSessionChanges() {
        withObservationTracking {
            _ = sessions.activeSession
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRunning { await self.refresh() }
                self.observeSessionChanges()
            }
        }
    }

    private func observeStoreChanges() {
        guard hasStarted else { return }
        withObservationTracking {
            _ = store.isEnabled
            _ = store.interval
            _ = store.targets
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted else { return }
                self.reconcileLoop()
                self.observeStoreChanges()
            }
        }
    }

    private func reconcileLoop() {
        guard hasStarted,
              store.isEnabled,
              !store.targets.isEmpty else {
            refreshGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            loopTask?.cancel()
            loopTask = nil
            let configuredIDs = Set(store.targets.map(\.id))
            statuses = statuses.filter { configuredIDs.contains($0.key) }
            for target in store.targets { statuses[target.id] = .inactive }
            return
        }
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                do {
                    try await Task.sleep(for: .seconds(self.store.interval))
                } catch {
                    break
                }
            }
        }
    }

    private var activeSessionIsRunning: Bool {
        sessions.isActive
    }

    private func failure(for error: Error) -> DriveAliveFailure {
        if let failure = error as? DriveAliveFailure { return failure }
        if error is DriveAliveStoreError { return .bookmarkInvalid }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .permissionDenied
            case .fileWriteVolumeReadOnly:
                return .readOnly
            default:
                return .targetUnavailable
            }
        }
        return .targetUnavailable
    }
}
