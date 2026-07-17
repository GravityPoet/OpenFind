import Foundation
import Testing
@testable import OpenFind

@Suite("Search Permission Tests")
struct SearchPermissionsTests {
    @Test func anyAccessibleProtectedLocationConfirmsFullDiskAccess() {
        var visited: [String] = []
        let granted = SearchPermissions.hasFullDiskAccess { url in
            visited.append(url.lastPathComponent)
            switch url.lastPathComponent {
            case "Mail": return .missing
            case "Messages": return .denied
            case "Safari": return .accessible
            default: return .missing
            }
        }

        #expect(granted)
        #expect(visited == ["Mail", "Messages", "Safari"])
    }

    @Test func missingAndDeniedProtectedLocationsRemainConservative() {
        var probeCount = 0
        let granted = SearchPermissions.hasFullDiskAccess { _ in
            probeCount += 1
            return probeCount.isMultiple(of: 2) ? .missing : .denied
        }

        #expect(!granted)
        #expect(probeCount >= 3)
    }
}
