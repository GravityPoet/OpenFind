import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Launch At Login Controller Tests")
struct LaunchAtLoginControllerTests {
    @Test func registrationAndUnregistrationFollowTheServiceState() {
        let service = FakeLaunchAtLoginService()
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(service.registerCount == 1)

        controller.setEnabled(false)
        #expect(controller.status == .disabled)
        #expect(!controller.isEnabled)
        #expect(service.unregisterCount == 1)
    }

    @Test func approvalStateRemainsEnabledAndCanOpenSystemSettings() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        #expect(controller.isEnabled)
        controller.openSystemSettings()
        #expect(service.openSettingsCount == 1)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LaunchAtLoginStatus = .disabled) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .disabled
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}
