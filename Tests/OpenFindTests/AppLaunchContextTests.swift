import AppKit
import Testing
@testable import OpenFind

@MainActor
@Suite("App Launch Context Tests", .serialized)
struct AppLaunchContextTests {
    @Test func initialLaunchStaysInTheMenuBarWithoutCreatingTheMainWindow() {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let delegate = AppDelegate()
        var appliedPolicies: [NSApplication.ActivationPolicy] = []
        delegate.activationPolicySetter = { policy in
            appliedPolicies.append(policy)
            return true
        }
        defer {
            application.windows
                .filter { !existingWindows.contains(ObjectIdentifier($0)) }
                .forEach { $0.orderOut(nil) }
        }

        delegate.presentInitialInterface()

        let newMainWindow = application.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.identifier?.rawValue == "OpenFind.main"
        }
        #expect(newMainWindow == nil)
        #expect(appliedPolicies.last == .accessory)
    }

    @Test func primaryWindowStaysOutOfTheDockWhileVisible() throws {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let delegate = AppDelegate()
        var appliedPolicies: [NSApplication.ActivationPolicy] = []
        delegate.activationPolicySetter = { policy in
            appliedPolicies.append(policy)
            return true
        }
        defer {
            application.windows
                .filter { !existingWindows.contains(ObjectIdentifier($0)) }
                .forEach { $0.orderOut(nil) }
        }

        delegate.showOpenFindWindow(nil)

        let window = try #require(application.windows.first {
            $0.identifier?.rawValue == "OpenFind.main"
        })
        #expect(window.isVisible)
        #expect(appliedPolicies.last == .accessory)

        #expect(!delegate.windowShouldClose(window))
        #expect(!window.isVisible)
        #expect(appliedPolicies.last == .accessory)
    }
}
