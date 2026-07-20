import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol ScreenSaverControlling: AnyObject {
    func start(policy: ScreenSaverPolicy, exceptionIdentifiers: Set<String>)
    func stop()
}

/// Implements Amphetamine's bounded idle-to-screen-saver behavior without
/// changing the user's global screen-saver preferences. A session that allows
/// the screen saver gets a private idle monitor; a prevented session simply
/// refrains from launching ScreenSaverEngine and relies on its power assertion
/// to keep the display awake.
@MainActor
final class ScreenSaverSessionController: ScreenSaverControlling {
    private static let engineURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"
    )
    private var monitorTask: Task<Void, Never>?

    func start(policy: ScreenSaverPolicy, exceptionIdentifiers: Set<String>) {
        stop()
        guard case let .allow(after) = policy else { return }
        let threshold = max(0, after)
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let idle = Self.systemIdleTime()
                if idle >= threshold {
                    if self?.hasRunningException(exceptionIdentifiers) == false {
                        self?.launchScreenSaver()
                        return
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func launchScreenSaver() {
        guard FileManager.default.fileExists(atPath: Self.engineURL.path) else { return }
        NSWorkspace.shared.open(Self.engineURL)
    }

    private func hasRunningException(_ identifiers: Set<String>) -> Bool {
        guard !identifiers.isEmpty else { return false }
        if !ProcessTriggerSignals.currentNames().isDisjoint(with: identifiers) {
            return true
        }
        return NSWorkspace.shared.runningApplications.contains { application in
            let candidates = [
                application.bundleIdentifier,
                application.localizedName,
                application.executableURL?.lastPathComponent,
            ].compactMap { $0 }
            return candidates.contains { identifiers.contains($0) }
        }
    }

    private static func systemIdleTime() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel,
        ]
        return eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? 0
    }
}
