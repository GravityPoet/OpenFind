import XCTest
@testable import OpenFindBrowser

final class BrowserLocalizationTests: XCTestCase {
    func testBrowserUsesFirstSupportedLanguageLikeTheHost() {
        XCTAssertEqual(BrowserLocalization.preferredIdentifier(for: ["fr-FR", "zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(BrowserLocalization.preferredIdentifier(for: ["en-US", "zh-Hans-CN"]), "en")
    }

    func testBatchRenameCountAndCollisionMessagesAreFullyChinese() {
        XCTAssertEqual(BrowserLocalization.format("Start at %lld", arguments: [12], language: "zh-Hans"), "起始编号：12")
        XCTAssertEqual(BrowserLocalization.format("“%@” already exists.", arguments: ["预算.txt"], language: "zh-Hans"), "“预算.txt”已存在。")
        XCTAssertEqual(BrowserLocalization.text("This archive format is not supported.", language: "zh-Hans"), "不支持此压缩包格式。")
    }

    func testInterpolatedNamesAndRecoveryPathsAreNotParsedOrTranslated() {
        let name = "Rename 9 Items · 100%@. Its file is at report.txt"
        let path = "/fixture/folder. Replace moves/\(name)"
        XCTAssertEqual(BrowserLocalization.format("Rename %@", arguments: [name], language: "zh-Hans"), "重新命名 \(name)")
        XCTAssertEqual(BrowserLocalization.format("Could not restore %@. Its file is at %@.", arguments: [name, path], language: "zh-Hans"), "无法恢复 \(name)。文件保存在 \(path)。")
        XCTAssertEqual(BrowserLocalization.format("Searching “%@”", arguments: [name], language: "zh-Hans"), "正在搜索“\(name)”")
    }

    func testEjectMessageHasBalancedQuotesAndEnglishFallbackKeepsValues() {
        let key = "Wait for the file operation to finish before ejecting ‘%@’."
        XCTAssertEqual(BrowserLocalization.format(key, arguments: ["SSD"], language: "zh-Hans"), "请等待文件操作完成后再推出“SSD”。")
        XCTAssertEqual(BrowserLocalization.format(key, arguments: ["SSD"], language: "en"), "Wait for the file operation to finish before ejecting ‘SSD’.")
        XCTAssertEqual(BrowserLocalization.format("Start at %lld", arguments: [12], language: "en"), "Start at 12")
    }

    func testBatchErrorsKeepUnknownSystemDetails() {
        XCTAssertEqual(BrowserLocalization.text("Each item needs a different name.\nSystem diagnostic 42", language: "zh-Hans"), "每个项目都需要使用不同的名称。\nSystem diagnostic 42")
    }
}
