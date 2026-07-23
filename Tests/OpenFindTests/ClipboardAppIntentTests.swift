import AppIntents
import Foundation
import Testing
@testable import OpenFind

@Suite("Clipboard App Intent Tests")
struct ClipboardAppIntentTests {
    @Test func entityPublishesSafeMetadataWithoutEmbeddingClipboardContent() {
        let entry = ClipboardEntry(
            previewText: "TOP-SECRET-CONTENT",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("full payload".utf8)],
            isPinned: true,
            sourceApplicationName: "TextEdit"
        )

        let entity = ClipboardItemEntity(entry: entry)

        #expect(entity.id == entry.id)
        #expect(entity.title == L("Text"))
        #expect(!entity.title.contains("TOP-SECRET-CONTENT"))
        #expect(!entity.subtitle.contains("TOP-SECRET-CONTENT"))
        #expect(entity.subtitle.contains("TextEdit"))
        #expect(entity.isPinned)
        let mirror = Mirror(reflecting: entity)
        #expect(!mirror.children.contains { $0.label == "representations" })
    }

    @Test func sensitiveAndDestructiveIntentsRequireAuthentication() {
        #expect(GetClipboardItemTextIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(CopyClipboardItemIntent.authenticationPolicy == .requiresAuthentication)
        #expect(DeleteClipboardItemIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(ClearClipboardHistoryIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(CreateClipboardSnippetIntent.authenticationPolicy == .requiresAuthentication)
    }

    @Test func shortcutProviderPublishesClipboardAndSnippetEntryPoints() {
        #expect(OpenFindClipboardShortcuts.appShortcuts.count == 3)
    }
}
