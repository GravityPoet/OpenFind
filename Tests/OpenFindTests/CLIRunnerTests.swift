import Foundation
import Testing
@testable import OpenFind

@Suite("CLI Runner Tests")
struct CLIRunnerTests {
    @Test func searchesPackageContentsByDefault() {
        #expect(CLIRunner.searchOptions(query: "needle", flags: []).includePackages)
    }

    @Test func usageWritesToProvidedHandle() {
        let pipe = Pipe()
        CLIRunner.printUsage(to: pipe.fileHandleForWriting)
        pipe.fileHandleForWriting.closeFile()
        let text = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(text.contains("Usage: OpenFind --search"))
        #expect(text.contains("--help"))
    }

    @Test func packageFlagsRemainCompatibleAndAllowOptOut() {
        #expect(CLIRunner.searchOptions(query: "needle", flags: ["--packages"]).includePackages)
        #expect(!CLIRunner.searchOptions(query: "needle", flags: ["--no-packages"]).includePackages)
        #expect(!CLIRunner.searchOptions(
            query: "needle",
            flags: ["--packages", "--no-packages"]
        ).includePackages)
    }
}
