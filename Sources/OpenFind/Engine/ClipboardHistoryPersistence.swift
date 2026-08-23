import CryptoKit
import Darwin
import Foundation
import Security

protocol ClipboardHistoryPersisting: AnyObject {
    var requiresExplicitMigration: Bool { get }
    /// True only for a populated v3 database that can finish a previously
    /// interrupted key migration without waiting for a user confirmation.
    /// Empty containers intentionally remain on the explicit-migration path so
    /// stale legacy ciphertext can never resurrect a history the user cleared.
    var hasRecoverableDatabase: Bool { get }
    var unloadedPayloadEntryIDs: Set<UUID> { get }
    func load() throws -> [ClipboardEntry]
    func loadResidentHistory() throws -> [ClipboardEntry]
    func loadEntry(id: UUID) throws -> ClipboardEntry?
    func save(_ entries: [ClipboardEntry]) throws
    func save(
        _ entries: [ClipboardEntry],
        preservingPayloadsFor entryIDs: Set<UUID>
    ) throws
    func remove() throws
}

extension ClipboardHistoryPersisting {
    var requiresExplicitMigration: Bool { false }
    var hasRecoverableDatabase: Bool { false }
    var unloadedPayloadEntryIDs: Set<UUID> { [] }

    func loadResidentHistory() throws -> [ClipboardEntry] { try load() }

    func loadEntry(id: UUID) throws -> ClipboardEntry? {
        try load().first { $0.id == id }
    }

    func save(
        _ entries: [ClipboardEntry],
        preservingPayloadsFor entryIDs: Set<UUID>
    ) throws {
        guard !entryIDs.isEmpty else {
            try save(entries)
            return
        }
        let storedByID = Dictionary(uniqueKeysWithValues: try load().map { ($0.id, $0) })
        let merged = try entries.map { entry in
            guard entryIDs.contains(entry.id), let stored = storedByID[entry.id] else {
                return entry
            }
            return try entry.restoringPayload(from: stored)
        }
        try save(merged)
    }
}

protocol ClipboardHistoryKeychainAccessing: AnyObject {
    func read() throws -> Data?
    func store(_ data: Data) throws
    func remove() throws
}

final class SystemClipboardHistoryKeychain: ClipboardHistoryKeychainAccessing {
    private static let service = "com.openfind.clipboard-history-key-v2"
    private static let account = "history-key-v2"

    func read() throws -> Data? {
        let query = baseQuery().merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        return data
    }

