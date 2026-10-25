// swift-tools-version: 5.9
import PackageDescription

// QuickTick builds the pinned Mirage C bridge with structured LoRA support.
// `scripts/build-mirage-lora.sh` creates the XCFramework before Xcode resolves
// this local package. A prebuilt remote Mirage binary has no LoRA C ABI.
let package = Package(
    name: "QuicktickMirageRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Mirage", targets: ["Mirage"])],
    targets: [
        .binaryTarget(
            name: "sdcpp",
            path: "Frameworks/sdcpp.xcframework"
        ),
        .target(name: "Mirage", dependencies: ["sdcpp"], path: "Sources/Mirage")
    ],
    cxxLanguageStandard: .cxx17
)
