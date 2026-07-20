import Foundation
import Testing
@testable import OpenFind

@Suite("Localization Tests")
struct LocalizationTests {
    @Test func simplifiedChineseSystemLanguagesUseChinese() {
        for preferredLanguage in ["zh-Hans", "zh-Hans-CN", "zh-CN", "zh-SG"] {
            #expect(
                AppLocalization.preferredIdentifier(for: [preferredLanguage]) == "zh-Hans"
            )
        }
    }

    @Test func englishSystemLanguageUsesEnglish() {
        #expect(AppLocalization.preferredIdentifier(for: ["en-GB"]) == "en")
    }

    @Test func firstSupportedSystemLanguageWins() {
        #expect(
            AppLocalization.preferredIdentifier(
                for: ["ja-JP", "zh-Hans-CN", "en-US"]
            ) == "zh-Hans"
        )
    }

    @Test func unsupportedSystemLanguageFallsBackToEnglish() {
        #expect(AppLocalization.preferredIdentifier(for: ["ja-JP"]) == "en")
        #expect(AppLocalization.preferredIdentifier(for: ["zh-Hant-TW"]) == "en")
        #expect(AppLocalization.preferredIdentifier(for: []) == "en")
    }

    @Test func bundleManifestAndResourcesCoverSupportedLanguages() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Info.plist"))
        let info = try #require(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        let declared = try #require(info["CFBundleLocalizations"] as? [String])

        #expect(Set(declared) == Set(AppLocalization.supportedIdentifiers))

        for identifier in AppLocalization.supportedIdentifiers {
            let stringsURL = repositoryRoot
                .appendingPathComponent("Sources/OpenFind/Resources")
                .appendingPathComponent("\(identifier).lproj/Localizable.strings")
            let stringsData = try Data(contentsOf: stringsURL)
            let strings = try #require(
                PropertyListSerialization.propertyList(
                    from: stringsData,
                    format: nil
                ) as? [String: String]
            )
            #expect(strings["Settings"] != nil)
        }
    }
}
