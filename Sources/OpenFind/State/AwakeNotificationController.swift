import AppKit
import AudioToolbox
import Foundation
import Observation
import UserNotifications

struct AwakeNotificationPayload: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let playsSound: Bool
}

@MainActor
protocol AwakeNotificationDelivering: AnyObject {
    func requestAuthorization() async throws -> Bool
    func deliver(_ payload: AwakeNotificationPayload) async throws
    func removeDeliveredNotifications()
}

@MainActor
final class SystemAwakeNotificationDelivery: AwakeNotificationDelivering {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ payload: AwakeNotificationPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        if payload.playsSound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    func removeDeliveredNotifications() {
        center.removeDeliveredNotifications(withIdentifiers: [
            AwakeNotificationController.startNotificationID,
            AwakeNotificationController.endNotificationID,
            AwakeNotificationController.reminderNotificationID,
            AwakeNotificationController.closedDisplayWarningNotificationID,
        ])
    }
}

@MainActor
protocol SessionSoundPlaying: AnyObject {
    func play()
}

@MainActor
final class SystemSessionSoundPlayer: SessionSoundPlaying {
    func play() {
        NSSound.beep()
    }
}

@MainActor
protocol ClosedDisplayWarningSoundPlaying: AnyObject {
    func play(temporaryVolumePercentage: Int?)
    func restoreVolume()
}

@MainActor
final class SystemClosedDisplayWarningSoundPlayer: ClosedDisplayWarningSoundPlaying {
    private var restoreTask: Task<Void, Never>?
    private var originalVolume: Float32?
    private var outputDevice: AudioDeviceID?

    func play(temporaryVolumePercentage: Int?) {
        if let percentage = temporaryVolumePercentage,
           let device = defaultOutputDevice(),
           let currentVolume = volume(device: device) {
            if let outputDevice, outputDevice != device {
                // The default route can change while a previous warning's
                // one-second restore window is still open. Restore that route
                // before touching the new one so neither device is stranded at
                // the temporary warning volume.
                restoreVolume()
            }
            let warningVolume = Float32(min(100, max(0, percentage))) / 100
            if originalVolume == nil, setVolume(warningVolume, device: device) {
                originalVolume = currentVolume
                outputDevice = device
            } else if originalVolume != nil {
                _ = setVolume(warningVolume, device: device)
            }
        }
        NSSound.beep()
        scheduleRestore()
    }

    func restoreVolume() {
        restoreTask?.cancel()
        restoreTask = nil
        if let originalVolume, let outputDevice {
            _ = setVolume(originalVolume, device: outputDevice)
        }
        originalVolume = nil
        outputDevice = nil
    }

    private func scheduleRestore() {
        guard originalVolume != nil else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            self?.restoreVolume()
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        HardwareTriggerSignals.defaultOutputDevice()
    }

