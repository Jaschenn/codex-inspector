// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CodexInspectorMenuBar",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0")
  ],
  targets: [
    .executableTarget(
      name: "CodexInspector",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")],
      path: "Sources/CodexInspector"
    ),
    .testTarget(
      name: "CodexInspectorTests",
      dependencies: ["CodexInspector"],
      path: "Tests/CodexInspectorTests"
    ),
  ]
)
