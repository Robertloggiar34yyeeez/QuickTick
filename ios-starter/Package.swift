// swift-tools-version: 6.0
import PackageDescription

// The same native sources are tested by Xcode and built/packaged by xtool.
// Models and the compiled icon catalog are copied by xtool.yml to Bundle.main.
let package = Package(
    name: "QuicktickNative",
    platforms: [.iOS(.v17)],
    products: [.library(name: "QuicktickNative", targets: ["QuicktickNative"])],
    targets: [.target(name: "QuicktickNative", path: "QuicktickNative",
                      exclude: ["Assets.xcassets", "SemanticAssets", "TestsSupport"],
                      swiftSettings: [.swiftLanguageMode(.v6)])]
)