    private func volume(device: AudioDeviceID) -> Float32? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    @discardableResult
    private func setVolume(_ volume: Float32, device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var value = min(1, max(0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

@MainActor
protocol ClosedDisplayWarningEnvironmentProviding: AnyObject {
    var suppressesWarning: Bool { get }
    func start(handler: @escaping @MainActor () -> Void)
    func stop()
}

/// Amphetamine intentionally omits the closed-display warning when the Mac is
/// already in the ordinary supported clamshell configuration: external power
/// plus an external display. Re-evaluate that exception on both power-route and
/// display-topology changes.
@MainActor
final class SystemClosedDisplayWarningEnvironment: ClosedDisplayWarningEnvironmentProviding {
    private let powerMonitor: any PowerSourceMonitoring
    private let applicationCenter: NotificationCenter
    private var displayObserver: NSObjectProtocol?
    private var adapterConnected: Bool?
    private var handler: (@MainActor () -> Void)?

    init(
        powerMonitor: any PowerSourceMonitoring = SystemPowerSourceMonitor(),
        applicationCenter: NotificationCenter = .default
    ) {
        self.powerMonitor = powerMonitor
        self.applicationCenter = applicationCenter
        adapterConnected = powerMonitor.snapshot().adapterConnected
    }

    var suppressesWarning: Bool {
        adapterConnected == true && NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
    }

    func start(handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler
        powerMonitor.start { [weak self] snapshot in
            guard let self else { return }
            let changed = self.adapterConnected != snapshot.adapterConnected
            self.adapterConnected = snapshot.adapterConnected
            if changed { self.handler?() }
        }
        displayObserver = applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?() }
        }
    }

    func stop() {
        powerMonitor.stop()
        if let displayObserver { applicationCenter.removeObserver(displayObserver) }
        displayObserver = nil
        handler = nil
    }
}

@MainActor
@Observable
final class AwakeNotificationController {
    static let startNotificationID = "OpenFind.awake.notification.start"
    static let endNotificationID = "OpenFind.awake.notification.end"
    static let reminderNotificationID = "OpenFind.awake.notification.reminder"
    static let closedDisplayWarningNotificationID = "OpenFind.awake.notification.closed-display"

    private static let automaticStartKey = "OpenFind.awakeNotifications.automaticStartV1"
    private static let automaticEndKey = "OpenFind.awakeNotifications.automaticEndV1"
    private static let remindersKey = "OpenFind.awakeNotifications.remindersV1"
    private static let reminderMinutesKey = "OpenFind.awakeNotifications.reminderMinutesV1"
    private static let notificationSoundKey = "OpenFind.awakeNotifications.notificationSoundV1"
    private static let startEndSoundKey = "OpenFind.awakeNotifications.startEndSoundV1"
    private static let replacementSoundKey = "OpenFind.awakeNotifications.replacementSoundV1"
    private static let cleanupKey = "OpenFind.awakeNotifications.cleanupV1"
    private static let closedDisplayWarningKey = "OpenFind.awakeNotifications.closedDisplayWarningV1"
    private static let repeatClosedDisplayWarningKey = "OpenFind.awakeNotifications.repeatClosedDisplayWarningV1"
    private static let closedDisplayWarningMinutesKey = "OpenFind.awakeNotifications.closedDisplayWarningMinutesV1"
    private static let adjustClosedDisplayWarningVolumeKey = "OpenFind.awakeNotifications.adjustClosedDisplayWarningVolumeV1"
    private static let closedDisplayWarningVolumeKey = "OpenFind.awakeNotifications.closedDisplayWarningVolumeV1"

    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let delivery: any AwakeNotificationDelivering
    @ObservationIgnored private let soundPlayer: any SessionSoundPlaying
    @ObservationIgnored private let closedDisplayWarningSound: any ClosedDisplayWarningSoundPlaying
    @ObservationIgnored private let closedDisplayState: any ClosedDisplayStateMonitoring
    @ObservationIgnored private let closedDisplayWarningEnvironment: any ClosedDisplayWarningEnvironmentProviding
    @ObservationIgnored private let secondsPerReminderMinute: TimeInterval
    @ObservationIgnored private let secondsPerClosedDisplayWarningMinute: TimeInterval
    @ObservationIgnored private var subscription: AwakeSessionEventSubscription?
    @ObservationIgnored private var reminderTask: Task<Void, Never>?
    @ObservationIgnored private var closedDisplayWarningTask: Task<Void, Never>?
    private var closedDisplayStateValue: ClosedDisplayHardwareState = .unknown
    private var warnedClosedDisplaySessionID: UUID?

    private(set) var notifiesAutomaticStarts: Bool
    private(set) var notifiesAutomaticEnds: Bool
    private(set) var remindersEnabled: Bool
    private(set) var reminderIntervalMinutes: Int
    private(set) var playsNotificationSounds: Bool
    private(set) var playsStartEndSounds: Bool
    private(set) var playsReplacementSounds: Bool
    private(set) var removesDeliveredNotifications: Bool
    private(set) var warnsClosedDisplay: Bool
    private(set) var repeatsClosedDisplayWarning: Bool
    private(set) var closedDisplayWarningIntervalMinutes: Int
    private(set) var adjustsClosedDisplayWarningVolume: Bool
    private(set) var closedDisplayWarningVolumePercentage: Int
    private(set) var lastErrorMessage: String?

    init(
        sessions: AwakeSessionController,
        defaults: UserDefaults = .standard,
        delivery: any AwakeNotificationDelivering = SystemAwakeNotificationDelivery(),
        soundPlayer: any SessionSoundPlaying = SystemSessionSoundPlayer(),
        closedDisplayWarningSound: any ClosedDisplayWarningSoundPlaying = SystemClosedDisplayWarningSoundPlayer(),
        closedDisplayState: any ClosedDisplayStateMonitoring = SystemClosedDisplayStateMonitor(),
        closedDisplayWarningEnvironment: any ClosedDisplayWarningEnvironmentProviding = SystemClosedDisplayWarningEnvironment(),
        secondsPerReminderMinute: TimeInterval = 60,
        secondsPerClosedDisplayWarningMinute: TimeInterval = 60
    ) {
        self.sessions = sessions
        self.defaults = defaults
        self.delivery = delivery
        self.soundPlayer = soundPlayer
        self.closedDisplayWarningSound = closedDisplayWarningSound
        self.closedDisplayState = closedDisplayState
        self.closedDisplayWarningEnvironment = closedDisplayWarningEnvironment
        self.secondsPerReminderMinute = secondsPerReminderMinute
        self.secondsPerClosedDisplayWarningMinute = secondsPerClosedDisplayWarningMinute
        notifiesAutomaticStarts = defaults.bool(forKey: Self.automaticStartKey)
        notifiesAutomaticEnds = defaults.bool(forKey: Self.automaticEndKey)
        remindersEnabled = defaults.bool(forKey: Self.remindersKey)
        let storedInterval = defaults.object(forKey: Self.reminderMinutesKey) as? Int ?? 60
        reminderIntervalMinutes = min(1_440, max(1, storedInterval))
        playsNotificationSounds = defaults.bool(forKey: Self.notificationSoundKey)
        playsStartEndSounds = defaults.bool(forKey: Self.startEndSoundKey)
        playsReplacementSounds = defaults.bool(forKey: Self.replacementSoundKey)
        removesDeliveredNotifications = defaults.object(forKey: Self.cleanupKey) as? Bool ?? true
        warnsClosedDisplay = defaults.bool(forKey: Self.closedDisplayWarningKey)
        repeatsClosedDisplayWarning = defaults.bool(forKey: Self.repeatClosedDisplayWarningKey)
        let storedClosedDisplayInterval = defaults.object(
            forKey: Self.closedDisplayWarningMinutesKey
        ) as? Int ?? 5
        closedDisplayWarningIntervalMinutes = min(1_440, max(1, storedClosedDisplayInterval))
        adjustsClosedDisplayWarningVolume = defaults.bool(
            forKey: Self.adjustClosedDisplayWarningVolumeKey
        )
        let storedWarningVolume = defaults.object(forKey: Self.closedDisplayWarningVolumeKey)
            as? Int ?? 5
        closedDisplayWarningVolumePercentage = min(100, max(0, storedWarningVolume))
    }

    func start() {
        guard subscription == nil else { return }
        subscription = sessions.observeEvents { [weak self] event in
            self?.handle(event)
        }
        if remindersEnabled, let session = sessions.activeSession {
            scheduleReminders(for: session.id)
        }
        closedDisplayWarningEnvironment.start { [weak self] in
            self?.refreshClosedDisplayWarning()
        }
        closedDisplayState.start { [weak self] state in
            self?.handleClosedDisplayState(state)
        }
        if notifiesAutomaticStarts || notifiesAutomaticEnds || remindersEnabled
            || warnsClosedDisplay {
            requestAuthorization()
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        reminderTask?.cancel()
        reminderTask = nil
        closedDisplayWarningTask?.cancel()
        closedDisplayWarningTask = nil
        closedDisplayState.stop()
        closedDisplayWarningEnvironment.stop()
        closedDisplayWarningSound.restoreVolume()
        warnedClosedDisplaySessionID = nil
        closedDisplayStateValue = .unknown
    }

    func setNotifiesAutomaticStarts(_ enabled: Bool) {
        notifiesAutomaticStarts = enabled
        defaults.set(enabled, forKey: Self.automaticStartKey)
        if enabled { requestAuthorization() }
    }

    func setNotifiesAutomaticEnds(_ enabled: Bool) {
        notifiesAutomaticEnds = enabled
        defaults.set(enabled, forKey: Self.automaticEndKey)
        if enabled { requestAuthorization() }
    }

    func setRemindersEnabled(_ enabled: Bool) {
        remindersEnabled = enabled
        defaults.set(enabled, forKey: Self.remindersKey)
        reminderTask?.cancel()
        reminderTask = nil
        if enabled {
            requestAuthorization()
            if let session = sessions.activeSession { scheduleReminders(for: session.id) }
        }
    }

    func setReminderIntervalMinutes(_ minutes: Int) {
        reminderIntervalMinutes = min(1_440, max(1, minutes))
        defaults.set(reminderIntervalMinutes, forKey: Self.reminderMinutesKey)
        if remindersEnabled, let session = sessions.activeSession {
            scheduleReminders(for: session.id)
        }
    }

    func setPlaysNotificationSounds(_ enabled: Bool) {
        playsNotificationSounds = enabled
        defaults.set(enabled, forKey: Self.notificationSoundKey)
        if enabled { requestAuthorization() }
    }

    func setPlaysStartEndSounds(_ enabled: Bool) {
        playsStartEndSounds = enabled
        defaults.set(enabled, forKey: Self.startEndSoundKey)
    }

    func setPlaysReplacementSounds(_ enabled: Bool) {
        playsReplacementSounds = enabled
        defaults.set(enabled, forKey: Self.replacementSoundKey)
    }

    func setRemovesDeliveredNotifications(_ enabled: Bool) {
        removesDeliveredNotifications = enabled
        defaults.set(enabled, forKey: Self.cleanupKey)
        if enabled { delivery.removeDeliveredNotifications() }
    }

    func setWarnsClosedDisplay(_ enabled: Bool) {
        warnsClosedDisplay = enabled
        defaults.set(enabled, forKey: Self.closedDisplayWarningKey)
        if enabled {
            requestAuthorization()
            refreshClosedDisplayWarning()
        } else {
            cancelClosedDisplayWarning(resetSession: true)
        }
    }

    func setRepeatsClosedDisplayWarning(_ enabled: Bool) {
        repeatsClosedDisplayWarning = enabled
        defaults.set(enabled, forKey: Self.repeatClosedDisplayWarningKey)
        if enabled {
            refreshClosedDisplayWarning()
        } else {
            closedDisplayWarningTask?.cancel()
            closedDisplayWarningTask = nil
        }
    }

    func setClosedDisplayWarningIntervalMinutes(_ minutes: Int) {
        closedDisplayWarningIntervalMinutes = min(1_440, max(1, minutes))
        defaults.set(
            closedDisplayWarningIntervalMinutes,
            forKey: Self.closedDisplayWarningMinutesKey
        )
        if repeatsClosedDisplayWarning { scheduleClosedDisplayWarningRepeats() }
    }

    func setAdjustsClosedDisplayWarningVolume(_ enabled: Bool) {
        adjustsClosedDisplayWarningVolume = enabled
        defaults.set(enabled, forKey: Self.adjustClosedDisplayWarningVolumeKey)
        if !enabled { closedDisplayWarningSound.restoreVolume() }
    }

    func setClosedDisplayWarningVolumePercentage(_ percentage: Int) {
        closedDisplayWarningVolumePercentage = min(100, max(0, percentage))
        defaults.set(
            closedDisplayWarningVolumePercentage,
            forKey: Self.closedDisplayWarningVolumeKey
        )
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func handle(_ event: AwakeSessionEvent) {
        switch event {
        case let .started(session):
            if playsStartEndSounds { soundPlayer.play() }
            if notifiesAutomaticStarts, isAutomaticSource(session.source) {
                deliver(
                    identifier: Self.startNotificationID,
                    title: L("Awake Session Started"),
                    body: L("OpenFind Is Keeping Mac Awake")
                )
            }
            if remindersEnabled { scheduleReminders(for: session.id) }
            refreshClosedDisplayWarning(for: session)
        case let .replaced(_, current):
            if playsReplacementSounds { soundPlayer.play() }
            if remindersEnabled { scheduleReminders(for: current.id) }
            refreshClosedDisplayWarning(for: current)
        case let .updated(session):
            refreshClosedDisplayWarning(for: session)
        case let .ended(_, reason):
            reminderTask?.cancel()
            reminderTask = nil
            cancelClosedDisplayWarning(resetSession: true)
            if reason != .applicationTermination, playsStartEndSounds { soundPlayer.play() }
            if notifiesAutomaticEnds, isAutomaticEnd(reason) {
                deliver(
                    identifier: Self.endNotificationID,
                    title: L("Awake Session Ended"),
                    body: L("Mac Will Use Normal Sleep Schedule")
                )
            }
        }
    }

    private func handleClosedDisplayState(_ state: ClosedDisplayHardwareState) {
        closedDisplayStateValue = state
        if state == .closed {
            refreshClosedDisplayWarning()
        } else {
            cancelClosedDisplayWarning(resetSession: true)
        }
    }

    private func refreshClosedDisplayWarning(for session: AwakeSession? = nil) {
        guard warnsClosedDisplay,
              closedDisplayStateValue == .closed,
              let session = session ?? sessions.activeSession,
              !session.options.allowsClosedDisplaySleep,
              !closedDisplayWarningEnvironment.suppressesWarning else {
            cancelClosedDisplayWarning(resetSession: true)
            return
        }
        if warnedClosedDisplaySessionID != session.id {
            warnedClosedDisplaySessionID = session.id
            emitClosedDisplayWarning()
        }
        scheduleClosedDisplayWarningRepeats()
    }

    private func scheduleClosedDisplayWarningRepeats() {
        closedDisplayWarningTask?.cancel()
        closedDisplayWarningTask = nil
        guard warnsClosedDisplay,
              repeatsClosedDisplayWarning,
              closedDisplayStateValue == .closed,
              let sessionID = warnedClosedDisplaySessionID else { return }
        let delay = TimeInterval(closedDisplayWarningIntervalMinutes)
            * secondsPerClosedDisplayWarningMinute
        guard delay.isFinite, delay > 0 else { return }
        closedDisplayWarningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard self.warnsClosedDisplay,
                      self.repeatsClosedDisplayWarning,
                      self.closedDisplayStateValue == .closed,
                      let session = self.sessions.activeSession,
                      session.id == sessionID,
                      !session.options.allowsClosedDisplaySleep,
                      !self.closedDisplayWarningEnvironment.suppressesWarning else { return }
                self.emitClosedDisplayWarning()
            }
        }
    }

    private func cancelClosedDisplayWarning(resetSession: Bool) {
        closedDisplayWarningTask?.cancel()
        closedDisplayWarningTask = nil
        closedDisplayWarningSound.restoreVolume()
        if resetSession { warnedClosedDisplaySessionID = nil }
    }

    private func emitClosedDisplayWarning() {
        closedDisplayWarningSound.play(
            temporaryVolumePercentage: adjustsClosedDisplayWarningVolume
                ? closedDisplayWarningVolumePercentage
                : nil
        )
        deliver(
            identifier: Self.closedDisplayWarningNotificationID,
            title: L("Closed Display Session Active"),
            body: L("Closed Display Warning Body"),
            playsSound: false,
            requiredSessionID: warnedClosedDisplaySessionID
        )
    }

    private func scheduleReminders(for sessionID: UUID) {
        reminderTask?.cancel()
        let delay = TimeInterval(reminderIntervalMinutes) * secondsPerReminderMinute
        guard delay.isFinite, delay > 0 else { return }
        reminderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard self.sessions.activeSession?.id == sessionID else { return }
                self.deliver(
                    identifier: Self.reminderNotificationID,
                    title: L("Awake Session Reminder"),
                    body: L("OpenFind Is Still Keeping Mac Awake"),
                    requiredSessionID: sessionID
                )
            }
        }
    }

