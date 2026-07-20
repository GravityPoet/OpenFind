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
        #expect(info["NSAppleScriptEnabled"] as? Bool == true)
        #expect(info["OSAScriptingDefinition"] as? String == "OpenFind.sdef")
        #expect(info["NSLocationUsageDescription"] as? String != nil)
        #expect(info["NSLocationWhenInUseUsageDescription"] as? String != nil)

        for entitlementName in [
            "OpenFind.direct.entitlements",
            "OpenFind.local.entitlements",
            "OpenFind.sandbox.entitlements",
        ] {
            let entitlementData = try Data(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Entitlements")
                    .appendingPathComponent(entitlementName)
            )
            let entitlements = try #require(
                PropertyListSerialization.propertyList(
                    from: entitlementData,
                    format: nil
                ) as? [String: Any]
            )
            #expect(entitlements["com.apple.security.personal-information.location"] as? Bool == true)
        }

        for identifier in AppLocalization.supportedIdentifiers {
            let stringsURL = repositoryRoot
                .appendingPathComponent("Sources/OpenFind/Resources")
                .appendingPathComponent("\(identifier).lproj/Localizable.strings")
            let stringsData = try Data(contentsOf: stringsURL)
            let stringsSource = try String(contentsOf: stringsURL, encoding: .utf8)
            let strings = try #require(
                PropertyListSerialization.propertyList(
                    from: stringsData,
                    format: nil
                ) as? [String: String]
            )
            #expect(strings["Settings"] != nil)

            let expression = try NSRegularExpression(pattern: #"(?m)^\s*\"([^\"]+)\"\s*="#)
            let range = NSRange(stringsSource.startIndex..., in: stringsSource)
            let keys = expression.matches(in: stringsSource, range: range).compactMap { match in
                Range(match.range(at: 1), in: stringsSource).map { String(stringsSource[$0]) }
            }
            #expect(keys.count == Set(keys).count)

            if identifier == "en" {
                #expect(strings["New Trigger"] == "New Trigger")
                #expect(strings["Keyboard Cleaning Lock"] == "Keyboard Cleaning Lock")
                #expect(strings["Keyboard Lock"] == "Keyboard Cleaning Lock")
            } else if identifier == "zh-Hans" {
                #expect(strings["New Trigger"] == "新建触发器")
                #expect(strings["Keyboard Cleaning Lock"] == "键盘清洁锁定")
                #expect(strings["Keyboard Lock"] == "键盘清洁锁定")
                #expect(strings["Lock Keyboard"] == "开始键盘清洁锁定")
            }
        }

        let scriptingDefinition = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/OpenFind/Resources/OpenFind.sdef"),
            encoding: .utf8
        )
        let commandCodes = [
            "amphcAct", "amphcmOn", "amphcOff", "amphSTRm", "amphDSOK",
            "amphAWDS", "amphPTDS", "amphSSOK", "amphAWSS", "amphPTSS",
            "amphCDMK", "amphECDM", "amphDCDM", "amphSisT", "amphTrEn",
            "amphEnTr", "amphDsTr", "amphDAEn", "amphEnDA", "amphDsDA",
            "amphcOoo",
        ]
        for code in commandCodes {
            #expect(scriptingDefinition.contains("code=\"\(code)\""))
        }
        #expect(scriptingDefinition.contains("cocoa class=\"OpenFindScriptCommand\""))
        #expect(scriptingDefinition.contains("<suite name=\"Standard Suite\""))
        #expect(scriptingDefinition.contains("code=\"aevtquit\""))
        #expect(scriptingDefinition.contains("cocoa class=\"OpenFindQuitScriptCommand\""))
        #expect(scriptingDefinition.contains("code=\"capp\""))
        #expect(scriptingDefinition.contains("code=\"cwin\""))
    }
}
