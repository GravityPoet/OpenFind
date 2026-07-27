import AppKit
import Carbon
import CoreGraphics
import Foundation

enum ClipboardPasteError: Error, Equatable, LocalizedError {
    case permissionRequired
    case noTargetApplication
    case targetTerminated
    case activationFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return L("Clipboard Automatic Paste Permission Required")
        case .noTargetApplication:
            return L("Clipboard No Target Application")
        case .targetTerminated:
            return L("Clipboard Target Terminated")
        case .activationFailed:
            return L("Clipboard Target Activation Failed")
        case .eventCreationFailed:
            return L("Clipboard Paste Event Failed")
        }
    }
}

/// Returns focus to the application that was frontmost before the history
/// panel opened and sends a standard Command-V event. The target is captured
/// by process identifier, so no clipboard payload or application data is
/// logged or persisted.
@MainActor
final class ClipboardPasteService {
    /// How long a captured target stays trusted when the panel is reopened
    /// from an OpenFind surface. Beyond this the previous external
    /// application is more likely a window the user has forgotten about
    /// than the one they expect to paste into.
    private static let staleTargetLifetime: Duration = .seconds(120)

    private let workspace: NSWorkspace
    private let ownProcessIdentifier: pid_t
    private var targetApplication: NSRunningApplication?
    private var targetCapturedAt: ContinuousClock.Instant?

    init(
        workspace: NSWorkspace = .shared,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.workspace = workspace
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    func captureTargetApplication() {
        guard let frontmost = workspace.frontmostApplication,
              frontmost.processIdentifier != ownProcessIdentifier,
              !frontmost.isTerminated else {
            // Opening the panel from an OpenFind menu should not erase a
            // previously captured external application — but only while that
            // capture is still recent.
            if let capturedAt = targetCapturedAt,
               ContinuousClock.now - capturedAt > Self.staleTargetLifetime {
                targetApplication = nil
                targetCapturedAt = nil
            }
            return
        }
        targetApplication = frontmost
        targetCapturedAt = ContinuousClock.now
    }

    /// Activates the captured target, then asks `preparePasteboard` for the
    /// payload and sends Command-V. The pasteboard is written only after
    /// activation succeeds, so a failed paste never destroys what the user
    /// had on the clipboard.
    func pasteIntoCapturedApplication(
        preparePasteboard: () throws -> Int
    ) async throws {
        let targetPID = try await activateCapturedApplicationProcess()
        await waitForPhysicalModifierRelease()
        let cursorOffsetFromEnd = try preparePasteboard()

        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        ) else {
            throw ClipboardPasteError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
        guard cursorOffsetFromEnd > 0 else { return }
        try await Task.sleep(for: .milliseconds(35))
        for _ in 0..<cursorOffsetFromEnd {
            guard let leftDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_LeftArrow),
                keyDown: true
            ), let leftUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_LeftArrow),
                keyDown: false
            ) else {
                throw ClipboardPasteError.eventCreationFailed
            }
            leftDown.postToPid(targetPID)
            leftUp.postToPid(targetPID)
        }
    }

    func activateCapturedApplication() async throws {
        _ = try await activateCapturedApplicationProcess()
    }

    /// Physical modifiers still held from the invoking shortcut (for example
    /// Option-Return) leak into the synthetic Command-V in applications that
    /// read live HID state, turning paste into a different command entirely
    /// (in Finder, Command-Option-V moves files). Wait briefly for release.
    private func waitForPhysicalModifierRelease() async {
        let watched: CGEventFlags = [
            .maskCommand, .maskAlternate, .maskShift, .maskControl,
        ]
        for _ in 0..<30 {
            let flags = CGEventSource.flagsState(.hidSystemState)
            if flags.intersection(watched).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func activateCapturedApplicationProcess() async throws -> pid_t {
        guard AccessibilityPermission.isTrusted else {
            throw ClipboardPasteError.permissionRequired
        }
        guard let targetApplication else {
            throw ClipboardPasteError.noTargetApplication
        }
        guard !targetApplication.isTerminated else {
            self.targetApplication = nil
            throw ClipboardPasteError.targetTerminated
        }
        let targetPID = targetApplication.processIdentifier
        guard targetApplication.activate(options: [.activateAllWindows]) else {
            throw ClipboardPasteError.activationFailed
        }

        // activate(options:) only submits an activation request. In particular,
        // switching Spaces can take longer than a fixed delay, and posting V
        // before the target is frontmost leaves the event queued until after a
        // Paste Stack has already advanced its pasteboard payload.
        for _ in 0..<50 {
            if targetApplication.isActive,
               workspace.frontmostApplication?.processIdentifier == targetPID {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard targetApplication.isActive,
              workspace.frontmostApplication?.processIdentifier == targetPID else {
            throw ClipboardPasteError.activationFailed
        }
        try await Task.sleep(for: .milliseconds(50))
        try Task.checkCancellation()
        self.targetApplication = nil
        return targetPID
    }
}
