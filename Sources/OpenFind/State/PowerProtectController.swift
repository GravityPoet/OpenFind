import Foundation
import Observation

@MainActor
@Observable
final class PowerProtectController {
    enum State: Equatable {
        case notInstalled
        case installed
        case invalid
        case unsupported
        case working
    }

    @ObservationIgnored private let service: any PowerProtectServicing
    @ObservationIgnored private let userName: String
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    private(set) var state: State
    private(set) var lastErrorMessage: String?

    init(
        service: any PowerProtectServicing = SudoersPowerProtectService(),
        userName: String = NSUserName()
    ) {
        self.service = service
        self.userName = userName
        state = Self.state(for: service.status())
    }

    var isInstalled: Bool { state == .installed }

    func refresh() {
        guard operationTask == nil else { return }
        state = Self.state(for: service.status())
    }

    func install() {
        guard operationTask == nil, state != .unsupported else { return }
        state = .working
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.service.install(for: self.userName)
                self.state = Self.state(for: self.service.status())
                self.lastErrorMessage = nil
            } catch is CancellationError {
                self.state = Self.state(for: self.service.status())
            } catch {
                self.state = Self.state(for: self.service.status())
                self.lastErrorMessage = error.localizedDescription
            }
            self.operationTask = nil
        }
    }

    func uninstall() {
        guard operationTask == nil, state != .unsupported else { return }
        state = .working
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.service.uninstall(for: self.userName)
                self.state = Self.state(for: self.service.status())
                self.lastErrorMessage = nil
            } catch is CancellationError {
                self.state = Self.state(for: self.service.status())
            } catch {
                self.state = Self.state(for: self.service.status())
                self.lastErrorMessage = error.localizedDescription
            }
            self.operationTask = nil
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private static func state(for status: PowerProtectInstallationStatus) -> State {
        switch status {
        case .notInstalled: .notInstalled
        case .installed: .installed
        case .invalid: .invalid
        case .unsupported: .unsupported
        }
    }
}
