// swift-tools-version: 6.0
import PackageDescription

// The same native sources are tested by Xcode and built/packaged by xtool.
// Models and the compiled icon catalog are copied by xtool.yml to Bundle.main.
let package = Package(
    name: "QuicktickNative",
    platforms: [.iOS(.v17)],
    products: [.library(name: "QuicktickNative", targets: ["QuicktickNative"])],
    dependencies: [
        .package(url: "https://github.com/apple-aiml-research/ml-stable-diffusion.git", exact: "1.1.1"),
        .package(url: "https://github.com/tuist/ZIPFoundation.git", from: "0.9.21")
    ],
    targets: [.target(name: "QuicktickNative",
                      dependencies: [
                        .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
                        .product(name: "ZIPFoundation", package: "ZIPFoundation")
                      ], path: "QuicktickNative",
                      exclude: ["Assets.xcassets", "SemanticAssets", "TestsSupport"],
                      swiftSettings: [.swiftLanguageMode(.v6)])]
)
