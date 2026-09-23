import AppKit
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
    @ObservationIgnored private var wakeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var removingIDs: Set<UUID> = []
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []

    private(set) var isRunning = false
    private(set) var statuses: [UUID: DriveAliveTargetStatus] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var lastSucceededAt: [UUID: Date] = [:]
    private(set) var lastFailedAt: [UUID: Date] = [:]
    private(set) var lastFailureByTarget: [UUID: DriveAliveFailure] = [:]
    private(set) var wakingTargetIDs: Set<UUID> = []
    private(set) var reachableTargetIDs: Set<UUID> = []

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
        observeVolumeChanges()
    }

    var activeTargetCount: Int {
        statuses.reduce(into: 0) { count, entry in
            guard reachableTargetIDs.contains(entry.key) else { return }
            if case .healthy = entry.value { count += 1 }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observeStoreChanges()
        reconcileLoop()
        Task { @MainActor [weak self] in
            await self?.revalidateAll()
        }
    }

    func stop() {
        hasStarted = false
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
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
        reachableTargetIDs = reachableTargetIDs.intersection(configuredIDs)
        wakingTargetIDs = wakingTargetIDs.intersection(configuredIDs)
        removingIDs = removingIDs.intersection(configuredIDs)
        for id in Array(wakeTasks.keys) where !configuredIDs.contains(id) {
            wakeTasks.removeValue(forKey: id)
        }
        guard store.isEnabled else {
            // Disabled: no writes, but still report current reachability so the
            // UI never shows a stale “healthy” as currently connected.
            for target in targets {
                statuses[target.id] = .inactive
                do {
                    let resource = try resolver.resolve(target.bookmarkData)
                    defer { resource.close() }
                    try ensureDirectoryExists(resource.url)
                    reachableTargetIDs.insert(target.id)
                } catch {
                    let failure = failure(for: error)
                    if failure == .targetUnavailable || failure == .bookmarkInvalid || failure == .unsupportedTarget {
                        reachableTargetIDs.remove(target.id)
                    } else {
                        reachableTargetIDs.insert(target.id)
                    }
                }
            }
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
            // A removal holds removingIDs to block new work during cleanup.
            if removingIDs.contains(target.id) { continue }
            do {
                let resource = try resolver.resolve(target.bookmarkData)
                if let refreshed = resource.refreshedBookmarkData {
                    try? store.replaceBookmark(refreshed, id: target.id)
                }
                resolved.append((target, resource))
                reachableTargetIDs.insert(target.id)
                statuses[target.id] = .writing
            } catch {
                let failure = failure(for: error)
                let now = Date()
                statuses[target.id] = .failed(failure)
                lastFailedAt[target.id] = now
                lastFailureByTarget[target.id] = failure
                if failure == .targetUnavailable || failure == .bookmarkInvalid || failure == .unsupportedTarget {
                    reachableTargetIDs.remove(target.id)
                } else {
                    // Resolve threw a permission-style error but the volume still exists.
                    reachableTargetIDs.insert(target.id)
                }
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
            guard !removingIDs.contains(id) else { continue }
            switch result {
            case .success:
                let now = Date()
                statuses[id] = .healthy(now)
                lastSucceededAt[id] = now
                reachableTargetIDs.insert(id)
            case let .failure(error):
                let now = Date()
                statuses[id] = .failed(error)
                lastFailedAt[id] = now
                lastFailureByTarget[id] = error
                // Write-phase failures keep reachability when resolve had succeeded.
                reachableTargetIDs.insert(id)
            }
        }
    }

    /// Re-check whether a target is currently reachable without writing.
    /// Keeps lastSucceededAt as history; unreachable targets become failed
    /// so the UI never shows stale “healthy” as currently connected.
    func revalidate(targetID: UUID) async {
        guard let target = store.target(id: targetID) else { return }
        guard !removingIDs.contains(targetID) else { return }
        do {
            let resource = try resolver.resolve(target.bookmarkData)
            defer { resource.close() }
            try ensureDirectoryExists(resource.url)
            if let refreshed = resource.refreshedBookmarkData {
                try? store.replaceBookmark(refreshed, id: target.id)
            }
            reachableTargetIDs.insert(targetID)
            // If we previously marked it unreachable but it is back, drop the
            // stale unavailable status. Keep healthy/last-success history.
            if case let .failed(failure) = statuses[targetID],
               failure == .targetUnavailable || failure == .bookmarkInvalid || failure == .unsupportedTarget
            {
                statuses[targetID] = .inactive
            }
        } catch {
            let failure = failure(for: error)
            let now = Date()
            // Only treat resolve failures as connectivity loss.
            if failure == .targetUnavailable || failure == .bookmarkInvalid || failure == .unsupportedTarget {
                reachableTargetIDs.remove(targetID)
                // Never report stale healthy as currently connected.
                statuses[targetID] = .failed(failure)
                lastFailedAt[targetID] = now
                lastFailureByTarget[targetID] = failure
            } else {
                reachableTargetIDs.insert(targetID)
                statuses[targetID] = .failed(failure)
                lastFailedAt[targetID] = now
                lastFailureByTarget[targetID] = failure
            }
        }
    }

    func revalidateAll() async {
        for target in store.targets {
            // Serialize lightly: resolve is cheap, no writes here.
            await revalidate(targetID: target.id)
        }
    }

    /// One-time wake for a single target. Never starts the continuous loop.
    /// Works even when continuous mode is disabled so users can pre-warm a disk on demand.
    /// Serialized per target with removeTarget: deletion waits for an in-flight
    /// wake, and a deletion in progress blocks new wakes so no orphan marker remains.
    func wake(targetID: UUID) async {
        if removingIDs.contains(targetID) { return }
        if wakingTargetIDs.contains(targetID) { return }
        if wakeTasks[targetID] != nil { return }
        guard store.target(id: targetID) != nil else { return }
        wakingTargetIDs.insert(targetID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performWake(targetID: targetID)
        }
        wakeTasks[targetID] = task
        await task.value
        wakeTasks.removeValue(forKey: targetID)
        // performWake always clears its own waking flag via defer; this is a
        // safety net if the task was cancelled before it started.
        wakingTargetIDs.remove(targetID)
    }

    private func performWake(targetID: UUID) async {
        defer {
            // Only clear if no removal is holding the target; removal cleans up
            // after awaiting this task, and Set removal is idempotent.
            wakingTargetIDs.remove(targetID)
        }
        guard let target = store.target(id: targetID) else { return }
        if removingIDs.contains(targetID) { return }
        statuses[targetID] = .writing
        do {
            let resource = try resolver.resolve(target.bookmarkData)
            defer { resource.close() }
            if removingIDs.contains(targetID) { return }
            if let refreshed = resource.refreshedBookmarkData {
                try? store.replaceBookmark(refreshed, id: target.id)
            }
            try await writer.write(
                to: resource.url,
                timeout: POSIXDriveAliveWriter.defaultTimeout
            )
            guard store.target(id: targetID) != nil else { return }
            guard !removingIDs.contains(targetID) else { return }
            let now = Date()
            statuses[targetID] = .healthy(now)
            lastSucceededAt[targetID] = now
            reachableTargetIDs.insert(targetID)
        } catch let failure as DriveAliveFailure {
            guard store.target(id: targetID) != nil else { return }
            guard !removingIDs.contains(targetID) else { return }
            let now = Date()
            statuses[targetID] = .failed(failure)
            lastFailedAt[targetID] = now
            lastFailureByTarget[targetID] = failure
            updateReachabilityAfterResolveFailure(targetID: targetID, failure: failure)
        } catch is CancellationError {
            guard store.target(id: targetID) != nil else { return }
            guard !removingIDs.contains(targetID) else { return }
            let now = Date()
            statuses[targetID] = .failed(.timedOut)
            lastFailedAt[targetID] = now
            lastFailureByTarget[targetID] = .timedOut
            reachableTargetIDs.insert(targetID)
        } catch {
            guard store.target(id: targetID) != nil else { return }
            guard !removingIDs.contains(targetID) else { return }
            let failure = failure(for: error)
            let now = Date()
            statuses[targetID] = .failed(failure)
            lastFailedAt[targetID] = now
            lastFailureByTarget[targetID] = failure
            updateReachabilityAfterResolveFailure(targetID: targetID, failure: failure)
        }
    }

    private func updateReachabilityAfterResolveFailure(targetID: UUID, failure: DriveAliveFailure) {
        if failure == .targetUnavailable || failure == .bookmarkInvalid || failure == .unsupportedTarget {
            reachableTargetIDs.remove(targetID)
        } else {
            reachableTargetIDs.insert(targetID)
        }
    }

    func removeTarget(id: UUID) async throws {
        // Serialize with an in-flight wake: wait first, then hold the removal
        // gate so no new wake can slip in between cleanup and store removal.
        // Do NOT clear wakingTargetIDs prematurely; the wake task owns its flag.
        if let inFlight = wakeTasks[id] {
            await inFlight.value
        }
        if let refreshTask { await refreshTask.value }
        // A new wake may have queued while we waited; drain once more.
        if let retry = wakeTasks[id] {
            await retry.value
        }
        // If a wake somehow restarted (should be blocked by removingIDs below
        // on the next attempt), keep waiting instead of racing its write.
        removingIDs.insert(id)
        defer { removingIDs.remove(id) }
        // After holding the gate, re-check for a wake that slipped in just
        // before the gate was set.
        if let late = wakeTasks[id] {
            await late.value
        }
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
        reachableTargetIDs.remove(id)
        wakingTargetIDs.remove(id)
        wakeTasks.removeValue(forKey: id)
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
            isRunning = false
            let configuredIDs = Set(store.targets.map(\.id))
            statuses = statuses.filter { configuredIDs.contains($0.key) }
            for target in store.targets { statuses[target.id] = .inactive }
            return
        }
        guard loopTask == nil else {
            // Keep the observable flag in sync even when the task already exists.
            isRunning = true
            return
        }
        isRunning = true
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

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let mount = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.revalidateAll()
            }
        }
        let unmount = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.revalidateAll()
            }
        }
        workspaceObservers = [mount, unmount]
    }

    private var activeSessionIsRunning: Bool {
        sessions.isActive
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DriveAliveFailure.targetUnavailable
        }
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
