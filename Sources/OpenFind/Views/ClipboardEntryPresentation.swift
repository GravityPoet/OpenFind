import AppKit
import ImageIO
import SwiftUI

extension ClipboardEntryKind {
    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .url: "link"
        case .file: "doc"
        case .image: "photo"
        case .other: "doc.on.clipboard"
        }
    }

    var localizedTitle: String {
        switch self {
        case .text: L("Text")
        case .richText: L("Rich Text")
        case .url: L("Link")
        case .file: L("File")
        case .image: L("Image")
        case .other: L("Clipboard Item")
        }
    }
}

extension ClipboardEntry {
    var previewImage: NSImage? {
        imageData.flatMap(NSImage.init(data:))
    }

    func downsampledPreviewImage(maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0,
              let imageData,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    var fileURL: URL? {
        fileURLs.first
    }

    var fileURLs: [URL] {
        retainedPasteboardItems.compactMap { item in
            item["public.file-url"].flatMap {
                URL(dataRepresentation: $0, relativeTo: nil)
            }
        }
    }

    var webURL: URL? {
        guard kind == .url else { return nil }
        if let data = retainedPasteboardItems.lazy.compactMap({ $0["public.url"] }).first,
           let url = URL(dataRepresentation: data, relativeTo: nil),
           !url.isFileURL {
            return url
        }
        let candidate = fullPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: candidate), !url.isFileURL, url.scheme != nil else {
            return nil
        }
        return url
    }

    private var flattenedRepresentations: [(String, Data)] {
        retainedPasteboardItems.flatMap { item in
            item.map { ($0.key, $0.value) }
        }
    }

    private func data(forFirstType types: [String]) -> Data? {
        for type in types {
            if let data = flattenedRepresentations.first(where: { $0.0 == type })?.1 {
                return data
            }
        }
        return nil
    }

    var fullPreviewText: String {
        if let data = data(forFirstType: [
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf8-plain-text",
        ]), let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = data(forFirstType: ["public.utf16-external-plain-text"]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if !fileURLs.isEmpty { return fileURLs.map(\.path).joined(separator: "\n") }
        return previewText
    }

    var payloadByteCount: Int {
        retainedPasteboardItems.flatMap(\.values).reduce(0) { $0 + $1.count }
    }

    var imageDimensions: String? {
        guard let imageData,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0 else { return nil }
        return "\(width.intValue)×\(height.intValue)"
    }

    var textStatistics: (words: Int, characters: Int)? {
        guard kind != .image, kind != .file else { return nil }
        let text = fullPreviewText
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return (words, text.count)
    }

    var sourceApplicationIcon: NSImage? {
        guard let sourceBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: sourceBundleIdentifier
              ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var hexColor: Color? {
        var value = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        if value.count == 3 || value.count == 4 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let red = Double((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = Double((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = Double((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? Double(number & 0xff) / 255 : 1
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var imageData: Data? {
        data(forFirstType: ["public.png", "public.tiff", "public.jpeg", "public.heic"])
    }
}
