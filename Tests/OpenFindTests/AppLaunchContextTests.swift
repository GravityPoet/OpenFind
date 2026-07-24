import AppKit
import Testing
@testable import OpenFind

@MainActor
@Suite("App Launch Context Tests", .serialized)
struct AppLaunchContextTests {
    @Test func loginItemAppleEventStartsInTheBackground() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: keyAELaunchedAsLogInItem
        )

        #expect(AppDelegate.isLoginItemLaunch(event: event))
    }

    @Test func ordinaryLaunchStillOpensTheMainWindow() {
        #expect(!AppDelegate.isLoginItemLaunch(event: nil))
        #expect(!AppDelegate.isLoginItemLaunch(event: NSAppleEventDescriptor.null()))
    }

    @Test func primaryWindowUsesTheDockUntilTheLastVisibleWindowCloses() throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let delegate = AppDelegate()
        var appliedPolicies: [NSApplication.ActivationPolicy] = []
        delegate.activationPolicySetter = { policy in
            appliedPolicies.append(policy)
            return true
        }
        defer {
            NSApp.windows
                .filter { !existingWindows.contains(ObjectIdentifier($0)) }
                .forEach { $0.orderOut(nil) }
        }

        delegate.showOpenFindWindow(nil)

        let window = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "OpenFind.main"
        })
        #expect(window.isVisible)
        #expect(appliedPolicies.last == .regular)

        #expect(!delegate.windowShouldClose(window))
        #expect(!window.isVisible)
        #expect(appliedPolicies.last == .accessory)
    }
}
