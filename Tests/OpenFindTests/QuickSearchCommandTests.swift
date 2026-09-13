import Foundation
import Testing
@testable import OpenFind

@Suite("Quick Search Commands")
struct QuickSearchCommandTests {
    @Test func parsesAlfredStyleModesWithoutChangingPlainSearch() {
        #expect(QuickSearchCommand.parse("report").mode == .combined)
        #expect(QuickSearchCommand.parse("open report.pdf") == .init(mode: .open, term: "report.pdf"))
        #expect(QuickSearchCommand.parse("find report").mode == .find)
        #expect(QuickSearchCommand.parse("in annual budget").mode == .content)
        #expect(QuickSearchCommand.parse("tags Work").mode == .tags)
        #expect(QuickSearchCommand.parse("bm docs").mode == .bookmarks)
        #expect(QuickSearchCommand.parse("contacts Evans").mode == .contacts)
        #expect(QuickSearchCommand.parse("web OpenFind").mode == .web)
        #expect(QuickSearchCommand.parse("/Users").mode == .path)
        #expect(QuickSearchCommand.parse("~/Documents").mode == .path)
    }

    @Test func transfersContentAndTagCommandsToFullSearchSyntax() {
        #expect(QuickSearchCommand.parse("in annual budget").fullSearchQuery == "content:\"annual budget\"")
        #expect(QuickSearchCommand.parse("tags Work").fullSearchQuery == "tag:\"Work\"")
        #expect(QuickSearchCommand.parse("in say \"hi\"").fullSearchQuery == "content:\"say \\\"hi\\\"\"")
    }

    @Test func parsesSafariAndChromeBookmarkRecords() {
        let safari: [String: Any] = [
            "Title": "Bookmarks",
            "Children": [[
                "Title": "OpenFind",
                "URLString": "https://openfind.example",
                "WebBookmarkType": "WebBookmarkTypeLeaf"
            ]]
        ]
        let chrome: [String: Any] = [
            "name": "Bookmarks bar",
            "type": "folder",
            "children": [[
                "name": "Docs",
                "type": "url",
                "url": "https://docs.example"
            ]]
        ]
        #expect(BookmarkSearchIndex.safariRecords(from: safari).map(\.title) == ["OpenFind"])
        #expect(BookmarkSearchIndex.chromeRecords(from: chrome).map(\.title) == ["Docs"])
    }

    @Test func buildsWebSearchChoicesWithoutPerformingNetworkRequests() {
        let results = WebSearchIndex.results(for: "OpenFind")
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0.url.scheme == "https" })
        #expect(results.map(\.name).contains("Google"))
    }

    @Test func calculatorAndDictionaryCommandsAreExplicit() {
        #expect(QuickSearchCommand.parse("calculator 2 + 3 * 4").mode == .calculator)
        #expect(QuickCalculator.evaluate("2 + 3 * 4") == "14")
        #expect(QuickCalculator.evaluate("(10 - 4) / 2") == "3")
        #expect(QuickCalculator.evaluate("10 / 0") == nil)
        #expect(QuickSearchCommand.parse("define launch").mode == .dictionary)
    }

    @Test func quickPathSearchListsFoldersAndFilesWithWildcard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Report-01.txt"))
        try Data().write(to: root.appendingPathComponent("Notes.md"))
        defer { try? FileManager.default.removeItem(at: root) }

        let response = QuickPathSearch.search(root.path + "/Report-*.txt")
        #expect(response.items.map(\.name) == ["Report-01.txt"])
        let children = QuickPathSearch.search(root.path + "/")
        #expect(children.items.first?.name == "Folder")
        #expect(QuickPathSearch.parent(of: root.path + "/Folder/") == root.path + "/")
    }

    @Test func systemCommandsAreExplicitAndBoundedToKnownActions() {
        let results = QuickSystemCommands.results(for: "lock")
        #expect(results.count == 1)
        #expect(results.first?.action == .system(.lockScreen))
        #expect(QuickSystemCommands.results(for: "rm -rf").isEmpty)
        #expect(QuickSearchCommand.parse("system lock").mode == .system)
    }
    @MainActor @Test func systemActionsUseCheckedAdaptersAndPropagateFailures() throws {
        let performer = QuickSystemTestPerformer()
        #expect(throws: QuickSystemCommandError.self) {
            try QuickSystemCommands.run(.lockScreen, performer: performer)
        }
        #expect(!performer.locked)
        performer.isAccessibilityTrusted = true
        try QuickSystemCommands.run(.lockScreen, performer: performer)
        #expect(performer.locked)
        #expect(throws: QuickSystemCommandError.self) {
            try QuickSystemCommands.run(.screenSaver, performer: performer, openScreenSaver: { _ in false })
        }
        #expect(throws: QuickSystemCommandError.self) {
            try QuickSystemCommands.run(.sleep, performer: performer, sleepSystem: { false })
        }
        try QuickSystemCommands.run(.sleep, performer: performer, sleepSystem: { true })
    }

}


@MainActor private final class QuickSystemTestPerformer: SessionActivityPerforming {
    var isAccessibilityTrusted = false
    var locked = false
    func idleSeconds(useCursorMovement: Bool) -> TimeInterval { 0 }
    func isScreenSaverActive() -> Bool { false }
    func isScreenLocked() -> Bool { locked }
    func moveCursor(speed: CursorMovementSpeed) {}
    func lockScreen() { locked = true }
}
