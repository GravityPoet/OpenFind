import Foundation
import SQLite3
import Testing
@testable import OpenFind

@Suite("Content Search Index Tests", .serialized)
struct ContentSearchIndexTests {
    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindContentIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resolvedNode(for url: URL) throws -> ResolvedNode {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let created = attributes[.creationDate] as? Date ?? modified
        return ResolvedNode(
            node: IndexedFileNode(
                name: url.lastPathComponent,
                parentIndex: -1,
                isDirectory: false,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedTime: modified.timeIntervalSinceReferenceDate,
                creationTime: created.timeIntervalSinceReferenceDate,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
            path: url.path
        )
    }

    private func paths(_ plan: ContentIndexPlan) -> Set<String> {
        Set(plan.workItems.map { $0.node.path })
    }

    private func sqliteScalarText(databaseURL: URL, sql: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            sqlite3_finalize(statement)
            return nil
        }
        let value = String(cString: text)
        sqlite3_finalize(statement)
        return value
    }

    private func executeSQLite(databaseURL: URL, sql: String) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { return false }
        defer { sqlite3_close_v2(database) }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func createLegacyIndex(
        at databaseURL: URL,
        node: ResolvedNode,
        text: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        let schema = """
        CREATE TABLE documents(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            size INTEGER NOT NULL,
            modified REAL NOT NULL,
            created REAL NOT NULL,
            extractor INTEGER NOT NULL,
            state INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE content_fts USING fts5(
            body,
            content='',
            contentless_delete=1,
            tokenize='trigram'
        );
        PRAGMA user_version=2;
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        var documentStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO documents(path,size,modified,created,extractor,state) VALUES(?,?,?,?,?,1)",
            -1,
            &documentStatement,
            nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(documentStatement) }
        sqlite3_bind_text(documentStatement, 1, node.path, -1, sqliteTransient)
        sqlite3_bind_int64(documentStatement, 2, node.size)
        sqlite3_bind_double(documentStatement, 3, node.modifiedTime)
        sqlite3_bind_double(documentStatement, 4, node.creationTime)
        sqlite3_bind_int(documentStatement, 5, Int32(DocumentTextExtractor.extractionVersion))
        guard sqlite3_step(documentStatement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rowID = sqlite3_last_insert_rowid(database)
        var ftsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO content_fts(rowid,body) VALUES(?,?)",
            -1,
            &ftsStatement,
            nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(ftsStatement) }
        sqlite3_bind_int64(ftsStatement, 1, rowID)
        sqlite3_bind_text(ftsStatement, 2, text, -1, sqliteTransient)
        guard sqlite3_step(ftsStatement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @Test func warmIndexSkipsOnlyFreshNonMatchesAndSurvivesRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("content.sqlite3")
        let alphaURL = root.appendingPathComponent("alpha.txt")
        let betaURL = root.appendingPathComponent("beta.txt")
        try "persistentneedle alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "unrelated beta".write(to: betaURL, atomically: true, encoding: .utf8)
        let alpha = try resolvedNode(for: alphaURL)
        let beta = try resolvedNode(for: betaURL)
        let candidates = [alpha, beta].map { ContentIndexCandidate(node: $0, forceRefresh: false) }

        let first = ContentSearchIndex(databaseURL: databaseURL)
        let coldPlan = await first.plan(candidates: candidates, requiredLiteral: "persistentneedle")
        #expect(paths(coldPlan) == [alpha.path, beta.path])
        #expect(coldPlan.workItems.allSatisfy { $0.shouldRecord })

        await first.record([
            ContentIndexRecord(node: alpha, text: "persistentneedle alpha"),
            ContentIndexRecord(node: beta, text: "unrelated beta"),
        ])
        let warmPlan = await first.plan(candidates: candidates, requiredLiteral: "persistentneedle")
        #expect(paths(warmPlan) == [alpha.path])
        #expect(warmPlan.workItems.first?.shouldRecord == false)
        #expect(warmPlan.skippedFreshNonMatches == 1)
        let beforeRestart = await first.diagnostics()
        #expect(beforeRestart.indexedDocuments == 2)
        await first.flush()
        await first.close()

        let restarted = ContentSearchIndex(databaseURL: databaseURL)
        let afterRestart = await restarted.diagnostics()
        #expect(afterRestart.lastError == nil)
        #expect(afterRestart.indexedDocuments == 2)
        let restartedPlan = await restarted.plan(candidates: candidates, requiredLiteral: "persistentneedle")
        #expect(paths(restartedPlan) == [alpha.path])
        #expect(restartedPlan.skippedFreshNonMatches == 1)
        await restarted.close()
    }

    @Test func backgroundEnrichmentSkipsFreshDocumentsAndKeepsStaleOnes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.txt")
        let secondURL = root.appendingPathComponent("second.txt")
        try "first body".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second body".write(to: secondURL, atomically: true, encoding: .utf8)
        let first = try resolvedNode(for: firstURL)
        let second = try resolvedNode(for: secondURL)
        let index = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))

        #expect(Set(await index.enrichmentCandidates([first, second]).map(\.path)) == [first.path, second.path])
        await index.record([ContentIndexRecord(node: first, text: "first body")])
        #expect(await index.enrichmentCandidates([first, second]).map(\.path) == [second.path])

        try "first body is now larger".write(to: firstURL, atomically: true, encoding: .utf8)
        let changedFirst = try resolvedNode(for: firstURL)
        #expect(Set(await index.enrichmentCandidates([changedFirst, second]).map(\.path)) == [changedFirst.path, second.path])
    }

    @Test func backgroundEnrichmentIndexesKnownTextWithoutMakingUnknownTypesIneligible() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("known.txt")
        let unknownURL = root.appendingPathComponent("still-searchable.unknownbinary")
        try "known background body".write(to: textURL, atomically: true, encoding: .utf8)
        try "unknown foreground body".write(to: unknownURL, atomically: true, encoding: .utf8)
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let nodes = await SearchIndexBuilder.build(signature: signature)
        let fileIndex = SearchIndex(signature: signature, nodes: nodes, pathsAreFresh: true)
        let contentIndex = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))

        await BackgroundContentIndexEnricher.enrich(
            index: fileIndex,
            contentIndex: contentIndex,
            maxFileSize: 1 * 1_024 * 1_024
        )

        #expect((await contentIndex.diagnostics()).indexedDocuments == 1)
        let unknown = try resolvedNode(for: unknownURL)
        let plan = await contentIndex.plan(
            candidates: [ContentIndexCandidate(node: unknown, forceRefresh: false)],
            requiredLiteral: "foreground"
        )
        #expect(plan.workItems.map { $0.node.path } == [unknown.path])
        #expect(plan.workItems.first?.shouldRecord == true)
    }

    @Test func createModifyDeleteRenameAndLostEventsReturnToAuthoritativeWork() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))
        let firstURL = root.appendingPathComponent("first.txt")
        let secondURL = root.appendingPathComponent("second.txt")
        try "old first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "old second".write(to: secondURL, atomically: true, encoding: .utf8)
        let first = try resolvedNode(for: firstURL)
        let second = try resolvedNode(for: secondURL)
        await index.record([
            ContentIndexRecord(node: first, text: "old first"),
            ContentIndexRecord(node: second, text: "old second"),
        ])

        try "eventneedle changed first with a different size".write(
            to: firstURL,
            atomically: true,
            encoding: .utf8
        )
        let modifiedFirst = try resolvedNode(for: firstURL)
        var plan = await index.plan(
            candidates: [
                ContentIndexCandidate(node: modifiedFirst, forceRefresh: false),
                ContentIndexCandidate(node: second, forceRefresh: false),
            ],
            requiredLiteral: "eventneedle"
        )
        #expect(paths(plan) == [modifiedFirst.path])
        #expect(plan.workItems.first?.shouldRecord == true)
        await index.record([ContentIndexRecord(node: modifiedFirst, text: "eventneedle changed first")])

        let createdURL = root.appendingPathComponent("created.txt")
        try "eventneedle created".write(to: createdURL, atomically: true, encoding: .utf8)
        let created = try resolvedNode(for: createdURL)
        plan = await index.plan(
            candidates: [ContentIndexCandidate(node: created, forceRefresh: false)],
            requiredLiteral: "eventneedle"
        )
        #expect(paths(plan) == [created.path])
        #expect(plan.workItems.first?.shouldRecord == true)

        await index.invalidate(exactPaths: [modifiedFirst.path], subtreePaths: [])
        let afterExactInvalidation = await index.diagnostics()
        #expect(afterExactInvalidation.lastError == nil)
        #expect(afterExactInvalidation.indexedDocuments == 1)
        plan = await index.plan(
            candidates: [ContentIndexCandidate(node: modifiedFirst, forceRefresh: false)],
            requiredLiteral: "eventneedle"
        )
        #expect(paths(plan) == [modifiedFirst.path])
        #expect(plan.workItems.first?.shouldRecord == true)

        let renamedURL = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: secondURL, to: renamedURL)
        let renamed = try resolvedNode(for: renamedURL)
        plan = await index.plan(
            candidates: [ContentIndexCandidate(node: renamed, forceRefresh: false)],
            requiredLiteral: "eventneedle"
        )
        #expect(paths(plan) == [renamed.path])
        #expect(plan.workItems.first?.shouldRecord == true)

        await index.invalidateAll()
        plan = await index.plan(
            candidates: [
                ContentIndexCandidate(node: modifiedFirst, forceRefresh: false),
                ContentIndexCandidate(node: renamed, forceRefresh: false),
            ],
            requiredLiteral: "eventneedle"
        )
        #expect(paths(plan) == [modifiedFirst.path, renamed.path])
        #expect(plan.workItems.allSatisfy { $0.shouldRecord })
    }

    @Test func corruptDatabaseIsRecreatedAndNeverSuppressesCandidates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("content.sqlite3")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let fileURL = root.appendingPathComponent("recover.txt")
        try "recoveryneedle".write(to: fileURL, atomically: true, encoding: .utf8)
        let node = try resolvedNode(for: fileURL)
        let candidate = ContentIndexCandidate(node: node, forceRefresh: false)

        let index = ContentSearchIndex(databaseURL: databaseURL)
        var plan = await index.plan(candidates: [candidate], requiredLiteral: "recoveryneedle")
        #expect(paths(plan) == [node.path])
        #expect(plan.workItems.first?.shouldRecord == true)

        await index.record([ContentIndexRecord(node: node, text: "recoveryneedle")])
        plan = await index.plan(candidates: [candidate], requiredLiteral: "recoveryneedle")
        #expect(paths(plan) == [node.path])
        #expect(plan.workItems.first?.shouldRecord == false)
    }

    @Test func shortUnicodeAndForcedRefreshQueriesNeverUseFTSToExclude() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("unicode.txt")
        try "你好世界 abc".write(to: fileURL, atomically: true, encoding: .utf8)
        let node = try resolvedNode(for: fileURL)
        let index = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))
        await index.record([ContentIndexRecord(node: node, text: "你好世界 abc")])

        for literal in ["ab", "你好世界"] {
            let plan = await index.plan(
                candidates: [ContentIndexCandidate(node: node, forceRefresh: false)],
                requiredLiteral: literal
            )
            #expect(paths(plan) == [node.path])
            #expect(plan.workItems.first?.shouldRecord == true)
        }

        let forced = await index.plan(
            candidates: [ContentIndexCandidate(node: node, forceRefresh: true)],
            requiredLiteral: "abc"
        )
        #expect(paths(forced) == [node.path])
        #expect(forced.workItems.first?.shouldRecord == true)
    }

    @Test func compactDetailNoneIndexUsesLosslessTrigramIntersection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("content-v2.sqlite3")
        let legacyURL = root.appendingPathComponent("content-v1.sqlite3")
        try Data("rebuildable legacy cache".utf8).write(to: legacyURL)
        let fileURL = root.appendingPathComponent("scattered.txt")
        try "authoritative file body".write(to: fileURL, atomically: true, encoding: .utf8)
        let node = try resolvedNode(for: fileURL)
        let candidate = ContentIndexCandidate(node: node, forceRefresh: false)
        let index = ContentSearchIndex(databaseURL: databaseURL, legacyDatabaseURL: legacyURL)

        // Every trigram exists, but not adjacently. The compact prefilter must
        // keep this false-positive candidate for authoritative raw scanning.
        await index.record([
            ContentIndexRecord(node: node, text: "abc separated bcd separated cde separated def"),
        ])
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        let possibleMatch = await index.plan(candidates: [candidate], requiredLiteral: "abcdef")
        #expect(paths(possibleMatch) == [node.path])
        #expect(possibleMatch.workItems.first?.shouldRecord == false)

        let provenNonMatch = await index.plan(candidates: [candidate], requiredLiteral: "abcxyz")
        #expect(provenNonMatch.workItems.isEmpty)
        #expect(provenNonMatch.skippedFreshNonMatches == 1)

        let diagnostics = await index.diagnostics()
        #expect(diagnostics.schemaVersion == 4)
        #expect(diagnostics.recordTransactions == 1)
        #expect(diagnostics.walAutoCheckpointPages == 0)
        #expect(diagnostics.tempStoreMode == 1)
        await index.flush()
        await index.close()

        let definition = sqliteScalarText(
            databaseURL: databaseURL,
            sql: "SELECT sql FROM sqlite_master WHERE name='content_fts'"
        )?.lowercased()
        #expect(definition?.contains("detail=none") == true)
        #expect(definition?.contains("contentless_delete=1") == true)
        #expect(definition?.contains("columnsize=0") == false)
    }

    @Test func legacyIndexAcceleratesUntilV2CoverageIsComplete() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("legacy.txt")
        try "legacyneedle searchable body".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        let node = try resolvedNode(for: fileURL)
        let legacyURL = root.appendingPathComponent("content-v1.sqlite3")
        try createLegacyIndex(at: legacyURL, node: node, text: "legacyneedle searchable body")
        let index = ContentSearchIndex(
            databaseURL: root.appendingPathComponent("content-v2.sqlite3"),
            legacyDatabaseURL: legacyURL
        )
        let candidate = ContentIndexCandidate(node: node, forceRefresh: false)

        let legacyMatch = await index.plan(candidates: [candidate], requiredLiteral: "legacyneedle")
        #expect(paths(legacyMatch) == [node.path])
        #expect(legacyMatch.workItems.first?.shouldRecord == true)
        let legacyNonMatch = await index.plan(candidates: [candidate], requiredLiteral: "absentneedle")
        #expect(legacyNonMatch.workItems.isEmpty)
        #expect(legacyNonMatch.skippedFreshNonMatches == 1)

        await index.record([ContentIndexRecord(node: node, text: nil)])
        await index.completeLegacyMigrationIfCovered()
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        await index.record([ContentIndexRecord(node: node, text: "legacyneedle searchable body")])
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        await index.completeLegacyMigrationIfCovered()
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func backgroundEnrichmentUsesBoundedContentTransactions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<520 {
            try "batched content \(index)".write(
                to: root.appendingPathComponent("batch-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let nodes = await SearchIndexBuilder.build(signature: signature)
        let fileIndex = SearchIndex(signature: signature, nodes: nodes, pathsAreFresh: true)
        let contentIndex = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))

        await BackgroundContentIndexEnricher.enrich(
            index: fileIndex,
            contentIndex: contentIndex,
            maxFileSize: 1 * 1_024 * 1_024
        )

        let diagnostics = await contentIndex.diagnostics()
        #expect(diagnostics.indexedDocuments == 520)
        #expect(diagnostics.recordTransactions == 1)
        #expect(diagnostics.checkpoints == 1)
    }

    @Test func backgroundReconciliationReadsMetadataWithoutQueryingFTS() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("metadata-only.txt")
        try "first body".write(to: fileURL, atomically: true, encoding: .utf8)
        let original = try resolvedNode(for: fileURL)
        let databaseURL = root.appendingPathComponent("content.sqlite3")
        let index = ContentSearchIndex(databaseURL: databaseURL)
        #expect(await index.record([
            ContentIndexRecord(node: original, text: "first body"),
        ]))
        #expect(await index.enrichmentCandidates([original]).isEmpty)

        try "changed body".write(to: fileURL, atomically: true, encoding: .utf8)
        let changed = try resolvedNode(for: fileURL)
        #expect(executeSQLite(databaseURL: databaseURL, sql: "DROP TABLE content_fts"))

        let stale = await index.enrichmentCandidates([changed])
        #expect(stale.map(\.path) == [changed.path])
    }

    @Test func subtreeInvalidationUsesExactDirectoryBoundaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("folder", isDirectory: true)
        let nested = target.appendingPathComponent("nested", isDirectory: true)
        let sibling = root.appendingPathComponent("folder0", isDirectory: true)
        let lexicalSibling = root.appendingPathComponent("folderish", isDirectory: true)
        for directory in [nested, sibling, lexicalSibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let urls = [
            target.appendingPathComponent("inside.txt"),
            nested.appendingPathComponent("deep.txt"),
            sibling.appendingPathComponent("sibling.txt"),
            lexicalSibling.appendingPathComponent("outside.txt"),
        ]
        for (offset, url) in urls.enumerated() {
            try "body \(offset)".write(to: url, atomically: true, encoding: .utf8)
        }
        let records = try urls.enumerated().map { offset, url in
            ContentIndexRecord(node: try resolvedNode(for: url), text: "body \(offset)")
        }
        let index = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))
        #expect(await index.record(records))

        await index.invalidate(exactPaths: [], subtreePaths: [target.path])

        let diagnostics = await index.diagnostics()
        #expect(diagnostics.indexedDocuments == 2)
        let survivors = try [urls[2], urls[3]].map { try resolvedNode(for: $0) }
        #expect(await index.enrichmentCandidates(survivors).isEmpty)
    }

    @Test func duplicateBodiesSharePostingsButNeverSuppressDuplicatePaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first-copy.txt")
        let secondURL = root.appendingPathComponent("second-copy.txt")
        try "shared duplicate body".write(to: firstURL, atomically: true, encoding: .utf8)
        try "shared duplicate body".write(to: secondURL, atomically: true, encoding: .utf8)
        let first = try resolvedNode(for: firstURL)
        let second = try resolvedNode(for: secondURL)
        let index = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))
        await index.record([
            ContentIndexRecord(node: first, text: "shared duplicate body"),
            ContentIndexRecord(node: second, text: "shared duplicate body"),
        ])

        var diagnostics = await index.diagnostics()
        #expect(diagnostics.indexedDocuments == 2)
        #expect(diagnostics.uniqueContentBodies == 1)
        #expect(diagnostics.deduplicatedDocuments == 1)

        let candidates = [first, second].map {
            ContentIndexCandidate(node: $0, forceRefresh: false)
        }
        let match = await index.plan(candidates: candidates, requiredLiteral: "duplicate")
        #expect(paths(match) == [first.path, second.path])

        // The canonical row can be excluded by a missing posting. The digest-
        // shared path remains on raw scan so a hypothetical hash collision can
        // never turn storage deduplication into a false negative.
        let nonMatch = await index.plan(candidates: candidates, requiredLiteral: "missing")
        #expect(paths(nonMatch) == [second.path])
        #expect(nonMatch.workItems.first?.shouldRecord == false)

        await index.invalidate(exactPaths: [first.path], subtreePaths: [])
        diagnostics = await index.diagnostics()
        #expect(diagnostics.indexedDocuments == 1)
        #expect(diagnostics.uniqueContentBodies == 1)
        await index.invalidate(exactPaths: [second.path], subtreePaths: [])
        diagnostics = await index.diagnostics()
        #expect(diagnostics.indexedDocuments == 0)
        #expect(diagnostics.uniqueContentBodies == 0)
    }

    @Test func diskBudgetStopsOptionalWritesButLeavesCandidatesAuthoritative() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("budget.txt")
        try "budgetneedle remains searchable".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        let node = try resolvedNode(for: fileURL)
        let index = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))

        let canContinue = await index.record(
            [ContentIndexRecord(node: node, text: "budgetneedle remains searchable")],
            maximumDatabaseBytes: 1
        )
        #expect(!canContinue)
        let diagnostics = await index.diagnostics()
        #expect(diagnostics.indexedDocuments == 0)
        #expect(diagnostics.budgetStops == 1)

        let plan = await index.plan(
            candidates: [ContentIndexCandidate(node: node, forceRefresh: false)],
            requiredLiteral: "budgetneedle"
        )
        #expect(plan.workItems.map { $0.node.path } == [node.path])
        #expect(plan.workItems.first?.shouldRecord == true)
    }

    @Test func backgroundEnrichmentReusesHardLinkExtractionBeforeHashDeduplication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let linked = root.appendingPathComponent("linked.txt")
        try "hardlink shared searchable body".write(
            to: original,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.linkItem(at: original, to: linked)

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let nodes = await SearchIndexBuilder.build(signature: signature)
        let fileIndex = SearchIndex(signature: signature, nodes: nodes, pathsAreFresh: true)
        let contentIndex = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))
        await BackgroundContentIndexEnricher.enrich(
            index: fileIndex,
            contentIndex: contentIndex,
            maxFileSize: 1 * 1_024 * 1_024
        )

        let diagnostics = await contentIndex.diagnostics()
        #expect(diagnostics.indexedDocuments == 2)
        #expect(diagnostics.uniqueContentBodies == 1)
        #expect(diagnostics.deduplicatedDocuments == 1)
        #expect(diagnostics.sourceIdentityReuses == 1)
    }
}
