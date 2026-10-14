import AppKit
import Foundation
import PDFKit
import Testing
@testable import OpenFind

@Suite("Image and Scan Content Search Tests", .serialized)
@MainActor
struct ImageContentSearchTests {
    private enum FixtureError: Error { case missingData, invalidRoot }

    private struct Fixture {
        let root: URL
        let parent: URL
        let parentIdentity: [String]

        init() throws {
            parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            parentIdentity = try Self.identity(parent)
            root = parent.appendingPathComponent("OpenFindOCRTests-\(UUID().uuidString)", isDirectory: true)
            guard parent.path != "/", parent != FileManager.default.homeDirectoryForCurrentUser,
                  root.resolvingSymlinksInPath().path.hasPrefix(parent.path + "/OpenFindOCRTests-") else {
                throw FixtureError.invalidRoot
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        private static func identity(_ url: URL) throws -> [String] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try [FileAttributeKey.systemNumber, .systemFileNumber].map {
                guard let number = attributes[$0] as? NSNumber else { throw FixtureError.invalidRoot }
                return number.stringValue
            }
        }

        func recycle() {
            do {
                guard try Self.identity(parent) == parentIdentity,
                      root.resolvingSymlinksInPath().path.hasPrefix(parent.path + "/OpenFindOCRTests-") else {
                    throw FixtureError.invalidRoot
                }
                var destination: NSURL?
                try FileManager.default.trashItem(at: root, resultingItemURL: &destination)
                let recovered = try #require(destination as URL?)
                #expect(FileManager.default.fileExists(atPath: recovered.path))
                #expect(!FileManager.default.fileExists(atPath: root.path))
                #expect(try Self.identity(parent) == parentIdentity)
                let receipt = ["fixture": root.path, "trash": recovered.path,
                               "parent_device": parentIdentity[0], "parent_inode": parentIdentity[1]]
                print(String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self))
            } catch {
                Issue.record("OCR fixture recovery failed: \(error)")
            }
        }
    }

    private func imageData(lines: [String]) throws -> Data {
        let image = NSImage(size: NSSize(width: 1_000, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 30, y: 160 - 65 * index), withAttributes: attributes)
        }
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func scannedPDF(_ imageData: Data, to url: URL, textPage: Bool = false) throws {
        let document = PDFDocument()
        if textPage {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
            view.string = "Existing searchable PDF heading"
            let typed = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
            document.insert(try #require(typed.page(at: 0)), at: 0)
        }
        let image = try #require(NSImage(data: imageData))
        let scanned = try #require(PDFPage(image: image))
        #expect(scanned.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        document.insert(scanned, at: document.pageCount)
        try #require(document.dataRepresentation()).write(to: url)
    }

    @Test func recognizesChineseAndEnglishInsideImageFiles() throws {
        let fixture = try Fixture()
        defer { fixture.recycle() }
        let url = fixture.root.appendingPathComponent("picture.png")
        try imageData(lines: ["下午三点开会", "Invoice 74219"]).write(to: url)
        #expect(DocumentTextExtractor.extract(from: url, maxFileSize: 16 * 1_024 * 1_024, allowOCR: false) == nil)
        let extracted = try #require(DocumentTextExtractor.extract(from: url, maxFileSize: 16 * 1_024 * 1_024))
        #expect(extracted.source == .imageText)
        #expect(extracted.text.contains("下午三点开会"))
        #expect(extracted.text.contains("74219"))
    }

    @Test func retainsPDFTextAndRecognizesItsScannedPages() throws {
        let fixture = try Fixture()
        defer { fixture.recycle() }
        let url = fixture.root.appendingPathComponent("mixed.pdf")
        try scannedPDF(imageData(lines: ["租房合同 宠物限制", "Invoice 74219"]), to: url, textPage: true)
        // Background extraction must not cache a partial text layer and hide later OCR matches.
        #expect(DocumentTextExtractor.extract(from: url, maxFileSize: 16 * 1_024 * 1_024, allowOCR: false) == nil)
        let extracted = try #require(DocumentTextExtractor.extract(from: url, maxFileSize: 16 * 1_024 * 1_024))
        #expect(extracted.source == .pdf)
        #expect(extracted.text.contains("Existing searchable PDF heading"))
        #expect(extracted.text.contains("宠物限制"))
        #expect(extracted.text.contains("74219"))
    }

    @Test func contentSearchFindsImagesAndScansWithPreviewsOnColdAndWarmQueries() async throws {
        let fixture = try Fixture()
        defer { fixture.recycle() }
        let pixels = try imageData(lines: ["下午三点开会", "Invoice 74219"])
        try pixels.write(to: fixture.root.appendingPathComponent("picture.png"))
        try scannedPDF(pixels, to: fixture.root.appendingPathComponent("page.pdf"))
        try "Invoice 74219".write(to: fixture.root.appendingPathComponent("notes.txt"),
                                  atomically: true, encoding: .utf8)
        let store = SearchIndexStore(persistenceURL: fixture.root.appendingPathComponent(".index.bin"))
        var options = SearchOptions(query: "74219")
        options.target = .content
        options.includeHidden = false
        options.maxContentFileSize = 16 * 1_024 * 1_024
        for _ in 0..<2 {
            var names = Set<String>()
            for await hit in SearchEngine.search(scopes: [fixture.root], options: options, store: store) {
                names.insert(hit.name)
                #expect(hit.contentPreview?.contains("74219") == true)
            }
            #expect(names == ["picture.png", "page.pdf", "notes.txt"])
        }
        await store.flushPersistence()
    }

    @Test func rejectsOversizedAndCorruptImagesWithoutPermanentNonTextClassification() throws {
        let fixture = try Fixture()
        defer { fixture.recycle() }
        let image = fixture.root.appendingPathComponent("picture.png")
        try imageData(lines: ["Invoice 74219"]).write(to: image)
        #expect(DocumentTextExtractor.extract(from: image, maxFileSize: 1) == nil)
        let corrupt = fixture.root.appendingPathComponent("corrupt.png")
        try Data([0, 1, 2, 3]).write(to: corrupt)
        #expect(DocumentTextExtractor.extract(from: corrupt, maxFileSize: 1_024) == nil)
        #expect(!DocumentTextExtractor.isStableNonTextFile(corrupt, maxFileSize: 1_024))
    }

    @Test func blankImageHasACompletedEmptyExtraction() throws {
        let fixture = try Fixture()
        defer { fixture.recycle() }
        let image = fixture.root.appendingPathComponent("blank.png")
        try imageData(lines: []).write(to: image)
        let extracted = try #require(DocumentTextExtractor.extract(from: image, maxFileSize: 16 * 1_024 * 1_024))
        #expect(extracted.text.isEmpty)
        #expect(extracted.source == .imageText)
    }

    @Test func imageOCRRunsOnDemandWithExpandableMemoryReservations() {
        #expect(DocumentTextExtractor.mayExpandDuringExtraction(name: "picture.png"))
        #expect(DocumentTextExtractor.isKnownSearchableContent(name: "picture.png", isDirectory: false))
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "picture.png", path: "/tmp/picture.png", isDirectory: false, size: 100
        ) == nil)
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "picture.png", path: "/tmp/project/node_modules/picture.png", isDirectory: false, size: 100
        ) == nil)
    }
}
