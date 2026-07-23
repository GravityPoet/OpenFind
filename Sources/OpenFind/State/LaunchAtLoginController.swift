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
final class ServiceManagementLaunchAtLoginService: LaunchAtLoginServicing {
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
final class UserLaunchAgentLaunchAtLoginService: LaunchAtLoginServicing {
    static let label = "com.openfind.app.open-at-login"

    private let fileManager: FileManager
    private let applicationURL: URL
    let configurationURL: URL

    init(
        fileManager: FileManager = .default,
        applicationURL: URL = Bundle.main.bundleURL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.applicationURL = applicationURL.standardizedFileURL
        self.configurationURL = homeDirectoryURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist", isDirectory: false)
    }

    var status: LaunchAtLoginStatus {
        guard isApplicationBundle else { return .unavailable }
        guard fileManager.fileExists(atPath: configurationURL.path) else { return .disabled }
        guard !configurationIsSymbolicLink,
              let configuration = storedConfiguration,
              isManagedConfiguration(configuration) else {
            return .unavailable
        }
        return matchesCurrentConfiguration(configuration) ? .enabled : .disabled
    }

    func register() throws {
        guard isApplicationBundle else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: applicationURL.path])
        }
        if fileManager.fileExists(atPath: configurationURL.path) {
            guard !configurationIsSymbolicLink,
                  let configuration = storedConfiguration,
                  isManagedConfiguration(configuration) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSFilePathErrorKey: configurationURL.path,
                ])
            }
        }

        try fileManager.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: expectedConfiguration,
            format: .xml,
            options: 0
        )
        try data.write(to: configurationURL, options: .atomic)
        guard status == .enabled else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: configurationURL.path,
            ])
        }
    }

    func unregister() throws {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return }
        guard !configurationIsSymbolicLink,
              let configuration = storedConfiguration,
              isManagedConfiguration(configuration) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSFilePathErrorKey: configurationURL.path,
            ])
        }
        try fileManager.removeItem(at: configurationURL)
    }

    func openSystemSettings() {}

    private var isApplicationBundle: Bool {
        var isDirectory: ObjCBool = false
        return applicationURL.pathExtension == "app"
            && fileManager.fileExists(atPath: applicationURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var expectedConfiguration: [String: Any] {
        [
            "Label": Self.label,
            "LimitLoadToSessionType": "Aqua",
            "ProgramArguments": ["/usr/bin/open", "-g", "-j", applicationURL.path],
            "RunAtLoad": true,
        ]
    }

    private var storedConfiguration: [String: Any]? {
        guard let data = try? Data(contentsOf: configurationURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else { return nil }
        return object as? [String: Any]
    }

    private var configurationIsSymbolicLink: Bool {
        (try? configurationURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
            == true
    }

    private func isManagedConfiguration(_ configuration: [String: Any]) -> Bool {
        configuration["Label"] as? String == Self.label
            && (configuration["ProgramArguments"] as? [String])?.first == "/usr/bin/open"
    }

    private func matchesCurrentConfiguration(_ configuration: [String: Any]) -> Bool {
        configuration["LimitLoadToSessionType"] as? String == "Aqua"
            && configuration["ProgramArguments"] as? [String]
                == expectedConfiguration["ProgramArguments"] as? [String]
            && configuration["RunAtLoad"] as? Bool == true
    }
}

@MainActor
final class MainAppLaunchAtLoginService: LaunchAtLoginServicing {
    private let nativeService: any LaunchAtLoginServicing
    private let fallbackService: any LaunchAtLoginServicing

    init(
        nativeService: any LaunchAtLoginServicing = ServiceManagementLaunchAtLoginService(),
        fallbackService: any LaunchAtLoginServicing = UserLaunchAgentLaunchAtLoginService()
    ) {
        self.nativeService = nativeService
        self.fallbackService = fallbackService
    }

    var status: LaunchAtLoginStatus { selectedService.status }

    func register() throws {
        try selectedService.register()
    }

    func unregister() throws {
        try selectedService.unregister()
    }

    func openSystemSettings() {
        selectedService.openSystemSettings()
    }

    private var selectedService: any LaunchAtLoginServicing {
        if fallbackService.status == .enabled { return fallbackService }
        return nativeService.status == .unavailable ? fallbackService : nativeService
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    static let defaultEnrollmentVersion = 1
    static let defaultEnrollmentVersionKey =
        "OpenFind.launchAtLoginDefaultEnrollmentVersion"

    @ObservationIgnored private let service: any LaunchAtLoginServicing
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var status: LaunchAtLoginStatus
    private(set) var lastErrorMessage: String?

    init(
        service: any LaunchAtLoginServicing = MainAppLaunchAtLoginService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        status = service.status
    }

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Enrolls new installations once, while preserving every later user
    /// choice. A transient registration failure deliberately leaves the
    /// migration pending so the next launch can retry.
    func enableByDefaultIfNeeded() {
        refresh()
        guard defaults.integer(forKey: Self.defaultEnrollmentVersionKey)
                < Self.defaultEnrollmentVersion else { return }
        do {
            if status == .disabled {
                try service.register()
                refresh()
            }
            guard isEnabled else { return }
            defaults.set(
                Self.defaultEnrollmentVersion,
                forKey: Self.defaultEnrollmentVersionKey
            )
            lastErrorMessage = nil
        } catch {
            refresh()
            lastErrorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(
            Self.defaultEnrollmentVersion,
            forKey: Self.defaultEnrollmentVersionKey
        )
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
