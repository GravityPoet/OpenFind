import Darwin
import Foundation
import SQLite3

private let clipboardSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct EncryptedClipboardHistorySnapshot {
    let manifest: Data?
    let records: [UUID: Data]
}

final class EncryptedClipboardHistoryDatabase {
    private static let schemaVersion: Int32 = 3
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    var exists: Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }

    func load() throws -> EncryptedClipboardHistorySnapshot {
        guard exists else {
            return EncryptedClipboardHistorySnapshot(manifest: nil, records: [:])
        }
        try validateDatabaseFile()
        let database = try open(flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(database) }
        guard try schemaVersion(in: database) == Self.schemaVersion else {
            throw ClipboardHistoryError.persistenceCorrupt
        }

        let manifest = try queryManifest(in: database)
        let records = try queryRecords(in: database)
        guard manifest != nil || records.isEmpty else {
            throw ClipboardHistoryError.persistenceCorrupt
        }
        return EncryptedClipboardHistorySnapshot(manifest: manifest, records: records)
    }

    func save(
        changedRecords: [UUID: Data],
        retainingIDs: Set<UUID>,
        manifest: Data
    ) throws {
        try prepareDirectory()
        if exists { try validateDatabaseFile() }
        let database = try open(
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close_v2(database) }
        try configure(database)
        try createSchema(in: database)
        try validateDatabaseFile()

        try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            let storedIDs = try queryRecordIDs(in: database)
            for id in storedIDs.subtracting(retainingIDs) {
                try deleteRecord(id: id, in: database)
            }
            for (id, payload) in changedRecords {
                try upsertRecord(id: id, payload: payload, in: database)
            }
            try upsertManifest(manifest, in: database)
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
        try validateDatabaseFile()
    }

    func remove() throws {
        for candidate in [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ] {
            guard Darwin.unlink(candidate.path) == 0 || errno == ENOENT else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }
    }

    private func open(flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw ClipboardHistoryError.persistenceUnavailable
        }
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    private func configure(_ database: OpaquePointer) throws {
        try execute("PRAGMA trusted_schema=OFF", in: database)
        try execute("PRAGMA secure_delete=ON", in: database)
        try execute("PRAGMA synchronous=FULL", in: database)
        try execute("PRAGMA journal_mode=WAL", in: database)
    }

    private func createSchema(in database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """,
            in: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """,
            in: database
        )
        try execute("PRAGMA user_version=\(Self.schemaVersion)", in: database)
    }

    private func schemaVersion(in database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceCorrupt
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ClipboardHistoryError.persistenceCorrupt
        }
        return sqlite3_column_int(statement, 0)
    }

    private func queryManifest(in database: OpaquePointer) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT payload FROM metadata WHERE key = 'order-v1'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceCorrupt
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let data = data(in: statement, column: 0) else {
            throw ClipboardHistoryError.persistenceCorrupt
        }
        return data
    }

    private func queryRecords(in database: OpaquePointer) throws -> [UUID: Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, payload FROM entries",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceCorrupt
        }
        defer { sqlite3_finalize(statement) }
        var records: [UUID: Data] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)),
                      let payload = data(in: statement, column: 1),
                      records[id] == nil else {
                    throw ClipboardHistoryError.persistenceCorrupt
                }
                records[id] = payload
            case SQLITE_DONE:
                return records
            default:
                throw ClipboardHistoryError.persistenceCorrupt
            }
        }
    }

    private func queryRecordIDs(in database: OpaquePointer) throws -> Set<UUID> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id FROM entries", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defer { sqlite3_finalize(statement) }
        var result = Set<UUID>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)) else {
                    throw ClipboardHistoryError.persistenceCorrupt
                }
                result.insert(id)
            case SQLITE_DONE:
                return result
            default:
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }
    }

    private func upsertRecord(
        id: UUID,
        payload: Data,
        in database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO entries(id, payload) VALUES(?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(
            statement,
            1,
            id.uuidString,
            -1,
            clipboardSQLiteTransient
        ) == SQLITE_OK,
        bind(payload, to: statement, index: 2),
        sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func deleteRecord(id: UUID, in database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "DELETE FROM entries WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(
            statement,
            1,
            id.uuidString,
            -1,
            clipboardSQLiteTransient
        ) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func upsertManifest(_ payload: Data, in database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO metadata(key, payload) VALUES('order-v1', ?) "
                + "ON CONFLICT(key) DO UPDATE SET payload=excluded.payload",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ClipboardHistoryError.persistenceUnavailable
        }
        defer { sqlite3_finalize(statement) }
        guard bind(payload, to: statement, index: 1),
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                clipboardSQLiteTransient
            ) == SQLITE_OK
        }
    }

    private func data(in statement: OpaquePointer, column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw ClipboardHistoryError.persistenceUnavailable
        }
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
    }

    private func validateDatabaseFile() throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        if information.st_mode & mode_t(0o7777) != mode_t(0o600) {
            guard chmod(url.path, mode_t(0o600)) == 0 else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
        }
    }
}
