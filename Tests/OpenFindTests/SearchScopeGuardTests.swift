import Foundation
import Testing
@testable import OpenFind

@Suite("Search Scope Guard Tests")
struct SearchScopeGuardTests {
    @Test func testBroadContentSearchRequiresConfirmation() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let narrowScope = URL(fileURLWithPath: NSTemporaryDirectory())
        let wholeMac = SearchScopes.wholeMacURL
        let legacyWholeMac = URL(fileURLWithPath: SearchScopes.legacyWholeMacPath)

        var options = SearchOptions(query: "openfind")
        options.target = .name
        #expect(!SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [home]))

        options.target = .content
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [wholeMac]))
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [legacyWholeMac]))
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [home]))
        #expect(!SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [narrowScope]))

        options.target = .both
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [wholeMac]))
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [home]))
    }

    @Test func wholeMacScopeNormalizesLegacyDataVolume() {
        let legacy = URL(fileURLWithPath: SearchScopes.legacyWholeMacPath)

        #expect(SearchScopes.isWholeMac(SearchScopes.wholeMacURL))
        #expect(SearchScopes.isWholeMac(legacy))
        #expect(SearchScopes.normalized(legacy) == SearchScopes.wholeMacURL)
    }
}
