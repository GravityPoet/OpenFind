import Testing
@testable import OpenFind

@Suite("Clipboard Frequent Popover Tests")
struct ClipboardFrequentPopoverTests {
    @Test func hiddenClipboardPanelRejectsHoverPresentation() {
        #expect(!ClipboardFrequentPopoverPresentationGate.allowsHoverPresentation(
            isPanelPresented: false,
            isTriggerHovered: true,
            hasEntries: true
        ))
    }

    @Test func visibleClipboardPanelStillRequiresHoverAndEntries() {
        #expect(ClipboardFrequentPopoverPresentationGate.allowsHoverPresentation(
            isPanelPresented: true,
            isTriggerHovered: true,
            hasEntries: true
        ))
        #expect(!ClipboardFrequentPopoverPresentationGate.allowsHoverPresentation(
            isPanelPresented: true,
            isTriggerHovered: false,
            hasEntries: true
        ))
        #expect(!ClipboardFrequentPopoverPresentationGate.allowsHoverPresentation(
            isPanelPresented: true,
            isTriggerHovered: true,
            hasEntries: false
        ))
    }

    @Test func openPopoverCannotRemainEligibleAfterParentPanelCloses() {
        #expect(ClipboardFrequentPopoverPresentationGate.allowsPresentation(
            isPanelPresented: true,
            hasEntries: true
        ))
        #expect(!ClipboardFrequentPopoverPresentationGate.allowsPresentation(
            isPanelPresented: false,
            hasEntries: true
        ))
    }
}
