import Foundation
import IOBluetooth
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

    @Test func bluetoothConnectCallbackHopsFromIOBluetoothQueueToMainActor() async throws {
        let monitor = BluetoothConnectionWakeMonitor()
        let device = try #require(IOBluetoothDevice(addressString: "00:11:22:33:44:55"))
        let context = BluetoothCallbackTestContext(monitor: monitor, device: device)
        let gate = BluetoothCallbackContinuationGate()

        await withCheckedContinuation { continuation in
            monitor.start {
                MainActor.preconditionIsolated()
                gate.resumeOnce(continuation)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = context.monitor.perform(
                    NSSelectorFromString("deviceConnected:device:"),
                    with: NSNull(),
                    with: context.device
                )
            }
        }

        monitor.stop()
    }
}

private final class BluetoothCallbackContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume()
    }
}

private final class BluetoothCallbackTestContext: @unchecked Sendable {
    let monitor: BluetoothConnectionWakeMonitor
    let device: IOBluetoothDevice

    init(monitor: BluetoothConnectionWakeMonitor, device: IOBluetoothDevice) {
        self.monitor = monitor
        self.device = device
    }
}
