import SwiftUI

struct AwakeSessionDefaultsSection: View {
    @Bindable var preferences: AwakeSessionPreferences
    let closedDisplaySupported: Bool
    @State private var screenSaverExceptionsText = ""

    var body: some View {
        Group {
            Section {
                Toggle(L("Use Timed Session by Default"), isOn: Binding(
                    get: { preferences.defaultDurationMinutes != nil },
                    set: { preferences.setDefaultDurationMinutes($0 ? 60 : nil) }
                ))
                if preferences.defaultDurationMinutes != nil {
                    Stepper(
                        value: Binding(
                            get: { preferences.defaultDurationMinutes ?? 60 },
                            set: { preferences.setDefaultDurationMinutes($0) }
                        ),
                        in: 1...(7 * 24 * 60)
                    ) {
                        LabeledContent(L("Default Duration")) {
                            Text(defaultDurationText)
                                .monospacedDigit()
                        }
                    }
                }
                Picker(L("End Time Calculation"), selection: Binding(
                    get: { preferences.endTimeCalculation },
                    set: { preferences.setEndTimeCalculation($0) }
                )) {
                    Text(L("Timer")).tag(AwakeEndTimeCalculation.timer)
                    Text(L("System Clock")).tag(AwakeEndTimeCalculation.systemClock)
                }
                Toggle(L("Allow Display Sleep"), isOn: Binding(
                    get: { preferences.allowsDisplaySleep },
                    set: { preferences.setAllowsDisplaySleep($0) }
                ))
                Toggle(L("Allow Screen Saver"), isOn: Binding(
                    get: { preferences.allowsScreenSaver },
                    set: { preferences.setAllowsScreenSaver($0) }
                ))
                if preferences.allowsScreenSaver {
                    Picker(L("Screen Saver Delay"), selection: Binding(
                        get: { preferences.screenSaverDelayMinutes },
                        set: { preferences.setScreenSaverDelayMinutes($0) }
                    )) {
                        ForEach([0, 5, 10, 15, 30, 60], id: \.self) { minutes in
                            Text(String(format: L("Minutes Format"), minutes)).tag(minutes)
                        }
                    }
                    TextField(
                        L("Screen Saver Exception Identifiers"),
                        text: $screenSaverExceptionsText,
                        axis: .vertical
                    )
                        .lineLimit(2...4)
                    Button(L("Save Screen Saver Exceptions")) {
                        let identifiers = Set(screenSaverExceptionsText
                            .components(separatedBy: CharacterSet(charactersIn: ",\n")))
                        preferences.setScreenSaverExceptionIdentifiers(identifiers)
                        screenSaverExceptionsText = preferences.screenSaverExceptionIdentifiers
                            .sorted()
                            .joined(separator: ", ")
                    }
                }
                if closedDisplaySupported {
                    Toggle(L("Allow Closed Display Sleep"), isOn: Binding(
                        get: { preferences.allowsClosedDisplaySleep },
                        set: { preferences.setAllowsClosedDisplaySleep($0) }
                    ))
                }
            } header: {
                Text(L("Awake Session Defaults"))
            } footer: {
                Text(L("Awake Session Defaults Help"))
            }

            Section {
                Toggle(L("Show Session Time in Menu Bar"), isOn: Binding(
                    get: { preferences.showsSessionTimeInMenuBar },
                    set: { preferences.setShowsSessionTimeInMenuBar($0) }
                ))
                if preferences.showsSessionTimeInMenuBar {
                    Picker(L("Session Time Display"), selection: Binding(
                        get: { preferences.menuBarTimeStyle },
                        set: { preferences.setMenuBarTimeStyle($0) }
                    )) {
                        Text(L("Remaining Time")).tag(AwakeMenuBarTimeStyle.remaining)
                        Text(L("End Time")).tag(AwakeMenuBarTimeStyle.endTime)
                    }
                    if preferences.menuBarTimeStyle == .endTime {
                        Toggle(L("Use 24-Hour Clock"), isOn: Binding(
                            get: { preferences.uses24HourClock },
                            set: { preferences.setUses24HourClock($0) }
                        ))
                    }
                    Toggle(L("Include Seconds"), isOn: Binding(
                        get: { preferences.includesSecondsInMenuBar },
                        set: { preferences.setIncludesSecondsInMenuBar($0) }
                    ))
                }
            } header: {
                Text(L("Menu Bar Session Time"))
            } footer: {
                Text(L("Menu Bar Session Time Help"))
            }
        }
        .onAppear {
            screenSaverExceptionsText = preferences.screenSaverExceptionIdentifiers
                .sorted()
                .joined(separator: ", ")
        }
    }

    private var defaultDurationText: String {
        let totalMinutes = preferences.defaultDurationMinutes ?? 0
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return String(format: L("Duration Days Hours Minutes Format"), days, hours, minutes)
        }
        return String(format: L("Duration Hours Minutes Format"), hours, minutes)
    }
}
