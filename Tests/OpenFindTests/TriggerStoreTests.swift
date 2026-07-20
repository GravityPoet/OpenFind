import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Trigger Store Tests")
struct TriggerStoreTests {
    @Test func persistsOrderEnabledStateAndPerTriggerEnabledState() throws {
        let suiteName = "OpenFindTests.TriggerStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        let first = try store.add(AwakeTrigger(name: "First", criteria: [.wifiNetwork("One")]))
        _ = try store.add(AwakeTrigger(name: "Second", criteria: [.wifiNetwork("Two")]))
        try store.move(from: 0, to: 2)
        try store.setTriggerEnabled(false, id: first)
        store.setEnabled(false)

        let reloaded = TriggerStore(defaults: defaults)
        #expect(!reloaded.isEnabled)
        #expect(reloaded.triggers.map(\.name) == ["Second", "First"])
        #expect(reloaded.triggers.last?.isEnabled == false)
    }

    @Test func adjacentMoveUsesInsertionIndexWithoutNoOp() throws {
        let suiteName = "OpenFindTests.TriggerStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        _ = try store.add(AwakeTrigger(name: "First", criteria: [.wifiNetwork("One")]))
        _ = try store.add(AwakeTrigger(name: "Second", criteria: [.wifiNetwork("Two")]))

        // The view passes the insertion index after the item when moving down.
        try store.move(from: 0, to: 2)
        #expect(store.triggers.map(\.name) == ["Second", "First"])
    }

    @Test func rejectsDuplicateNamesCaseInsensitively() throws {
        let suiteName = "OpenFindTests.TriggerStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = TriggerStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = try store.add(AwakeTrigger(name: "Network", criteria: [.wifiNetwork("One")]))

        #expect(throws: AwakeTriggerValidationError.duplicateName) {
            try store.add(AwakeTrigger(name: "network", criteria: [.wifiNetwork("Two")]))
        }
    }

    @Test func corruptDataIsNotOverwritten() throws {
        let suiteName = "OpenFindTests.TriggerStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = Data(repeating: 0xFF, count: 8)
        defaults.set(original, forKey: "OpenFind.awakeTriggersV1")

        let store = TriggerStore(defaults: defaults)

        #expect(store.triggers.isEmpty)
        #expect(store.loadErrorMessage != nil)
        #expect(defaults.data(forKey: "OpenFind.awakeTriggersV1") == original)
    }

    @Test func supportsMoreThanTheLegacyFixedTriggerLimit() throws {
        let suiteName = "OpenFindTests.TriggerStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)

        for index in 0..<150 {
            _ = try store.add(AwakeTrigger(
                name: "Trigger \(index)",
                criteria: [.wifiNetwork("Network \(index)")]
            ))
        }

        #expect(store.triggers.count == 150)
        #expect(TriggerStore(defaults: defaults).triggers.count == 150)
    }
}
