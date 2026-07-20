import SwiftUI

struct AwakeAutomationSettingsSection: View {
    @Bindable var preferences: AwakeSessionPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Section {
            Toggle(L("Launch OpenFind at Login"), isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .disabled(launchAtLogin.status == .unavailable)

            if launchAtLogin.status == .requiresApproval {
                LabeledContent {
                    Button(L("Open Login Items Settings")) {
                        launchAtLogin.openSystemSettings()
                    }
                } label: {
                    Label(L("Login Item Requires Approval"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else if launchAtLogin.status == .unavailable {
                Label(L("Launch at Login Unavailable"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Toggle(L("Start Session When OpenFind Launches"), isOn: Binding(
                get: { preferences.startsSessionAtLaunch },
                set: { preferences.setStartsSessionAtLaunch($0) }
            ))
            Toggle(L("Start Session After Waking"), isOn: Binding(
                get: { preferences.startsSessionAfterWake },
                set: { preferences.setStartsSessionAfterWake($0) }
            ))
            Toggle(L("End Session on Forced Sleep"), isOn: Binding(
                get: { preferences.endsSessionOnForcedSleep },
                set: { preferences.setEndsSessionOnForcedSleep($0) }
            ))
            Toggle(L("End Session When User Session Becomes Inactive"), isOn: Binding(
                get: { preferences.endsSessionOnSessionResign },
                set: { preferences.setEndsSessionOnSessionResign($0) }
            ))

            Toggle(L("End Session on Low Battery"), isOn: Binding(
                get: { preferences.lowBatteryEndEnabled },
                set: { preferences.setLowBatteryEndEnabled($0) }
            ))
            if preferences.lowBatteryEndEnabled {
                Stepper(
                    value: Binding(
                        get: { preferences.lowBatteryThreshold },
                        set: { preferences.setLowBatteryThreshold($0) }
                    ),
                    in: 1...100
                ) {
                    LabeledContent(L("Low Battery Threshold")) {
                        Text(lowBatteryThresholdText)
                            .monospacedDigit()
                    }
                }
                Toggle(L("Prompt Before Ending for Low Battery"), isOn: Binding(
                    get: { preferences.promptsBeforeLowBatteryEnd },
                    set: { preferences.setPromptsBeforeLowBatteryEnd($0) }
                ))
                Toggle(L("Ignore Low Battery While on AC Power"), isOn: Binding(
                    get: { preferences.ignoresLowBatteryWhileOnAC },
                    set: { preferences.setIgnoresLowBatteryWhileOnAC($0) }
                ))
                Toggle(L("Restart Session After AC Reconnect"), isOn: Binding(
                    get: { preferences.restartsSessionAfterACReconnect },
                    set: { preferences.setRestartsSessionAfterACReconnect($0) }
                ))
            }

            if let error = launchAtLogin.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(L("Dismiss Error")) { launchAtLogin.clearError() }
            }
        } header: {
            Text(L("Awake Automation"))
        } footer: {
            Text(L("Awake Automation Help"))
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var lowBatteryThresholdText: String {
        if preferences.lowBatteryThreshold == 100 {
            return L("When AC Power Disconnects")
        }
        return "\(preferences.lowBatteryThreshold)%"
    }

}
