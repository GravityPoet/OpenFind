import CryptoKit
import Foundation
import Security

protocol ClipboardHistoryPersisting: AnyObject {
    func load() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
    func remove() throws
}

final class EncryptedClipboardHistoryPersistence: ClipboardHistoryPersisting {
    private static let service = "com.openfind.clipboard-history-key-v2"
    private static let account = "history-key-v2"
    private static let ciphertextKey = "OpenFind.clipboardEncryptedHistoryV2"
    private static let maximumEncodedSize = 80 * 1_024 * 1_024
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [ClipboardEntry] {
        guard let encrypted = defaults.data(forKey: Self.ciphertextKey) else { return [] }
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let data = try AES.GCM.open(box, using: key())
            guard data.count <= Self.maximumEncodedSize else {
                throw ClipboardHistoryError.persistenceCorrupt
            }
            return try JSONDecoder().decode([ClipboardEntry].self, from: data)
        } catch let error as ClipboardHistoryError {
            throw error
        } catch {
            throw ClipboardHistoryError.persistenceCorrupt
        }
    }

    func save(_ entries: [ClipboardEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maximumEncodedSize else {
            throw ClipboardHistoryError.contentTooLarge
        }
        let box = try AES.GCM.seal(data, using: key())
        guard let combined = box.combined else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defaults.set(combined, forKey: Self.ciphertextKey)
    }

    func remove() throws {
        defaults.removeObject(forKey: Self.ciphertextKey)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func key() throws -> SymmetricKey {
        let query = baseQuery().merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        let addStatus = SecItemAdd(baseQuery().merging([
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        if addStatus == errSecDuplicateItem {
            return try key()
        }
        return SymmetricKey(data: bytes)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
