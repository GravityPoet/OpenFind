import AppKit
import Compression
import Foundation
import PDFKit
import Testing
@testable import OpenFind

@Suite("Document Text Extractor Tests", .serialized)
@MainActor
struct DocumentTextExtractorTests {
    private enum FixtureError: Error {
        case commandFailed(String, Int32)
        case missingData
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeAttributedDocument(
        _ text: String,
        type: NSAttributedString.DocumentType,
        to url: URL
    ) throws {
        let attributed = NSAttributedString(string: text)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: type]
        )
        try data.write(to: url)
    }

    private func writePDF(_ text: String, to url: URL) throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.string = text
        let data = view.dataWithPDF(inside: view.bounds)
        guard !data.isEmpty else { throw FixtureError.missingData }
        try data.write(to: url)
    }

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw FixtureError.commandFailed(errorText, process.terminationStatus)
        }
        return output
    }

    private func zipDirectory(_ source: URL, to archive: URL) throws {
        try run("/usr/bin/zip", ["-q", "-r", archive.path, "."], currentDirectory: source)
    }

    private func lzmaCompressed(_ data: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: max(1_024, data.count * 2 + 1_024))
        let count = data.withUnsafeBytes { source in
            compression_encode_buffer(
                &output,
                output.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                COMPRESSION_LZMA
            )
        }
        guard count > 0 else { throw FixtureError.missingData }
        return Data(output.prefix(count))
    }

    @Test func nativePDFRTFAndOfficeDocumentsExposeTheirText() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtures: [(String, NSAttributedString.DocumentType, String)] = [
            ("sample.rtf", .rtf, "openfind rtf marker 你好"),
            ("sample.doc", .docFormat, "openfind legacy doc marker 你好"),
            ("sample.docx", .officeOpenXML, "openfind docx marker 你好"),
            ("sample.odt", .openDocument, "openfind odt marker 你好"),
        ]
        for (name, type, marker) in fixtures {
            let url = root.appendingPathComponent(name)
            try writeAttributedDocument(marker, type: type, to: url)
            let extracted = try #require(DocumentTextExtractor.extract(from: url, maxFileSize: 16 * 1_024 * 1_024))
            #expect(extracted.text.localizedCaseInsensitiveContains(marker))
            #expect(extracted.source == .attributedDocument)
        }

        let pdfURL = root.appendingPathComponent("sample.pdf")
        let pdfMarker = "openfind pdf marker 你好"
        try writePDF(pdfMarker, to: pdfURL)
        let extractedPDF = try #require(DocumentTextExtractor.extract(from: pdfURL, maxFileSize: 16 * 1_024 * 1_024))
        #expect(extractedPDF.text.localizedCaseInsensitiveContains(pdfMarker))
        #expect(extractedPDF.source == .pdf)
    }

    @Test func openXMLSpreadsheetsAndPresentationsExposeSharedAndSlideText() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let spreadsheetSource = root.appendingPathComponent("xlsx-source", isDirectory: true)
        let spreadsheetXML = spreadsheetSource.appendingPathComponent("xl", isDirectory: true)
            .appendingPathComponent("sharedStrings.xml")
        try FileManager.default.createDirectory(
            at: spreadsheetXML.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<sst><si><t>openfind xlsx marker &amp; 你好</t></si></sst>"
            .write(to: spreadsheetXML, atomically: true, encoding: .utf8)
        let xlsxURL = root.appendingPathComponent("sample.xlsx")
        try zipDirectory(spreadsheetSource, to: xlsxURL)

        let presentationSource = root.appendingPathComponent("pptx-source", isDirectory: true)
        let slideXML = presentationSource.appendingPathComponent("ppt", isDirectory: true)
            .appendingPathComponent("slides", isDirectory: true)
            .appendingPathComponent("slide1.xml")
        try FileManager.default.createDirectory(
            at: slideXML.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<p:sld><a:t>openfind pptx marker &lt; 你好</a:t></p:sld>"
            .write(to: slideXML, atomically: true, encoding: .utf8)
        let pptxURL = root.appendingPathComponent("sample.pptx")
        try zipDirectory(presentationSource, to: pptxURL)

        let spreadsheet = try #require(DocumentTextExtractor.extract(from: xlsxURL, maxFileSize: 16 * 1_024 * 1_024))
        #expect(spreadsheet.text.contains("openfind xlsx marker & 你好"))
        #expect(spreadsheet.source == .openXML)

        let presentation = try #require(DocumentTextExtractor.extract(from: pptxURL, maxFileSize: 16 * 1_024 * 1_024))
        #expect(presentation.text.contains("openfind pptx marker < 你好"))
        #expect(presentation.source == .openXML)
    }

    @Test func iWorkAndRTFDPackagesAreSearchableWithoutReadingAttachments() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pages = root.appendingPathComponent("sample.pages", isDirectory: true)
        let preview = pages.appendingPathComponent("QuickLook", isDirectory: true)
            .appendingPathComponent("Preview.pdf")
        try FileManager.default.createDirectory(
            at: preview.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writePDF("openfind pages preview marker 你好", to: preview)
        let pagesText = try #require(DocumentTextExtractor.extract(from: pages, maxFileSize: 16 * 1_024 * 1_024))
        #expect(pagesText.text.contains("openfind pages preview marker 你好"))
        #expect(pagesText.source == .iWorkPreview)

        let rtfd = root.appendingPathComponent("sample.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: rtfd, withIntermediateDirectories: true)
        try writeAttributedDocument(
            "openfind rtfd marker 你好",
            type: .rtf,
            to: rtfd.appendingPathComponent("TXT.rtf")
        )
        try Data(repeating: 0, count: 2 * 1_024 * 1_024)
            .write(to: rtfd.appendingPathComponent("ignored-attachment.bin"))
        let rtfdText = try #require(DocumentTextExtractor.extract(from: rtfd, maxFileSize: 1 * 1_024 * 1_024))
        #expect(rtfdText.text.contains("openfind rtfd marker 你好"))
    }

    @Test func archivesExposeReadableMembersButNeverRecurseIntoNestedArchives() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nestedSource = root.appendingPathComponent("nested-source", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)
        try "nested-only-secret-marker".write(
            to: nestedSource.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        let nestedArchive = root.appendingPathComponent("nested.zip")
        try zipDirectory(nestedSource, to: nestedArchive)

        let archiveSource = root.appendingPathComponent("archive-source", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveSource, withIntermediateDirectories: true)
        try "openfind archive marker 你好".write(
            to: archiveSource.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.copyItem(
            at: nestedArchive,
            to: archiveSource.appendingPathComponent("nested.zip")
        )
        let archive = root.appendingPathComponent("sample.zip")
        try zipDirectory(archiveSource, to: archive)

        let extracted = try #require(DocumentTextExtractor.extract(from: archive, maxFileSize: 16 * 1_024 * 1_024))
        #expect(extracted.text.contains("openfind archive marker 你好"))
        #expect(!extracted.text.contains("nested-only-secret-marker"))
        #expect(extracted.source == .archive)

        let nestedOnlySource = root.appendingPathComponent("nested-only-source", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedOnlySource, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: nestedArchive,
            to: nestedOnlySource.appendingPathComponent("only.zip")
        )
        let nestedOnly = root.appendingPathComponent("nested-only.zip")
        try zipDirectory(nestedOnlySource, to: nestedOnly)
        #expect(DocumentTextExtractor.extract(from: nestedOnly, maxFileSize: 16 * 1_024 * 1_024) == nil)
    }

    @Test func commonTarAndSingleCompressionFormatsExposeText() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let marker = "openfind common archive marker 你好"
        let textFile = source.appendingPathComponent("notes.txt")
        try marker.write(to: textFile, atomically: true, encoding: .utf8)

        let tarVariants: [(String, String)] = [
            ("sample.tar", "-cf"),
            ("sample.tar.gz", "-czf"),
            ("sample.tar.bz2", "-cjf"),
            ("sample.tar.xz", "-cJf"),
        ]
        for (name, mode) in tarVariants {
            let archive = root.appendingPathComponent(name)
            try run("/usr/bin/bsdtar", [mode, archive.path, "notes.txt"], currentDirectory: source)
            let extracted = try #require(DocumentTextExtractor.extract(
                from: archive,
                maxFileSize: 16 * 1_024 * 1_024
            ))
            #expect(extracted.text.contains(marker))
        }

        for (name, executable) in [("notes.txt.gz", "/usr/bin/gzip"), ("notes.txt.bz2", "/usr/bin/bzip2")] {
            let archive = root.appendingPathComponent(name)
            try run(executable, ["-c", "--", textFile.path]).write(to: archive)
            let extracted = try #require(DocumentTextExtractor.extract(
                from: archive,
                maxFileSize: 16 * 1_024 * 1_024
            ))
            #expect(extracted.text.contains(marker))
        }

        let xz = root.appendingPathComponent("notes.txt.xz")
        try lzmaCompressed(Data(marker.utf8)).write(to: xz)
        let xzText = try #require(DocumentTextExtractor.extract(from: xz, maxFileSize: 16 * 1_024 * 1_024))
        #expect(xzText.text.contains(marker))

        var corrupt = try Data(contentsOf: xz)
        corrupt.removeLast(min(8, corrupt.count))
        let corruptXZ = root.appendingPathComponent("corrupt.txt.xz")
        try corrupt.write(to: corruptXZ)
        #expect(DocumentTextExtractor.extract(from: corruptXZ, maxFileSize: 16 * 1_024 * 1_024) == nil)
    }

    @Test func encodingsCorruptionAndExtractionLimitsFailSafely() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let utf32URL = root.appendingPathComponent("utf32.txt")
        let utf32Marker = "openfind utf32 marker 你好"
        try #require(utf32Marker.data(using: .utf32)).write(to: utf32URL)
        #expect(DocumentTextExtractor.extract(from: utf32URL, maxFileSize: 1 * 1_024 * 1_024)?.text == utf32Marker)

        let oversized = root.appendingPathComponent("oversized.txt")
        try Data(repeating: UInt8(ascii: "a"), count: 4_096).write(to: oversized)
        #expect(DocumentTextExtractor.extract(from: oversized, maxFileSize: 1_024) == nil)

        let corruptPDF = root.appendingPathComponent("corrupt.pdf")
        try Data([0x25, 0x50, 0x44, 0x46, 0x00, 0x01]).write(to: corruptPDF)
        #expect(DocumentTextExtractor.extract(from: corruptPDF, maxFileSize: 1 * 1_024 * 1_024) == nil)

        let bombSource = root.appendingPathComponent("bomb-source", isDirectory: true)
        try FileManager.default.createDirectory(at: bombSource, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "z"), count: 1 * 1_024 * 1_024)
            .write(to: bombSource.appendingPathComponent("huge.txt"))
        let bomb = root.appendingPathComponent("bounded.zip")
        try zipDirectory(bombSource, to: bomb)
        #expect((try bomb.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 64 * 1_024)
        #expect(DocumentTextExtractor.extract(from: bomb, maxFileSize: 64 * 1_024) == nil)
    }

    @Test func unlimitedASCIIStreamMatchesAcrossChunksWithoutAHiddenCeiling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let large = root.appendingPathComponent("large.log")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: large)
            try handle.write(contentsOf: Data("OpenFind-stream-marker".utf8))
            try handle.seek(toOffset: UInt64(2 * 1_024 * 1_024 * 1_024 - 1))
            try handle.write(contentsOf: Data([UInt8(ascii: "x")]))
            try handle.close()
        }

        let chunkSize = 1 * 1_024 * 1_024
        let boundary = root.appendingPathComponent("boundary.log")
        var boundaryData = Data(repeating: UInt8(ascii: "x"), count: chunkSize + 32)
        boundaryData.replaceSubrange(
            (chunkSize - 3)..<(chunkSize + 19),
            with: Data("OpenFind-stream-marker".utf8)
        )
        try boundaryData.write(to: boundary)

        #expect(
            DocumentTextExtractor.streamASCIIPlainTextMatch(
                from: large,
                needle: "openfind-stream-marker",
                caseSensitive: false
            ) == .match
        )
        #expect(
            DocumentTextExtractor.streamASCIIPlainTextMatch(
                from: boundary,
                needle: "OpenFind-stream-marker",
                caseSensitive: true
            ) == .match
        )

        let encoded = root.appendingPathComponent("utf16.txt")
        try "OpenFind encoded marker".data(using: .utf16LittleEndian)?.write(to: encoded)
        #expect(
            DocumentTextExtractor.streamASCIIPlainTextMatch(
                from: encoded,
                needle: "marker",
                caseSensitive: false
            ) == .unsupported
        )
    }

    @Test func contentSearchReturnsTheCompleteSupportedFormatSet() async throws {
        let root = try temporaryDirectory()
        let staging = try temporaryDirectory()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDocumentIndex-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: cacheURL)
        }

        let marker = "formatmarker74219 你好"
        try writePDF(marker, to: root.appendingPathComponent("manual.pdf"))
        try writeAttributedDocument(marker, type: .rtf, to: root.appendingPathComponent("notes.rtf"))
        try writeAttributedDocument(
            marker,
            type: .officeOpenXML,
            to: root.appendingPathComponent("proposal.docx")
        )

        let spreadsheetSource = staging.appendingPathComponent("sheet", isDirectory: true)
        let sharedStrings = spreadsheetSource.appendingPathComponent("xl", isDirectory: true)
            .appendingPathComponent("sharedStrings.xml")
        try FileManager.default.createDirectory(
            at: sharedStrings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<sst><si><t>\(marker)</t></si></sst>".write(
            to: sharedStrings,
            atomically: true,
            encoding: .utf8
        )
        try zipDirectory(spreadsheetSource, to: root.appendingPathComponent("budget.xlsx"))

        let presentationSource = staging.appendingPathComponent("slides", isDirectory: true)
        let slide = presentationSource.appendingPathComponent("ppt", isDirectory: true)
            .appendingPathComponent("slides", isDirectory: true)
            .appendingPathComponent("slide1.xml")
        try FileManager.default.createDirectory(
            at: slide.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<p:sld><a:t>\(marker)</a:t></p:sld>".write(
            to: slide,
            atomically: true,
            encoding: .utf8
        )
        try zipDirectory(presentationSource, to: root.appendingPathComponent("briefing.pptx"))

        let pages = root.appendingPathComponent("report.pages", isDirectory: true)
        let preview = pages.appendingPathComponent("QuickLook", isDirectory: true)
            .appendingPathComponent("Preview.pdf")
        try FileManager.default.createDirectory(
            at: preview.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writePDF(marker, to: preview)

        let archiveSource = staging.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveSource, withIntermediateDirectories: true)
        try marker.write(
            to: archiveSource.appendingPathComponent("content.txt"),
            atomically: true,
            encoding: .utf8
        )
        try zipDirectory(archiveSource, to: root.appendingPathComponent("research.zip"))
        try "this document deliberately does not match".write(
            to: root.appendingPathComponent("decoy.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: root.appendingPathComponent("binary.bin"))

        var options = SearchOptions()
        options.query = "formatmarker74219"
        options.target = .content
        options.includePackages = false
        options.maxContentFileSize = 100 * 1_024 * 1_024

        let store = SearchIndexStore(persistenceURL: cacheURL)
        var names = Set<String>()
        for await result in SearchEngine.search(scopes: [root], options: options, store: store) {
            names.insert(result.name)
        }
        #expect(names == [
            "manual.pdf", "notes.rtf", "proposal.docx", "budget.xlsx",
            "briefing.pptx", "report.pages", "research.zip",
        ])

        let contentIndex = await store.contentIndexHandle()
        #expect(await contentIndex.diagnostics().indexedDocuments == 9)
        var warmNames = Set<String>()
        for await result in SearchEngine.search(scopes: [root], options: options, store: store) {
            warmNames.insert(result.name)
        }
        #expect(warmNames == names)
    }

    @Test func backgroundTiersDeferExpensiveWorkWithoutExcludingFormats() {
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "SearchEngine.swift",
            path: "/Users/test/project/Sources/SearchEngine.swift",
            isDirectory: false,
            size: 2 * 1_024 * 1_024
        ) == .preferred)
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "manual.pdf",
            path: "/Users/test/Documents/manual.pdf",
            isDirectory: false,
            size: 20 * 1_024 * 1_024
        ) == .structured)
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "copy.swift",
            path: "/Users/test/project/node_modules/pkg/copy.swift",
            isDirectory: false,
            size: 100
        ) == nil)
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "large.log",
            path: "/Users/test/logs/large.log",
            isDirectory: false,
            size: 17 * 1_024 * 1_024
        ) == nil)
        #expect(DocumentTextExtractor.backgroundIndexTier(
            name: "source.zip",
            path: "/Users/test/Downloads/source.zip",
            isDirectory: false,
            size: 100
        ) == nil)

        // Deferred formats remain known to the authoritative content matcher.
        #expect(DocumentTextExtractor.isKnownSearchableContent(name: "source.zip", isDirectory: false))
        #expect(DocumentTextExtractor.isKnownSearchableContent(name: "large.log", isDirectory: false))
    }
}
