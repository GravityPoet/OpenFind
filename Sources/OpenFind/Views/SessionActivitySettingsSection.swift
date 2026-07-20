import SwiftUI

struct SessionActivitySettingsSection: View {
    @Bindable var preferences: AwakeSessionPreferences
    @Bindable var activity: SessionActivityController

    var body: some View {
        Section {
            Toggle(L("Move Cursor During Awake Sessions"), isOn: Binding(
                get: { preferences.cursorMovementEnabled },
                set: { preferences.setCursorMovementEnabled($0) }
            ))
            if preferences.cursorMovementEnabled {
                Stepper(
                    value: Binding(
                        get: { preferences.cursorMovementIntervalSeconds },
                        set: { preferences.setCursorMovementIntervalSeconds($0) }
                    ),
                    in: 5...3_600
                ) {
                    LabeledContent(L("Move Cursor Every")) {
                        Text(secondsText(preferences.cursorMovementIntervalSeconds))
                            .monospacedDigit()
                    }
                }
                Stepper(
                    value: Binding(
                        get: { preferences.cursorInactivityThresholdSeconds },
                        set: { preferences.setCursorInactivityThresholdSeconds($0) }
                    ),
                    in: 1...86_400
                ) {
                    LabeledContent(L("Move Cursor After Inactivity")) {
                        Text(secondsText(preferences.cursorInactivityThresholdSeconds))
                            .monospacedDigit()
                    }
                }
                Picker(L("Cursor Speed"), selection: Binding(
                    get: { preferences.cursorMovementSpeed },
                    set: { preferences.setCursorMovementSpeed($0) }
                )) {
                    Text(L("Slow")).tag(CursorMovementSpeed.slow)
                    Text(L("Normal")).tag(CursorMovementSpeed.normal)
                    Text(L("Fast")).tag(CursorMovementSpeed.fast)
                }
                Toggle(L("Stop Cursor Movement Automatically"), isOn: Binding(
                    get: { preferences.cursorStopAfterSeconds != nil },
                    set: {
                        preferences.setCursorStopAfterSeconds(
                            $0 ? 600 : nil
                        )
                    }
                ))
                if let stopAfter = preferences.cursorStopAfterSeconds {
                    Stepper(
                        value: Binding(
                            get: { stopAfter },
                            set: { preferences.setCursorStopAfterSeconds($0) }
                        ),
                        in: 1...86_400
                    ) {
                        LabeledContent(L("Stop Cursor Movement After")) {
                            Text(secondsText(stopAfter)).monospacedDigit()
                        }
                    }
                }
            }

            Toggle(L("Lock Screen During Awake Sessions"), isOn: Binding(
                get: { preferences.screenLockEnabled },
                set: { preferences.setScreenLockEnabled($0) }
            ))
            if preferences.screenLockEnabled {
                Stepper(
                    value: Binding(
                        get: { preferences.screenLockInactivityThresholdSeconds },
                        set: { preferences.setScreenLockInactivityThresholdSeconds($0) }
                    ),
                    in: 1...86_400
                ) {
                    LabeledContent(L("Lock Screen After Inactivity")) {
                        Text(secondsText(preferences.screenLockInactivityThresholdSeconds))
                            .monospacedDigit()
                    }
                }
                Toggle(L("Use Cursor Movement to Determine Inactivity"), isOn: Binding(
                    get: { preferences.lockUsesCursorMovement },
                    set: { preferences.setLockUsesCursorMovement($0) }
                ))
                Toggle(L("Lock Screen When Closed Display Starts"), isOn: Binding(
                    get: { preferences.lockOnClosedDisplay },
                    set: { preferences.setLockOnClosedDisplay($0) }
                ))
                Toggle(L("Allow Display Sleep When Screen Is Locked"), isOn: Binding(
                    get: { preferences.allowsDisplaySleepWhenLocked },
                    set: { preferences.setAllowsDisplaySleepWhenLocked($0) }
                ))
            }
            if let error = activity.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(L("Dismiss Error")) { activity.clearError() }
            }
        } header: {
            Text(L("Cursor and Screen Lock"))
        } footer: {
            Text(L("Cursor and Screen Lock Help"))
        }
    }

    private func secondsText(_ seconds: Int) -> String {
        if seconds >= 3_600 {
            return String(format: L("Hours Format"), seconds / 3_600)
        }
        if seconds >= 60 {
            return String(format: L("Minutes Format"), seconds / 60)
        }
        return String(format: L("Seconds Format"), seconds)
    }
}
