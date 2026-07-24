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
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/OpenFind",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OpenFindTests",
            dependencies: ["OpenFind"],
            resources: [.process("Fixtures")]
        )
    ]
)
