import AppKit
import SwiftUI
import Testing
@testable import OpenFind

@Suite(
    "Visual Regression Tests",
    .serialized,
    .enabled(if:
        ProcessInfo.processInfo.environment["OPENFIND_RUN_VISUAL_REGRESSION"] == "1"
            || ProcessInfo.processInfo.environment["OPENFIND_UPDATE_VISUAL_BASELINES"] == "1"
    )
)
struct VisualRegressionTests {
    @Test func firstRunGuideMatchesApprovedBaselines() async throws {
        try await assertSnapshot(interfaceSize: .standard, name: "first-run-standard")
        try await assertSnapshot(interfaceSize: .compact, name: "first-run-compact")
    }

    private func assertSnapshot(
        interfaceSize: OpenFindInterfaceSize,
        name: String
    ) async throws {
        let currentData = try await renderSnapshot(interfaceSize: interfaceSize)
        let baselineURL = baselineDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("png")

        if ProcessInfo.processInfo.environment["OPENFIND_UPDATE_VISUAL_BASELINES"] == "1" {
            try FileManager.default.createDirectory(
                at: baselineDirectory,
                withIntermediateDirectories: true
            )
            try currentData.write(to: baselineURL, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            throw VisualRegressionError.missingBaseline(
                baselineURL.path,
                updateCommand: "bash Scripts/update_visual_baselines.sh"
            )
        }
        let baselineData = try Data(contentsOf: baselineURL)
        let comparison = try compare(baselineData, currentData)

        #expect(
            comparison.meanChannelDifference <= 0.012,
            "Mean channel difference \(comparison.meanChannelDifference) exceeded 0.012 for \(name)"
        )
        #expect(
            comparison.changedPixelRatio <= 0.025,
            "Changed pixel ratio \(comparison.changedPixelRatio) exceeded 0.025 for \(name)"
        )
    }

    @MainActor
    private func renderSnapshot(interfaceSize: OpenFindInterfaceSize) throws -> Data {
        let scale = interfaceSize.scale
        let size = CGSize(width: 620 * scale, height: 510 * scale)
        let view = FirstRunGuideView(
            capabilities: Self.fixtureCapabilities,
            copy: Self.fixtureCopy,
            onStartSearching: {},
            onOpenSettings: {},
            onDismiss: {}
        )
        .openFindInterfaceSizing(interfaceSize)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        return try render(view, size: size)
    }

    private var baselineDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VisualBaselines", isDirectory: true)
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize) throws -> Data {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let pixelWidth = max(1, Int(size.width.rounded(.up)))
        let pixelHeight = max(1, Int(size.height.rounded(.up)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: pixelWidth * 4,
            bitsPerPixel: 32
        ) else {
            throw VisualRegressionError.renderFailed
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw VisualRegressionError.renderFailed
        }
        return data
    }

    private func compare(_ expectedData: Data, _ actualData: Data) throws -> SnapshotComparison {
        let expected = try rgbaPixels(expectedData)
        let actual = try rgbaPixels(actualData)
        guard expected.width == actual.width,
              expected.height == actual.height else {
            throw VisualRegressionError.sizeMismatch(
                expected: "\(expected.width)x\(expected.height)",
                actual: "\(actual.width)x\(actual.height)"
            )
        }

        var totalDifference = 0.0
        var changedPixels = 0
        let pixelCount = expected.width * expected.height

        for index in stride(from: 0, to: expected.bytes.count, by: 4) {
            var maximumDifference = 0
            for channel in 0..<4 {
                let difference = abs(
                    Int(expected.bytes[index + channel])
                        - Int(actual.bytes[index + channel])
                )
                totalDifference += Double(difference) / 255
                maximumDifference = max(maximumDifference, difference)
            }
            if maximumDifference > 20 {
                changedPixels += 1
            }
        }

        return SnapshotComparison(
            meanChannelDifference: totalDifference / Double(pixelCount * 4),
            changedPixelRatio: Double(changedPixels) / Double(pixelCount)
        )
    }

    private func rgbaPixels(_ data: Data) throws -> SnapshotPixels {
        guard let bitmap = NSBitmapImageRep(data: data),
              let image = bitmap.cgImage else {
            throw VisualRegressionError.decodeFailed
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw VisualRegressionError.decodeFailed }
        return SnapshotPixels(width: width, height: height, bytes: bytes)
    }

    private static let fixtureCopy = FirstRunGuideCopy(
        title: "Welcome to OpenFind",
        subtitle: "Five Mac tools, one quiet menu bar app. Start with search, then use each tool when you need it.",
        dismiss: "Not Now",
        reopenHelp: "Reopen this guide from the OpenFind menu at any time.",
        openSettings: "Open Settings",
        startSearching: "Start Searching",
        shortcutFormat: "Shortcut: %@"
    )

    private static let fixtureCapabilities = [
        FirstRunCapability(
            id: .search,
            systemImage: "magnifyingglass",
            title: "Find files instantly",
            detail: "Search names, paths, and file contents across the folders you choose.",
            shortcut: "⌃⌥F"
        ),
        FirstRunCapability(
            id: .clipboard,
            systemImage: "doc.on.clipboard",
            title: "Recall clipboard history",
            detail: "Find, preview, paste, and save reusable items without leaving your flow.",
            shortcut: "⇧⌘C"
        ),
        FirstRunCapability(
            id: .keepAwake,
            systemImage: "moon.zzz",
            title: "Keep your Mac awake",
            detail: "Start timed sessions from the menu bar or enable this optional shortcut.",
            shortcut: "⌃⌥A"
        ),
        FirstRunCapability(
            id: .driveAlive,
            systemImage: "externaldrive",
            title: "Keep external drives ready",
            detail: "Prevent selected external drives from idling during important work.",
            shortcut: "Menu Bar"
        ),
        FirstRunCapability(
            id: .keyboardCleaning,
            systemImage: "keyboard",
            title: "Clean the keyboard safely",
            detail: "Temporarily block keystrokes while you wipe down your keyboard.",
            shortcut: "⌥⌘K"
        ),
    ]
}

private struct SnapshotComparison {
    let meanChannelDifference: Double
    let changedPixelRatio: Double
}

private struct SnapshotPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

private enum VisualRegressionError: Error, CustomStringConvertible {
    case missingBaseline(String, updateCommand: String)
    case renderFailed
    case decodeFailed
    case sizeMismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .missingBaseline(let path, let updateCommand):
            "Missing visual baseline at \(path). Run \(updateCommand)."
        case .renderFailed:
            "SwiftUI snapshot rendering failed."
        case .decodeFailed:
            "A visual snapshot could not be decoded as RGBA pixels."
        case .sizeMismatch(let expected, let actual):
            "Visual snapshot size changed from \(expected) to \(actual)."
        }
    }
}
