// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexInspectorMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CodexInspector",
            path: "Sources/CodexInspector"
        )
    ]
)
