import AppKit
import Testing
@testable import OpenFind

@Suite("Menu Bar Icon Tests")
@MainActor
struct MenuBarIconTests {
    @Test func reusesStableTemplateImage() {
        let first = MenuBarIcon.make()
        let second = MenuBarIcon.make()

        #expect(first === second)
        #expect(first.isTemplate)
        #expect(first.size == NSSize(width: 18, height: 18))
    }

    @Test func imageKeepsRingDotGeometry() throws {
        let data = try #require(MenuBarIcon.make().tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let center = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )

        #expect(center.alphaComponent > 0.9)
        let gap = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide * 2 / 3, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )
        #expect(gap.alphaComponent < 0.2)

        let ringHasOpaquePixel = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    return false
                }
                return color.alphaComponent > 0.8
            }
        }
        #expect(ringHasOpaquePixel)
    }
}
