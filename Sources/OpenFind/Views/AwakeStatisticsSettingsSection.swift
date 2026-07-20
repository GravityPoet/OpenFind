import SwiftUI

struct AwakeStatisticsSettingsSection: View {
    @Bindable var controller: AwakeStatisticsController

    var body: some View {
        Section {
            Toggle(L("Enable Statistics Collection"), isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            if controller.isEnabled {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        statisticRow(
                            L("Total Awake Time"),
                            duration(controller.totalDuration(at: context.date))
                        )
                        statisticRow(
                            L("Total Sessions"),
                            String(controller.sessionCount(at: context.date))
                        )
                        statisticRow(
                            L("Average Session Duration"),
                            duration(controller.averageSessionDuration(at: context.date))
                        )
                    }
                }
                Button(L("Reset Statistics"), role: .destructive) {
                    controller.reset()
                }
            }
        } header: {
            Text(L("Statistics"))
        } footer: {
            Text(L("Statistics Help"))
        }
    }

    private func statisticRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
        }
    }

    private func duration(_ interval: TimeInterval) -> String {
        let safeInterval = interval.isFinite ? interval : 0
        let rounded = Int(max(0, min(Double(Int.max), safeInterval.rounded(.down))))
        let days = rounded / 86_400
        let hours = rounded % 86_400 / 3_600
        let minutes = rounded % 3_600 / 60
        let seconds = rounded % 60
        return String(
            format: L("Statistics Duration Format"),
            Int64(days),
            Int64(hours),
            Int64(minutes),
            Int64(seconds)
        )
    }
}
