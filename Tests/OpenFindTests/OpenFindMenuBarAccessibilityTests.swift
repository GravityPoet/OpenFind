import Testing
@testable import OpenFind

@Suite("OpenFind Menu Bar Accessibility Tests")
struct OpenFindMenuBarAccessibilityTests {
    @Test func labelDistinguishesIdleActiveAndTimedSessions() {
        #expect(OpenFindMenuBarAccessibility.label(
            isActive: false,
            timeText: nil,
            timeStyle: .remaining
        ) == L("OpenFind Idle Accessibility"))
        #expect(OpenFindMenuBarAccessibility.label(
            isActive: true,
            timeText: nil,
            timeStyle: .remaining
        ) == L("OpenFind Keeping Awake Accessibility"))
        #expect(OpenFindMenuBarAccessibility.label(
            isActive: true,
            timeText: "1:25",
            timeStyle: .remaining
        ) == String(
            format: L("OpenFind Remaining Time Accessibility Format"),
            "1:25"
        ))
        #expect(OpenFindMenuBarAccessibility.label(
            isActive: true,
            timeText: "18:30",
            timeStyle: .endTime
        ) == String(
            format: L("OpenFind End Time Accessibility Format"),
            "18:30"
        ))
    }
}
