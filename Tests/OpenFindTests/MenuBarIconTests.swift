import AppKit
import Testing
@testable import OpenFind

@Suite("Menu Bar Icon Tests")
@MainActor
struct MenuBarIconTests {
    @Test func reusesStableImagesForEachSessionState() {
        let firstInactive = MenuBarIcon.make(isActive: false)
        let secondInactive = MenuBarIcon.make(isActive: false)
        let firstActive = MenuBarIcon.make(isActive: true)
        let secondActive = MenuBarIcon.make(isActive: true)

        #expect(firstInactive === secondInactive)
        #expect(firstActive === secondActive)
        #expect(firstInactive !== firstActive)
        #expect(firstInactive.isTemplate)
        #expect(firstActive.isTemplate)
        #expect(firstInactive.size == NSSize(width: 18, height: 18))
        #expect(firstActive.size == NSSize(width: 18, height: 18))
    }
}
