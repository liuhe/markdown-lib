// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "markdown-editor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "markdown-editor",
            path: "Sources/App",
            resources: [.copy("Resources")]
        ),
    ]
)
