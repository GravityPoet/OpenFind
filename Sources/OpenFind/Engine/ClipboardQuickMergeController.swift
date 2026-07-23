import AppKit
import Carbon
import CoreGraphics
import Foundation
import Observation

enum ClipboardQuickMergeError: Error, Equatable, LocalizedError, Sendable {
    case permissionRequired
    case eventTapUnavailable
    case noTrackedClipboard

    var errorDescription: String? {
        switch self {
        case .permissionRequired: L("Quick Merge Permission Required")
        case .eventTapUnavailable: L("Quick Merge Event Tap Unavailable")
        case .noTrackedClipboard: L("Quick Merge Requires Tracked Clipboard")
        }
    }
}

struct ClipboardQuickMergeRequest: Equatable, Sendable {
    let base: String
    let appended: String
    let separator: String
    let sourceBundleIdentifier: String?
    let sourceApplicationName: String?

    var mergedText: String { base + separator + appended }
}

@MainActor
@Observable
final class ClipboardQuickMergeController {
    private static let activationInterval: TimeInterval = 0.85

    @ObservationIgnored private let store: ClipboardHistoryStore
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let workspace: NSWorkspace
    @ObservationIgnored private let ownProcessIdentifier: pid_t
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var armedBase: String?
    @ObservationIgnored private var armedProcessIdentifier: pid_t?
    @ObservationIgnored private var armedAt: TimeInterval?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var lastErrorMessage: String?

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        workspace: NSWorkspace = .shared,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    func refresh() {
        store.preferences.quickMergeEnabled ? start() : stop()
    }

    func start() {
        guard store.preferences.quickMergeEnabled else {
            stop()
            return
        }
        guard AccessibilityPermission.isTrusted else {
            stop()
            lastErrorMessage = ClipboardQuickMergeError.permissionRequired.localizedDescription
            return
        }
        guard tap == nil else {
            isRunning = true
            lastErrorMessage = nil
            return
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: clipboardQuickMergeEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastErrorMessage = ClipboardQuickMergeError.eventTapUnavailable.localizedDescription
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        lastErrorMessage = nil
    }

    func stop() {
        resetTask?.cancel()
        resetTask = nil
        resetArming()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        isRunning = false
    }

    fileprivate func reenableTap() {
        guard let tap, store.preferences.quickMergeEnabled else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func handleKeyDown(keyCode: UInt16, modifierFlagsRawValue: UInt64) -> Bool {
        let modifierFlags = CGEventFlags(rawValue: modifierFlagsRawValue)
        guard isRunning,
              keyCode == UInt16(kVK_ANSI_C),
              modifierFlags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                == .maskCommand,
              let application = workspace.frontmostApplication,
              application.processIdentifier != ownProcessIdentifier,
              !application.isTerminated,
              isCaptureAllowed(from: application) else {
            resetArming()
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let armedBase,
           armedProcessIdentifier == application.processIdentifier,
           let armedAt,
           now - armedAt <= Self.activationInterval,
           let appended = pasteboard.string(forType: .string) {
            let request = ClipboardQuickMergeRequest(
                base: armedBase,
                appended: appended,
                separator: separator,
                sourceBundleIdentifier: application.bundleIdentifier,
                sourceApplicationName: application.localizedName
            )
            resetTask?.cancel()
            resetTask = nil
            resetArming()
            Task { @MainActor [weak self] in self?.perform(request) }
            return true
        }

        resetArming()
        guard let current = pasteboard.string(forType: .string),
              store.entries.prefix(50).contains(where: {
                  store.plainText(for: $0) == current
              }) else {
            lastErrorMessage = ClipboardQuickMergeError.noTrackedClipboard.localizedDescription
            return false
        }
        armedBase = current
        armedProcessIdentifier = application.processIdentifier
        armedAt = now
        lastErrorMessage = nil
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.resetArming()
            self?.resetTask = nil
        }
        return false
    }

    func perform(_ request: ClipboardQuickMergeRequest) {
        let merged = request.mergedText
        do {
            try store.writePlainText(merged)
            _ = store.ingest(
                representations: [NSPasteboard.PasteboardType.string.rawValue: Data(merged.utf8)],
                previewText: merged,
                kind: .text,
                sourceBundleIdentifier: request.sourceBundleIdentifier,
                sourceApplicationName: request.sourceApplicationName
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? L("Quick Merge Failed")
        }
    }

    private var separator: String {
        switch store.preferences.quickMergeSeparator {
        case .newline: "\n"
        case .space: " "
        case .none: ""
        case .custom: store.preferences.quickMergeCustomSeparator
        }
    }

    private func isCaptureAllowed(from application: NSRunningApplication) -> Bool {
        if let identifier = application.bundleIdentifier {
            if store.preferences.ignoredBundleIdentifiers.contains(identifier) { return false }
            if store.preferences.captureOnlyFromAllowedApplications,
               !store.preferences.allowedBundleIdentifiers.contains(identifier) { return false }
        } else if store.preferences.captureOnlyFromAllowedApplications {
            return false
        }
        return true
    }

    private func resetArming() {
        armedBase = nil
        armedProcessIdentifier = nil
        armedAt = nil
    }
}

private let clipboardQuickMergeEventCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ClipboardQuickMergeController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    guard Thread.isMainThread else { return Unmanaged.passUnretained(event) }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let modifierFlagsRawValue = event.flags.rawValue
    let shouldSuppress = MainActor.assumeIsolated {
        controller.handleKeyDown(
            keyCode: keyCode,
            modifierFlagsRawValue: modifierFlagsRawValue
        )
    }
    return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}
