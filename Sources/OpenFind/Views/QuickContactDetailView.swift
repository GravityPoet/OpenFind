import AppKit
import SwiftUI

struct QuickContactDetailView: View {
    let contact: QuickContact
    let scale: CGFloat
    let onBack: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack {
                Button(action: onBack) { Label(L("Go Back"), systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Text(contact.name).font(.system(size: 18 * scale, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button(L("Copy Contact Details")) {
                    copy(([contact.name] + contact.emails + contact.phones).joined(separator: "\n"))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10 * scale) {
                    ForEach(Array(contact.emails.enumerated()), id: \.offset) { _, email in
                        detail(email, symbol: "envelope")
                    }
                    ForEach(Array(contact.phones.enumerated()), id: \.offset) { _, phone in
                        detail(phone, symbol: "phone")
                    }
                    if contact.emails.isEmpty && contact.phones.isEmpty {
                        Text(L("No Contact Details")).foregroundStyle(.secondary)
                    }
                }
            }
            Text(copied ? L("Copied") : L("Contact Copy Hint"))
                .foregroundStyle(.secondary).font(.system(size: 11 * scale))
        }
        .padding(20 * scale)
        .accessibilityIdentifier("OpenFind.quickSearch.contactDetail")
        .onChange(of: contact.identifier) { _, _ in copied = false }
    }

    private func detail(_ value: String, symbol: String) -> some View {
        HStack {
            Label(value, systemImage: symbol).textSelection(.enabled)
            Spacer()
            Button { copy(value) } label: { Image(systemName: "doc.on.doc") }
                .help(L("Copy Contact Details"))
                .accessibilityLabel(L("Copy Contact Details") + ": " + value)
        }
        .font(.system(size: 14 * scale))
        .padding(8 * scale)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}
