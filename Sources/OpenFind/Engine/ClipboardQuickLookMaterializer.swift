import Foundation

enum ClipboardQuickLookError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedContent
    case materializationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedContent: L("Clipboard Quick Look Unsupported")
        case .materializationFailed: L("Clipboard Quick Look Failed")
        }
    }
}

struct ClipboardQuickLookMaterialization: Equatable, Sendable {
    let urls: [URL]
    let generatedDirectoryURL: URL?
}

/// Creates short-lived, owner-only files so Quick Look can preview clipboard
/// values that do not already exist as files. The caller owns cleanup.
struct ClipboardQuickLookMaterializer {
    private let fileManager: FileManager
    private let temporaryDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    func materialize(_ entry: ClipboardEntry) throws -> ClipboardQuickLookMaterialization {
        let fileURLs = retainedFileURLs(in: entry)
        if !fileURLs.isEmpty {
            return ClipboardQuickLookMaterialization(
                urls: fileURLs,
                generatedDirectoryURL: nil
            )
        }

        let payload = try previewPayload(for: entry)
        let directoryURL = temporaryDirectoryURL.appendingPathComponent(
            "OpenFindQuickLook-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let fileURL = directoryURL
                .appendingPathComponent(safeFilename(for: entry))
                .appendingPathExtension(payload.fileExtension)
            try payload.data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return ClipboardQuickLookMaterialization(
                urls: [fileURL],
                generatedDirectoryURL: directoryURL
            )
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw ClipboardQuickLookError.materializationFailed
        }
    }

    func cleanup(_ materialization: ClipboardQuickLookMaterialization?) {
        guard let directoryURL = materialization?.generatedDirectoryURL,
              directoryURL.deletingLastPathComponent().standardizedFileURL
                == temporaryDirectoryURL.standardizedFileURL,
              directoryURL.lastPathComponent.hasPrefix("OpenFindQuickLook-") else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    private func previewPayload(
        for entry: ClipboardEntry
    ) throws -> (data: Data, fileExtension: String) {
        let representations = entry.retainedPasteboardItems.flatMap { $0 }
        let preferredBinaryTypes: [(type: String, fileExtension: String)] = [
            ("public.png", "png"),
            ("public.jpeg", "jpg"),
            ("public.heic", "heic"),
            ("public.tiff", "tiff"),
            ("public.rtf", "rtf"),
            ("public.html", "html"),
        ]
        for candidate in preferredBinaryTypes {
            if let data = representations.first(where: { $0.key == candidate.type })?.value,
               !data.isEmpty {
                return (data, candidate.fileExtension)
            }
        }

        if let url = retainedWebURL(in: entry) {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["URL": url.absoluteString],
                format: .xml,
                options: 0
            )
            return (data, "webloc")
        }

        if let text = retainedText(in: entry), !text.isEmpty {
            return (Data(text.utf8), "txt")
        }
        let fallback = entry.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { throw ClipboardQuickLookError.unsupportedContent }
        return (Data(fallback.utf8), "txt")
    }

    private func retainedFileURLs(in entry: ClipboardEntry) -> [URL] {
        entry.retainedPasteboardItems.compactMap { item in
            item["public.file-url"].flatMap {
                URL(dataRepresentation: $0, relativeTo: nil)
            }
        }
    }

    private func retainedWebURL(in entry: ClipboardEntry) -> URL? {
        if let data = entry.retainedPasteboardItems.lazy.compactMap({ $0["public.url"] }).first,
           let url = URL(dataRepresentation: data, relativeTo: nil),
           !url.isFileURL {
            return url
        }
        guard entry.kind == .url,
              let text = retainedText(in: entry)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              !url.isFileURL,
              url.scheme != nil else { return nil }
        return url
    }

    private func retainedText(in entry: ClipboardEntry) -> String? {
        let representations = entry.retainedPasteboardItems.flatMap { $0 }
        if let data = representations.first(where: {
            $0.key == "public.utf8-plain-text" || $0.key == "public.text"
                || $0.key == "NSStringPboardType"
        })?.value,
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = representations.first(where: {
            $0.key == "public.utf16-external-plain-text"
        })?.value,
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        return nil
    }

    private func safeFilename(for entry: ClipboardEntry) -> String {
        "OpenFind-Clipboard-\(entry.id.uuidString.prefix(8))"
    }
}