    private func requestAuthorization() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard try await self.delivery.requestAuthorization() else {
                    self.lastErrorMessage = L("Notification Permission Denied")
                    return
                }
                self.lastErrorMessage = nil
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func deliver(
        identifier: String,
        title: String,
        body: String,
        playsSound: Bool? = nil,
        requiredSessionID: UUID? = nil
    ) {
        let payload = AwakeNotificationPayload(
            identifier: identifier,
            title: title,
            body: body,
            playsSound: playsSound ?? playsNotificationSounds
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let requiredSessionID,
               self.sessions.activeSession?.id != requiredSessionID {
                return
            }
            do {
                if self.removesDeliveredNotifications {
                    self.delivery.removeDeliveredNotifications()
                }
                if let requiredSessionID,
                   self.sessions.activeSession?.id != requiredSessionID {
                    return
                }
                try await self.delivery.deliver(payload)
                self.lastErrorMessage = nil
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func isAutomaticSource(_ source: AwakeSessionSource) -> Bool {
        switch source {
        case .manual, .appleScript:
            false
        case .trigger, .applicationLaunch, .wake, .powerAdapter:
            true
        }
    }

    private func isAutomaticEnd(_ reason: AwakeSessionEndReason) -> Bool {
        switch reason {
        case .requested, .applicationTermination:
            false
        case .deadline, .condition, .triggerCondition, .forcedSleep, .sessionResign,
             .lowBattery, .closedDisplayPowerChange:
            true
        }
    }
}
