import SwiftUI

struct AwakeNotificationSettingsSection: View {
    @Bindable var controller: AwakeNotificationController

    var body: some View {
        Section {
            Toggle(L("Notify Automatic Session Starts"), isOn: Binding(
                get: { controller.notifiesAutomaticStarts },
                set: { controller.setNotifiesAutomaticStarts($0) }
            ))
            Toggle(L("Notify Automatic Session Ends"), isOn: Binding(
                get: { controller.notifiesAutomaticEnds },
                set: { controller.setNotifiesAutomaticEnds($0) }
            ))
            Toggle(L("Session Reminders"), isOn: Binding(
                get: { controller.remindersEnabled },
                set: { controller.setRemindersEnabled($0) }
            ))
            if controller.remindersEnabled {
                Stepper(
                    value: Binding(
                        get: { controller.reminderIntervalMinutes },
                        set: { controller.setReminderIntervalMinutes($0) }
                    ),
                    in: 1...1_440
                ) {
                    LabeledContent(L("Reminder Interval")) {
                        Text(String(format: L("Minutes Format"), controller.reminderIntervalMinutes))
                            .monospacedDigit()
                    }
                }
            }
            Toggle(L("Play Sound with Notifications"), isOn: Binding(
                get: { controller.playsNotificationSounds },
                set: { controller.setPlaysNotificationSounds($0) }
            ))
            Toggle(L("Play Sound When Session Starts or Ends"), isOn: Binding(
                get: { controller.playsStartEndSounds },
                set: { controller.setPlaysStartEndSounds($0) }
            ))
            Toggle(L("Play Sound When Session Is Replaced"), isOn: Binding(
                get: { controller.playsReplacementSounds },
                set: { controller.setPlaysReplacementSounds($0) }
            ))
            Toggle(L("Remove Delivered Notifications"), isOn: Binding(
                get: { controller.removesDeliveredNotifications },
                set: { controller.setRemovesDeliveredNotifications($0) }
            ))
            Toggle(L("Closed Display Warnings"), isOn: Binding(
                get: { controller.warnsClosedDisplay },
                set: { controller.setWarnsClosedDisplay($0) }
            ))
            if controller.warnsClosedDisplay {
                Toggle(L("Repeat Closed Display Warning"), isOn: Binding(
                    get: { controller.repeatsClosedDisplayWarning },
                    set: { controller.setRepeatsClosedDisplayWarning($0) }
                ))
                if controller.repeatsClosedDisplayWarning {
                    Stepper(
                        value: Binding(
                            get: { controller.closedDisplayWarningIntervalMinutes },
                            set: { controller.setClosedDisplayWarningIntervalMinutes($0) }
                        ),
                        in: 1...1_440
                    ) {
                        LabeledContent(L("Closed Display Warning Interval")) {
                            Text(String(
                                format: L("Minutes Format"),
                                controller.closedDisplayWarningIntervalMinutes
                            ))
                                .monospacedDigit()
                        }
                    }
                }
                Toggle(L("Temporarily Adjust Warning Volume"), isOn: Binding(
                    get: { controller.adjustsClosedDisplayWarningVolume },
                    set: { controller.setAdjustsClosedDisplayWarningVolume($0) }
                ))
                if controller.adjustsClosedDisplayWarningVolume {
                    Stepper(
                        value: Binding(
                            get: { controller.closedDisplayWarningVolumePercentage },
                            set: { controller.setClosedDisplayWarningVolumePercentage($0) }
                        ),
                        in: 0...100,
                        step: 5
                    ) {
                        LabeledContent(L("Closed Display Warning Volume")) {
                            Text("\(controller.closedDisplayWarningVolumePercentage)%")
                                .monospacedDigit()
                        }
                    }
                }
            }
            if let error = controller.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(L("Dismiss Error")) { controller.clearError() }
            }
        } header: {
            Text(L("Notifications and Sounds"))
        } footer: {
            Text(L("Notifications and Sounds Help"))
            if controller.warnsClosedDisplay {
                Text(L("Closed Display Warning Help"))
            }
        }
    }
}
