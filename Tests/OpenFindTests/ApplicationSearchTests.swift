import Foundation
import Testing
@testable import OpenFind

@Suite("Application Search")
struct ApplicationSearchTests {
    private let candidates = [
        ApplicationSearchResult(
            url: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome"
        ),
        ApplicationSearchResult(
            url: URL(fileURLWithPath: "/Applications/Ghostty.app"),
            name: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty"
        ),
        ApplicationSearchResult(
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode"
        ),
    ]

    @Test func matchesApplicationInitialsLikeAlfred() {
        let results = ApplicationSearchIndex.rank("gc", in: candidates)
        #expect(results.first?.name == "Google Chrome")
    }

    @Test func prefersExactNameOverAcronymAndSubsequence() {
        let results = ApplicationSearchIndex.rank("ghostty", in: candidates)
        #expect(results.first?.name == "Ghostty")
    }

    @Test func ignoresEmptyQueries() {
        #expect(ApplicationSearchIndex.rank("   ", in: candidates).isEmpty)
    }

    @Test func matchesChineseApplicationPinyinInitials() {
        let wechat = ApplicationSearchResult(
            url: URL(fileURLWithPath: "/Applications/WeChat.app"),
            name: "微信",
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        #expect(ApplicationSearchIndex.rank("wx", in: [wechat]).first?.name == "微信")
        #expect(ApplicationSearchIndex.rank("weixin", in: [wechat]).first?.name == "微信")
        #expect(ApplicationSearchIndex.rank("WeChat", in: [wechat]).first?.name == "微信")
    }

    @Test func camelCaseAndWordBoundaryFuzzyMatches() {
        let app = ApplicationSearchResult(url: URL(fileURLWithPath: "/Applications/PhotoShop.app"),
                                          name: "PhotoShop", bundleIdentifier: "test.photoshop")
        #expect(ApplicationSearchIndex.rank("ps", in: [app]).first == app)
        #expect(ApplicationSearchIndex.rank("vscode", in: candidates).first?.name == "Visual Studio Code")
    }

    @Test func discoverySkipsNestedHelpersAndKeepsMenuBarApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ path: String, _ id: String, background: Bool = false) throws {
            let contents = root.appendingPathComponent(path + "/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id,
                                        "LSUIElement": true, "LSBackgroundOnly": background]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("Launcher.app", "test.launcher")
        try app("Launcher.app/Contents/Helpers/Helper.app", "test.helper")
        try app("Agent.app", "test.agent", background: true)
        try app("Copy.app", "test.launcher")
        let found = ApplicationSearchIndex.discoverApplications(roots: [root, root])
        #expect(found.count == 1)
        #expect(found.first?.bundleIdentifier == "test.launcher")
    }
}
