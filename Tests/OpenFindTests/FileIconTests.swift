import AppKit
import Testing
@testable import OpenFind

@MainActor
@Suite("File Icon Cache", .serialized)
struct FileIconTests {
    @Test func iconsUseBoundedRetinaBitmapsAndReuseTheMatchingSize() throws {
        let url = URL(fileURLWithPath: "/Applications")
        let small = FileIcon.icon(for: url, size: 16)
        let large = FileIcon.icon(for: url, size: 48)
        #expect(small === FileIcon.icon(for: url, size: 16))
        #expect(large === FileIcon.icon(for: url, size: 48))
        #expect(small !== large)
        for (image, points) in [(small, 16), (large, 48)] {
            #expect(image.size == NSSize(width: points, height: points))
            #expect(image.representations.count == 1)
            let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
            #expect(bitmap.pixelsWide == points * 2)
            #expect(bitmap.pixelsHigh == points * 2)
            #expect(bitmap.bytesPerRow * bitmap.pixelsHigh <= points * points * 16)
            #expect(bitmap.colorAt(x: points, y: points)?.alphaComponent ?? 0 > 0)
        }
    }
}
