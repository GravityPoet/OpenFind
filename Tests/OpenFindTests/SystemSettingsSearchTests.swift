import Foundation
import Testing
@testable import OpenFind

struct SystemSettingsSearchTests {
    @Test func installedSettingsSupportChineseEnglishPinyinAndModernRoutes() throws {
        let settings = SystemSettingsSearchIndex.discover(language: "zh_CN")
        let keyboard = try #require(settings.first { $0.bundleIdentifier == "com.apple.Keyboard-Settings.extension" })
        #expect(keyboard.name == "键盘")
        for query in ["keyboard", "键盘", "jp"] {
            #expect(ApplicationSearchMatcher.rank(query, in: settings).contains { $0.id == keyboard.id })
        }
        let wifi = try #require(settings.first { $0.bundleIdentifier == "com.apple.wifi-settings-extension" })
        #expect(wifi.url.absoluteString == "x-apple.systempreferences:com.apple.wifi-settings-extension")
        #expect(ApplicationSearchMatcher.rank("wifi", in: settings).contains { $0.id == wifi.id })
        #expect(settings.contains { $0.name == "蓝牙" })
        #expect(Set(settings.map(\.id)).count == settings.count)
    }

    @Test func discoveryRejectsUnrelatedExtensionsAndDoesNotRequireLegacyPaneIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Settings.appex/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.Example-Settings.extension", "CFBundleDisplayName": "Example",
            "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui",
                "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": true]],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        #expect(SystemSettingsSearchIndex.discover(root: root).count == 1)
        #expect(SystemSettingsSearchIndex.discover(root: contents).isEmpty)
    }
}
