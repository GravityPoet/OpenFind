import AppKit
import Testing
@testable import OpenFind

@Suite("Clipboard Image Text Recognizer Tests")
struct ClipboardImageTextRecognizerTests {
    @MainActor
    @Test func recognizesChineseTextInACompactImageBanner() async throws {
        let expectedText = "下午三点开会"
        let image = NSImage(size: NSSize(width: 560, height: 66))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black,
        ]
        let sourceText = "比如截图里写着“\(expectedText)”，"
        let textSize = (sourceText as NSString).size(withAttributes: attributes)
        (sourceText as NSString).draw(
            at: NSPoint(x: 12, y: (image.size.height - textSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let imageData = try #require(bitmap.representation(using: .png, properties: [:]))

        let recognized = await VisionClipboardImageTextRecognizer().recognizeText(
            in: imageData
        )

        #expect(recognized?.contains(expectedText) == true)
    }
}
