import AppKit
import Contacts
import Testing
@testable import OpenFind

@Suite("Quick Search Source Integration", .serialized)
struct QuickSearchSourcesTests {
    @Test func readsActualBrowserRootStructuresAndDeduplicatesAcrossProfiles() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let safari: [String: Any] = ["Children": [["Title": "com.apple.ReadingList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URIDictionary": ["title": "中文文档"], "URLString": "https://example.com/docs"]
        ]]]]
        let chrome: [String: Any] = ["roots": ["bookmark_bar": ["type": "folder", "name": "Work", "children": [
            ["type": "url", "name": "Duplicate", "url": "https://example.com/docs"],
            ["type": "url", "name": "Swift Manual", "url": "https://example.org/swift"],
            ["type": "url", "name": "Unsafe", "url": "javascript:alert(1)"]
        ]]]]
        let safariURL = root.appendingPathComponent("Bookmarks.plist")
        try PropertyListSerialization.data(fromPropertyList: safari, format: .binary, options: 0).write(to: safariURL)
        let profile = root.appendingPathComponent("Profile 1")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: chrome).write(to: profile.appendingPathComponent("Bookmarks"))
        let snapshot = BookmarkSearchIndex.discover(safariURL: safariURL, chromeRoots: [profile, profile])
        #expect(snapshot.records.count == 2)
        #expect(snapshot.records.first?.title == "中文文档")
        let chinese = BookmarkSearchIndex.search("zwwd", snapshot: snapshot, limit: 50)
        #expect(chinese.items.map(\.name) == ["中文文档"])
        #expect(chinese.items.first?.kind == .bookmark)
        #expect(BookmarkSearchIndex.search("swift", snapshot: snapshot, limit: 50).items.count == 1)
        #expect(BookmarkSearchIndex.search("", snapshot: snapshot, limit: 1).hasMore)
        try Data("broken".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        let damaged = BookmarkSearchIndex.discover(safariURL: safariURL, chromeRoots: [profile])
        #expect(damaged.records.count == 1 && damaged.message != nil)
    }

    @Test func contactsMatchCombinedNamesPinyinEmailAndPhoneWithoutReadingTheRealStore() {
        let contact = QuickContact(identifier: "fixture:ABPerson", name: "张三",
                                   emails: ["zhang@example.com"], phones: ["555-0100"], aliases: ["张三", "三张"])
        for query in ["张三", "zhangsan", "zs", "zhang@example.com", "555-0100"] {
            let response = ContactSearchIndex.search(query, contacts: [contact], limit: 50)
            #expect(response.items.count == 1)
            #expect(response.items.first?.action == .showContact(contact))
        }
        #expect(ContactSearchIndex.search("missing", contacts: [contact], limit: 50).items.isEmpty)
        #expect(contact.candidate.url.scheme == "openfind-contact")
        #expect(ContactSearchIndex.search("", contacts: [contact], limit: 1).items.count == 1)
    }

    @Test(arguments: ["sfl2", "sfl3", "sfl4"])
    func readsSystemRecentArchivesAndRetainsTheOpeningApplication(suffix: String) throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Budget.txt")
        try Data("local fixture".utf8).write(to: document)
        let bookmark = try document.bookmarkData(options: .minimalBookmark)
        let archive: [String: Any] = ["items": [["Bookmark": bookmark], ["Bookmark": bookmark]], "properties": [:]]
        let data = try NSKeyedArchiver.archivedData(withRootObject: archive, requiringSecureCoding: true)
        let app = ApplicationSearchResult(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "test.Fixture")
        let directory = root.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("test.fixture." + suffix))
        let response = RecentDocumentsSearch.search("budget", application: app, root: root)
        #expect(response.items.map(\.name) == ["Budget.txt"])
        #expect(response.items.first?.action == .openWithApplication(app.url))
        #expect(RecentDocumentsSearch.search("none", application: app, root: root).items.isEmpty)
        #expect(RecentDocumentsSearch.search("", root: root).items.isEmpty)
        try data.write(to: root.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments." + suffix))
        #expect(RecentDocumentsSearch.search("", root: root).items.first?.action == .open)
        try FileManager.default.removeItem(at: document)
        #expect(RecentDocumentsSearch.search("", application: app, root: root).items.isEmpty)
    }

    @Test func invalidRecentArchiveReturnsAVisibleError() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not an archive".utf8).write(to: root.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl4"))
        let response = RecentDocumentsSearch.search("", root: root)
        #expect(response.items.isEmpty && response.message != nil)
    }

    @Test func navigationKeepsHiddenFilesPackagesExactPathsAndMoreThanFiftyReachable() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Normal Folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.app"), withIntermediateDirectories: true)
        for i in 0..<61 { try Data().write(to: root.appendingPathComponent("File-\(i).txt")) }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("File-1.txt.backup"))
        let first = QuickPathSearch.search(root.path + "/", limit: 50)
        #expect(first.hasMore && first.items.count == 50)
        let all = QuickPathSearch.search(root.path + "/", limit: 100)
        #expect(!all.hasMore && all.items.count == 65)
        #expect(all.items.contains { $0.name == ".hidden" })
        #expect(all.items.first?.name == "Normal Folder")
        #expect(all.items.first { $0.name == "Fixture.app" }?.isDirectory == false)
        #expect(!QuickPathSearch.search(root.path + "/", limit: 100, includeHidden: false).items.contains { $0.name == ".hidden" })
        #expect(QuickPathSearch.search(root.path + "/File-1.txt").items.map(\.name) == ["File-1.txt"])
        #expect(QuickPathSearch.search(root.path + "/File-?.txt").items.count == 10)
        #expect(QuickPathSearch.parent(of: "/") == "/")
        #expect(QuickPathSearch.search(root.path + "/missing/folder/").message != nil)
    }

    @Test func webQueryEncodingCannotAddParametersOrFragments() throws {
        let term = "a &b=2 + 中文 #part ?next=1"
        for item in WebSearchIndex.results(for: term) {
            let components = try #require(URLComponents(url: item.url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.count == 1)
            #expect(components.queryItems?.first?.value == term)
            #expect(components.fragment == nil)
        }
        #expect(WebSearchIndex.directURL("https://example.com/path?q=a") != nil)
        #expect(WebSearchIndex.directURL("https://") == nil)
        #expect(WebSearchIndex.directURL("file:///tmp/file") == nil)
        #expect(WebSearchIndex.directURL("javascript:alert(1)") == nil)
    }

    @Test func arithmeticIsBoundedAndHandlesLargeNumbersAndInvalidInput() {
        for expression in ["", "1/0", "1%0", "1..2", "(1+2", "2+", "1 2", "sin(0)", String(repeating: "(", count: 513)] {
            #expect(QuickCalculator.evaluate(expression) == nil)
        }
        #expect(QuickCalculator.evaluate("9999999999999999999999999") != nil)
        #expect(QuickCalculator.evaluate("-(-4)+2.5*2") == "9")
        #expect(QuickCalculator.evaluate("10 % 3") == "1")
        #expect(QuickCalculator.evaluate(" 2 + 3 ") == "5")
        #expect(QuickDictionary.definition(for: "") == nil)
        #expect(QuickDictionary.definition(for: String(repeating: "a", count: 121)) == nil)
    }

    @Test func commandsPreserveApplicationNamesAndQuotedFullSearchTerms() throws {
        for name in ["Contacts", "Dictionary", "Settings", "Calculator", "Recent"] {
            #expect(QuickSearchCommand.parse(name).mode == .combined)
        }
        #expect(QuickSearchCommand.parse("contacts ").mode == .contacts)
        #expect(QuickSearchCommand.parse("bm ").mode == .bookmarks)
        #expect(QuickSearchCommand.parse(" report").mode == .open)
        let term = #"a\b "quoted" text"#
        let command = QuickSearchCommand.parse("in " + term)
        let plan = SearchQueryPlan.parse(command.fullSearchQuery)
        #expect(plan.explicitContentTerms == [term])
        let path = QuickSearchCommand.parse("/tmp/Folder With Spaces/*.txt")
        _ = try SearchQueryPlan.parse(path.fullSearchQuery).compile(options: .init())
        #expect(path.fullSearchQuery.contains("parent:\"/tmp/Folder With Spaces\""))
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Launcher-Fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
