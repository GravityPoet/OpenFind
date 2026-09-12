import Foundation
import Observation

@MainActor
@Observable
final class ConfigurationSyncController {
    let transfer: ConfigurationTransferStore
    let defaults: UserDefaults
    private(set) var folder: URL?
    private(set) var isBusy = false
    var message: String?
    var hasConflict = false
    var lastSync: Date?
    var hasRecovery: Bool { FileManager.default.fileExists(atPath: transfer.recoveryURL.path) }
    var baseline: ConfigurationArchive?
    private var remoteBaseline: ConfigurationArchive?
    private var remoteVersion: [String: Int] = [:]
    var conflictData: Data?
    var conflictLocal: ConfigurationArchive?
    private var accessURL: URL?
    private var task: Task<Void, Never>?
    private let bookmarkKey = "OpenFind.configurationSync.folderV1"
    var baselineURL: URL { transfer.recoveryURL.deletingLastPathComponent().appendingPathComponent("sync-baseline.json") }
    var syncURL: URL? { folder?.appendingPathComponent("OpenFind-Configuration.json") }

    init(transfer: ConfigurationTransferStore, defaults: UserDefaults) {
        self.transfer = transfer
        self.defaults = defaults
    }

    func start() {
        guard task == nil else { return }
        if folder == nil, let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { accessURL = url }
                folder = url
                if stale { defaults.set(try url.bookmarkData(options: [.withSecurityScope]), forKey: bookmarkKey) }
            } catch { message = L("Configuration Folder Unavailable") }
        }
        guard folder != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronize()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    func setBusy(_ value: Bool) { isBusy = value }

    func disconnect() {
        guard !isBusy else { return }
        stop()
        accessURL?.stopAccessingSecurityScopedResource()
        accessURL = nil
        folder = nil
        baseline = nil
        remoteBaseline = nil
        remoteVersion = [:]
        conflictData = nil
        conflictLocal = nil
        hasConflict = false
        defaults.removeObject(forKey: bookmarkKey)
        message = L("Configuration Sync Disconnected")
    }

    func connect(_ url: URL) async {
        guard !isBusy else { return }
        disconnect()
        isBusy = true
        defer { isBusy = false }
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ConfigurationError.missingFile
            }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope])
            if url.startAccessingSecurityScopedResource() { accessURL = url }
            folder = url
            defaults.set(bookmark, forKey: bookmarkKey)
            try FileManager.default.createDirectory(at: baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            baseline = nil
            try await synchronizeCore()
            start()
        } catch { message = error.localizedDescription; start() }
    }

    func synchronize() async {
        guard !isBusy, !hasConflict, syncURL != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await synchronizeCore() }
        catch { message = error.localizedDescription }
    }

    private func synchronizeCore() async throws {
        guard let url = syncURL else { return }
        let local = try transfer.snapshot()
        if baseline == nil, let data = try await ConfigurationFile.read(baselineURL), !data.isEmpty {
            let state = try JSONDecoder().decode(ConfigurationSyncBaseline.self, from: data)
            if state.folderPath == folder?.standardizedFileURL.path {
                baseline = state.local
                remoteBaseline = state.remote
                remoteVersion = state.version
            }
        }
        let data = try await ConfigurationFile.read(url)
        guard !Task.isCancelled else { return }
        guard try transfer.snapshot() == local else { throw ConfigurationError.conflict }
        if let data {
            let document = try ConfigurationSyncDocument.decode(data)
            let remote = document.archive
            _ = try transfer.validate(remote)
            if remote == local { try await recordBaseline(local, version: document.version); return }
            if local == baseline, remote == remoteBaseline, document.includes(remoteVersion) {
                message = L("Configuration Up To Date")
                return
            }
            if remote == remoteBaseline, document.includes(remoteVersion) {
                let outgoing = makeDocument(local, merging: document.version)
                try await ConfigurationFile.write(outgoing.encoded(), to: url, replacing: data)
                try await recordBaseline(local, version: outgoing.version)
            } else if let baseline, local == baseline, document.includes(remoteVersion) {
                try await transfer.apply(remote)
                try await recordBaseline(transfer.snapshot(), remote: remote, version: document.version)
            } else {
                conflictData = data
                conflictLocal = local
                hasConflict = true
                message = L("Configuration Conflict")
            }
        } else {
            // Never recreate a deleted/offline shared file once connected.
            guard baseline == nil else { throw ConfigurationError.missingFile }
            let outgoing = makeDocument(local, merging: [:])
            try await ConfigurationFile.write(outgoing.encoded(), to: url, replacing: nil)
            try await recordBaseline(local, version: outgoing.version)
        }
    }

    func recordBaseline(_ archive: ConfigurationArchive, remote: ConfigurationArchive? = nil,
                        version: [String: Int]) async throws {
        try FileManager.default.createDirectory(at: baselineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = try await ConfigurationFile.read(baselineURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ConfigurationSyncBaseline(
            folderPath: folder?.standardizedFileURL.path ?? "", local: archive, remote: remote ?? archive, version: version
        ))
        if data != previous { try await ConfigurationFile.write(data, to: baselineURL, replacing: previous) }
        baseline = archive
        remoteBaseline = remote ?? archive
        remoteVersion = version
        lastSync = Date()
        message = L("Configuration Up To Date")
    }

    func resolveConflict(useLocal: Bool) async {
        guard !isBusy, let url = syncURL, let expected = conflictData, let local = conflictLocal else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard try await ConfigurationFile.read(url) == expected,
                  try transfer.snapshot() == local else { throw ConfigurationError.conflict }
            let document = try ConfigurationSyncDocument.decode(expected)
            let chosen = useLocal ? local : document.archive
            let outgoing = makeDocument(chosen, merging: document.version)
            if useLocal {
                let saved = url.deletingLastPathComponent().appendingPathComponent("OpenFind-Conflict-\(UUID()).json")
                try await ConfigurationFile.write(expected, to: saved, replacing: nil)
                try await ConfigurationFile.write(outgoing.encoded(), to: url, replacing: expected)
            } else {
                try await transfer.apply(document.archive)
                try await ConfigurationFile.write(outgoing.encoded(), to: url, replacing: expected)
            }
            let applied = useLocal ? local : try transfer.snapshot()
            try await recordBaseline(applied, remote: chosen, version: outgoing.version)
            hasConflict = false
            conflictData = nil
            conflictLocal = nil
        } catch {
            hasConflict = false // reread both sides before offering a new decision
            message = error.localizedDescription
        }
    }

    private func makeDocument(_ archive: ConfigurationArchive, merging version: [String: Int]) -> ConfigurationSyncDocument {
        let key = "OpenFind.configurationSync.deviceV1"
        let device = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(device, forKey: key)
        var combined = remoteVersion.merging(version, uniquingKeysWith: max)
        combined[device] = (combined[device] ?? 0) + 1
        return ConfigurationSyncDocument(archive: archive, version: combined)
    }
}
