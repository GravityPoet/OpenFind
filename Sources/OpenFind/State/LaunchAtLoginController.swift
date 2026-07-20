import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class MainAppLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    @ObservationIgnored private let service: any LaunchAtLoginServicing
    private(set) var status: LaunchAtLoginStatus
    private(set) var lastErrorMessage: String?

    init(service: any LaunchAtLoginServicing = MainAppLaunchAtLoginService()) {
        self.service = service
        status = service.status
    }

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status == .disabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            refresh()
            lastErrorMessage = nil
        } catch {
            refresh()
            lastErrorMessage = error.localizedDescription
        }
    }

    func refresh() {
        status = service.status
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    func clearError() {
        lastErrorMessage = nil
    }
}