    func store(_ data: Data) throws {
        guard data.count == 32 else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        let status = SecItemAdd(baseQuery().merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem,
           try read() != nil {
            return
        }
        guard status == errSecSuccess else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

final class EncryptedClipboardHistoryPersistence: ClipboardHistoryPersisting {
    static let ciphertextKey = "OpenFind.clipboardEncryptedHistoryV2"
    private static let maximumLegacyEncodedSize = 80 * 1_024 * 1_024
    private static let keyByteCount = 32
    private let defaults: UserDefaults
    private let keyFileURL: URL
    private let database: EncryptedClipboardHistoryDatabase
    private let keychain: any ClipboardHistoryKeychainAccessing
    private let usesStableKeychainIdentity: Bool
    private var savedMetadataFingerprintByID: [UUID: Data] = [:]
    private var hasLoadedHistory = false
    private(set) var unloadedPayloadEntryIDs: Set<UUID> = []

    init(
        defaults: UserDefaults = .standard,
        keyFileURL: URL = EncryptedClipboardHistoryPersistence.defaultKeyFileURL,
        databaseURL: URL? = nil,
        keychain: any ClipboardHistoryKeychainAccessing = SystemClipboardHistoryKeychain(),
        signingTeamIdentifier: String? = CodeSigningIdentity.teamIdentifier(at: Bundle.main.bundleURL)
    ) {
        self.defaults = defaults
        self.keyFileURL = keyFileURL
        database = EncryptedClipboardHistoryDatabase(
            url: databaseURL ?? keyFileURL.deletingLastPathComponent()
                .appendingPathComponent("clipboard-history-v3.sqlite3")
        )
        self.keychain = keychain
        usesStableKeychainIdentity = signingTeamIdentifier?.isEmpty == false
    }

    var requiresExplicitMigration: Bool {
        !usesStableKeychainIdentity
            && defaults.data(forKey: Self.ciphertextKey) != nil
            && !localKeyPathExists
    }

    var hasRecoverableDatabase: Bool {
        guard database.exists else { return false }
        return (try? database.storedEntryCount()).map { $0 > 0 } ?? false
    }

    func load() throws -> [ClipboardEntry] {
        let resident = try loadResidentHistory()
        guard !unloadedPayloadEntryIDs.isEmpty else { return resident }
        let keyData = try keyDataForUse()
        var storedByID: [UUID: ClipboardEntry] = [:]
        storedByID.reserveCapacity(resident.count)
        try database.forEachRecord { id, encrypted in
            let data = try open(
                encrypted,
                keyData: keyData,
                context: "entry:\(id.uuidString)"
            )
            let stored = try JSONDecoder().decode(ClipboardEntry.self, from: data)
                .synchronizingPayloadDescriptor()
            guard stored.id == id else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            storedByID[id] = stored
        }
        return try resident.map { entry in
            guard unloadedPayloadEntryIDs.contains(entry.id),
                  let stored = storedByID[entry.id] else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            return try entry.restoringPayload(from: stored)
        }
    }

    func loadResidentHistory() throws -> [ClipboardEntry] {
        if database.exists {
            return try loadDatabase()
        }
        guard let encrypted = defaults.data(forKey: Self.ciphertextKey) else {
            savedMetadataFingerprintByID = [:]
            unloadedPayloadEntryIDs = []
            hasLoadedHistory = true
            return []
        }
        return try migrateLegacyHistory(encrypted)
    }

    func save(_ entries: [ClipboardEntry]) throws {
        try save(entries, preservingPayloadsFor: [])
    }

    func save(
        _ entries: [ClipboardEntry],
        preservingPayloadsFor entryIDs: Set<UUID>
    ) throws {
        guard !requiresExplicitMigration else {
            // Never replace legacy ciphertext with a newly generated key while
            // its original Keychain key is still waiting to be migrated.
            throw ClipboardHistoryError.persistenceUnavailable
        }
        if !database.exists, defaults.data(forKey: Self.ciphertextKey) != nil {
            _ = try load()
        }
        // Safety valve against history wipe-out: `saveToDatabase` deletes
        // every stored row absent from `entries`. If this session has never
        // successfully read the store while rows exist on disk, writing now would
        // permanently destroy them all — a startup hiccup must degrade to
        // read-only, never to deletion.
        if !hasLoadedHistory, try database.storedEntryCount() > 0 {
            throw ClipboardHistoryError.persistenceDesynchronized
        }
        let keyData = try keyDataForUse()
        try saveToDatabase(
            entries,
            preservingPayloadsFor: entryIDs,
            keyData: keyData
        )
        defaults.removeObject(forKey: Self.ciphertextKey)
    }

    func remove() throws {
        try database.remove()
        defaults.removeObject(forKey: Self.ciphertextKey)
        if localKeyPathExists {
            // unlink removes a regular file or the link itself, but refuses a
            // directory. Never recursively delete a path an attacker swapped
            // in place of the key file.
            guard Darwin.unlink(keyFileURL.path) == 0 else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }
        // A self-signed build intentionally leaves an unused legacy Keychain
        // item behind. Deleting it can itself trigger the authorization dialog
        // this migration is designed to eliminate, while all ciphertext above
        // has already been removed.
        if usesStableKeychainIdentity {
            try keychain.remove()
        }
        savedMetadataFingerprintByID = [:]
        unloadedPayloadEntryIDs = []
        hasLoadedHistory = true
    }

    private func migrateLegacyHistory(_ encrypted: Data) throws -> [ClipboardEntry] {
        let isMigration = !usesStableKeychainIdentity && !localKeyPathExists
        do {
            let keyData: Data
            if isMigration {
                // This is the only path that reads the legacy Keychain item in
                // a self-signed build. ClipboardHistoryStore only calls it in
                // response to the explicit migration button.
                guard let legacyKey = try keychain.read() else {
                    throw ClipboardHistoryError.persistenceUnavailable
                }
                keyData = legacyKey
            } else {
                keyData = try keyDataForUse()
            }
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let data = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            guard data.count <= Self.maximumLegacyEncodedSize else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            let entries = try JSONDecoder().decode([ClipboardEntry].self, from: data).map {
                $0.synchronizingPayloadDescriptor()
            }
            try saveToDatabase(entries, preservingPayloadsFor: [], keyData: keyData)
            if isMigration {
                // Commit the local key only after the authenticated legacy
                // ciphertext and the replacement database are both durable.
                // If the database transaction fails, the next launch can
                // retry from the untouched legacy ciphertext.
                try writeLocalKey(keyData)
            }
            defaults.removeObject(forKey: Self.ciphertextKey)
            hasLoadedHistory = true
            unloadedPayloadEntryIDs = Set(entries.map(\.id))
            return entries.map { $0.strippingPayload() }
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceCorrupt
        }
    }

    private func loadDatabase() throws -> [ClipboardEntry] {
        do {
            let header = try database.loadHeader()
            // An interrupted first migration can leave a valid empty v3
            // container beside the still-authenticated legacy blob. Prefer
            // the legacy source so an empty replacement can never hide user
            // history, regardless of whether the empty manifest was written.
            if header.recordIDs.isEmpty,
               let legacy = defaults.data(forKey: Self.ciphertextKey),
               !localKeyPathExists || header.manifest == nil {
                return try migrateLegacyHistory(legacy)
            }
            guard let manifest = header.manifest else {
                guard header.recordIDs.isEmpty else {
                    throw ClipboardHistoryError.persistenceCorrupt
                }
                savedMetadataFingerprintByID = [:]
                unloadedPayloadEntryIDs = []
                hasLoadedHistory = true
                return []
            }
            let migrationKeyData: Data?
            let keyData: Data
            if requiresExplicitMigration {
                guard let legacyKey = try keychain.read() else {
                    throw ClipboardHistoryError.persistenceUnavailable
                }
                keyData = legacyKey
                migrationKeyData = legacyKey
            } else {
                keyData = try keyDataForUse()
                migrationKeyData = nil
            }
            let orderData = try open(
                manifest,
                keyData: keyData,
                context: "manifest-v1"
            )
            let order = try JSONDecoder().decode([UUID].self, from: orderData)
            guard Set(order).count == order.count,
                  Set(order) == header.recordIDs else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            let entries: [ClipboardEntry]
            if let encryptedIndex = header.residentIndex,
               let indexed = try? decodeResidentIndex(
                    encryptedIndex,
                    order: order,
                    keyData: keyData
               ) {
                entries = indexed
            } else {
                var entryByID: [UUID: ClipboardEntry] = [:]
                entryByID.reserveCapacity(order.count)
                try database.forEachRecord { id, encrypted in
                    let data = try open(
                        encrypted,
                        keyData: keyData,
                        context: "entry:\(id.uuidString)"
                    )
                    let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: data)
                    guard decoded.id == id else {
                        throw ClipboardHistoryError.persistenceCorrupt
                    }
                    let summary = decoded.synchronizingPayloadDescriptor().strippingPayload()
                    guard summary.payloadDescriptor != nil else {
                        throw ClipboardHistoryError.persistenceCorrupt
                    }
                    entryByID[id] = summary
                }
                guard Set(entryByID.keys) == Set(order) else {
                    throw ClipboardHistoryError.persistenceCorrupt
                }
                entries = try order.map { id in
                    guard let entry = entryByID[id] else {
                        throw ClipboardHistoryError.persistenceCorrupt
                    }
                    return entry
                }
                let indexData = try encode(entries)
                let encryptedIndex = try seal(
                    indexData,
                    keyData: keyData,
                    context: "resident-index-v1"
                )
                // The resident index is an encrypted acceleration cache. A
                // read-only/locked database must not turn a valid history into
                // a startup failure; the next writable launch can rebuild it.
                try? database.writeResidentIndex(encryptedIndex)
            }
            savedMetadataFingerprintByID = try metadataFingerprints(entries)
            unloadedPayloadEntryIDs = Set(order)
            hasLoadedHistory = true
            if let migrationKeyData {
                // Recover the crash window where the database commit landed
                // but the local key rename did not. All authenticated rows
                // have been checked before this write is attempted.
                try writeLocalKey(migrationKeyData)
            }
            // A successfully opened v3 database supersedes the legacy blob.
            // Removing it here also closes the crash window where migration
            // committed the database but did not reach the final cleanup.
            defaults.removeObject(forKey: Self.ciphertextKey)
            return entries
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceCorrupt
        }
    }

    private func saveToDatabase(
        _ entries: [ClipboardEntry],
        preservingPayloadsFor entryIDs: Set<UUID>,
        keyData: Data
    ) throws {
        do {
            let order = entries.map(\.id)
            guard Set(order).count == order.count else {
                throw ClipboardHistoryError.persistenceDesynchronized
            }
            let summaries = entries.map { $0.strippingPayload() }
            let currentFingerprints = try metadataFingerprints(summaries)
            var changedRecords: [UUID: Data] = [:]
            for (entry, summary) in zip(entries, summaries)
                where currentFingerprints[entry.id] != savedMetadataFingerprintByID[entry.id] {
                let materialized: ClipboardEntry
                if entryIDs.contains(entry.id) {
                    guard let stored = try loadEntry(id: entry.id) else {
                        throw ClipboardHistoryError.persistenceDesynchronized
                    }
                    materialized = try summary.restoringPayload(from: stored)
                } else {
                    materialized = entry.synchronizingPayloadDescriptor()
                    guard materialized.hasResidentPayload,
                          materialized.payloadDescriptor != nil else {
                        throw ClipboardHistoryError.persistenceDesynchronized
                    }
                }
                let encoded = try encode(materialized)
                changedRecords[entry.id] = try seal(
                    encoded,
                    keyData: keyData,
                    context: "entry:\(entry.id.uuidString)"
                )
            }
            let manifestData = try encode(order)
            let manifest = try seal(
                manifestData,
                keyData: keyData,
                context: "manifest-v1"
            )
            let residentIndex = try seal(
                try encode(summaries),
                keyData: keyData,
                context: "resident-index-v1"
            )
            try database.save(
                changedRecords: changedRecords,
                retainingIDs: Set(order),
                manifest: manifest,
                residentIndex: residentIndex
            )
            savedMetadataFingerprintByID = currentFingerprints
            unloadedPayloadEntryIDs = Set(summaries.lazy.filter {
                !$0.hasResidentPayload && $0.payloadDescriptor != nil
            }.map(\.id))
            hasLoadedHistory = true
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    func loadEntry(id: UUID) throws -> ClipboardEntry? {
        guard database.exists else {
            return try loadResidentHistory().first { $0.id == id }
        }
        do {
            guard let encrypted = try database.loadRecord(id: id) else { return nil }
            let data = try open(
                encrypted,
                keyData: keyDataForUse(),
                context: "entry:\(id.uuidString)"
            )
            let entry = try JSONDecoder().decode(ClipboardEntry.self, from: data)
                .synchronizingPayloadDescriptor()
            guard entry.id == id, entry.payloadDescriptor != nil else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            return entry
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceCorrupt
        }
    }

    private func decodeResidentIndex(
        _ encrypted: Data,
        order: [UUID],
        keyData: Data
    ) throws -> [ClipboardEntry] {
        let data = try open(
            encrypted,
            keyData: keyData,
            context: "resident-index-v1"
        )
        let entries = try JSONDecoder().decode([ClipboardEntry].self, from: data)
        guard entries.map(\.id) == order,
              entries.allSatisfy({ entry in
                  guard !entry.hasResidentPayload,
                        let descriptor = entry.payloadDescriptor else { return false }
                  // Force one streaming rebuild for indexes written before
                  // the plain-text digest was added; this keeps Quick Merge
                  // cold-safe across an in-place app upgrade.
                  return !descriptor.hasPlainText || descriptor.plainTextFingerprint != nil
              }) else {
            throw ClipboardHistoryError.persistenceCorrupt
        }
        return entries
    }

    private func metadataFingerprints(
        _ entries: [ClipboardEntry]
    ) throws -> [UUID: Data] {
        Dictionary(uniqueKeysWithValues: try entries.map { entry in
            (entry.id, Data(SHA256.hash(data: try encode(entry.strippingPayload()))))
        })
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func seal(_ data: Data, keyData: Data, context: String) throws -> Data {
        let box = try AES.GCM.seal(
            data,
            using: SymmetricKey(data: keyData),
            authenticating: Data(context.utf8)
        )
        guard let combined = box.combined else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        return combined
    }

    private func open(_ data: Data, keyData: Data, context: String) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: keyData),
            authenticating: Data(context.utf8)
        )
    }

    private func keyDataForUse() throws -> Data {
        if let local = try readValidatedLocalKey() { return local }
        if usesStableKeychainIdentity {
            if let existing = try keychain.read() { return existing }
            guard !database.exists,
                  defaults.data(forKey: Self.ciphertextKey) == nil else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
            let generated = try randomKeyData()
            try keychain.store(generated)
            return try keychain.read() ?? generated
        }
        guard !database.exists,
              defaults.data(forKey: Self.ciphertextKey) == nil else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        let generated = try randomKeyData()
        try writeLocalKey(generated)
        return generated
    }

    private func randomKeyData() throws -> Data {
        var bytes = Data(count: Self.keyByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        return bytes
    }

    private var localKeyPathExists: Bool {
        var information = stat()
        return lstat(keyFileURL.path, &information) == 0
    }

    private func readValidatedLocalKey() throws -> Data? {
        let descriptor = Darwin.open(
            keyFileURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        if information.st_mode & mode_t(0o7777) != mode_t(0o600) {
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fstat(descriptor, &information) == 0,
                  information.st_mode & mode_t(0o7777) == mode_t(0o600) else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }

        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let data = try handle.readToEnd(), data.count == Self.keyByteCount else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
            return data
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func writeLocalKey(_ data: Data) throws {
        guard data.count == Self.keyByteCount else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        if let existing = try readValidatedLocalKey() {
            guard existing == data else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
            return
        }

        let directory = keyFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        try validateKeyDirectory(directory)

        let temporaryURL = directory.appendingPathComponent(
            ".clipboard-history-key-\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let wroteAllBytes = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAllBytes, fsync(descriptor) == 0 else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw ClipboardHistoryError.persistenceUnavailable
        }
        descriptorIsOpen = false

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: keyFileURL)
        } catch {
            guard let existing = try readValidatedLocalKey(), existing == data else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }
        // The file fsync above does not make the directory entry durable. A
        // power loss between rename and the next launch could otherwise leave
        // the database and its key out of sync.
        try validateKeyDirectory(directory)
        guard let written = try readValidatedLocalKey(), written == data else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func validateKeyDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        if information.st_mode & mode_t(0o077) != 0 {
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private static var defaultKeyFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenFind", isDirectory: true)
            .appendingPathComponent("clipboard-history-key-v3", isDirectory: false)
    }
}
