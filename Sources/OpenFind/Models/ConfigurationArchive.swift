import Foundation

struct ConfigurationArchive: Codable, Equatable, Sendable {
    var format = "OpenFind Configuration"
    var version = 1
    var preferences: [String: Data]
    var snippets: [ClipboardSnippetRecord]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1_024 * 1_024 else { throw ConfigurationError.tooLarge }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.format == "OpenFind Configuration", archive.version == 1 else {
            throw ConfigurationError.unsupportedVersion
        }
        return archive
    }
}

struct ConfigurationSyncBaseline: Codable {
    let folderPath: String
    let local: ConfigurationArchive
    let remote: ConfigurationArchive
    let version: [String: Int]
}

struct ConfigurationSyncDocument: Codable {
    var format = "OpenFind Configuration Sync"
    let archive: ConfigurationArchive
    let version: [String: Int]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= ConfigurationFile.maximumBytes else { throw ConfigurationError.tooLarge }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.format == "OpenFind Configuration Sync", document.version.count <= 256,
              document.version.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value >= 0 && $0.value < Int.max }) else {
            throw ConfigurationError.invalidPreferences
        }
        return document
    }

    func includes(_ ancestor: [String: Int]) -> Bool {
        ancestor.allSatisfy { (version[$0.key] ?? 0) >= $0.value }
    }
}

enum ConfigurationError: Error, Equatable, LocalizedError {
    case unsupportedVersion, tooLarge, invalidPreferences, conflict, missingFile, unavailable, saveFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: L("Configuration Version Unsupported")
        case .tooLarge: L("Configuration Too Large")
        case .invalidPreferences: L("Configuration Invalid")
        case .conflict: L("Configuration Conflict")
        case .missingFile: L("Configuration File Missing")
        case .unavailable: L("Configuration Import Unavailable")
        case .saveFailed: L("Configuration Save Failed")
        }
    }
}
