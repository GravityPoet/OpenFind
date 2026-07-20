import SwiftUI

struct AwakeMenuSection: View {
    @Bindable var controller: AwakeSessionController
    @Bindable var preferences: AwakeSessionPreferences

    var body: some View {
        Section(L("Keep Awake")) {
            if let session = controller.activeSession {
                Text(statusText(for: session))
                Button {
                    controller.requestEnd()
                } label: {
                    Label(
                        isTriggerSession(session)
                            ? L("Disable Triggers and End Session")
                            : L("End Awake Session"),
                        systemImage: "stop.fill"
                    )
                }

                if session.deadline != nil {
                    Menu(L("Extend Awake Session")) {
                        extensionButton(L("15 Minutes"), duration: 15 * 60)
                        extensionButton(L("30 Minutes"), duration: 30 * 60)
                        extensionButton(L("1 Hour"), duration: 60 * 60)
                        extensionButton(L("2 Hours"), duration: 2 * 60 * 60)
                        Button(L("Custom Duration")) {
                            guard let duration = AwakeSessionPrompt.customExtension() else { return }
                            controller.requestExtend(by: duration)
                        }
                    }
                }

                Toggle(
                    L("Allow Display Sleep"),
                    isOn: Binding(
                        get: { session.options.allowsDisplaySleep },
                        set: { controller.requestDisplaySleepAllowed($0) }
                    )
                )

                Toggle(
                    L("Allow Screen Saver"),
                    isOn: Binding(
                        get: { controller.allowsScreenSaver },
                        set: { controller.requestScreenSaverAllowed($0) }
                    )
                )

                if controller.closedDisplayModeSupported {
                    Toggle(
                        L("Allow Closed Display Sleep"),
                        isOn: Binding(
                            get: { controller.allowsClosedDisplaySleep },
                            set: { controller.requestClosedDisplaySleepAllowed($0) }
                        )
                    )
                }
            } else {
                Menu {
                    sessionButton(L("Indefinitely"), condition: .indefinitely)
                    Divider()
                    sessionButton(L("15 Minutes"), condition: .after(15 * 60))
                    sessionButton(L("30 Minutes"), condition: .after(30 * 60))
                    sessionButton(L("1 Hour"), condition: .after(60 * 60))
                    sessionButton(L("2 Hours"), condition: .after(2 * 60 * 60))
                    Button(L("Custom Duration")) {
                        guard let duration = AwakeSessionPrompt.customDuration() else { return }
                        startSession(.after(duration))
                    }
                    Button(L("Until Date and Time")) {
                        guard let date = AwakeSessionPrompt.endDate() else { return }
                        startSession(.at(date))
                    }
                    Button(L("While Application Runs")) {
                        guard let identifier = AwakeSessionPrompt.applicationBundleIdentifier() else { return }
                        startSession(.whileApplicationRuns(bundleIdentifier: identifier))
                    }
                    Divider()
                    Menu(L("While File Is Downloading")) {
                        fileDownloadButton(L("30 Second Timeout"), timeout: 30)
                        fileDownloadButton(L("1 Minute Timeout"), timeout: 60)
                        fileDownloadButton(L("5 Minute Timeout"), timeout: 5 * 60)
                    }
                    Divider()
                    Menu(L("Next Session Options")) {
                        Toggle(L("Allow Display Sleep"), isOn: Binding(
                            get: { preferences.allowsDisplaySleep },
                            set: { preferences.setAllowsDisplaySleep($0) }
                        ))
                        Toggle(L("Allow Screen Saver"), isOn: Binding(
                            get: { preferences.allowsScreenSaver },
                            set: { preferences.setAllowsScreenSaver($0) }
                        ))
                        if controller.closedDisplayModeSupported {
                            Toggle(L("Allow Closed Display Sleep"), isOn: Binding(
                                get: { preferences.allowsClosedDisplaySleep },
                                set: { preferences.setAllowsClosedDisplaySleep($0) }
                            ))
                        }
                    }
                } label: {
                    Label(L("Start Awake Session"), systemImage: "play.fill")
                }
            }

            if let error = controller.lastErrorMessage {
                Text(error)
                Button(L("Dismiss Error")) {
                    controller.clearError()
                }
            }
        }
    }

    private func fileDownloadButton(_ title: String, timeout: TimeInterval) -> some View {
        Button(title) {
            guard let url = FileActions.chooseFile(
                message: L("Select Downloading File"),
                prompt: L("Monitor File")
            ) else { return }
            controller.requestStart(.init(
                endCondition: .whileFileDownloads(url, inactivityTimeout: timeout),
                options: preferences.sessionOptions
            ))
        }
    }

    private func sessionButton(
        _ title: String,
        condition: AwakeSessionEndCondition
    ) -> some View {
        Button(title) {
            startSession(condition)
        }
    }

    private func extensionButton(_ title: String, duration: TimeInterval) -> some View {
        Button(title) {
            controller.requestExtend(by: duration)
        }
    }

    private func startSession(_ condition: AwakeSessionEndCondition) {
        controller.requestStart(.init(
            endCondition: condition,
            options: preferences.sessionOptions
        ))
    }

    private func statusText(for session: AwakeSession) -> String {
        switch session.endCondition {
        case .whileApplicationRuns:
            return L("Awake While Application Runs")
        case .whileFileDownloads:
            return L("Awake While File Downloads")
        case .indefinitely, .after, .at:
            break
        }
        guard let deadline = session.deadline else { return L("Awake Session Active") }
        return String(format: L("Awake Until %@"), deadline.formatted(date: .omitted, time: .shortened))
    }

    private func isTriggerSession(_ session: AwakeSession) -> Bool {
        if case .trigger = session.source { return true }
        return false
    }
}
