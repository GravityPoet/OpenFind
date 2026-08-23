import Testing
@testable import OpenFind

@Suite("Clipboard Presentation Tests")
struct ClipboardPresentationTests {
    @Test func captureStatusExplainsPauseAndOneShotIgnore() {
        #expect(ClipboardCaptureStatus.resolve(
            capturePaused: false,
            ignoreOnlyNextCapture: false
        ) == .active)
        #expect(ClipboardCaptureStatus.resolve(
            capturePaused: true,
            ignoreOnlyNextCapture: false
        ) == .paused)
        #expect(ClipboardCaptureStatus.resolve(
            capturePaused: true,
            ignoreOnlyNextCapture: true
        ) == .ignoringNextCopy)
    }

    @Test func frequentActionIsExplicitOnlyForSingleSelection() {
        #expect(ClipboardFrequentAction.resolve(
            selectedItemCount: 1,
            isFrequentlyUsed: false
        ) == .add)
        #expect(ClipboardFrequentAction.resolve(
            selectedItemCount: 1,
            isFrequentlyUsed: true
        ) == .remove)
        #expect(ClipboardFrequentAction.resolve(
            selectedItemCount: 2,
            isFrequentlyUsed: false
        ) == nil)
        #expect(ClipboardFrequentAction.resolve(
            selectedItemCount: 0,
            isFrequentlyUsed: false
        ) == nil)
    }

    @Test func previewDelayFormatterInterpolatesMilliseconds() {
        #expect(ClipboardPreviewDelayFormatter.label(milliseconds: 200) == "200 ms")
        #expect(ClipboardPreviewDelayFormatter.label(milliseconds: 1_000) == "1.0 s")
        #expect(ClipboardPreviewDelayFormatter.label(milliseconds: 1_500) == "1500 ms")
    }
}
