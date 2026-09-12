import Darwin
import Foundation

enum ConfigurationFile {
    static let maximumBytes = 32 * 1_024 * 1_024

    static func read(_ url: URL) async throws -> Data? {
        try await Task.detached(priority: .utility) {
            guard url.isFileURL else { throw ConfigurationError.invalidPreferences }
            try rejectSymlink(url)
            if !FileManager.default.fileExists(atPath: url.path),
               FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) { return nil }
            var coordinationError: NSError?
            var result: Result<Data?, Error> = .success(nil)
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
                result = Result { try readLocal(file) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    /// Compare and replace inside the coordinated access, so a remote edit
    /// arriving after the preceding read cannot silently be overwritten.
    static func write(_ data: Data, to url: URL, replacing expected: Data?) async throws {
        guard data.count <= maximumBytes else { throw ConfigurationError.tooLarge }
        try await Task.detached(priority: .utility) {
            guard url.isFileURL else { throw ConfigurationError.invalidPreferences }
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
                throw ConfigurationError.missingFile
            }
            try rejectSymlink(url)
            var coordinationError: NSError?
            var result: Result<Void, Error> = .failure(ConfigurationError.saveFailed)
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                          error: &coordinationError) { file in
                result = Result {
                    guard try readLocal(file) == expected else { throw ConfigurationError.conflict }
                    let temporary = file.deletingLastPathComponent().appendingPathComponent(".openfind-\(UUID()).tmp")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw ConfigurationError.saveFailed
                    }
                    let handle = try FileHandle(forWritingTo: temporary)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                    guard rename(temporary.path, file.path) == 0 else { throw ConfigurationError.saveFailed }
                }
            }
            if let coordinationError { throw coordinationError }
            try result.get()
        }.value
    }

    private static func readLocal(_ url: URL) throws -> Data? {
        guard url.isFileURL else { throw ConfigurationError.invalidPreferences }
        try rejectSymlink(url)
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw ConfigurationError.missingFile
        }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let info = try manager.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular else { throw ConfigurationError.invalidPreferences }
        guard ((info[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumBytes else {
            throw ConfigurationError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationError.tooLarge }
        return data
    }

    private static func rejectSymlink(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ConfigurationError.invalidPreferences
        }
    }
}
