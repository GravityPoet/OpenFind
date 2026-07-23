import Foundation
import Testing
@testable import OpenFind

@Suite("Clipboard Quick Look Materializer Tests")
struct ClipboardQuickLookMaterializerTests {
    @Test func textUsesOwnerOnlyTemporaryFileAndCleanupRemovesIt() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let materialization = try context.materializer.materialize(entry(
            text: "synthetic preview",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("synthetic preview".utf8)]
        ))
        let fileURL = try #require(materialization.urls.first)

        #expect(fileURL.pathExtension == "txt")
        #expect(fileURL.deletingPathExtension().lastPathComponent.hasPrefix("OpenFind-Clipboard-"))
        #expect(!fileURL.lastPathComponent.contains("synthetic preview"))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "synthetic preview")
        #expect(posixPermissions(at: fileURL) == 0o600)
        #expect(posixPermissions(at: try #require(materialization.generatedDirectoryURL)) == 0o700)

        context.materializer.cleanup(materialization)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func richImageAndURLUseNativeQuickLookFormats() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }

        let rtf = try context.materializer.materialize(entry(
            text: "Rich",
            kind: .richText,
            representations: ["public.rtf": Data("{\\rtf1 Rich}".utf8)]
        ))
        #expect(rtf.urls.first?.pathExtension == "rtf")
        context.materializer.cleanup(rtf)

        let image = try context.materializer.materialize(entry(
            text: "Image",
            kind: .image,
            representations: ["public.png": Data([0x89, 0x50, 0x4E, 0x47])]
        ))
        #expect(image.urls.first?.pathExtension == "png")
        context.materializer.cleanup(image)

        let urlString = "https://openfind.example/preview"
        let url = try context.materializer.materialize(entry(
            text: urlString,
            kind: .url,
            representations: ["public.url": try #require(URL(string: urlString)).dataRepresentation]
        ))
        let urlFile = try #require(url.urls.first)
        #expect(urlFile.pathExtension == "webloc")
        let propertyList = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: urlFile),
                options: [],
                format: nil
            ) as? [String: String]
        )
        #expect(propertyList["URL"] == urlString)
        context.materializer.cleanup(url)
    }

    @Test func existingFilesAreReturnedDirectlyAndNeverDeleted() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let fileURL = context.root.appendingPathComponent("existing.txt")
        try Data("existing".utf8).write(to: fileURL)
        let materialization = try context.materializer.materialize(entry(
            text: "existing.txt",
            kind: .file,
            representations: ["public.file-url": fileURL.dataRepresentation]
        ))

        #expect(materialization.urls == [fileURL])
        #expect(materialization.generatedDirectoryURL == nil)
        context.materializer.cleanup(materialization)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeContext() throws -> MaterializerTestContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFindQuickLookTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return MaterializerTestContext(
            root: root,
            materializer: ClipboardQuickLookMaterializer(temporaryDirectoryURL: root)
        )
    }

    private func entry(
        text: String,
        kind: ClipboardEntryKind,
        representations: [String: Data]
    ) -> ClipboardEntry {
        ClipboardEntry(
            previewText: text,
            kind: kind,
            representations: representations
        )
    }

    private func posixPermissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.posixPermissions] as? Int ?? -1
    }
}

private struct MaterializerTestContext {
    let root: URL
    let materializer: ClipboardQuickLookMaterializer
}
