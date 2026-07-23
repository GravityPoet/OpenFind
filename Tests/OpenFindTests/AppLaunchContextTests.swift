import AppKit
import Testing
@testable import OpenFind

@MainActor
@Suite("App Launch Context Tests")
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
}
