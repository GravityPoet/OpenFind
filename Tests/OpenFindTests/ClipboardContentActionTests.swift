import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Content Action Tests")
struct ClipboardContentActionTests {
    @Test func standardActionsAreTypeAwareAndDeterministic() throws {
        let registry = ClipboardContentActionRegistry.standard
        let json = #"{"b":2,"a":1}"#
        let jsonActions = registry.actions(for: json)
        #expect(jsonActions.contains { $0.id == "json.pretty" })
        #expect(jsonActions.contains { $0.id == "json.minify" })
        #expect(!registry.actions(for: "ordinary").contains { $0.id == "json.pretty" })

        #expect(try registry.transform(actionID: "text.trim", text: "  value \n") == "value")
        #expect(try registry.transform(actionID: "text.quote", text: "a\nb") == "> a\n> b")
        #expect(try registry.transform(actionID: "json.minify", text: json) == #"{"a":1,"b":2}"#)
        #expect(try registry.transform(actionID: "base64.decode", text: "b3BlbmZpbmQ=") == "openfind")
    }

    @Test func registryAcceptsAdditionalProvidersWithoutChangingThePanelModel() throws {
        let registry = ClipboardContentActionRegistry(providers: [PrefixActionProvider()])
        let action = try #require(registry.actions(for: "value").first)

        #expect(action.id == "test.prefix")
        #expect(try registry.transform(actionID: action.id, text: "value") == "prefix:value")
    }

    @Test func storeExecutesAnInjectedActionWithoutMutatingHistory() throws {
        let suite = "OpenFindTests.ContentActions.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: ContentActionMemoryPersistence(),
            pasteboard: pasteboard,
            contentActionRegistry: ClipboardContentActionRegistry(
                providers: [PrefixActionProvider()]
            )
        )
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("value".utf8)],
            previewText: "value",
            kind: .text
        ))
        let entry = try #require(store.entries.first)
        let historyBefore = store.entries
        let action = try #require(store.availableContentActions(for: entry).first)

        try store.performContentAction(action, on: entry)

        #expect(pasteboard.string(forType: .string) == "prefix:value")
        #expect(store.entries == historyBefore)
    }
}

private struct PrefixActionProvider: ClipboardContentActionProviding {
    func actions(for text: String) -> [ClipboardContentActionDescriptor] {
        [.init(id: "test.prefix", titleKey: "Prefix", systemImage: "plus")]
    }

    func transform(actionID: String, text: String) throws -> String {
        guard actionID == "test.prefix" else {
            throw ClipboardContentActionError.unavailable
        }
        return "prefix:\(text)"
    }
}

private final class ContentActionMemoryPersistence: ClipboardHistoryPersisting {
    private var entries: [ClipboardEntry] = []
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func remove() throws { entries = [] }
}
