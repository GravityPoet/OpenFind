import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DriveAliveController {
    private struct WriteOperation {
        let token: UUID
        let continuous: Bool
        let task: Task<Void, Never>
    }

    @ObservationIgnored private let store: DriveAliveStore
    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let resolver: any DriveAliveBookmarkResolving
    @ObservationIgnored private let writer: any DriveAliveWriting
    @ObservationIgnored private let accessChecker: any DriveAliveAccessChecking
    @ObservationIgnored private let workspaceCenter: NotificationCenter
    @ObservationIgnored private let resolverExecutor = DriveAliveIOExecutor()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = UUID()
    @ObservationIgnored private var writeTasks: [UUID: WriteOperation] = [:]
    @ObservationIgnored private var inspectionTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var observationGeneration = UUID()
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var hasStarted = false

    private(set) var isRunning = false
    private(set) var statuses: [UUID: DriveAliveTargetStatus] = [:]
    private(set) var accessStates: [UUID: DriveAliveAccess] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var lastSucceededAt: [UUID: Date] = [:]
    private(set) var lastFailedAt: [UUID: Date] = [:]
    private(set) var lastFailureByTarget: [UUID: DriveAliveFailure] = [:]
    private(set) var wakingTargetIDs: Set<UUID> = []
    private(set) var removingTargetIDs: Set<UUID> = []

    init(
        store: DriveAliveStore,
        sessions: AwakeSessionController,
        resolver: any DriveAliveBookmarkResolving = SecurityScopedDriveAliveBookmarkResolver(),
        writer: any DriveAliveWriting = POSIXDriveAliveWriter(),
        accessChecker: (any DriveAliveAccessChecking)? = nil,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.store = store
        self.sessions = sessions
        self.resolver = resolver
        self.writer = writer
        self.accessChecker = accessChecker ?? FileSystemDriveAliveAccessChecker(resolver: resolver)
        self.workspaceCenter = workspaceCenter
    }

    var reachableTargetIDs: Set<UUID> {
        let configuredIDs = Set(store.targets.map(\.id))
        return Set(accessStates.compactMap {
            configuredIDs.contains($0.key) && $0.value.isReachable ? $0.key : nil
        })
    }

    func canWake(targetID: UUID) -> Bool {
        guard store.target(id: targetID) != nil,
              !wakingTargetIDs.contains(targetID),
              !removingTargetIDs.contains(targetID)
        else { return false }
        switch accessStates[targetID] {
        case .readOnly, .permissionDenied, .unavailable, .checking:
            return false
        case .unknown, .writable, nil:
            return true
        }
    }

    var activeTargetCount: Int {
        let configuredIDs = Set(store.targets.map(\.id))
        return statuses.filter { id, state in
            guard configuredIDs.contains(id) else { return false }
            if case .healthy = state { return accessStates[id]?.isReachable == true }
            return false
        }.count
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observationGeneration = UUID()
        observePreferences(generation: observationGeneration)
        observeVolumeChanges()
        reconcileLoop()
        Task { @MainActor [weak self] in await self?.refreshStatus() }
    }

    func stop() {
        hasStarted = false
        observationGeneration = UUID()
        cancelContinuousWork()
        for operation in writeTasks.values { operation.task.cancel() }
        for operation in inspectionTasks.values { operation.task.cancel() }
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        for target in store.targets { statuses[target.id] = .inactive }
    }

    /// Continuous mode's write tick. UI status refreshes use refreshStatus().
    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let token = UUID()
        refreshToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.store.isEnabled {
                await self.refreshStatus()
                return
            }
            for target in self.store.targets {
                guard !Task.isCancelled else { return }
                if self.isEligible(target) {
                    await self.writeTarget(id: target.id, continuous: true)
                } else {
                    await self.revalidate(targetID: target.id)
                }
            }
        }
        refreshTask = task
        await task.value
        if refreshToken == token { refreshTask = nil }
    }

    /// Read-only metadata check; never creates or updates a marker.
    func refreshStatus() async {
        for target in store.targets {
            guard !Task.isCancelled else { return }
            await revalidate(targetID: target.id)
        }
    }

    func revalidateAll() async { await refreshStatus() }

    func revalidate(targetID: UUID) async {
        guard !removingTargetIDs.contains(targetID), !Task.isCancelled else { return }
        if let write = writeTasks[targetID] { await write.task.value }
        guard let target = store.target(id: targetID), !removingTargetIDs.contains(targetID),
              !Task.isCancelled else { return }
        if let existing = inspectionTasks[targetID] { await existing.task.value; return }
        let token = UUID()
        let checker = accessChecker
        if statuses[targetID] == nil {
            statuses[targetID] = .inactive
        }
        accessStates[targetID] = .checking
        let task = Task { @MainActor [weak self] in
            let result = await checker.inspect(target)
            guard let self, !Task.isCancelled, self.store.target(id: targetID) != nil,
                  !self.removingTargetIDs.contains(targetID), self.writeTasks[targetID] == nil,
                  self.inspectionTasks[targetID]?.token == token else { return }
            if let bookmark = result.refreshedBookmarkData {
                try? self.store.replaceBookmark(bookmark, id: targetID)
            }
            self.accessStates[targetID] = result.access
            if let failure = result.access.failure {
                self.recordFailure(failure, id: targetID)
            } else if result.access == .unknown {
                self.statuses[targetID] = .inactive
            } else if case let .failed(failure) = self.statuses[targetID],
                      [.targetUnavailable, .bookmarkInvalid, .readOnly, .permissionDenied].contains(failure) {
                self.statuses[targetID] = .inactive
            }
        }
        inspectionTasks[targetID] = (token, task)
        await task.value
        if inspectionTasks[targetID]?.token == token { inspectionTasks.removeValue(forKey: targetID) }
    }

    func wake(targetID: UUID) async { await writeTarget(id: targetID, continuous: false) }

    private func writeTarget(id: UUID, continuous: Bool) async {
        guard !Task.isCancelled, !removingTargetIDs.contains(id), let target = store.target(id: id) else { return }
        if continuous && (!store.isEnabled || !isEligible(target)) { return }
        // Coalesce manual and timer requests for this target instead of racing the writer.
        if let existing = writeTasks[id] { await existing.task.value; return }
        inspectionTasks.removeValue(forKey: id)?.task.cancel()
        let token = UUID()
        wakingTargetIDs.insert(id)
        statuses[id] = .writing
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishWrite(id: id, token: token) }
            do {
                let resource = try await self.resolve(target)
                defer { resource.close() }
                try Task.checkCancellation()
                guard !self.removingTargetIDs.contains(id) else { return }
                guard let currentTarget = self.store.target(id: id) else { return }
                if continuous && (!self.store.isEnabled || !self.isEligible(currentTarget)) { return }
                if let bookmark = resource.refreshedBookmarkData {
                    try? self.store.replaceBookmark(bookmark, id: id)
                }
                // Resolution succeeded, so the location is connected. The
                // writer still determines whether it is writable or whether
                // a marker conflict or other write failure should be shown.
                self.accessStates[id] = .writable
                try await self.writer.write(to: resource.url, timeout: POSIXDriveAliveWriter.defaultTimeout)
                try Task.checkCancellation()
                guard self.store.target(id: id) != nil, !self.removingTargetIDs.contains(id) else { return }
                let now = Date()
                self.statuses[id] = .healthy(now)
                self.lastSucceededAt[id] = now
                self.accessStates[id] = .writable
            } catch is CancellationError {
                if self.store.target(id: id) != nil { self.statuses[id] = .inactive }
            } catch {
                guard !Task.isCancelled, self.store.target(id: id) != nil,
                      !self.removingTargetIDs.contains(id) else { return }
                self.recordFailure(DriveAliveFailure.from(error), id: id)
            }
        }
        writeTasks[id] = WriteOperation(token: token, continuous: continuous, task: task)
        await task.value
        finishWrite(id: id, token: token)
    }

    func removeTarget(id: UUID) async throws {
        guard !removingTargetIDs.contains(id) else { return }
        guard let target = store.target(id: id) else { throw DriveAliveStoreError.targetNotFound }
        // Set the gate before waiting so neither a timer nor another click can queue new work.
        removingTargetIDs.insert(id)
        defer { removingTargetIDs.remove(id) }
        inspectionTasks.removeValue(forKey: id)?.task.cancel()
        if let write = writeTasks[id] { await write.task.value }
        var cleanupFailure: DriveAliveFailure?
        do {
            let resource = try await resolve(target)
            defer { resource.close() }
            try await writer.removeMarker(from: resource.url, timeout: POSIXDriveAliveWriter.defaultTimeout)
        } catch {
            let failure = DriveAliveFailure.from(error)
            if failure == .timedOut || failure == .writeAlreadyPending {
                // A syscall may still be in flight. Keep the target so cleanup can be retried.
                lastErrorMessage = L("Disk Cleanup Pending")
                throw failure
            }
            cleanupFailure = failure
        }
        _ = try store.remove(id: id)
        statuses.removeValue(forKey: id)
        accessStates.removeValue(forKey: id)
        lastSucceededAt.removeValue(forKey: id)
        lastFailedAt.removeValue(forKey: id)
        lastFailureByTarget.removeValue(forKey: id)
        wakingTargetIDs.remove(id)
        writeTasks.removeValue(forKey: id)
        lastErrorMessage = cleanupFailure?.localizedDescription
        reconcileLoop()
    }

    func clearError() { lastErrorMessage = nil }

    private func resolve(_ target: DriveAliveTarget) async throws -> DriveAliveResolvedResource {
        let resolver = self.resolver
        return try await resolverExecutor.run(
            key: target.id.uuidString,
            timeout: .seconds(10),
            waitForPending: true
        ) { _ in
            try resolver.resolve(target.bookmarkData)
        }
    }

    private func recordFailure(_ failure: DriveAliveFailure, id: UUID) {
        statuses[id] = .failed(failure)
        lastFailedAt[id] = Date()
        lastFailureByTarget[id] = failure
        switch failure {
        case .targetUnavailable, .bookmarkInvalid, .unsupportedTarget: accessStates[id] = .unavailable
        case .readOnly: accessStates[id] = .readOnly
        case .permissionDenied: accessStates[id] = .permissionDenied
        case .timedOut, .writeAlreadyPending, .ioFailure: accessStates[id] = .unknown
        case .markerConflict: break
        }
    }

    private func finishWrite(id: UUID, token: UUID) {
        guard writeTasks[id]?.token == token else { return }
        writeTasks.removeValue(forKey: id)
        wakingTargetIDs.remove(id)
    }

    private func isEligible(_ target: DriveAliveTarget) -> Bool {
        target.policy == .whileOpenFindRuns || sessions.isActive
    }

    private func observePreferences(generation: UUID) {
        withObservationTracking {
            _ = store.isEnabled
            _ = store.interval
            _ = store.targets
            _ = sessions.activeSession
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted, self.observationGeneration == generation else { return }
                self.observePreferences(generation: generation)
                self.reconcileLoop()
                await self.refreshStatus()
                if self.store.isEnabled {
                    await self.refresh()
                }
            }
        }
    }

    private func cancelContinuousWork() {
        loopTask?.cancel()
        loopTask = nil
        refreshToken = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRunning = false
        for (id, operation) in writeTasks where operation.continuous {
            operation.task.cancel()
            statuses[id] = .inactive
        }
    }

    private func reconcileLoop() {
        guard hasStarted, store.isEnabled, !store.targets.isEmpty else {
            cancelContinuousWork()
            let configuredIDs = Set(store.targets.map(\.id))
            statuses = statuses.filter { configuredIDs.contains($0.key) }
            accessStates = accessStates.filter { configuredIDs.contains($0.key) }
            for target in store.targets { statuses[target.id] = .inactive }
            return
        }
        for (id, operation) in writeTasks where operation.continuous {
            if let target = store.target(id: id), !isEligible(target) { operation.task.cancel() }
        }
        guard loopTask == nil else { return }
        isRunning = true
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(self.store.interval)) } catch { return }
            }
        }
    }

    private func observeVolumeChanges() {
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.hasStarted else { return }
                    await self.refreshStatus()
                }
            })
        }
    }
}
