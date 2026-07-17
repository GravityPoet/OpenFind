import Testing
@testable import OpenFind

@Suite("CLI Runner Tests")
struct CLIRunnerTests {
    @Test func searchesPackageContentsByDefault() {
        #expect(CLIRunner.searchOptions(query: "needle", flags: []).includePackages)
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
