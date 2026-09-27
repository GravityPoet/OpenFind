import AppKit
import SwiftUI

struct TerminalCommandSettingsSection: View {
    @AppStorage(QuickTerminalPrefix.persistenceKey)
    private var storedPrefix = QuickTerminalPrefix.defaultValue
    @AppStorage(TerminalCommandTarget.persistenceKey)
    private var targetValue = ""
    @State private var installations: [TerminalInstallation] = []
    @State private var testMessage: String?
    @State private var testError: TerminalCommandError?
    @State private var isTesting = false

    private var prefix: String {
        QuickTerminalPrefix.normalized(storedPrefix) ?? QuickTerminalPrefix.defaultValue
    }

    private var target: TerminalCommandTarget {
        TerminalCommandTarget(rawValue: targetValue) ?? TerminalCommandTarget.load()
    }

    private var selectedInstallation: TerminalInstallation? {
        installations.first { $0.target == target }
    }

    private var targetStatus: String {
        if target == .systemDefault { return L("Terminal Target Legacy") }
        guard let installation = selectedInstallation else { return L("Terminal Detecting") }
        if let error = installation.error { return error.userMessage }
        return String(format: L("Terminal Target Detected"),
                      LD(target.titleKey), installation.version ?? "")
    }

    var body: some View {
        Section {
            Picker(L("Terminal App"), selection: Binding(
                get: { target.rawValue }, set: { targetValue = $0 }
            )) {
                ForEach(installations.filter { $0.url != nil || $0.target == target || $0.target == .terminal }) { installation in
                    Text(LD(installation.target.titleKey)).tag(installation.target.rawValue)
                }
                Divider()
                Text(L("System Terminal Compatibility")).tag(TerminalCommandTarget.systemDefault.rawValue)
            }
            .pickerStyle(.menu)
            .disabled(isTesting)
            .accessibilityIdentifier("OpenFind.settings.terminalTarget")

            Text(targetStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("OpenFind.settings.terminalStatus")

            HStack {
                Button(isTesting ? L("Terminal Testing") : L("Test Terminal Connection"), action: testConnection)
                    .disabled(isTesting || (target != .systemDefault && (selectedInstallation == nil || selectedInstallation?.error != nil)))
                    .accessibilityIdentifier("OpenFind.settings.testTerminal")
                Button(L("Refresh Terminal Detection")) { refreshInstallations() }
                    .disabled(isTesting)
                if let url = (testError ?? selectedInstallation?.error)?.recoveryURL {
                    Button(testError == .automationDenied ? L("Open Automation Settings") : L("Terminal Setup Help")) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            if let testMessage {
                Text(testMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("OpenFind.settings.terminalTestResult")
            }

            Picker(L("Terminal Command Prefix"), selection: Binding(
                get: { prefix }, set: { storedPrefix = $0 }
            )) {
                ForEach(QuickTerminalPrefix.choices, id: \.self) { letter in
                    Text(letter).tag(letter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("OpenFind.settings.terminalPrefix")

            Text(String(format: L("Terminal Command Example Format"), prefix))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if prefix != QuickTerminalPrefix.defaultValue {
                Button(L("Restore Default Terminal Prefix")) { storedPrefix = QuickTerminalPrefix.defaultValue }
            }
        } header: {
            Text(L("Run in Terminal"))
        } footer: {
            Text(L("Terminal Target Help"))
        }
        .onAppear { refreshInstallations() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshInstallations()
        }
        .onChange(of: targetValue) {
            testMessage = nil
            testError = nil
            refreshInstallations()
        }
    }

    private func refreshInstallations() {
        installations = TerminalInstallation.detected()
    }

    private func testConnection() {
        let testedTarget = target
        isTesting = true
        testMessage = nil
        testError = nil
        Task { @MainActor in
            defer { isTesting = false }
            do {
                try await TerminalCommandRunner(target: testedTarget).testConnection()
                if target == testedTarget { testMessage = L("Terminal Test Passed") }
            } catch {
                guard target == testedTarget else { return }
                testError = error as? TerminalCommandError
                testMessage = testError?.userMessage ?? L("Terminal Send Failed")
            }
        }
    }
}
