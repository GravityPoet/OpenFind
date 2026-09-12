import AppKit
import Carbon
import Testing
@testable import OpenFind

@MainActor
@Suite("Quick Search Interaction", .serialized)
struct QuickSearchTests {
    @Test func appResultsArriveBeforeFilesAndKeepKeyboardSelection() async throws {
        let app = application("OpenFind")
        let file = fileResult("OpenFind Notes.txt")
        let model = QuickSearchViewModel(
            searchApplications: { _ in [app] },
            searchSettings: { _ in [] },
            searchFiles: { _ in
                try? await Task.sleep(for: .milliseconds(150))
                return QuickSearchFileResponse(results: [file])
            }
        )
        defer { model.cancel() }
        model.query = "OpenFind"
        try await waitUntil { !model.results.isEmpty }
        #expect(model.results.first?.isApplication == true)
        #expect(model.isSearching)
        try await waitUntil { !model.isSearching }
        #expect(model.results.map(\.name) == ["OpenFind", "OpenFind Notes.txt"])
        #expect(model.selectedResult?.name == "OpenFind")
        model.moveSelection(by: 1)
        #expect(model.selectedResult?.name == "OpenFind Notes.txt")
    }

    @Test func changingQueryRejectsOldAsyncResultsAndStaleReturnTargets() async throws {
        let model = QuickSearchViewModel(
            searchApplications: { _ in [] },
            searchSettings: { _ in [] },
            searchFiles: { query in
                try? await Task.sleep(for: .milliseconds(query == "old" ? 200 : 10))
                return QuickSearchFileResponse(results: [fileResult(query)])
            }
        )
        defer { model.cancel() }
        model.query = "old"
        try await Task.sleep(for: .milliseconds(60))
        model.query = "new"
        #expect(model.selectedResult == nil)
        try await waitUntil { !model.isSearching }
        #expect(model.results.map(\.name) == ["new"])
        model.query = ""
        #expect(model.results.isEmpty)
        #expect(model.presentationHeight == 118)
    }

    @Test func digitShortcutsUseCharactersAndRespectIMEComposition() throws {
        let panel = QuickSearchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        var opened: [Int] = []
        var reveals = 0
        var fullSearches = 0
        panel.onOpenNumber = { opened.append($0) }
        panel.onReveal = { reveals += 1 }
        panel.onFullSearch = { fullSearches += 1 }
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                     kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, code) in codes.enumerated() {
            #expect(panel.handleCommand(key(code, flags: .command, text: String(index + 1))))
        }
        #expect(opened == Array(0...8))
        #expect(!panel.handleCommand(key(kVK_ANSI_Equal, flags: .command, text: "=")))
        #expect(!panel.handleCommand(key(kVK_ANSI_0, flags: .command, text: "0")))
        #expect(panel.handleCommand(key(kVK_Return, flags: .command)))
        #expect(panel.handleCommand(key(kVK_Return, flags: .option)))
        #expect(reveals == 1 && fullSearches == 1)
        let editor = NSTextView()
        panel.contentView = editor
        panel.makeFirstResponder(editor)
        editor.setMarkedText("wei", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!panel.handleCommand(key(kVK_Return)))
        #expect(!panel.handleCommand(key(kVK_DownArrow)))
        editor.unmarkText()
        panel.close()
    }

    @Test func typingKeepsRowsAndHeightButCannotOpenAnOldQuery() async throws {
        let model = QuickSearchViewModel(
            searchApplications: { query in
                if query == "new" { try? await Task.sleep(for: .milliseconds(120)) }
                return (0..<12).map { application("\(query)-\($0)") }
            }, searchSettings: { _ in [] }
        )
        defer { model.cancel() }
        model.query = "old"
        try await waitUntil { !model.isSearching }
        #expect(model.results.count == 12)
        model.selectResult(at: 11)
        #expect(model.selectedResult?.name == "old-11")
        let height = model.presentationHeight
        model.query = "new"
        #expect(model.results.count == 12)
        #expect(model.presentationHeight == height)
        #expect(model.selectedResult == nil)
        try await waitUntil { !model.isSearching }
        #expect(model.results.first?.name == "new-0")
        model.moveSelection(by: -1)
        #expect(model.selectedResult?.name == "new-11")
    }

    @Test func loadingMorePreservesSelectionAndSettingsHaveTheirOwnDestination() async throws {
        let settings = ApplicationSearchResult(
            url: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!,
            name: "Keyboard", bundleIdentifier: "com.apple.Keyboard-Settings.extension"
        )
        let model = QuickSearchViewModel(
            searchApplications: { _ in [] }, searchSettings: { _ in [settings] },
            searchFilesWithLimit: { _, limit in
                .init(results: (0..<min(limit, 65)).map { fileResult("file-\($0)") }, hasMore: limit < 65)
            }
        )
        defer { model.cancel() }
        model.query = "file"
        try await waitUntil { !model.isSearching }
        #expect(model.results.count == 51)
        #expect(model.results.first?.isSystemSetting == true)
        model.selectResult(at: 50)
        let selected = model.selectedResult?.id
        model.moveSelection(by: 1)
        try await waitUntil { !model.isSearching }
        #expect(model.results.count == 66)
        #expect(!model.hasMoreFiles)
        #expect(model.selectedResult?.id == selected)
    }

    @Test func showFocusesTheInputOnFirstAndRepeatedPresentation() async throws {
        let model = QuickSearchViewModel(searchApplications: { _ in [] })
        var transferred: String?
        let controller = QuickSearchWindowController(viewModel: model, onShowFullSearch: { transferred = $0 })
        defer { controller.close() }
        controller.show()
        try await Task.sleep(for: .milliseconds(50))
        let panel = try #require(controller.panel)
        let editor = try #require(panel.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(panel.frame.height <= 160)
        model.query = "fixture"
        controller.close()
        controller.show()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.query.isEmpty)
        #expect(panel.firstResponder is NSTextView)
        model.query = "fixture"
        panel.onFullSearch?()
        #expect(transferred == "fixture")
        #expect(!controller.isVisible)
    }

    private func key(_ code: Int, flags: NSEvent.ModifierFlags = [], text: String = "\r") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code))!
    }

    private nonisolated func application(_ name: String) -> ApplicationSearchResult {
        .init(url: URL(fileURLWithPath: "/Applications/\(name).app"),
              name: name, bundleIdentifier: "test.\(name)")
    }

    private nonisolated func fileResult(_ name: String) -> SearchResult {
        .init(name: name, path: "/fixtures/\(name)", isDirectory: false, size: 1,
              modified: .distantPast, created: .distantPast, matchedContent: false, contentPreview: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
