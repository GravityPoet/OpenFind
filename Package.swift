// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenFind",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenFind",
            path: "Sources/OpenFind",
            resources: [.process("Resources")]
        )
    ]
)
