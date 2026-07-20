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

    @Test func unavailableNativeServiceUsesTheUserLaunchAgentFallback() throws {
        let native = FakeLaunchAtLoginService(status: .unavailable)
        let fallback = FakeLaunchAtLoginService()
        let service = MainAppLaunchAtLoginService(
            nativeService: native,
            fallbackService: fallback
        )

        try service.register()
        #expect(service.status == .enabled)
        #expect(native.registerCount == 0)
        #expect(fallback.registerCount == 1)

        try service.unregister()
        #expect(service.status == .disabled)
        #expect(fallback.unregisterCount == 1)
    }

    @Test func userLaunchAgentFallbackIsAtomicIdempotentAndReversible() throws {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenFindLaunchAtLoginTests-\(UUID().uuidString)")
        let applicationURL = homeURL.appendingPathComponent("OpenFind.app", isDirectory: true)
        try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeURL) }

        let service = UserLaunchAgentLaunchAtLoginService(
            fileManager: fileManager,
            applicationURL: applicationURL,
            homeDirectoryURL: homeURL
        )
        #expect(service.status == .disabled)

        try service.register()
        try service.register()
        #expect(service.status == .enabled)

        let data = try Data(contentsOf: service.configurationURL)
        let configuration = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        #expect(configuration["Label"] as? String == UserLaunchAgentLaunchAtLoginService.label)
        #expect(configuration["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(configuration["ProgramArguments"] as? [String] == [
            "/usr/bin/open", "-g", "-j", applicationURL.path,
        ])
        #expect(configuration["RunAtLoad"] as? Bool == true)

        try service.unregister()
        try service.unregister()
        #expect(service.status == .disabled)
        #expect(!fileManager.fileExists(atPath: service.configurationURL.path))
    }

    @Test func userLaunchAgentFallbackDoesNotOverwriteForeignConfiguration() throws {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenFindLaunchAtLoginTests-\(UUID().uuidString)")
        let applicationURL = homeURL.appendingPathComponent("OpenFind.app", isDirectory: true)
        let configurationURL = homeURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(UserLaunchAgentLaunchAtLoginService.label).plist")
        try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreignData = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": UserLaunchAgentLaunchAtLoginService.label,
                "ProgramArguments": ["/bin/sh", "-c", "exit 0"],
                "RunAtLoad": true,
            ],
            format: .xml,
            options: 0
        )
        try foreignData.write(to: configurationURL)
        defer { try? fileManager.removeItem(at: homeURL) }

        let service = UserLaunchAgentLaunchAtLoginService(
            fileManager: fileManager,
            applicationURL: applicationURL,
            homeDirectoryURL: homeURL
        )
        #expect(service.status == .unavailable)

        var registerFailed = false
        do { try service.register() } catch { registerFailed = true }
        #expect(registerFailed)
        #expect(try Data(contentsOf: configurationURL) == foreignData)

        var unregisterFailed = false
        do { try service.unregister() } catch { unregisterFailed = true }
        #expect(unregisterFailed)
        #expect(try Data(contentsOf: configurationURL) == foreignData)
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
