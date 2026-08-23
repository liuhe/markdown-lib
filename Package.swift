// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "markdown-lib",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "markdown-lib",
            path: "Sources/App",
            resources: [.copy("Resources")]
        ),
    ]
)
