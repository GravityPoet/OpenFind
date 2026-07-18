import CryptoKit
import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    deinit {
        close()
    }
}

struct ContentIndexCandidate: Sendable {
    let node: ResolvedNode
    let forceRefresh: Bool
}

struct ContentIndexWorkItem: Sendable {
    let node: ResolvedNode
    let shouldRecord: Bool
}

struct ContentIndexPlan: Sendable {
    let workItems: [ContentIndexWorkItem]
    let skippedFreshNonMatches: Int
}

struct ContentIndexRecord: Sendable {
    let node: ResolvedNode
    /// nil means a readable raw file was proven to contain no searchable text.
    /// Retryable extraction failures are never recorded.
    let text: String?
    let digest: Data?
    let reusedSourceIdentity: Bool

    init(
        node: ResolvedNode,
        text: String?,
        digest: Data? = nil,
        reusedSourceIdentity: Bool = false
    ) {
        self.node = node
        self.text = text
        self.digest = digest
        self.reusedSourceIdentity = reusedSourceIdentity
    }
}

struct ContentIndexDiagnostics: Sendable, Equatable {
    let indexedDocuments: Int
    let uniqueContentBodies: Int
    let deduplicatedDocuments: Int
    let sourceIdentityReuses: Int
    let databaseBytes: Int64
    let schemaVersion: Int32
    let recordTransactions: Int
    let checkpoints: Int
    let budgetStops: Int
    let walAutoCheckpointPages: Int
    let tempStoreMode: Int
    let lastError: String?
}

