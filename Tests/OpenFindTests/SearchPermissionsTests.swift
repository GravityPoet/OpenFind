import Foundation
import Testing
@testable import OpenFind

@Suite("Search Permission Tests")
struct SearchPermissionsTests {
    @Test func accessibleTCCDatabaseConfirmsFullDiskAccess() {
        var visited: [String] = []
        let granted = SearchPermissions.hasFullDiskAccess { url in
            visited.append(url.path(percentEncoded: false))
            return visited.count == 1 ? .missing : .accessible
        }

        #expect(granted)
        #expect(visited.count == 2)
        #expect(visited.allSatisfy { $0.hasSuffix("/com.apple.TCC/TCC.db") })
        #expect(visited.allSatisfy { !$0.contains("/Mail") && !$0.contains("/Messages") && !$0.contains("/Safari") })
    }

    @Test func missingAndDeniedProtectedLocationsRemainConservative() {
        var probeCount = 0
        let granted = SearchPermissions.hasFullDiskAccess { _ in
            probeCount += 1
            return probeCount.isMultiple(of: 2) ? .missing : .denied
        }

        #expect(!granted)
        #expect(probeCount == 2)
    }
}
