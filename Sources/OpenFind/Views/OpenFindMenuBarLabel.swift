import SwiftUI

struct OpenFindMenuBarLabel: View {
    @Bindable var controller: AwakeSessionController
    @Bindable var preferences: AwakeSessionPreferences

    @ViewBuilder
    var body: some View {
        if preferences.showsSessionTimeInMenuBar, controller.isActive {
            TimelineView(.periodic(from: .now, by: refreshInterval)) { context in
                label(timeText: sessionTimeText(at: context.date))
            }
        } else {
            label(timeText: nil)
        }
    }

    private func label(timeText: String?) -> some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.make())
                .renderingMode(.template)
            if let timeText {
                Text(timeText)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(timeText: timeText))
    }

    private var refreshInterval: TimeInterval {
        preferences.includesSecondsInMenuBar ? 1 : 30
    }

    private func sessionTimeText(at now: Date) -> String? {
        guard preferences.showsSessionTimeInMenuBar,
              let session = controller.activeSession else { return nil }
        return AwakeSessionTimeFormatter.text(
            session: session,
            remainingTime: controller.remainingTime(),
            now: now,
            style: preferences.menuBarTimeStyle,
            uses24HourClock: preferences.uses24HourClock,
            includesSeconds: preferences.includesSecondsInMenuBar
        )
    }

    private func accessibilityLabel(timeText: String?) -> String {
        guard let timeText else { return "OpenFind" }
        return String(format: L("OpenFind Session Time Accessibility Format"), timeText)
    }
}
