// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PromptSlash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PromptSlash", path: "Sources/PromptSlash")
    ]
)
