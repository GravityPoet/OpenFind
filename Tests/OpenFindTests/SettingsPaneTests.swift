import Testing
@testable import OpenFind

@Suite("Settings Pane Tests")
struct SettingsPaneTests {
    @Test func resolvesPersistedPaneAndFallsBackToSearch() {
        #expect(SettingsPane.resolve("clipboard") == .clipboard)
        #expect(SettingsPane.resolve("unknown-pane") == .search)
    }
}
