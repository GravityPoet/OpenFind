import AppKit
import Foundation
import OSLog

enum OpenFindScriptError: Error, Equatable, LocalizedError {
    case invalidSessionOptions
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidSessionOptions:
            L("AppleScript Session Options Invalid")
        case .unavailable:
            L("AppleScript Service Unavailable")
        }
    }
}

/// Cocoa Scripting installs its command dispatcher lazily. Registering a raw
/// `aevtquit` handler during app launch is therefore not stable: the first
/// custom command can replace it. Keep quit in the scripting dictionary and
/// route it through a dedicated command class instead.
@objc(OpenFindQuitScriptCommand)
final class OpenFindQuitScriptCommand: NSScriptCommand {
    private static let logger = Logger(subsystem: "com.openfind.app", category: "Lifecycle")

    override func execute() -> Any? {
        requestTermination()
        return nil
    }

    override func performDefaultImplementation() -> Any? {
        requestTermination()
        return nil
    }

    private func requestTermination() {
        Self.logger.notice("Cocoa scripting quit command received")
        if Thread.isMainThread {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class OpenFindScriptingService {
    private let sessions: AwakeSessionController
    private let preferences: AwakeSessionPreferences
    private let triggerStore: TriggerStore
    private let triggerCoordinator: TriggerCoordinator
    private let driveAliveStore: DriveAliveStore
    private let driveAlive: DriveAliveController

    init(
        sessions: AwakeSessionController,
        preferences: AwakeSessionPreferences,
        triggerStore: TriggerStore,
        triggerCoordinator: TriggerCoordinator,
        driveAliveStore: DriveAliveStore,
        driveAlive: DriveAliveController
    ) {
        self.sessions = sessions
        self.preferences = preferences
        self.triggerStore = triggerStore
        self.triggerCoordinator = triggerCoordinator
        self.driveAliveStore = driveAliveStore
        self.driveAlive = driveAlive
    }

    convenience init(delegate: AppDelegate) {
        self.init(
            sessions: delegate.awakeSession,
            preferences: delegate.awakeSessionPreferences,
            triggerStore: delegate.triggerStore,
            triggerCoordinator: delegate.triggerCoordinator,
            driveAliveStore: delegate.driveAliveStore,
            driveAlive: delegate.driveAlive
        )
    }

    var sessionIsActive: Bool { sessions.isActive }

    func sessionRequest(options: Any?) throws -> AwakeSessionRequest {
        try Self.sessionRequest(options: options, preferences: preferences)
    }

    func startNewSession(options: Any?) async throws -> Bool {
        let request = try sessionRequest(options: options)
        return await startNewSession(request: request)
    }

    func startNewSession(request: AwakeSessionRequest) async -> Bool {
        await sessions.requestStartAsync(request)
    }

    func endSession() async -> Bool {
        await sessions.requestEndAsync(reason: .scriptRequested)
    }

    var sessionTimeRemaining: Int {
        guard let session = sessions.activeSession else { return -3 }
        if case .trigger = session.source { return -1 }
        switch session.endCondition {
        case .indefinitely:
            return 0
        case .whileApplicationRuns, .whileFileDownloads, .at:
            return -2
        case .after:
            return Int(ceil(session.remainingTime(at: Date()) ?? 0))
        }
    }

    var displaySleepAllowed: Bool {
        sessions.activeSession?.options.allowsDisplaySleep ?? preferences.allowsDisplaySleep
    }

    func setDisplaySleepAllowed(_ allowed: Bool) throws {
        if sessions.isActive {
            try sessions.setDisplaySleepAllowed(allowed)
        } else {
            preferences.setAllowsDisplaySleep(allowed)
        }
    }

    var screenSaverAllowed: Bool {
        sessions.isActive ? sessions.allowsScreenSaver : preferences.allowsScreenSaver
    }

    func setScreenSaverAllowed(_ allowed: Bool) {
        if sessions.isActive {
            sessions.setScreenSaverPolicy(allowed
                ? .allow(after: TimeInterval(preferences.screenSaverDelayMinutes * 60))
                : .prevent)
        } else {
            preferences.setAllowsScreenSaver(allowed)
        }
    }

    var closedDisplayModeEnabled: Bool {
        guard sessions.closedDisplayModeSupported else { return false }
        return sessions.isActive
            ? !sessions.allowsClosedDisplaySleep
            : !preferences.allowsClosedDisplaySleep
    }

    func setClosedDisplayModeEnabled(_ enabled: Bool) async -> Bool {
        guard sessions.closedDisplayModeSupported else { return false }
        if sessions.isActive {
            do {
                try await sessions.setClosedDisplaySleepAllowed(!enabled)
                return true
            } catch {
                return false
            }
        }
        preferences.setAllowsClosedDisplaySleep(!enabled)
        return true
    }

    var sessionIsTrigger: Bool {
        guard let session = sessions.activeSession else { return false }
        if case .trigger = session.source { return true }
        return false
    }

    var triggersAreEnabled: Bool { triggerStore.isEnabled }

    func setTriggersEnabled(_ enabled: Bool) async {
        triggerStore.setEnabled(enabled)
        await triggerCoordinator.evaluate(snapshot: triggerCoordinator.currentSnapshot)
    }

    var driveAliveIsEnabled: Bool { driveAliveStore.isEnabled }

    func setDriveAliveEnabled(_ enabled: Bool) async {
        driveAliveStore.setEnabled(enabled)
        await driveAlive.refresh()
    }

    static func sessionRequest(
        options: Any?,
        preferences: AwakeSessionPreferences
    ) throws -> AwakeSessionRequest {
        guard let options else { return preferences.defaultRequest(source: .appleScript) }
        guard let dictionary = optionDictionary(from: options) else {
            throw OpenFindScriptError.invalidSessionOptions
        }
        var normalized: [String: Any] = [:]
        for (key, value) in dictionary {
            let normalizedKey = String(describing: key)
                .lowercased()
                .filter(\.isLetter)
            if !normalizedKey.isEmpty { normalized[normalizedKey] = value }
        }
        let duration = integerValue(normalized["duration"])
        let interval = intervalValue(normalized["interval"])
        let displaySleepAllowed = boolValue(
            normalized["displaysleepallowed"] ?? normalized["displaysleep"]
        ) ?? preferences.allowsDisplaySleep

        let endCondition: AwakeSessionEndCondition
        if duration == nil, interval == nil {
            endCondition = preferences.defaultEndCondition
        } else if duration == 0, interval == .indefinite {
            endCondition = .indefinitely
        } else if let duration, duration > 0, let interval, interval != .indefinite {
            let multiplier = interval == .hours ? 3_600.0 : 60.0
            let seconds = Double(duration) * multiplier
            guard seconds.isFinite, seconds > 0, seconds <= 7 * 24 * 60 * 60 else {
                throw OpenFindScriptError.invalidSessionOptions
            }
            endCondition = .after(seconds)
        } else {
            throw OpenFindScriptError.invalidSessionOptions
        }

        var sessionOptions = preferences.sessionOptions
        sessionOptions.allowsDisplaySleep = displaySleepAllowed
        return AwakeSessionRequest(
            endCondition: endCondition,
            options: sessionOptions,
            source: .appleScript
        )
    }

    private static func optionDictionary(from value: Any) -> NSDictionary? {
        if let dictionary = value as? NSDictionary { return dictionary }
        guard let descriptor = value as? NSAppleEventDescriptor,
              descriptor.isRecordDescriptor,
              let fields = descriptor.forKeyword(userRecordFieldsKeyword),
              fields.numberOfItems.isMultiple(of: 2) else { return nil }

        var dictionary: [String: Any] = [:]
        var index = 1
        while index <= fields.numberOfItems {
            guard let keyDescriptor = fields.atIndex(index),
                  let key = keyDescriptor.stringValue,
                  let valueDescriptor = fields.atIndex(index + 1) else {
                return nil
            }
            dictionary[key] = valueDescriptor
            index += 2
        }
        return dictionary as NSDictionary
    }

    private static let userRecordFieldsKeyword: AEKeyword = {
        "usrf".utf8.reduce(0) { (partial, byte) in
            (partial << 8) | AEKeyword(byte)
        }
    }()

    private enum ScriptInterval: Equatable {
        case minutes
        case hours
        case indefinite
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let descriptor = value as? NSAppleEventDescriptor {
            switch descriptor.descriptorType {
            case typeSInt16, typeSInt32, typeSInt64:
                return Int(descriptor.int32Value)
            default:
                break
            }
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        if let descriptor = value as? NSAppleEventDescriptor,
           [typeBoolean, typeTrue, typeFalse].contains(descriptor.descriptorType) {
            return descriptor.booleanValue
        }
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func intervalValue(_ value: Any?) -> ScriptInterval? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            switch number.intValue {
            case 0: return .indefinite
            case 60: return .minutes
            case 3_600: return .hours
            default: break
            }
        }
        let raw: String
        if let descriptor = value as? NSAppleEventDescriptor {
            if [typeSInt16, typeSInt32, typeSInt64].contains(descriptor.descriptorType) {
                switch descriptor.int32Value {
                case 0: return .indefinite
                case 60: return .minutes
                case 3_600: return .hours
                default: break
                }
            }
            if descriptor.descriptorType == typeEnumerated {
                // AppleScript's built-in `minutes` and `hours` values are
                // encoded as their duration in seconds in a user record.
                switch descriptor.enumCodeValue {
                case 0: return .indefinite
                case 60: return .minutes
                case 3_600: return .hours
                default: break
                }
                raw = fourCharacterString(descriptor.enumCodeValue)
            } else {
                raw = descriptor.stringValue ?? ""
            }
        } else {
            raw = String(describing: value)
        }
        let normalized = raw.lowercased()
        if normalized.contains("hour") { return .hours }
        if normalized.contains("min") { return .minutes }
        if normalized == "0" || normalized.contains("indef") { return .indefinite }
        return nil
    }

    private static func fourCharacterString(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }
}

@objc(OpenFindScriptCommand)
final class OpenFindScriptCommand: NSScriptCommand {
    private static let optionsKeyword: AEKeyword = {
        "optn".utf8.reduce(0) { (partial, byte) in
            (partial << 8) | AEKeyword(byte)
        }
    }()
    override func execute() -> Any? {
        // The Cocoa validator rejects user-record parameters before it reaches
        // `performDefaultImplementation` on current macOS. OpenFind has no
        // receiver/object-specifier commands, so dispatch directly and parse
        // the raw event descriptor ourselves.
        performDefaultImplementation()
    }

    override func performDefaultImplementation() -> Any? {
        // NSScriptCommand is explicitly non-Sendable in current SDKs, but its
        // implementation must touch the AppKit graph on the main actor. The
        // box records that this single command reference is synchronously
        // handed off and never used concurrently by this method.
        let command = OpenFindScriptCommandBox(self)
        let result: OpenFindScriptResultBox
        if Thread.isMainThread {
            result = MainActor.assumeIsolated {
                OpenFindScriptResultBox(command.value.performOnMainActor())
            }
        } else {
            result = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    OpenFindScriptResultBox(command.value.performOnMainActor())
                }
            }
        }
        return result.value
    }

    @MainActor
    private func performOnMainActor() -> Any? {
        guard let delegate = AppDelegate.shared ?? (NSApp.delegate as? AppDelegate) else {
            setError(OpenFindScriptError.unavailable)
            return nil
        }
        let service = OpenFindScriptingService(delegate: delegate)
        switch commandDescription.commandName.lowercased() {
        case "session is active":
            return NSNumber(value: service.sessionIsActive)
        case "start new session":
            // Cocoa's evaluated-arguments bridge cannot materialize the
            // user-record form emitted by AppleScript on recent macOS. Read
            // the raw `optn` descriptor first, then retain the dictionary
            // bridge as a fallback for programmatic NSScriptCommand users.
            let options = appleEvent?.paramDescriptor(forKeyword: Self.optionsKeyword)
                ?? evaluatedArguments?["options"]
                ?? arguments?["options"]
            do {
                let request = try service.sessionRequest(options: options)
                return suspendAndRun {
                    NSNumber(value: await service.startNewSession(request: request))
                }
            } catch {
                setError(error)
                return nil
            }
        case "end session":
            return suspendAndRun { NSNumber(value: await service.endSession()) }
        case "session time remaining":
            return NSNumber(value: service.sessionTimeRemaining)
        case "display sleep allowed":
            return NSNumber(value: service.displaySleepAllowed)
        case "allow display sleep":
            return performSync { try service.setDisplaySleepAllowed(true) }
        case "prevent display sleep":
            return performSync { try service.setDisplaySleepAllowed(false) }
        case "screen saver allowed":
            return NSNumber(value: service.screenSaverAllowed)
        case "allow screen saver":
            service.setScreenSaverAllowed(true)
            return nil
        case "prevent screen saver":
            service.setScreenSaverAllowed(false)
            return nil
        case "closed display mode enabled":
            return NSNumber(value: service.closedDisplayModeEnabled)
        case "enable closed display mode":
            return suspendAndRun {
                NSNumber(value: await service.setClosedDisplayModeEnabled(true))
            }
        case "disable closed display mode":
            return suspendAndRun {
                NSNumber(value: await service.setClosedDisplayModeEnabled(false))
            }
        case "session is trigger":
            return NSNumber(value: service.sessionIsTrigger)
        case "triggers are enabled":
            return NSNumber(value: service.triggersAreEnabled)
        case "enable triggers":
            return suspendAndRun {
                await service.setTriggersEnabled(true)
                return nil
            }
        case "disable triggers":
            return suspendAndRun {
                await service.setTriggersEnabled(false)
                return nil
            }
        case "drive alive is enabled":
            return NSNumber(value: service.driveAliveIsEnabled)
        case "enable drive alive":
            return suspendAndRun {
                await service.setDriveAliveEnabled(true)
                return nil
            }
        case "disable drive alive":
            return suspendAndRun {
                await service.setDriveAliveEnabled(false)
                return nil
            }
        case "give molecule":
            NSSound.beep()
            NSApp.requestUserAttention(.informationalRequest)
            return nil
        default:
            setError(OpenFindScriptError.unavailable)
            return nil
        }
    }

    @MainActor
    private func performSync(_ operation: () throws -> Void) -> Any? {
        do {
            try operation()
            return nil
        } catch {
            setError(error)
            return nil
        }
    }

    @MainActor
    private func suspendAndRun(
        _ operation: @escaping @MainActor () async throws -> Any?
    ) -> Any? {
        suspendExecution()
        Task { @MainActor [self] in
            do {
                resumeExecution(withResult: try await operation())
            } catch {
                setError(error)
                resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    @MainActor
    private func setError(_ error: Error) {
        scriptErrorNumber = NSInternalScriptError
        scriptErrorString = error.localizedDescription
    }
}

private final class OpenFindScriptCommandBox: @unchecked Sendable {
    let value: OpenFindScriptCommand

    init(_ value: OpenFindScriptCommand) {
        self.value = value
    }
}

private final class OpenFindScriptResultBox: @unchecked Sendable {
    let value: Any?

    init(_ value: Any?) {
        self.value = value
    }
}
