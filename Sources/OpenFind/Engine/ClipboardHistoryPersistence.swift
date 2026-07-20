import CryptoKit
import Darwin
import Foundation
import Security

protocol ClipboardHistoryPersisting: AnyObject {
    var requiresExplicitMigration: Bool { get }
    func load() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
    func remove() throws
}

extension ClipboardHistoryPersisting {
    var requiresExplicitMigration: Bool { false }
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
    private static let maximumEncodedSize = 80 * 1_024 * 1_024
    private static let keyByteCount = 32
    private let defaults: UserDefaults
    private let keyFileURL: URL
    private let keychain: any ClipboardHistoryKeychainAccessing
    private let usesStableKeychainIdentity: Bool

    init(
        defaults: UserDefaults = .standard,
        keyFileURL: URL = EncryptedClipboardHistoryPersistence.defaultKeyFileURL,
        keychain: any ClipboardHistoryKeychainAccessing = SystemClipboardHistoryKeychain(),
        signingTeamIdentifier: String? = CodeSigningIdentity.teamIdentifier(at: Bundle.main.bundleURL)
    ) {
        self.defaults = defaults
        self.keyFileURL = keyFileURL
        self.keychain = keychain
        usesStableKeychainIdentity = signingTeamIdentifier?.isEmpty == false
    }

    var requiresExplicitMigration: Bool {
        !usesStableKeychainIdentity
            && defaults.data(forKey: Self.ciphertextKey) != nil
            && !localKeyPathExists
    }

    func load() throws -> [ClipboardEntry] {
        guard let encrypted = defaults.data(forKey: Self.ciphertextKey) else { return [] }
        let isMigration = requiresExplicitMigration
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
            guard data.count <= Self.maximumEncodedSize else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            let entries = try JSONDecoder().decode([ClipboardEntry].self, from: data)
            if isMigration {
                // Commit the local key only after the old ciphertext has been
                // authenticated and decoded successfully.
                try writeLocalKey(keyData)
            }
            return entries
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceCorrupt
        }
    }

    func save(_ entries: [ClipboardEntry]) throws {
        guard !requiresExplicitMigration else {
            // Never replace legacy ciphertext with a newly generated key while
            // its original Keychain key is still waiting to be migrated.
            throw ClipboardHistoryError.persistenceUnavailable
        }
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maximumEncodedSize else {
            throw ClipboardHistoryError.contentTooLarge
        }
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: keyDataForUse()))
        guard let combined = box.combined else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defaults.set(combined, forKey: Self.ciphertextKey)
    }

    func remove() throws {
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
        // this migration is designed to eliminate, while the ciphertext above
        // has already been removed.
        if usesStableKeychainIdentity {
            try keychain.remove()
        }
    }

    private func keyDataForUse() throws -> Data {
        if let local = try readValidatedLocalKey() { return local }
        if usesStableKeychainIdentity {
            if let existing = try keychain.read() { return existing }
            let generated = try randomKeyData()
            try keychain.store(generated)
            return try keychain.read() ?? generated
        }
        guard defaults.data(forKey: Self.ciphertextKey) == nil else {
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
