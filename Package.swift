// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "LLMKit", targets: ["LLMKit"]),
    ],
    targets: [
        .target(
            name: "LLMKit",
            path: "Sources/LLMKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMKit"],
            path: "Tests/LLMKitTests"
        ),
    ]
)
