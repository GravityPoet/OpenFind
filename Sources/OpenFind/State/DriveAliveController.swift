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

    private(set) var statuses: [UUID: DriveAliveTargetStatus] = [:]
    private(set) var lastErrorMessage: String?

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

    func stop() {
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
                statuses[target.id] = .failed(failure(for: error))
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
        for (id, result) in outcomes {
            switch result {
            case .success:
                statuses[id] = .healthy(Date())
            case let .failure(error):
                statuses[id] = .failed(error)
            }
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
        lastErrorMessage = cleanupFailure?.localizedDescription
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
