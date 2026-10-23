// swift-tools-version: 5.9
import PackageDescription

// Mirage's iOS Metal backend is distributed by its maintainer as a 27 MB
// XCFramework. Pin both release URL and SHA-256 to make CI reproducible.
// The Swift adapter omits newer native upscaler entry points not present in
// this binary; QuickTick uses its own Real-ESRGAN Core ML adapter instead.
let package = Package(
    name: "QuicktickMirageRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Mirage", targets: ["Mirage"])],
    targets: [
        .binaryTarget(
            name: "sdcpp",
            url: "https://github.com/haplollc/Mirage/releases/download/sdcpp-2026-08-27/sdcpp.xcframework.zip",
            checksum: "f56d84fa1d15baaa440507a7905f00fed28e7683ecf47b3af0aa05f53d4c0b94"
        ),
        .target(name: "Mirage", dependencies: ["sdcpp"], path: "Sources/Mirage")
    ],
    cxxLanguageStandard: .cxx17
)
