import SwiftUI

struct AwakeMenuSection: View {
    @Bindable var controller: AwakeSessionController
    @Bindable var preferences: AwakeSessionPreferences

    var body: some View {
        Menu {
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
                Divider()
                if session.deadline != nil {
                    extensionButton(L("15 Minutes"), duration: 15 * 60)
                    extensionButton(L("30 Minutes"), duration: 30 * 60)
                    extensionButton(L("1 Hour"), duration: 60 * 60)
                    extensionButton(L("2 Hours"), duration: 2 * 60 * 60)
                    Button(L("Extend Awake Session")) {
                        guard let duration = AwakeSessionPrompt.customExtension() else { return }
                        controller.requestExtend(by: duration)
                    }
                    Divider()
                }
                sessionOptions
            } else {
                Button {
                    startSession(.indefinitely)
                } label: {
                    Label(L("Indefinitely"), systemImage: "play.fill")
                }
                extensionButton(L("15 Minutes"), duration: 15 * 60, starting: true)
                extensionButton(L("30 Minutes"), duration: 30 * 60, starting: true)
                extensionButton(L("1 Hour"), duration: 60 * 60, starting: true)
                extensionButton(L("2 Hours"), duration: 2 * 60 * 60, starting: true)
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
                Section(L("While File Is Downloading")) {
                    fileDownloadButton(L("30 Second Timeout"), timeout: 30)
                    fileDownloadButton(L("1 Minute Timeout"), timeout: 60)
                    fileDownloadButton(L("5 Minute Timeout"), timeout: 5 * 60)
                }
                Divider()
                Text(L("Next Session Options"))
                sessionOptions
            }

            if let error = controller.lastErrorMessage {
                Divider()
                Text(error)
                Button(L("Dismiss Error")) {
                    controller.clearError()
                }
            }

            if controller.isPowerTransitionInProgress {
                Label(L("Updating Keep Awake"), systemImage: "hourglass")
            }
        } label: {
            Label(
                controller.isPowerTransitionInProgress
                    ? L("Updating Keep Awake")
                    : controller.activeSession.map(statusText(for:)) ?? L("Keep Awake"),
                systemImage: controller.isActive ? "sun.max" : "moon.zzz"
            )
        }
        .disabled(controller.isPowerTransitionInProgress)
    }

    @ViewBuilder
    private var sessionOptions: some View {
        Toggle(
            L("Allow Display Sleep"),
            isOn: Binding(
                get: { controller.activeSession?.options.allowsDisplaySleep ?? preferences.allowsDisplaySleep },
                set: { enabled in
                    if controller.activeSession != nil {
                        controller.requestDisplaySleepAllowed(enabled)
                    } else {
                        preferences.setAllowsDisplaySleep(enabled)
                    }
                }
            )
        )
        Toggle(
            L("Allow Screen Saver"),
            isOn: Binding(
                get: { controller.activeSession != nil ? controller.allowsScreenSaver : preferences.allowsScreenSaver },
                set: { enabled in
                    if controller.activeSession != nil {
                        controller.requestScreenSaverAllowed(enabled)
                    } else {
                        preferences.setAllowsScreenSaver(enabled)
                    }
                }
            )
        )
        if controller.closedDisplayModeSupported {
            Toggle(
                L("Allow Closed Display Sleep"),
                isOn: Binding(
                    get: { controller.activeSession != nil ? !controller.allowsClosedDisplaySleep : !preferences.allowsClosedDisplaySleep },
                    set: { enabled in
                        if controller.activeSession != nil {
                            controller.requestClosedDisplaySleepAllowed(!enabled)
                        } else {
                            preferences.setAllowsClosedDisplaySleep(!enabled)
                        }
                    }
                )
            )
        }
    }

    private func fileDownloadButton(_ title: String, timeout: TimeInterval) -> some View {
        Button(title) {
            guard let url = FileActions.chooseFile(
                message: L("Select Downloading File"),
                prompt: L("Monitor File")
            ) else { return }
            startSession(.whileFileDownloads(url, inactivityTimeout: timeout))
        }
    }

    private func extensionButton(
        _ title: String,
        duration: TimeInterval,
        starting: Bool = false
    ) -> some View {
        Button(title) {
            if starting {
                startSession(.after(duration))
            } else {
                controller.requestExtend(by: duration)
            }
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
