// swift-tools-version: 6.0
import PackageDescription

// This SwiftPM manifest mirrors Xcode dependencies for optional xtool builds.
// The CI IPA is exported from the already-compiled Xcode device archive.
let package = Package(
    name: "QuicktickNative",
    platforms: [.iOS(.v17)],
    products: [.library(name: "QuicktickNative", targets: ["QuicktickNative"])],
    dependencies: [
        .package(url: "https://github.com/apple-aiml-research/ml-stable-diffusion.git", exact: "1.1.1"),
        .package(url: "https://github.com/tuist/ZIPFoundation.git", from: "0.9.21"),
        .package(path: "MirageRuntime")
    ],
    targets: [.target(name: "QuicktickNative",
                      dependencies: [
                        .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
                        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                        .product(name: "Mirage", package: "QuicktickMirageRuntime")
                      ], path: "QuicktickNative",
                      exclude: ["Assets.xcassets", "SemanticAssets", "TestsSupport"],
                      swiftSettings: [.swiftLanguageMode(.v6)])]
)
