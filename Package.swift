// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenFind",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", exact: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "OpenFind",
            dependencies: [
                "OpenFindBrowser",
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/OpenFind",
            resources: [.process("Resources")]
        ),
        .target(
            name: "OpenFindBrowser",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenFindBrowserTests", dependencies: ["OpenFindBrowser"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenFindTests",
            dependencies: ["OpenFind"],
            resources: [.process("Fixtures")]
        )
    ]
)
