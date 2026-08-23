import SwiftUI

enum ClipboardCaptureStatus: Equatable {
    case active
    case paused
    case ignoringNextCopy

    static func resolve(
        capturePaused: Bool,
        ignoreOnlyNextCapture: Bool
    ) -> Self {
        if ignoreOnlyNextCapture { return .ignoringNextCopy }
        return capturePaused ? .paused : .active
    }

    var title: String {
        switch self {
        case .active: ""
        case .paused: L("Clipboard Capture Paused Status")
        case .ignoringNextCopy: L("Clipboard Ignore Next Copy Status")
        }
    }

    var description: String {
        switch self {
        case .active: L("Copy Something to Build History")
        case .paused: L("Clipboard Capture Paused Description")
        case .ignoringNextCopy: L("Clipboard Ignore Next Copy Description")
        }
    }

    var systemImage: String {
        switch self {
        case .active: "doc.on.clipboard"
        case .paused: "pause.circle.fill"
        case .ignoringNextCopy: "arrow.right.circle.fill"
        }
    }
}

struct ClipboardHistoryContent: View {
    @Bindable var store: ClipboardHistoryStore
    let onUse: (ClipboardEntry) -> Void
    let onCopy: (ClipboardEntry) -> Void
    let onPaste: (ClipboardEntry) -> Void
    let onPastePlainText: (ClipboardEntry) -> Void
    let onEditNote: (ClipboardEntry) -> Void
    let onToggleFrequentlyUsed: (ClipboardEntry) -> Void
    let onPin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void

    var body: some View {
        if store.requiresPersistenceMigration {
            migrationView
        } else if store.entries.isEmpty {
            ContentUnavailableView(
                L("No Clipboard History"),
                systemImage: "doc.on.clipboard",
                description: Text(emptyHistoryDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if store.isPreviewVisible {
                HSplitView {
                    historyList
                        .frame(minWidth: 310, idealWidth: 350, maxWidth: 410)
                        .background(
                            Color(nsColor: .controlBackgroundColor).opacity(0.18)
                        )

                    ClipboardEntryPreview(
                        store: store,
                        onCopy: onCopy,
                        onTogglePin: onPin
                    )
                        .frame(
                            minWidth: 300,
                            idealWidth: store.preferences.previewWidth,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.42))
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onChange(of: proxy.size.width) {
                                        retainPreviewWidth(proxy.size.width)
                                    }
                            }
                        }
                }
            } else {
                historyList
            }
        }
    }

    private var historyList: some View {
        ClipboardHistoryList(
            store: store,
            onUse: onUse,
            onCopy: onCopy,
            onPaste: onPaste,
            onPastePlainText: onPastePlainText,
            onEditNote: onEditNote,
            onToggleFrequentlyUsed: onToggleFrequentlyUsed,
            onPin: onPin,
            onDelete: onDelete
        )
    }

    private var migrationView: some View {
        ContentUnavailableView {
            Label(L("Clipboard Migration Required"), systemImage: "key.fill")
        } description: {
            Text(L("Clipboard Migration Help"))
        } actions: {
            Button(L("Unlock and Migrate Clipboard History")) {
                store.migratePersistence()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHistoryDescription: String {
        ClipboardCaptureStatus.resolve(
            capturePaused: store.preferences.capturePaused,
            ignoreOnlyNextCapture: store.preferences.ignoreOnlyNextCapture
        ).description
    }

    private func retainPreviewWidth(_ width: CGFloat) {
        guard (260...800).contains(width),
              abs(store.preferences.previewWidth - width) >= 4 else { return }
        store.setPreference(\.previewWidth, to: width)
    }
}

struct ClipboardCaptureStatusBanner: View {
    let status: ClipboardCaptureStatus
    let onResume: () -> Void
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(status.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: status.systemImage)
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.title)
            .accessibilityValue(status.description)

            Spacer(minLength: 8)

            Button(L("Resume Clipboard Capture"), action: onResume)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("clipboard.resume-capture")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.10)
        )
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.72)
        }
        .accessibilityIdentifier("clipboard.capture-status")
    }
}
