// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LanguageModelContextKit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
        .visionOS("26.0")
    ],
    products: [
        .library(
            name: "LanguageModelContextKit",
            targets: ["LanguageModelContextKit"]
        )
    ],
    targets: [
        .target(
            name: "LanguageModelContextKit",
            path: "Sources/LanguageModelContextKit"
        ),
        .testTarget(
            name: "LanguageModelContextKitTests",
            dependencies: ["LanguageModelContextKit"],
            path: "Tests",
            exclude: ["LanguageModelContextKitIntegrationTests"],
            sources: ["LanguageModelContextKitTests"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "LanguageModelContextKitIntegrationTests",
            dependencies: ["LanguageModelContextKit"],
            path: "Tests/LanguageModelContextKitIntegrationTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
