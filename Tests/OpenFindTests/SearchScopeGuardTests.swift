import Foundation
import Testing
@testable import OpenFind

@Suite("Search Scope Guard Tests")
struct SearchScopeGuardTests {
    @Test func testBroadContentSearchRequiresConfirmation() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let narrowScope = URL(fileURLWithPath: NSTemporaryDirectory())

        var options = SearchOptions(query: "openfind")
        options.target = .name
        #expect(!SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [home]))

        options.target = .content
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [home]))
        #expect(!SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [narrowScope]))

        options.target = .both
        #expect(SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: [home]))
    }
}
