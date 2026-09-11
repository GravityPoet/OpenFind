import Foundation
import Testing
@testable import OpenFind

@Suite("Quick File Search")
struct QuickFileSearchTests {
    @Test func searchesFileAndFolderNamesWithoutExtractingContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "private body marker".write(to: root.appendingPathComponent("Sample.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sample Folder"), withIntermediateDirectories: true)
        let store = SearchIndexStore(persistenceURL: root.appendingPathComponent("index.bin"))
        let options = try #require(QuickFileSearch.options(for: "Sample", using: SearchOptions()))
        let results = await QuickFileSearch.search(scopes: [root], options: options, store: store)
        #expect(Set(results.results.map(\.name)) == Set(["Sample.txt", "Sample Folder"]))
        #expect(results.results.allSatisfy { !$0.matchedContent && $0.contentPreview == nil })
        await store.cancelActiveWorkForTermination()
    }

    @Test func quickSearchDoesNotInheritRegexOrContentModeAndRedirectsAdvancedQueries() throws {
        var preferences = SearchOptions()
        preferences.target = .content
        preferences.matchMode = .regex
        preferences.includePackages = true
        let quick = try #require(QuickFileSearch.options(for: "Sample", using: preferences))
        #expect(quick.target == .name)
        #expect(quick.matchMode == .substring)
        #expect(!quick.includePackages)
        #expect(quick.deepIndex == preferences.deepIndex)
        #expect(QuickFileSearch.options(for: "content:budget", using: preferences) == nil)
        #expect(QuickFileSearch.options(for: "tag:work", using: preferences) == nil)
        #expect(QuickFileSearch.options(for: "path:/Documents/Sample", using: preferences) == nil)
        #expect(preferences.target == .content && preferences.includePackages)
    }
}
