// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TagwerkCore",
    defaultLocalization: "de",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "TagwerkCore", targets: ["TagwerkCore"]),
    ],
    targets: [
        .target(name: "TagwerkCore", path: "Sources/TagwerkCore"),
        .testTarget(name: "TagwerkCoreTests", dependencies: ["TagwerkCore"], path: "Tests/TagwerkCoreTests"),
        // CI only: end-to-end run against the real GitHub API.
        .executableTarget(name: "tagwerk-e2e", dependencies: ["TagwerkCore"], path: "Sources/tagwerk-e2e"),
    ],
    swiftLanguageModes: [.v5]
)
