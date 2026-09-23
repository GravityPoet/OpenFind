import AppKit
import SwiftUI
import Testing
@testable import OpenFind

@Suite("Settings Pane Tests")
struct SettingsPaneTests {
    @Test func resolvesPersistedPaneAndFallsBackToSearch() {
        #expect(SettingsPane.resolve("clipboard") == .clipboard)
        #expect(SettingsPane.resolve("unknown-pane") == .search)
    }

    @MainActor
    @Test func openSettingsPersistsRequestedPane() {
        let key = SettingsPane.persistenceKey
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        FileActions.openSettings(pane: .driveAlive, showSettings: {})
        #expect(defaults.string(forKey: key) == SettingsPane.driveAlive.rawValue)
        FileActions.openSettings(pane: .triggers, showSettings: {})
        #expect(defaults.string(forKey: key) == SettingsPane.triggers.rawValue)
    }

    @MainActor
    @Test func customNavigationRetainsPageDraftsAndHasNoSecondTabBar() async throws {
        var drafts: [SettingsPane: Binding<String>] = [:]
        let content: (SettingsPane) -> AnyView = { pane in
            AnyView(SettingsPageDraftFixture { drafts[pane] = $0 })
        }
        let controller = SettingsPageContainer.Controller(selection: .clipboard, content: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        #expect(controller.tabStyle == .unspecified)
        #expect(controller.tabView.tabViewType == .noTabsNoBorder)
        #expect(window.toolbar == nil)
        let originalPages = controller.children.map(ObjectIdentifier.init)
        for pane in SettingsPane.navigationOrder {
            controller.update(selection: pane, content: content)
            window.contentView?.layoutSubtreeIfNeeded()
            for _ in 0..<20 where drafts[pane] == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let draft = try #require(drafts[pane])
            draft.wrappedValue = "Draft for \(pane.rawValue)"
            #expect(controller.tabView.selectedTabViewItem?.identifier as? String == pane.rawValue)
        }
        for pane in SettingsPane.navigationOrder.reversed() {
            controller.update(selection: pane, content: content)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            #expect(drafts[pane]?.wrappedValue == "Draft for \(pane.rawValue)")
        }
        #expect(controller.children.map(ObjectIdentifier.init) == originalPages)
        #expect(SettingsPane.navigationOrder == [
            .search, .clipboard, .keepAwake, .triggers, .driveAlive, .keyboardCleaning,
        ])
    }
}

private struct SettingsPageDraftFixture: View {
    @State private var draft = ""
    let capture: (Binding<String>) -> Void

    var body: some View {
        TextField("Draft", text: $draft)
            .onAppear { capture($draft) }
    }
}
