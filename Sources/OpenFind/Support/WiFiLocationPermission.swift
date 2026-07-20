import AppKit
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class WiFiLocationPermissionController: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    @ObservationIgnored private let manager: CLLocationManager
    private(set) var state: State

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.state = Self.map(manager.authorizationStatus)
        super.init()
        manager.delegate = self
    }

    func requestIfNeeded() {
        guard state == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.state = Self.map(status)
        }
    }

    nonisolated private static func map(_ status: CLAuthorizationStatus) -> State {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized, .authorizedAlways: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}
