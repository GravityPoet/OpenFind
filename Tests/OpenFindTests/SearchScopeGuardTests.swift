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
        let noFollowRoot = URL(fileURLWithPath: "/.nofollow/")

        #expect(SearchScopes.isWholeMac(SearchScopes.wholeMacURL))
        #expect(SearchScopes.isWholeMac(legacy))
        #expect(SearchScopes.isWholeMac(noFollowRoot))
        #expect(SearchScopes.normalized(legacy) == SearchScopes.wholeMacURL)
        #expect(SearchScopes.normalized(noFollowRoot) == SearchScopes.wholeMacURL)
    }

    @Test func addingCustomScopeReplacesWholeMacScope() {
        let custom = URL(fileURLWithPath: "/Users/test/Project")
        let other = URL(fileURLWithPath: "/tmp")

        #expect(SearchScopes.adding(custom, to: [SearchScopes.wholeMacURL]) == [custom])
        #expect(SearchScopes.adding(custom, to: [other]) == [other, custom])
        #expect(SearchScopes.adding(custom, to: [custom]) == [custom])
        #expect(SearchScopes.adding(SearchScopes.wholeMacURL, to: [custom]) == [SearchScopes.wholeMacURL])
    }
}
