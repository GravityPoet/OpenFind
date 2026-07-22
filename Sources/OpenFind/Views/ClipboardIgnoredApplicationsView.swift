import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardIgnoredApplicationsView: View {
    @Bindable var store: ClipboardHistoryStore
    @State private var selection: String?
    @State private var isImporting = false
    @State private var manualIdentifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                L("Clipboard Allow Listed Apps Only"),
                isOn: Binding(
                    get: { store.preferences.ignoreAllAppsExceptListed },
                    set: { store.setIgnoreAllAppsExceptListed($0) }
                )
            )

            List(applications, id: \.self, selection: $selection) { identifier in
                HStack(spacing: 8) {
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: identifier
                    ) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.deletingPathExtension().lastPathComponent)
                            Text(identifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "questionmark.app")
                            .frame(width: 22, height: 22)
                        if let applicationName = Self.knownApplicationNames[identifier] {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(applicationName)
                                Text(identifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(identifier)
                        }
                    }
                }
                .tag(identifier)
            }

            HStack(spacing: 8) {
                Button {
                    isImporting = true
                } label: {
                    Label(L("Add Application"), systemImage: "plus")
                }
                Button {
                    removeSelection()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)

                TextField(L("Bundle Identifiers"), text: $manualIdentifier)
                    .onSubmit { addManualIdentifier() }
                Button(L("Add")) { addManualIdentifier() }
                    .disabled(manualIdentifier.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty)
            }

            Text(store.preferences.ignoreAllAppsExceptListed
                ? L("Clipboard Allow List Help")
                : L("Clipboard Ignore Apps Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.application]
        ) { result in
            guard case let .success(url) = result,
                  let identifier = Bundle(url: url)?.bundleIdentifier else { return }
            add(identifier)
        }
    }

    private var applications: [String] {
        store.preferences.ignoredBundleIdentifiers.sorted()
    }

    private static let knownApplicationNames = [
        "com.1password.1password": "1Password",
        "com.apple.Passwords": "Passwords",
        "com.bitwarden.desktop": "Bitwarden",
    ]

    private func addManualIdentifier() {
        let identifier = manualIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        add(identifier)
        manualIdentifier = ""
    }

    private func add(_ identifier: String) {
        store.setIgnoredBundleIdentifiers(
            store.preferences.ignoredBundleIdentifiers.union([identifier])
        )
        selection = identifier
    }

    private func removeSelection() {
        guard let selection else { return }
        store.setIgnoredBundleIdentifiers(
            store.preferences.ignoredBundleIdentifiers.subtracting([selection])
        )
        self.selection = nil
    }
}
