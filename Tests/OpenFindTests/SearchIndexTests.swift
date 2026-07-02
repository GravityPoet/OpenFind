import Foundation
import Testing
@testable import OpenFind

@Suite("SearchIndex Tests")
struct SearchIndexTests {
    private func createTempDirectory() throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenFindIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func writeFile(at url: URL, content: String = "") throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func indexedNameSearchFindsFilesWithoutTraversalOptions() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let visible = root.appendingPathComponent("cardinal_report.txt")
        let hidden = root.appendingPathComponent(".cardinal_secret.txt")
        try writeFile(at: visible)
        try writeFile(at: hidden)

        var options = SearchOptions()
        options.query = "cardinal"
        options.target = .name

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["cardinal_report.txt"])

        options.includeHidden = true
        let hiddenResults = await collect(scopes: [root], options: options)
        #expect(Set(hiddenResults.map(\.name)) == Set(["cardinal_report.txt", ".cardinal_secret.txt"]))
    }

    @Test func contentSearchUsesIndexedCandidates() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("name_only.txt"), content: "nothing")
        try writeFile(at: root.appendingPathComponent("body.txt"), content: "needle in content")

        var options = SearchOptions()
        options.query = "needle"
        options.target = .content

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["body.txt"])
        #expect(results.first?.matchedContent == true)
    }

    @Test func eventPathCollapseKeepsMinimalAncestors() {
        let root = URL(fileURLWithPath: "/tmp/openfind-index")
        let signature = SearchIndexSignature(scopes: [root])
        let collapsed = SearchIndexBuilder.collapseEventPaths(
            [
                "/tmp/openfind-index/a/b/file.txt",
                "/tmp/openfind-index/a",
                "/tmp/openfind-index/z.txt",
                "/tmp/outside.txt",
            ],
            signature: signature
        )

        #expect(collapsed == ["/tmp/openfind-index/a", "/tmp/openfind-index/z.txt"])
    }

    @Test func querySyntaxFiltersIndexedResults() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try writeFile(at: root.appendingPathComponent("report.pdf"), content: "short")
        try writeFile(at: root.appendingPathComponent("report.txt"), content: "short")
        try writeFile(at: root.appendingPathComponent("draft_report.pdf"), content: "short")
        try writeFile(at: archive.appendingPathComponent("archive_report.pdf"), content: "short")
        try writeFile(at: root.appendingPathComponent("large.bin"), content: String(repeating: "x", count: 256))

        var options = SearchOptions()
        options.target = .name

        // Relevance ranking puts the stem-exact hit before the word-boundary hit.
        options.query = "report ext:pdf !draft"
        var results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["report.pdf", "archive_report.pdf"])

        options.query = "path:Archive"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["Archive", "archive_report.pdf"]))

        options.query = "size:>100b"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["large.bin"])

        options.query = "folder:Archive"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["Archive"])
    }

    @Test func contentFilterRunsEvenWhenTargetIsName() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("budget.txt"), content: "q3 actuals")
        try writeFile(at: root.appendingPathComponent("notes.txt"), content: "q3 actuals")
        try writeFile(at: root.appendingPathComponent("budget.md"), content: "q3 actuals")
        try writeFile(at: root.appendingPathComponent("budget_empty.txt"), content: "nothing")

        var options = SearchOptions()
        options.target = .name
        options.query = "budget ext:txt content:q3"

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["budget.txt"])
        #expect(results.first?.matchedContent == true)
    }

    @Test func nameResultsRankByMatchQuality() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("myreport.txt"))
        try writeFile(at: root.appendingPathComponent("draft_report.pdf"))
        try writeFile(at: root.appendingPathComponent("reports_2024.txt"))
        try writeFile(at: root.appendingPathComponent("report.pdf"))

        var options = SearchOptions()
        options.target = .name
        options.query = "report"

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == [
            "report.pdf",       // stem exact
            "reports_2024.txt", // prefix
            "draft_report.pdf", // word boundary
            "myreport.txt",     // bare substring
        ])
    }

    @Test func normalizedPrefixMatchesContainmentSemantics() {
        #expect(SearchPath.hasNormalizedPrefix("/a/b/c", of: "/a/b"))
        #expect(SearchPath.hasNormalizedPrefix("/a/b", of: "/a/b"))
        #expect(!SearchPath.hasNormalizedPrefix("/a/bc", of: "/a/b"))
        #expect(!SearchPath.hasNormalizedPrefix("/a", of: "/a/b"))
        #expect(SearchPath.hasNormalizedPrefix("/a", of: "/"))
    }

    @Test func modifiedDateFilterMatchesIsoDay() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = root.appendingPathComponent("old.txt")
        let newFile = root.appendingPathComponent("new.txt")
        try writeFile(at: oldFile)
        try writeFile(at: newFile)

        let oldDate = try #require(DatePredicate.parse("2024-01-02").flatMap { predicate -> Date? in
            if case .comparison(_, let date) = predicate.kind { return date }
            return nil
        })
        let newDate = try #require(DatePredicate.parse("2025-02-03").flatMap { predicate -> Date? in
            if case .comparison(_, let date) = predicate.kind { return date }
            return nil
        })
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newFile.path)

        var options = SearchOptions()
        options.target = .name
        options.query = "dm:2025-02-03"

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["new.txt"])
    }

    private func collect(scopes: [URL], options: SearchOptions) async -> [SearchResult] {
        let store = SearchIndexStore()
        var results: [SearchResult] = []
        for await result in SearchEngine.search(scopes: scopes, options: options, store: store) {
            results.append(result)
        }
        return results
    }

    @Test func testBinarySerializationRoundTrip() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("file1.txt"))
        try writeFile(at: root.appendingPathComponent("file2.txt"))

        let signature = SearchIndexSignature(scopes: [root])
        let nodes = await SearchIndexBuilder.build(signature: signature)
        let originalIndex = SearchIndex(signature: signature, nodes: nodes)

        let testIndexURL = root.appendingPathComponent("search-index-test.bin")
        SearchIndexPersistence.save(index: originalIndex, to: testIndexURL)

        let loadedIndex = try #require(SearchIndexPersistence.load(signature: signature, from: testIndexURL))
        #expect(loadedIndex.signature == originalIndex.signature)
        #expect(loadedIndex.nodes.count == originalIndex.nodes.count)

        let originalPaths = (0..<originalIndex.nodes.count).map { originalIndex.path(for: $0) }
        let loadedPaths = (0..<loadedIndex.nodes.count).map { loadedIndex.path(for: $0) }
        #expect(Set(originalPaths) == Set(loadedPaths))
    }

    @Test func testIncrementalIndexingReturnsPartialResults() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sub1 = root.appendingPathComponent("dir1")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try writeFile(at: sub1.appendingPathComponent("apple_in_dir1.txt"))

        let sub2 = root.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        try writeFile(at: sub2.appendingPathComponent("apple_in_dir2.txt"))

        let store = SearchIndexStore()
        let prepareTask = Task {
            await store.prepare(scopes: [root])
        }

        try? await Task.sleep(for: .milliseconds(50))

        let partialIndex = await store.snapshot(for: [root])
        #expect(partialIndex.signature.scopes == [root.path])

        _ = await prepareTask.value

        let finalIndex = await store.snapshot(for: [root])
        #expect(finalIndex.nodes.count > 0)
    }
}
