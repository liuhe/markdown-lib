// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "markdown-lib",
    platforms: [.macOS(.v14)],
    products: [
        // Reusable editor library. Other apps can depend on this without
        // pulling in the workspace / tabs / windows machinery.
        .library(name: "MarkdownEditor", targets: ["MarkdownEditor"]),
        // The full app.
        .executable(name: "markdown-lib", targets: ["markdown-lib"]),
    ],
    targets: [
        .target(
            name: "MarkdownEditor",
            path: "Sources/MarkdownEditor",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "markdown-lib",
            dependencies: ["MarkdownEditor"],
            path: "Sources/App"
        ),
    ]
)
