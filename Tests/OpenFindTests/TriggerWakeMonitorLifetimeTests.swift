import Testing
@testable import OpenFind

@MainActor
@Suite("Trigger Wake Monitor Lifetime Tests")
struct TriggerWakeMonitorLifetimeTests {
    @Test func networkMonitorCanRestartWithoutRetainingAStaleCallback() {
        let monitor = NetworkConfigurationWakeMonitor()

        for _ in 0..<32 {
            monitor.start {}
            monitor.stop()
        }

        // A second stop must be idempotent after the retained callback context
        // and its run-loop source have already been released.
        monitor.stop()
    }

    @Test func usbMonitorCanRestartWithoutRetainingAStaleCallback() {
        let monitor = USBDeviceWakeMonitor()

        for _ in 0..<32 {
            monitor.start {}
            monitor.stop()
        }

        monitor.stop()
    }
}
