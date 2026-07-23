import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardIgnoredApplicationsView: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        ClipboardApplicationsListEditor(
            identifiers: store.preferences.ignoredBundleIdentifiers,
            knownApplicationNames: ClipboardPreferences.defaultIgnoredApplicationNames,
            emptyTitle: L("No Ignored Clipboard Apps"),
            emptyDescription: L("No Ignored Clipboard Apps Help"),
            emptySystemImage: "app.badge",
            helpText: L("Clipboard Ignore Apps Help"),
            updateIdentifiers: store.setIgnoredBundleIdentifiers
        )
    }
}

struct ClipboardAllowedApplicationsView: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        ClipboardApplicationsListEditor(
            identifiers: store.preferences.allowedBundleIdentifiers,
            knownApplicationNames: ClipboardPreferences.defaultIgnoredApplicationNames,
            emptyTitle: L("No Allowed Clipboard Apps"),
            emptyDescription: L("No Allowed Clipboard Apps Help"),
            emptySystemImage: "checkmark.app",
            helpText: L("Clipboard Allowed Apps Help"),
            updateIdentifiers: store.setAllowedBundleIdentifiers
        )
    }
}

struct ClipboardAllowedApplicationsSheet: View {
    @Bindable var store: ClipboardHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Allowed Clipboard Apps"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()
            ClipboardAllowedApplicationsView(store: store)
        }
        .frame(width: 560, height: 430)
    }
}

private struct ClipboardApplicationsListEditor: View {
    let identifiers: Set<String>
    let knownApplicationNames: [String: String]
    let emptyTitle: String
    let emptyDescription: String
    let emptySystemImage: String
    let helpText: String
    let updateIdentifiers: (Set<String>) -> Void

    @State private var selection: String?
    @State private var isImporting = false
    @State private var manualIdentifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if applications.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications, id: \.self, selection: $selection) { identifier in
                    applicationRow(identifier)
                        .tag(identifier)
                }
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

            Text(helpText)
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

    @ViewBuilder
    private func applicationRow(_ identifier: String) -> some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier
            ) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(applicationDisplayName(for: url))
                    Text(identifier)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "questionmark.app")
                    .frame(width: 22, height: 22)
                if let applicationName = knownApplicationNames[identifier] {
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
    }

    private var applications: [String] {
        identifiers.sorted()
    }

    private func applicationDisplayName(for url: URL) -> String {
        let canonicalName = url.deletingPathExtension().lastPathComponent
        guard let metadataName = NSMetadataItem(url: url)?.value(
            forAttribute: NSMetadataItemDisplayNameKey
        ) as? String else { return canonicalName }
        let localizedName = (metadataName as NSString).deletingPathExtension
        guard !localizedName.isEmpty,
              localizedName.caseInsensitiveCompare(canonicalName) != .orderedSame else {
            return canonicalName
        }
        return "\(localizedName) (\(canonicalName))"
    }

    private func addManualIdentifier() {
        let identifier = manualIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        add(identifier)
        manualIdentifier = ""
    }

    private func add(_ identifier: String) {
        updateIdentifiers(identifiers.union([identifier]))
        selection = identifier
    }

    private func removeSelection() {
        guard let selection else { return }
        updateIdentifiers(identifiers.subtracting([selection]))
        self.selection = nil
    }
}
