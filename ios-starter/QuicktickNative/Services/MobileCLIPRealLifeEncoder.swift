import Foundation
import CoreML
import CoreImage
import CoreVideo
import CryptoKit

/// Optional Apple MobileCLIP-S0 image encoder for real-life visual similarity.
/// The official Core ML image-only package is installed explicitly from Apple;
/// it never downloads models or runs inference during feed playback/scrolling.
/// This is visual similarity, not an NSFW action or consent classifier.
actor MobileCLIPRealLifeEncoder {
    static let shared = MobileCLIPRealLifeEncoder()
    static let version = "mobileclip-s0-image-apple-3e0a7bf-v1"
    static let downloadBytes = 22_871_573

    private struct ModelFile: Sendable {
        let path: String
        let bytes: Int
        let sha256: String?
    }

    // Apple's published, non-gated Core ML checkpoint. Pin the revision and
    // verify the large binary files to avoid accidental upstream replacements.
    private static let source = "https://huggingface.co/apple/coreml-mobileclip/resolve/3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947/mobileclip_s0_image.mlpackage/"
    private static let files: [ModelFile] = [
        ModelFile(path: "Manifest.json", bytes: 617, sha256: nil),
        ModelFile(path: "Data/com.apple.CoreML/model.mlmodel", bytes: 153_260,
                  sha256: "2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591"),
        ModelFile(path: "Data/com.apple.CoreML/weights/weight.bin", bytes: 22_717_696,
                  sha256: "87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6")
    ]

    private static var installationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuicktickModels", isDirectory: true)
            .appendingPathComponent("MobileCLIP-S0-image-3e0a7bf.mlmodelc", isDirectory: true)
    }

    static func isInstalled() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: installationURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var model: MLModel?
    private var installing = false

    func release() { model = nil }

    func install() async throws {
        guard !Self.isInstalled() else { return }
        guard !installing else { throw CocoaError(.fileWriteFileExists) }
        installing = true
        defer { installing = false }
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("quicktick-mobileclip-\(UUID().uuidString)", isDirectory: true)
        let package = scratch.appendingPathComponent("mobileclip_s0_image.mlpackage", isDirectory: true)
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        for file in Self.files {
            try Task.checkCancellation()
            guard let url = URL(string: Self.source + file.path) else { throw URLError(.badURL) }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let destination = package.appendingPathComponent(file.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = try manager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
            guard size?.intValue == file.bytes else { throw CocoaError(.fileReadCorruptFile) }
            if let sha256 = file.sha256 {
                let measured = try Self.hashFile(temporary)
                guard measured == sha256 else { throw CocoaError(.fileReadCorruptFile) }
            }
            try manager.moveItem(at: temporary, to: destination)
        }

        try Task.checkCancellation()
        let compiled = try MLModel.compileModel(at: package)
        // Ensure the downloaded package is loadable and matches the feature
        // contract used for inference before declaring installation complete.
        let verified = try MLModel(contentsOf: compiled)
        guard verified.modelDescription.inputDescriptionsByName["image"]?.type == .image,
              verified.modelDescription.outputDescriptionsByName["final_emb_1"]?.type == .multiArray
        else { throw CocoaError(.fileReadCorruptFile) }
        let destination = Self.installationURL
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Self.isInstalled() { return }
        try manager.moveItem(at: compiled, to: destination)
    }

    func embedding(_ image: DecodedMediaImage) throws -> [Float] {
        try Task.checkCancellation()
        guard Self.isInstalled() else { throw CocoaError(.fileNoSuchFile) }
        if model == nil {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: Self.installationURL, configuration: configuration)
        }
        let input = CIImage(cgImage: image.image)
        let side = min(input.extent.width, input.extent.height)
        guard side > 0 else { throw CocoaError(.coderInvalidValue) }
        let crop = CGRect(x: input.extent.midX - side / 2, y: input.extent.midY - side / 2,
                          width: side, height: side)
        let prepared = input.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: 256 / side, y: 256 / side))
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { throw CocoaError(.coderInvalidValue) }
        context.render(prepared, to: pixelBuffer)
        try Task.checkCancellation()
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        guard let output = try model?.prediction(from: provider).featureValue(for: "final_emb_1")?.multiArrayValue,
              (64...2048).contains(output.count) else { throw CocoaError(.coderInvalidValue) }
        let vector = (0..<output.count).map { output[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { throw CocoaError(.coderInvalidValue) }
        return vector.map { $0 / magnitude }
    }

    private static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
