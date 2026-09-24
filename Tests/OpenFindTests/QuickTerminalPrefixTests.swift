import Foundation
import Testing
@testable import OpenFind

struct QuickTerminalPrefixTests {
    @Test func everyLetterWorksOnlyWhenFollowedByAnExplicitSpace() {
        for prefix in QuickTerminalPrefix.choices {
            #expect(QuickSearchCommand.parse(prefix + " pwd", terminalPrefix: prefix)
                    == .init(mode: .terminal, term: "pwd"))
            #expect(QuickSearchCommand.parse(prefix.uppercased() + " pwd", terminalPrefix: prefix).mode == .terminal)
            #expect(QuickSearchCommand.parse(prefix, terminalPrefix: prefix).mode == .combined)
            #expect(QuickSearchCommand.parse(prefix + "\tpwd", terminalPrefix: prefix).mode == .combined)
            #expect(QuickSearchCommand.parse(prefix + " pwd\n", terminalPrefix: prefix).term == "pwd\n")
            if prefix != "g" {
                #expect(QuickSearchCommand.parse("g pwd", terminalPrefix: prefix).mode == .combined)
            }
        }
    }

    @Test func prefixPersistsAndInvalidLocalValuesFallBackToG() throws {
        let suite = "OpenFindTests.TerminalPrefix." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(QuickTerminalPrefix.load(from: defaults) == "g")
        defaults.set("x", forKey: QuickTerminalPrefix.persistenceKey)
        #expect(QuickTerminalPrefix.load(from: try #require(UserDefaults(suiteName: suite))) == "x")
        #expect(QuickTerminalPrefix.normalized("X") == "x")
        for invalid in ["", "ab", " ", "x ", ">", "1", "中", "\n", "é"] {
            #expect(QuickTerminalPrefix.normalized(invalid) == nil)
            defaults.set(invalid, forKey: QuickTerminalPrefix.persistenceKey)
            #expect(QuickTerminalPrefix.load(from: defaults) == "g")
        }
    }

    @MainActor
    @Test func configurationTransferCarriesValidPrefixAndRejectsInvalidImports() async throws {
        let source = try ConfigurationTestContext(), target = try ConfigurationTestContext()
        defer { source.cleanup(); target.cleanup() }
        source.defaults.set("t", forKey: QuickTerminalPrefix.persistenceKey)
        let archive = try source.transfer.snapshot()
        #expect(archive.preferences[QuickTerminalPrefix.persistenceKey] != nil)
        try await target.transfer.apply(archive)
        #expect(QuickTerminalPrefix.load(from: target.defaults) == "t")
        for invalid in ["", "terminal", "1", "x\n", "X"] {
            #expect(throws: ConfigurationError.invalidPreferences) {
                try ConfigurationPreferenceKeys.validatePortableValues([QuickTerminalPrefix.persistenceKey: invalid])
            }
        }
        #expect(QuickTerminalPrefix.load(from: target.defaults) == "t")
    }
}