/// Query-driven persistent content index.
///
/// FTS is only allowed to exclude a candidate when the current metadata
/// fingerprint exactly matches a successfully extracted row. Unknown, stale,
/// invalidated, or unsupported query shapes stay on the authoritative scan
/// path, so an incomplete database can cost time but cannot hide a result.
actor ContentSearchIndex {
    private struct ContentBodyIdentity: Hashable {
        let digest: Data
        let utf8Bytes: Int
    }

    private struct Metadata {
        let size: Int64
        let modifiedTime: TimeInterval
        let creationTime: TimeInterval
        let extractionVersion: Int
        let hasSearchableText: Bool
        let requiresAuthoritativeScan: Bool
        let containsRequiredLiteral: Bool

        func matches(_ node: ResolvedNode) -> Bool {
            size == node.size
                && modifiedTime == node.modifiedTime
                && creationTime == node.creationTime
                && extractionVersion == DocumentTextExtractor.extractionVersion
        }
    }

    private static let schemaVersion: Int32 = 4
    private static let queryChunkSize = 256
    /// FTS5 trigram postings can expand a single very large body by orders of
    /// magnitude while the row is inserted. Files above this cache threshold
    /// stay authoritative raw-scan candidates, so search coverage and the
    /// user-selected maximum searchable file size remain unchanged.
    static let maximumPersistedBodyBytes = 8 * 1_024 * 1_024
    private static let checkpointWALBytes: Int64 = 64 * 1_024 * 1_024
    private static let checkpointInterval: Duration = .seconds(30)
    private static let maximumUnmergedTransactions = 32
    private static let oversizedEmptyDatabaseBytes: Int64 = 64 * 1_024 * 1_024

    let databaseURL: URL
    private let legacyDatabaseURL: URL?
    private var connection: SQLiteConnection?
    private var database: OpaquePointer? { connection?.handle }
    private var legacyConnection: SQLiteConnection?
    private var legacyDatabase: OpaquePointer? { legacyConnection?.handle }
    private var recoveryAttempted = false
    private var lastErrorMessage: String?
    private var recordTransactionCount = 0
    private var recordTransactionsSinceIdleMerge = 0
    private var checkpointCount = 0
    private var budgetStopCount = 0
    private var sourceIdentityReuseCount = 0
    private var lastCheckpoint = ContinuousClock.now

    init(databaseURL: URL, legacyDatabaseURL: URL? = nil) {
        self.databaseURL = databaseURL
        self.legacyDatabaseURL = legacyDatabaseURL
    }

    static func databaseURL(for indexURL: URL) -> URL {
        indexURL.deletingPathExtension().appendingPathExtension("content-v2.sqlite3")
    }

    static func legacyDatabaseURL(for indexURL: URL) -> URL {
        indexURL.deletingPathExtension().appendingPathExtension("content-v1.sqlite3")
    }

    static func isDatabaseEvent(path: String, indexURL: URL) -> Bool {
        let canonicalPath = SearchPath.canonicalAliasPath(path)
        return [databaseURL(for: indexURL), legacyDatabaseURL(for: indexURL)].contains { url in
            let databasePath = SearchPath.canonicalAliasPath(url.path)
            return canonicalPath == databasePath
                || canonicalPath == databasePath + "-wal"
                || canonicalPath == databasePath + "-shm"
                || canonicalPath == databasePath + "-journal"
        }
    }

    func plan(
        candidates: [ContentIndexCandidate],
        requiredLiteral: String?
    ) -> ContentIndexPlan {
        guard !candidates.isEmpty else {
            return ContentIndexPlan(workItems: [], skippedFreshNonMatches: 0)
        }
        guard let requiredLiteral,
              Self.isSafeTrigramLiteral(requiredLiteral),
              openIfNeeded() else {
            return ContentIndexPlan(
                workItems: candidates.map { ContentIndexWorkItem(node: $0.node, shouldRecord: true) },
                skippedFreshNonMatches: 0
            )
        }

        guard let matchQuery = Self.trigramMatchQuery(requiredLiteral) else {
            return ContentIndexPlan(
                workItems: candidates.map { ContentIndexWorkItem(node: $0.node, shouldRecord: true) },
                skippedFreshNonMatches: 0
            )
        }
        var workItems: [ContentIndexWorkItem] = []
        workItems.reserveCapacity(min(candidates.count, 4_096))
        var skipped = 0

        for start in stride(from: 0, to: candidates.count, by: Self.queryChunkSize) {
            let end = min(start + Self.queryChunkSize, candidates.count)
            let chunk = candidates[start..<end]
            guard let metadata = metadataByPath(
                paths: chunk.map { $0.node.path },
                matchQuery: matchQuery
            ) else {
                return ContentIndexPlan(
                    workItems: candidates.map { ContentIndexWorkItem(node: $0.node, shouldRecord: true) },
                    skippedFreshNonMatches: 0
                )
            }
            let legacyMetadata = legacyMetadataByPath(
                paths: chunk.map { $0.node.path },
                matchQuery: matchQuery
            ) ?? [:]

            for candidate in chunk {
                if candidate.forceRefresh {
                    workItems.append(ContentIndexWorkItem(node: candidate.node, shouldRecord: true))
                    continue
                }
                if let stored = metadata[candidate.node.path], stored.matches(candidate.node) {
                    if !stored.hasSearchableText {
                        skipped += 1
                    } else if stored.requiresAuthoritativeScan {
                        workItems.append(ContentIndexWorkItem(node: candidate.node, shouldRecord: false))
                    } else if stored.containsRequiredLiteral {
                        workItems.append(ContentIndexWorkItem(node: candidate.node, shouldRecord: false))
                    } else {
                        skipped += 1
                    }
                    continue
                }
                guard let legacy = legacyMetadata[candidate.node.path],
                      legacy.matches(candidate.node) else {
                    workItems.append(ContentIndexWorkItem(node: candidate.node, shouldRecord: true))
                    continue
                }
                if !legacy.hasSearchableText {
                    skipped += 1
                } else if legacy.containsRequiredLiteral {
                    // A legacy hit still receives an authoritative raw scan.
                    // Record that scan into v2 so ordinary searches advance
                    // migration instead of depending on v1 forever.
                    workItems.append(ContentIndexWorkItem(node: candidate.node, shouldRecord: true))
                } else {
                    skipped += 1
                }
            }
        }

        return ContentIndexPlan(
            workItems: workItems,
            skippedFreshNonMatches: skipped
        )
    }

    /// Returns only documents that have never been extracted or whose metadata
    /// fingerprint changed. Background enrichment is optional acceleration: a
    /// database failure stops this pass, while foreground content search keeps
    /// its authoritative raw-file fallback and therefore cannot lose results.
    func enrichmentCandidates(_ candidates: [ResolvedNode]) -> [ResolvedNode] {
        guard !candidates.isEmpty, openIfNeeded() else { return [] }
        var work: [ResolvedNode] = []
        work.reserveCapacity(min(candidates.count, 4_096))

        for start in stride(from: 0, to: candidates.count, by: Self.queryChunkSize) {
            let end = min(start + Self.queryChunkSize, candidates.count)
            let chunk = candidates[start..<end]
            guard let metadata = metadataFingerprintsByPath(
                paths: chunk.map(\.path)
            ) else { return [] }
            for candidate in chunk {
                if metadata[candidate.path]?.matches(candidate) != true {
                    work.append(candidate)
                }
            }
        }
        return work
    }

    /// Persists one bounded acceleration batch. `false` means the caller should
    /// stop optional enrichment (database failure or disk budget reached).
    /// Foreground search may ignore the return value because it has already
    /// scanned the original file and produced the authoritative result.
    @discardableResult
    func record(
        _ records: [ContentIndexRecord],
        maximumDatabaseBytes: Int64 = 0
    ) -> Bool {
        let preparedRecords = records.compactMap {
            record -> (record: ContentIndexRecord, digest: Data?, byteCount: Int, persistsBody: Bool)? in
            let byteCount = record.text?.utf8.count ?? 0
            guard byteCount <= Int(Int32.max) else { return nil }
            let persistsBody = record.text == nil || byteCount <= Self.maximumPersistedBodyBytes
            let digest = persistsBody ? (record.digest ?? record.text.map(Self.contentDigest)) : nil
            return (record, digest, byteCount, persistsBody)
        }
        guard !preparedRecords.isEmpty else { return true }
        guard openIfNeeded(), let database else { return false }
        if maximumDatabaseBytes > 0,
           databaseStorageBytes() >= maximumDatabaseBytes {
            budgetStopCount += 1
            return false
        }
        guard execute("BEGIN IMMEDIATE", in: database) else { return false }

        let upsertDocumentSQL = """
        INSERT INTO documents(path, size, modified, created, extractor, state, content_id)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            size=excluded.size,
            modified=excluded.modified,
            created=excluded.created,
            extractor=excluded.extractor,
            state=excluded.state,
            content_id=excluded.content_id
        """
        var selectPrevious: OpaquePointer?
        var insertBody: OpaquePointer?
        var selectBody: OpaquePointer?
        var upsertDocument: OpaquePointer?
        var insertFTS: OpaquePointer?
        guard sqlite3_prepare_v2(
                database, "SELECT content_id, state FROM documents WHERE path=?", -1, &selectPrevious, nil
              ) == SQLITE_OK,
              sqlite3_prepare_v2(
                database,
                "INSERT INTO content_bodies(digest, utf8_bytes) VALUES(?, ?) "
                    + "ON CONFLICT DO NOTHING RETURNING id",
                -1, &insertBody, nil
              ) == SQLITE_OK,
              sqlite3_prepare_v2(
                database, "SELECT id FROM content_bodies WHERE digest=? AND utf8_bytes=?", -1, &selectBody, nil
              ) == SQLITE_OK,
              sqlite3_prepare_v2(database, upsertDocumentSQL, -1, &upsertDocument, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "INSERT INTO content_fts(rowid, body) VALUES(?, ?)", -1, &insertFTS, nil) == SQLITE_OK else {
            sqlite3_finalize(selectPrevious)
            sqlite3_finalize(insertBody)
            sqlite3_finalize(selectBody)
            sqlite3_finalize(upsertDocument)
            sqlite3_finalize(insertFTS)
            _ = execute("ROLLBACK", in: database)
            recoverIfCorrupt(database)
            return false
        }
        defer {
            sqlite3_finalize(selectPrevious)
            sqlite3_finalize(insertBody)
            sqlite3_finalize(selectBody)
            sqlite3_finalize(upsertDocument)
            sqlite3_finalize(insertFTS)
        }

        var succeeded = true
        let sourceIdentityReuses = preparedRecords.reduce(into: 0) { count, prepared in
            if prepared.record.reusedSourceIdentity, prepared.persistsBody { count += 1 }
        }
        var potentiallyOrphanedContentIDs = Set<Int64>()
        var contentIDsByIdentity: [ContentBodyIdentity: Int64] = [:]
        contentIDsByIdentity.reserveCapacity(preparedRecords.count)
        for prepared in preparedRecords where !Task.isCancelled {
            let record = prepared.record
            let digest = prepared.digest
            let textByteCount = prepared.byteCount
            sqlite3_reset(selectPrevious)
            sqlite3_clear_bindings(selectPrevious)
            guard bind(record.node.path, to: selectPrevious, at: 1) else {
                succeeded = false
                break
            }
            let previousStatus = sqlite3_step(selectPrevious)
            let previousContentID: Int64? = previousStatus == SQLITE_ROW
                && sqlite3_column_type(selectPrevious, 0) != SQLITE_NULL
                ? sqlite3_column_int64(selectPrevious, 0)
                : nil
            let previousState = previousStatus == SQLITE_ROW
                ? sqlite3_column_int(selectPrevious, 1)
                : 0
            guard previousStatus == SQLITE_ROW || previousStatus == SQLITE_DONE else {
                succeeded = false
                break
            }

            var contentID: Int64?
            var documentState: Int32 = 0
            if record.text != nil, !prepared.persistsBody {
                // State 3 means searchable text exists but intentionally has
                // no persistent posting list. Every content query must scan
                // the original file, which preserves exact results while
                // preventing unbounded trigram insertion memory.
                documentState = 3
            } else if let text = record.text {
                guard let digest else {
                    succeeded = false
                    break
                }
                let identity = ContentBodyIdentity(digest: digest, utf8Bytes: textByteCount)
                var insertedNewBody = false
                if let cachedContentID = contentIDsByIdentity[identity] {
                    contentID = cachedContentID
                } else {
                    sqlite3_reset(insertBody)
                    sqlite3_clear_bindings(insertBody)
                    guard bind(digest, to: insertBody, at: 1),
                          sqlite3_bind_int64(insertBody, 2, Int64(textByteCount)) == SQLITE_OK else {
                        succeeded = false
                        break
                    }
                    let insertStatus = sqlite3_step(insertBody)
                    insertedNewBody = insertStatus == SQLITE_ROW
                    if insertedNewBody {
                        contentID = sqlite3_column_int64(insertBody, 0)
                        guard sqlite3_step(insertBody) == SQLITE_DONE else {
                            succeeded = false
                            break
                        }
                    } else if insertStatus == SQLITE_DONE {
                        sqlite3_reset(selectBody)
                        sqlite3_clear_bindings(selectBody)
                        guard bind(digest, to: selectBody, at: 1),
                              sqlite3_bind_int64(selectBody, 2, Int64(textByteCount)) == SQLITE_OK,
                              sqlite3_step(selectBody) == SQLITE_ROW else {
                            succeeded = false
                            break
                        }
                        contentID = sqlite3_column_int64(selectBody, 0)
                    } else {
                        succeeded = false
                        break
                    }
                    if let contentID {
                        contentIDsByIdentity[identity] = contentID
                    }
                }

                guard let contentID else {
                    succeeded = false
                    break
                }
                if insertedNewBody {
                    sqlite3_reset(insertFTS)
                    sqlite3_clear_bindings(insertFTS)
                    guard sqlite3_bind_int64(insertFTS, 1, contentID) == SQLITE_OK,
                          bind(text, to: insertFTS, at: 2),
                          sqlite3_step(insertFTS) == SQLITE_DONE else {
                        succeeded = false
                        break
                    }
                    documentState = 1
                } else if previousContentID == contentID, previousState == 1 {
                    documentState = 1
                } else {
                    // Hash-shared rows save one posting list. They deliberately
                    // remain authoritative-scan candidates so correctness never
                    // depends on treating a digest as proof of byte equality.
                    documentState = 2
                }
            }

            sqlite3_reset(upsertDocument)
            sqlite3_clear_bindings(upsertDocument)
            guard bind(record.node.path, to: upsertDocument, at: 1),
                  sqlite3_bind_int64(upsertDocument, 2, record.node.size) == SQLITE_OK,
                  sqlite3_bind_double(upsertDocument, 3, record.node.modifiedTime) == SQLITE_OK,
                  sqlite3_bind_double(upsertDocument, 4, record.node.creationTime) == SQLITE_OK,
                  sqlite3_bind_int(upsertDocument, 5, Int32(DocumentTextExtractor.extractionVersion)) == SQLITE_OK,
                  sqlite3_bind_int(upsertDocument, 6, documentState) == SQLITE_OK,
                  bindOptional(contentID, to: upsertDocument, at: 7),
                  sqlite3_step(upsertDocument) == SQLITE_DONE else {
                succeeded = false
                break
            }
            if let previousContentID, previousContentID != contentID {
                potentiallyOrphanedContentIDs.insert(previousContentID)
            }
        }

        if succeeded {
            succeeded = deleteOrphanedContentBodies(
                potentiallyOrphanedContentIDs,
                database: database
            )
        }

        if succeeded, execute("COMMIT", in: database) {
            recordTransactionCount += 1
            recordTransactionsSinceIdleMerge += 1
            sourceIdentityReuseCount += sourceIdentityReuses
            checkpointIfNeeded()
            if maximumDatabaseBytes > 0,
               databaseStorageBytes() >= maximumDatabaseBytes {
                budgetStopCount += 1
                return false
            }
            return true
        } else {
            _ = execute("ROLLBACK", in: database)
            recoverIfCorrupt(database)
            return false
        }
    }

    func invalidate(exactPaths: [String], subtreePaths: [String]) {
        guard (!exactPaths.isEmpty || !subtreePaths.isEmpty),
              openIfNeeded(), let database,
              execute("BEGIN IMMEDIATE", in: database) else { return }

        var succeeded = true
        for path in Set(exactPaths.map(SearchPath.canonicalAliasPath)) where succeeded {
            succeeded = deleteRows(where: "path = ?", values: [path], database: database)
        }
        for root in Set(subtreePaths.map(SearchPath.canonicalAliasPath)) where succeeded {
            let prefix = root == "/" ? "/" : root + "/"
            // `prefix` always ends in ASCII `/` (0x2f), so replacing that
            // final byte with `0` (0x30) creates the exclusive upper bound
            // for every descendant under SQLite's BINARY path collation.
            // Unlike substr(path, ...), this lets both lookup and DELETE use
            // the UNIQUE path index even for a very large content cache.
            let prefixUpperBound = root == "/" ? "0" : root + "0"
            succeeded = deleteRows(
                where: "path = ? OR (path >= ? AND path < ?)",
                values: [root, prefix, prefixUpperBound],
                database: database
            )
        }

        if succeeded {
            _ = execute("COMMIT", in: database)
        } else {
            _ = execute("ROLLBACK", in: database)
            recoverIfCorrupt(database)
        }
    }

    func invalidateAll() {
        // A global invalidation has no reusable v2 rows. Recreating the cache
        // avoids leaving hundreds of megabytes of FTS deletion segments and
        // freelist pages behind after a logical DELETE of every document.
        connection?.close()
        connection = nil
        removeDatabaseFiles()
        _ = openDatabase(allowEmptyRebuild: false)
    }

    func flush() {
        guard openIfNeeded(), let database else { return }
        // Do a bounded amount of segment work during idle instead of charging
        // every document batch for aggressive automatic merging.
        if recordTransactionsSinceIdleMerge >= Self.maximumUnmergedTransactions,
           execute("INSERT INTO content_fts(content_fts, rank) VALUES('merge', 1)", in: database) {
            recordTransactionsSinceIdleMerge = 0
        }
        checkpoint(mode: "TRUNCATE")
        let freePages = integerValue("PRAGMA freelist_count", in: database)
        if freePages > 2_048 {
            _ = execute("PRAGMA incremental_vacuum(2048)", in: database)
        }
    }

    func diagnostics() -> ContentIndexDiagnostics {
        guard openIfNeeded(), let database else {
            return ContentIndexDiagnostics(
                indexedDocuments: 0,
                uniqueContentBodies: 0,
                deduplicatedDocuments: 0,
                sourceIdentityReuses: sourceIdentityReuseCount,
                databaseBytes: 0,
                schemaVersion: 0,
                recordTransactions: recordTransactionCount,
                checkpoints: checkpointCount,
                budgetStops: budgetStopCount,
                walAutoCheckpointPages: 0,
                tempStoreMode: 0,
                lastError: lastErrorMessage
            )
        }
        var statement: OpaquePointer?
        let count: Int
        if sqlite3_prepare_v2(database, "SELECT count(*) FROM documents", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(statement, 0))
        } else {
            count = 0
        }
        sqlite3_finalize(statement)
        let uniqueContentBodies = integerValue("SELECT count(*) FROM content_bodies", in: database)
        let deduplicatedDocuments = integerValue("SELECT count(*) FROM documents WHERE state=2", in: database)
        var versionStatement: OpaquePointer?
        let version: Int32
        if sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
           sqlite3_step(versionStatement) == SQLITE_ROW {
            version = sqlite3_column_int(versionStatement, 0)
        } else {
            version = 0
        }
        sqlite3_finalize(versionStatement)
        let files = ["", "-wal", "-shm"].compactMap { suffix -> Int64? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path + suffix)
            return (attributes?[.size] as? NSNumber)?.int64Value
        }
        return ContentIndexDiagnostics(
            indexedDocuments: count,
            uniqueContentBodies: uniqueContentBodies,
            deduplicatedDocuments: deduplicatedDocuments,
            sourceIdentityReuses: sourceIdentityReuseCount,
            databaseBytes: files.reduce(0, +),
            schemaVersion: version,
            recordTransactions: recordTransactionCount,
            checkpoints: checkpointCount,
            budgetStops: budgetStopCount,
            walAutoCheckpointPages: integerValue("PRAGMA wal_autocheckpoint", in: database),
            tempStoreMode: integerValue("PRAGMA temp_store", in: database),
            lastError: lastErrorMessage
        )
    }

    func close() {
        connection?.close()
        connection = nil
        legacyConnection?.close()
        legacyConnection = nil
    }

    /// Removes v1 only after every legacy fingerprint has an equivalent v2
    /// row. Until then v1 remains a read-only query accelerator and rollback
    /// cache; it is never authoritative for result membership.
    func completeLegacyMigrationIfCovered() {
        guard legacyDatabaseURL.map({
            FileManager.default.fileExists(atPath: $0.path)
        }) == true,
        openIfNeeded(),
        openLegacyIfNeeded(),
        legacyCoverageIsComplete() else { return }

        legacyConnection?.close()
        legacyConnection = nil
        removeLegacyDatabaseFiles()
    }

    private static func isSafeTrigramLiteral(_ literal: String) -> Bool {
        literal.utf8.count >= 3
            && literal.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    private static func quotedFTSLiteral(_ literal: String) -> String {
        "\"" + literal.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// FTS5 `detail=none` rejects query tokens longer than three Unicode
    /// characters. The persistent prefilter therefore intersects every ASCII
    /// trigram. A document containing the literal necessarily contains all of
    /// these postings; non-adjacent postings can only create false positives,
    /// which the authoritative raw-file matcher removes.
    private static func trigramMatchQuery(_ literal: String) -> String? {
        guard isSafeTrigramLiteral(literal) else { return nil }
        let bytes = Array(literal.utf8)
        var seen = Set<String>()
        var terms: [String] = []
        terms.reserveCapacity(max(1, bytes.count - 2))
        for start in 0...(bytes.count - 3) {
            guard let trigram = String(bytes: bytes[start..<(start + 3)], encoding: .ascii) else {
                return nil
            }
            if seen.insert(trigram).inserted {
                terms.append(quotedFTSLiteral(trigram))
            }
        }
        return terms.joined(separator: " AND ")
    }

    /// Background reconciliation only needs the durable metadata fingerprint.
    /// Running an FTS MATCH subquery here repeated the same posting lookup for
    /// every 256 paths while walking a whole-Mac index, consuming a full core
    /// for minutes without changing which files required extraction.
    private func metadataFingerprintsByPath(paths: [String]) -> [String: Metadata]? {
        guard let database, !paths.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let sql = """
        SELECT path, size, modified, created, extractor, state
        FROM documents
        WHERE path IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            recoverIfCorrupt(database)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (offset, path) in paths.enumerated() {
            guard bind(path, to: statement, at: Int32(offset + 1)) else { return nil }
        }

        var result: [String: Metadata] = [:]
        result.reserveCapacity(paths.count)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW,
                  let pathText = sqlite3_column_text(statement, 0) else {
                recoverIfCorrupt(database)
                return nil
            }
            let path = String(cString: pathText)
            result[path] = Metadata(
                size: sqlite3_column_int64(statement, 1),
                modifiedTime: sqlite3_column_double(statement, 2),
                creationTime: sqlite3_column_double(statement, 3),
                extractionVersion: Int(sqlite3_column_int(statement, 4)),
                hasSearchableText: sqlite3_column_int(statement, 5) != 0,
                requiresAuthoritativeScan: sqlite3_column_int(statement, 5) >= 2,
                containsRequiredLiteral: false
            )
        }
    }

    private func metadataByPath(paths: [String], matchQuery: String) -> [String: Metadata]? {
        guard let database, !paths.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let sql = """
        SELECT d.path, d.size, d.modified, d.created, d.extractor, d.state,
               CASE WHEN matched.rowid IS NULL THEN 0 ELSE 1 END
        FROM documents AS d
        LEFT JOIN (
            SELECT rowid FROM content_fts WHERE content_fts MATCH ?
        ) AS matched ON matched.rowid = d.content_id
        WHERE d.path IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              bind(matchQuery, to: statement, at: 1) else {
            sqlite3_finalize(statement)
            recoverIfCorrupt(database)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (offset, path) in paths.enumerated() {
            guard bind(path, to: statement, at: Int32(offset + 2)) else { return nil }
        }

        var result: [String: Metadata] = [:]
        result.reserveCapacity(paths.count)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW,
                  let pathText = sqlite3_column_text(statement, 0) else {
                recoverIfCorrupt(database)
                return nil
            }
            let path = String(cString: pathText)
            result[path] = Metadata(
                size: sqlite3_column_int64(statement, 1),
                modifiedTime: sqlite3_column_double(statement, 2),
                creationTime: sqlite3_column_double(statement, 3),
                extractionVersion: Int(sqlite3_column_int(statement, 4)),
                hasSearchableText: sqlite3_column_int(statement, 5) != 0,
                requiresAuthoritativeScan: sqlite3_column_int(statement, 5) >= 2,
                containsRequiredLiteral: sqlite3_column_int(statement, 6) != 0
            )
        }
    }

    private func legacyMetadataByPath(
        paths: [String],
        matchQuery: String
    ) -> [String: Metadata]? {
        guard !paths.isEmpty else { return [:] }
        guard openLegacyIfNeeded(), let legacyDatabase else { return [:] }
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let sql = """
        SELECT d.path, d.size, d.modified, d.created, d.extractor, d.state,
               CASE WHEN matched.rowid IS NULL THEN 0 ELSE 1 END
        FROM documents AS d
        LEFT JOIN (
            SELECT rowid FROM content_fts WHERE content_fts MATCH ?
        ) AS matched ON matched.rowid = d.id
        WHERE d.path IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(legacyDatabase, sql, -1, &statement, nil) == SQLITE_OK,
              bind(matchQuery, to: statement, at: 1) else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (offset, path) in paths.enumerated() {
            guard bind(path, to: statement, at: Int32(offset + 2)) else { return nil }
        }

        var result: [String: Metadata] = [:]
        result.reserveCapacity(paths.count)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW,
                  let pathText = sqlite3_column_text(statement, 0) else { return nil }
            let path = String(cString: pathText)
            result[path] = Metadata(
                size: sqlite3_column_int64(statement, 1),
                modifiedTime: sqlite3_column_double(statement, 2),
                creationTime: sqlite3_column_double(statement, 3),
                extractionVersion: Int(sqlite3_column_int(statement, 4)),
                hasSearchableText: sqlite3_column_int(statement, 5) != 0,
                requiresAuthoritativeScan: false,
                containsRequiredLiteral: sqlite3_column_int(statement, 6) != 0
            )
        }
    }

    private func openLegacyIfNeeded() -> Bool {
        if legacyDatabase != nil { return true }
        guard let legacyDatabaseURL,
              FileManager.default.fileExists(atPath: legacyDatabaseURL.path) else { return false }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(legacyDatabaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        var versionStatement: OpaquePointer?
        guard quickCheck(handle),
              sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              sqlite3_step(versionStatement) == SQLITE_ROW,
              sqlite3_column_int(versionStatement, 0) == 2 else {
            sqlite3_finalize(versionStatement)
            sqlite3_close_v2(handle)
            return false
        }
        sqlite3_finalize(versionStatement)
        legacyConnection = SQLiteConnection(handle)
        return true
    }

    private func legacyCoverageIsComplete() -> Bool {
        guard let legacyDatabase,
              let metadataProbe = Self.trigramMatchQuery("openfind-legacy-coverage-probe") else {
            return false
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            legacyDatabase,
            "SELECT path,size,modified,created,extractor,state FROM documents ORDER BY id",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        var batch: [(path: String, metadata: Metadata)] = []
        batch.reserveCapacity(Self.queryChunkSize)
        func covered(_ batch: [(path: String, metadata: Metadata)]) -> Bool {
            guard let current = metadataByPath(
                paths: batch.map(\.path),
                matchQuery: metadataProbe
            ) else { return false }
            return batch.allSatisfy { legacy in
                guard let v2 = current[legacy.path] else { return false }
                return v2.size == legacy.metadata.size
                    && v2.modifiedTime == legacy.metadata.modifiedTime
                    && v2.creationTime == legacy.metadata.creationTime
                    && v2.extractionVersion == legacy.metadata.extractionVersion
                    && (!legacy.metadata.hasSearchableText || v2.hasSearchableText)
            }
        }

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return batch.isEmpty || covered(batch)
            }
            guard status == SQLITE_ROW,
                  let pathText = sqlite3_column_text(statement, 0) else { return false }
            batch.append((
                path: String(cString: pathText),
                metadata: Metadata(
                    size: sqlite3_column_int64(statement, 1),
                    modifiedTime: sqlite3_column_double(statement, 2),
                    creationTime: sqlite3_column_double(statement, 3),
                    extractionVersion: Int(sqlite3_column_int(statement, 4)),
                    hasSearchableText: sqlite3_column_int(statement, 5) != 0,
                    requiresAuthoritativeScan: false,
                    containsRequiredLiteral: false
                )
            ))
            if batch.count == Self.queryChunkSize {
                guard covered(batch) else { return false }
                batch.removeAll(keepingCapacity: true)
            }
        }
    }

    private func deleteRows(
        where predicate: String,
        values: [String],
        database: OpaquePointer,
        integerValueIndex: Int? = nil
    ) -> Bool {
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(
                database,
                "SELECT DISTINCT content_id FROM documents WHERE content_id IS NOT NULL AND (\(predicate))",
                -1, &select, nil
              ) == SQLITE_OK,
              bind(values, integerValueIndex: integerValueIndex, to: select) else {
            captureError(database, context: "prepare invalidation lookup")
            sqlite3_finalize(select)
            return false
        }
        var contentIDs = Set<Int64>()
        while true {
            let status = sqlite3_step(select)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                captureError(database, context: "run invalidation lookup")
                sqlite3_finalize(select)
                return false
            }
            contentIDs.insert(sqlite3_column_int64(select, 0))
        }
        sqlite3_finalize(select)

        var delete: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM documents WHERE \(predicate)", -1, &delete, nil) == SQLITE_OK,
              bind(values, integerValueIndex: integerValueIndex, to: delete),
              sqlite3_step(delete) == SQLITE_DONE else {
            captureError(database, context: "run invalidation")
            sqlite3_finalize(delete)
            return false
        }
        sqlite3_finalize(delete)
        return deleteOrphanedContentBodies(contentIDs, database: database)
    }

    private func openIfNeeded() -> Bool {
        if database != nil { return true }
        if openDatabase() { return true }
        guard !recoveryAttempted else { return false }
        recoveryAttempted = true
        removeDatabaseFiles()
        return openDatabase()
    }

    private func openDatabase(allowEmptyRebuild: Bool = true) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { captureError(handle, context: "open") }
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        sqlite3_busy_timeout(handle, 5_000)
        guard execute("PRAGMA journal_mode=WAL", in: handle),
              execute("PRAGMA synchronous=NORMAL", in: handle),
              execute("PRAGMA temp_store=FILE", in: handle),
              execute("PRAGMA cache_size=-65536", in: handle),
              execute("PRAGMA wal_autocheckpoint=0", in: handle),
              execute("PRAGMA journal_size_limit=67108864", in: handle),
              execute("PRAGMA auto_vacuum=INCREMENTAL", in: handle),
              quickCheck(handle),
              initializeSchema(handle) else {
            sqlite3_close_v2(handle)
            return false
        }
        if allowEmptyRebuild,
           integerValue("SELECT count(*) FROM documents", in: handle) == 0,
           databaseStorageBytes() >= Self.oversizedEmptyDatabaseBytes {
            sqlite3_close_v2(handle)
            removeDatabaseFiles()
            return openDatabase(allowEmptyRebuild: false)
        }
        connection = SQLiteConnection(handle)
        recoveryAttempted = false
        return true
    }

    private func recreateEmptyDatabaseIfOversized() {
        guard let database,
              integerValue("SELECT count(*) FROM documents", in: database) == 0,
              databaseStorageBytes() >= Self.oversizedEmptyDatabaseBytes else { return }
        connection?.close()
        connection = nil
        removeDatabaseFiles()
        _ = openDatabase(allowEmptyRebuild: false)
    }

    private func initializeSchema(_ database: OpaquePointer) -> Bool {
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              sqlite3_step(versionStatement) == SQLITE_ROW else {
            sqlite3_finalize(versionStatement)
            return false
        }
        let existingVersion = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard existingVersion == 0 || existingVersion == Self.schemaVersion else { return false }

        return execute(
            """
            CREATE TABLE IF NOT EXISTS documents(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                modified REAL NOT NULL,
                created REAL NOT NULL,
                extractor INTEGER NOT NULL,
                state INTEGER NOT NULL,
                content_id INTEGER
            )
            """,
            in: database
        ) && execute(
            """
            CREATE TABLE IF NOT EXISTS content_bodies(
                id INTEGER PRIMARY KEY,
                digest BLOB NOT NULL,
                utf8_bytes INTEGER NOT NULL,
                UNIQUE(digest, utf8_bytes)
            )
            """,
            in: database
        ) && execute(
            "CREATE INDEX IF NOT EXISTS documents_content_id ON documents(content_id)",
            in: database
        ) && execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(
                body,
                content='',
                contentless_delete=1,
                detail=none,
                tokenize='trigram'
            )
            """,
            in: database
        // SQLite does not permit `columnsize=0` together with
        // `contentless_delete=1`. Keep the small docsize table so updates and
        // invalidations can delete old postings instead of leaking them until
        // a full rebuild.
        ) && execute("INSERT INTO content_fts(content_fts, rank) VALUES('automerge', 0)", in: database)
            && execute("INSERT INTO content_fts(content_fts, rank) VALUES('crisismerge', 64)", in: database)
            && execute("INSERT INTO content_fts(content_fts, rank) VALUES('usermerge', 8)", in: database)
            && execute("PRAGMA user_version=\(Self.schemaVersion)", in: database)
    }

    private func quickCheck(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            sqlite3_finalize(statement)
            return false
        }
        let isOkay = String(cString: value) == "ok"
        sqlite3_finalize(statement)
        return isOkay
    }

    private func integerValue(_ sql: String, in database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return 0
        }
        let value = Int(sqlite3_column_int64(statement, 0))
        sqlite3_finalize(statement)
        return value
    }

    private func execute(_ sql: String, in database: OpaquePointer) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let detail = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            lastErrorMessage = "SQL \(status): \(detail) [\(sql.prefix(80))]"
        }
        if let error { sqlite3_free(error) }
        return status == SQLITE_OK
    }

    private func captureError(_ database: OpaquePointer, context: String) {
        lastErrorMessage = "\(context): \(sqlite3_extended_errcode(database)) "
            + String(cString: sqlite3_errmsg(database))
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) -> Bool {
        let count = text.utf8.count
        guard count <= Int(Int32.max) else { return false }
        return text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, Int32(count), sqliteTransient) == SQLITE_OK
        }
    }

    private func bind(_ data: Data, to statement: OpaquePointer?, at index: Int32) -> Bool {
        guard data.count <= Int(Int32.max) else { return false }
        return data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient) == SQLITE_OK
        }
    }

    private func bindOptional(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) -> Bool {
        if let value {
            return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
        }
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }

    private func bind(
        _ values: [String],
        integerValueIndex: Int?,
        to statement: OpaquePointer?
    ) -> Bool {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            if integerValueIndex == offset {
                guard sqlite3_bind_int64(statement, index, Int64(value) ?? 0) == SQLITE_OK else {
                    return false
                }
            } else if !bind(value, to: statement, at: index) {
                return false
            }
        }
        return true
    }

    fileprivate static func contentDigest(_ text: String) -> Data {
        if let digest = text.utf8.withContiguousStorageIfAvailable({ bytes -> Data in
            guard let baseAddress = bytes.baseAddress else {
                return Data(SHA256.hash(data: Data()))
            }
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                count: bytes.count,
                deallocator: .none
            )
            return Data(SHA256.hash(data: data))
        }) {
            return digest
        }
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    private func deleteOrphanedContentBodies(
        _ contentIDs: Set<Int64>,
        database: OpaquePointer
    ) -> Bool {
        guard !contentIDs.isEmpty else { return true }
        var hasReference: OpaquePointer?
        var deleteFTS: OpaquePointer?
        var deleteBody: OpaquePointer?
        guard sqlite3_prepare_v2(
                database, "SELECT 1 FROM documents WHERE content_id=? LIMIT 1", -1, &hasReference, nil
              ) == SQLITE_OK,
              sqlite3_prepare_v2(database, "DELETE FROM content_fts WHERE rowid=?", -1, &deleteFTS, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "DELETE FROM content_bodies WHERE id=?", -1, &deleteBody, nil) == SQLITE_OK else {
            sqlite3_finalize(hasReference)
            sqlite3_finalize(deleteFTS)
            sqlite3_finalize(deleteBody)
            captureError(database, context: "prepare orphan cleanup")
            return false
        }
        defer {
            sqlite3_finalize(hasReference)
            sqlite3_finalize(deleteFTS)
            sqlite3_finalize(deleteBody)
        }

        for contentID in contentIDs {
            sqlite3_reset(hasReference)
            sqlite3_clear_bindings(hasReference)
            guard sqlite3_bind_int64(hasReference, 1, contentID) == SQLITE_OK else { return false }
            let referenceStatus = sqlite3_step(hasReference)
            if referenceStatus == SQLITE_ROW { continue }
            guard referenceStatus == SQLITE_DONE else {
                captureError(database, context: "check orphan content")
                return false
            }

            for statement in [deleteFTS, deleteBody] {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard sqlite3_bind_int64(statement, 1, contentID) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    captureError(database, context: "delete orphan content")
                    return false
                }
            }
        }
        return true
    }

    private func recoverIfCorrupt(_ database: OpaquePointer) {
        let code = sqlite3_extended_errcode(database)
        guard code == SQLITE_CORRUPT || code == SQLITE_NOTADB else { return }
        connection?.close()
        connection = nil
        recoveryAttempted = false
        removeDatabaseFiles()
    }

    private func removeDatabaseFiles() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    private func removeLegacyDatabaseFiles() {
        guard let legacyDatabaseURL,
              legacyDatabaseURL.standardizedFileURL != databaseURL.standardizedFileURL else { return }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: legacyDatabaseURL.path + suffix)
        }
    }

    private func databaseStorageBytes() -> Int64 {
        ["", "-wal", "-shm"].reduce(into: 0) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: databaseURL.path + suffix
            )
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    private func checkpointIfNeeded() {
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walBytes = ((try? walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let elapsed = ContinuousClock.now - lastCheckpoint
        guard Int64(walBytes) >= Self.checkpointWALBytes
                || (walBytes > 0 && elapsed >= Self.checkpointInterval) else { return }
        checkpoint(mode: "PASSIVE")
    }

    private func checkpoint(mode: String) {
        guard let database else { return }
        if execute("PRAGMA wal_checkpoint(\(mode))", in: database) {
            checkpointCount += 1
            lastCheckpoint = ContinuousClock.now
        }
    }
}

/// Resumable, low-priority content enrichment. It processes only formats that
/// OpenFind knows how to extract efficiently and asks the persistent index to
/// skip fresh fingerprints. Foreground search remains authoritative for every
/// file type and always takes precedence through `SearchWorkCoordinator`.
enum BackgroundContentIndexEnricher {
    private static let indexNodeBatchSize = 2_048
    // The byte ceiling is the normal commit boundary. The count ceiling keeps
    // millions of empty or tiny files from growing one metadata batch without
    // bound, while extracted text stays capped at 32 MiB.
    private static let recordBatchSize = 4_096
    private static let recordBatchBytes = 32 * 1_024 * 1_024

    private struct HardLinkIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
    }

    static func enrich(
        index: SearchIndex,
        contentIndex: ContentSearchIndex,
        maxFileSize: Int64,
        maximumDatabaseBytes: Int64 = 0
    ) async {
        var hadRetryableExtractionFailure = false
        for tier in BackgroundContentTier.allCases {
            for start in stride(from: 0, to: index.nodes.count, by: indexNodeBatchSize) {
                guard !Task.isCancelled else { return }
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
                guard !Task.isCancelled else { return }
                guard await BackgroundMemoryPressureMonitor.shared.waitUntilNormal() else { return }

                let end = min(start + indexNodeBatchSize, index.nodes.count)
                let candidates = index.backgroundContentCandidates(
                    in: start..<end,
                    maxFileSize: maxFileSize,
                    tier: tier
                )
                let staleCandidates = await contentIndex.enrichmentCandidates(candidates)
                var records: [ContentIndexRecord] = []
                records.reserveCapacity(recordBatchSize)
                var recordBytes = 0
                var hardLinkContent: [HardLinkIdentity: (text: String, digest: Data)] = [:]

                for node in staleCandidates {
                    guard !Task.isCancelled else { return }
                    SearchWorkCoordinator.shared.waitForSearchesToFinish()
                    guard !Task.isCancelled else { return }
                    guard await BackgroundMemoryPressureMonitor.shared.waitUntilNormal() else { return }

                    let hardLinkIdentity = hardLinkIdentity(for: node.path)
                    let record: ContentIndexRecord? = if let hardLinkIdentity,
                                                         let cached = hardLinkContent[hardLinkIdentity] {
                        ContentIndexRecord(
                            node: node,
                            text: cached.text,
                            digest: cached.digest,
                            reusedSourceIdentity: true
                        )
                    } else { autoreleasepool {
                        if let extracted = DocumentTextExtractor.extract(
                            from: node.url,
                            maxFileSize: maxFileSize
                        ) {
                            let digest = hardLinkIdentity.map { _ in
                                ContentSearchIndex.contentDigest(extracted.text)
                            }
                            if let hardLinkIdentity, let digest {
                                hardLinkContent[hardLinkIdentity] = (extracted.text, digest)
                            }
                            return ContentIndexRecord(
                                node: node,
                                text: extracted.text,
                                digest: digest
                            )
                        }
                        if DocumentTextExtractor.isStableNonTextFile(
                            node.url,
                            maxFileSize: maxFileSize
                        ) {
                            return ContentIndexRecord(node: node, text: nil)
                        }
                        hadRetryableExtractionFailure = true
                        return nil
                    } }
                    if let record {
                        recordBytes += record.text?.utf8.count ?? 0
                        records.append(record)
                    }

                    if records.count >= recordBatchSize || recordBytes >= recordBatchBytes {
                        let canContinue = await contentIndex.record(
                            records,
                            maximumDatabaseBytes: maximumDatabaseBytes
                        )
                        records.removeAll(keepingCapacity: true)
                        recordBytes = 0
                        hardLinkContent.removeAll(keepingCapacity: true)
                        if !canContinue {
                            await contentIndex.flush()
                            return
                        }
                    }
                }

                if !records.isEmpty {
                    let canContinue = await contentIndex.record(
                        records,
                        maximumDatabaseBytes: maximumDatabaseBytes
                    )
                    if !canContinue {
                        await contentIndex.flush()
                        return
                    }
                }
            }
        }
        await contentIndex.flush()
        if !hadRetryableExtractionFailure, !Task.isCancelled {
            await contentIndex.completeLegacyMigrationIfCovered()
        }
    }

    private static func hardLinkIdentity(for path: String) -> HardLinkIdentity? {
        var metadata = stat()
        let status = path.withCString { lstat($0, &metadata) }
        guard status == 0, metadata.st_nlink > 1 else { return nil }
        return HardLinkIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size)
        )
    }
}

/// System memory pressure pauses only optional background extraction. Name,
/// path, metadata, and foreground raw-file search remain available.
private final class BackgroundMemoryPressureMonitor: @unchecked Sendable {
    static let shared = BackgroundMemoryPressureMonitor()

    private let lock = NSLock()
    private var pressured = false
    private let source: DispatchSourceMemoryPressure

    private init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            lock.lock()
            pressured = event.contains(.warning) || event.contains(.critical)
            lock.unlock()
        }
        source.resume()
    }

    func waitUntilNormal() async -> Bool {
        while isPressured {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !Task.isCancelled
    }

    private var isPressured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressured
    }
}
