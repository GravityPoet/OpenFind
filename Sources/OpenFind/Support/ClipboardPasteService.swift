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
    private let workspace: NSWorkspace
    private let ownProcessIdentifier: pid_t
    private var targetApplication: NSRunningApplication?

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
            // previously captured external application.
            return
        }
        targetApplication = frontmost
    }

    func pasteIntoCapturedApplication() async throws {
        let targetPID = try await activateCapturedApplicationProcess()

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
    }

    func activateCapturedApplication() async throws {
        _ = try await activateCapturedApplicationProcess()
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
