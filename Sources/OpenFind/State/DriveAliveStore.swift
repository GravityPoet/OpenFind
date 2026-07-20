import Foundation
import Observation

@MainActor
@Observable
final class DriveAliveStore {
    static let defaultInterval: TimeInterval = 10
    static let minimumInterval: TimeInterval = 1
    static let maximumInterval: TimeInterval = 3_600
    static let maximumTargetCount = 64

    private static let enabledKey = "OpenFind.driveAliveEnabledV1"
    private static let intervalKey = "OpenFind.driveAliveIntervalV1"
    private static let targetsKey = "OpenFind.driveAliveTargetsV1"
    private static let maximumBookmarkSize = 512 * 1_024
    private static let maximumDataSize = 4 * 1_024 * 1_024

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let resolver: any DriveAliveBookmarkResolving

    private(set) var isEnabled: Bool
    private(set) var interval: TimeInterval
    private(set) var targets: [DriveAliveTarget]
    private(set) var loadErrorMessage: String?

    init(
        defaults: UserDefaults = .standard,
        resolver: any DriveAliveBookmarkResolving = SecurityScopedDriveAliveBookmarkResolver()
    ) {
        self.defaults = defaults
        self.resolver = resolver
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        let storedInterval = defaults.object(forKey: Self.intervalKey) as? NSNumber
        interval = Self.validInterval(storedInterval?.doubleValue) ?? Self.defaultInterval
        let loaded = Self.loadTargets(from: defaults)
        targets = loaded.targets
        loadErrorMessage = loaded.errorMessage
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func setInterval(_ value: TimeInterval) throws {
        guard let normalized = Self.validInterval(value) else {
            throw DriveAliveStoreError.invalidInterval
        }
        interval = normalized
        defaults.set(normalized, forKey: Self.intervalKey)
    }

    @discardableResult
    func add(
        directoryURL: URL,
        policy: DriveAlivePolicy = .duringAwakeSession
    ) throws -> UUID {
        guard targets.count < Self.maximumTargetCount,
              directoryURL.isFileURL else {
            throw directoryURL.isFileURL
                ? DriveAliveStoreError.targetLimitReached
                : DriveAliveStoreError.invalidTarget
        }
        let normalizedURL = directoryURL.standardizedFileURL
        guard (try? normalizedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw DriveAliveStoreError.invalidTarget
        }
        let bookmark: Data
        do {
            bookmark = try resolver.bookmarkData(for: normalizedURL)
        } catch let error as DriveAliveStoreError {
            throw error
        } catch {
            throw DriveAliveStoreError.invalidTarget
        }
        guard !bookmark.isEmpty else { throw DriveAliveStoreError.invalidTarget }
        guard bookmark.count <= Self.maximumBookmarkSize else {
            throw DriveAliveStoreError.bookmarkTooLarge
        }

        for target in targets {
            guard let resource = try? resolver.resolve(target.bookmarkData) else { continue }
            defer { resource.close() }
            if resource.url.standardizedFileURL == normalizedURL {
                throw DriveAliveStoreError.duplicateTarget
            }
        }

        let target = DriveAliveTarget(
            displayName: displayName(for: normalizedURL),
            bookmarkData: bookmark,
            policy: policy
        )
        targets.append(target)
        do {
            try persist()
        } catch {
            targets.removeLast()
            throw error
        }
        return target.id
    }

    @discardableResult
    func remove(id: UUID) throws -> DriveAliveTarget {
        guard let index = targets.firstIndex(where: { $0.id == id }) else {
            throw DriveAliveStoreError.targetNotFound
        }
        let removed = targets.remove(at: index)
        do {
            try persist()
        } catch {
            targets.insert(removed, at: index)
            throw error
        }
        return removed
    }

    func setPolicy(_ policy: DriveAlivePolicy, id: UUID) throws {
        guard let index = targets.firstIndex(where: { $0.id == id }) else {
            throw DriveAliveStoreError.targetNotFound
        }
        let previous = targets[index].policy
        targets[index].policy = policy
        do {
            try persist()
        } catch {
            targets[index].policy = previous
            throw error
        }
    }

    func replaceBookmark(_ bookmarkData: Data, id: UUID) throws {
        guard bookmarkData.count <= Self.maximumBookmarkSize, !bookmarkData.isEmpty else {
            throw DriveAliveStoreError.bookmarkTooLarge
        }
        guard let index = targets.firstIndex(where: { $0.id == id }) else {
            throw DriveAliveStoreError.targetNotFound
        }
        let previous = targets[index].bookmarkData
        targets[index].bookmarkData = bookmarkData
        do {
            try persist()
        } catch {
            targets[index].bookmarkData = previous
            throw error
        }
    }

    func clearLoadError() {
        loadErrorMessage = nil
    }

    func target(id: UUID) -> DriveAliveTarget? {
        targets.first { $0.id == id }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(targets)
        guard data.count <= Self.maximumDataSize else {
            throw DriveAliveStoreError.dataTooLarge
        }
        defaults.set(data, forKey: Self.targetsKey)
    }

    private func displayName(for url: URL) -> String {
        let raw = url.lastPathComponent.isEmpty ? "Drive" : url.lastPathComponent
        let sanitized = raw
            .filter { !$0.isNewline && !CharacterSet.controlCharacters.contains($0.unicodeScalars.first!) }
        return String(sanitized.prefix(128)).isEmpty ? "Drive" : String(sanitized.prefix(128))
    }

    private static func validInterval(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, (minimumInterval...maximumInterval).contains(value) else {
            return nil
        }
        return value
    }

    private static func loadTargets(
        from defaults: UserDefaults
    ) -> (targets: [DriveAliveTarget], errorMessage: String?) {
        guard let data = defaults.data(forKey: targetsKey) else { return ([], nil) }
        guard data.count <= maximumDataSize,
              let decoded = try? JSONDecoder().decode([DriveAliveTarget].self, from: data) else {
            return ([], "Saved Drive Alive data could not be read and was left untouched.")
        }
        var valid: [DriveAliveTarget] = []
        var bookmarkSet: Set<Data> = []
        for target in decoded.prefix(maximumTargetCount) {
            let name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.count <= 128,
                  !target.bookmarkData.isEmpty,
                  target.bookmarkData.count <= maximumBookmarkSize,
                  bookmarkSet.insert(target.bookmarkData).inserted else { continue }
            var normalized = target
            normalized.displayName = String(name.prefix(128))
            valid.append(normalized)
        }
        let dropped = decoded.count - valid.count
        return dropped == 0
            ? (valid, nil)
            : (valid, "Some saved Drive Alive targets were invalid and were skipped.")
    }
}
