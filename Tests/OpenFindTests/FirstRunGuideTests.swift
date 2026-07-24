import Foundation
import Testing
@testable import OpenFind

@Suite("First Run Guide Tests", .serialized)
struct FirstRunGuideTests {
    @Test func firstLaunchPresentsAndCompletionPersists() throws {
        let suite = "OpenFindTests.FirstRunGuide.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(FirstRunGuideStore.shouldPresent(defaults: defaults))

        FirstRunGuideStore.markCompleted(defaults: defaults)

        #expect(!FirstRunGuideStore.shouldPresent(defaults: defaults))
    }

    @Test func capabilitiesHaveStableUniqueOrder() {
        #expect(FirstRunCapability.ID.allCases == [
            .search,
            .clipboard,
            .keepAwake,
            .driveAlive,
            .keyboardCleaning,
        ])
        #expect(Set(FirstRunCapability.ID.allCases).count == 5)
    }
}
