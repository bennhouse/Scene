// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Scene",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SceneApp", path: "Sources/SceneApp")
    ],
    swiftLanguageModes: [.v5]
)
