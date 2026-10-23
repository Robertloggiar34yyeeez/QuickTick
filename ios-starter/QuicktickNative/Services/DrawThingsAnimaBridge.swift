import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Kept behind a separate import so QuickTick's crash-tested Mirage renderer
// remains usable if this experimental Swift package is unavailable.
#if canImport(_MediaGenerationKit) && canImport(ModelOp) && canImport(ModelZoo) && canImport(DataModels)
import _MediaGenerationKit
import ModelOp
import ModelZoo
import DataModels

/// Experimental local Draw Things backend. The source checkpoint must be the
/// exact Civitai Anima Turbo v1.1 safetensors; never substitute Turbo v1.0.
actor DrawThingsAnimaBridge {
    static let shared = DrawThingsAnimaBridge()

    static let modelID = "quicktick_anima_turbo_v11_f16.ckpt"
    private static let modelPrefix = "quicktick_anima_turbo_v11"
    private static let manifestName = "quicktick_anima_turbo_v11_source.json"
    private struct Manifest: Codable {
        let sourceName: String
        let sourceBytes: Int64
    }
    private static let helperFiles: [(name: String, url: URL)] = [
        ("qwen_3_0.6b_q8p.ckpt", URL(string: "https://huggingface.co/JoyFusionAI/dt-components/resolve/main/qwen_3_0.6b_q8p.ckpt")!),
        ("qwen_image_vae_f16.ckpt", URL(string: "https://huggingface.co/JoyFusionAI/dt-components/resolve/main/qwen_image_vae_f16.ckpt")!)
    ]

    enum Error: LocalizedError {
        case checkpointFormat, checkpointProvenance, checkpointVersion, insufficientDisk, missingConvertedModel, imageDecode

        var errorDescription: String? {
            switch self {
            case .checkpointFormat: "Draw Things requires the original Anima Turbo v1.1 .safetensors checkpoint, not a GGUF preview model."
            case .checkpointProvenance: "Select the Civitai-downloaded Anima Turbo v1.1 checkpoint (model version 3263843) to verify the exact release."
            case .checkpointVersion: "The imported checkpoint was not recognized as Anima/Cosmos 2.5 2B."
            case .insufficientDisk: "Free at least 7 GB before converting Anima; the original checkpoint is retained for Mirage."
            case .missingConvertedModel: "Convert the exact Anima Turbo v1.1 checkpoint before selecting the Draw Things engine."
            case .imageDecode: "Draw Things rendered an image but its output could not be decoded."
            }
        }
    }

    func isReady(checkpoint: URL?) -> Bool {
        guard let checkpoint,
              FileManager.default.fileExists(atPath: ModelZoo.filePathForModelDownloaded(Self.modelID)),
              Self.helperFiles.allSatisfy({ FileManager.default.fileExists(atPath: ModelZoo.filePathForModelDownloaded($0.name)) }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: ModelZoo.filePathForModelDownloaded(Self.manifestName))),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return false }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: checkpoint.path)[.size] as? NSNumber)?.int64Value
        return manifest.sourceName == checkpoint.lastPathComponent && manifest.sourceBytes == bytes
    }

    /// Performs a one-time conversion into s4nnc's native tensor store.
    /// The original source remains in QuickTick's model library as fallback.
    func prepare(checkpoint: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard checkpoint.pathExtension.lowercased() == "safetensors" else { throw Error.checkpointFormat }
        guard checkpoint.lastPathComponent == "checkpoint-3263843.safetensors" else { throw Error.checkpointProvenance }
        let sourceBytes = (try FileManager.default.attributesOfItem(atPath: checkpoint.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceBytes > 2_000_000_000 else { throw Error.checkpointFormat }
        guard let values = try? checkpoint.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              (values.volumeAvailableCapacityForImportantUsage ?? 0) >= 7_000_000_000 else {
            throw Error.insufficientDisk
        }

        for (index, helper) in Self.helperFiles.enumerated() {
            let destination = URL(fileURLWithPath: ModelZoo.filePathForModelDownloaded(helper.name))
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            let (download, response) = try await URLSession.shared.download(from: helper.url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw StudioError.invalidResponse }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: download, to: destination)
            onProgress(Double(index + 1) * 0.1)
        }

        let importer = ModelImporter(
            filePath: checkpoint.path, modelName: Self.modelPrefix,
            isTextEncoderCustomized: false, autoencoderFilePath: nil,
            textEncoderFilePath: nil, textEncoder2FilePath: nil
        )
        let (files, version, modifier, inspection) = try importer.import(
            versionCheck: { _ in }, progress: { value in onProgress(0.2 + 0.8 * Double(value)) }
        )
        guard version == .cosmos2_5_2b else { throw Error.checkpointVersion }
        let inferred = ModelImporter.inferModelSpecification(
            modelName: "Anima Turbo v1.1 · QuickTick", fileName: Self.modelPrefix,
            fileNames: files + Self.helperFiles.map(\.name), modelVersion: version,
            modifier: modifier, inspectionResult: inspection, prefix: "",
            objective: nil, conditioning: nil, noiseDiscretization: nil,
            upcastAttention: false, finetuneScale: 8
        )
        await MainActor.run { ModelZoo.appendCustomSpecification(inferred.specification) }
        let manifest = Manifest(sourceName: checkpoint.lastPathComponent, sourceBytes: sourceBytes)
        let manifestURL = URL(fileURLWithPath: ModelZoo.filePathForModelDownloaded(Self.manifestName))
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        onProgress(1)
    }

    /// LoRAs are converted once; individual strengths remain adjustable.
    private func convertedLoRA(_ source: URL) throws -> URL {
        // Include the file size so different revisions do not silently share a converted LoRA.
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let key = source.deletingPathExtension().lastPathComponent + "_\(size)"
        let destination = URL(fileURLWithPath: ModelZoo.filePathForModelDownloaded("quicktick_\(key)_lora_f16.ckpt"))
        if !FileManager.default.fileExists(atPath: destination.path) {
            var importer = _MediaGenerationKit.LoRAImporter(file: source)
            try importer.import(to: destination)
        }
        return destination
    }

    func generate(prompt: String, negative: String, steps: Int, guidance: Float, seed: UInt32,
                  width: Int, height: Int, checkpoint: URL?, loras: [StudioLoRA],
                  onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> CGImage {
        guard isReady(checkpoint: checkpoint) else { throw Error.missingConvertedModel }
        var pipeline = try await MediaGenerationPipeline.fromPretrained(Self.modelID, backend: .local)
        pipeline.configuration.width = width
        pipeline.configuration.height = height
        pipeline.configuration.steps = steps
        pipeline.configuration.guidanceScale = guidance
        pipeline.configuration.seed = seed
        pipeline.configuration.sampler = .eulerASubstep
        pipeline.configuration.loras = try loras.map { item in
            let converted = try convertedLoRA(item.file)
            return LoRA(file: converted.lastPathComponent, weight: item.strength, mode: .all)
        }
        let results = try await pipeline.generate(prompt: prompt, negativePrompt: negative) { state, _ in
            switch state {
            case .generating(let step, let total):
                onProgress(step, total)
            case .decoding:
                NSLog("[QuickTick Anima] backend=drawthings stage=vae-decoding")
            case .postprocessing:
                NSLog("[QuickTick Anima] backend=drawthings stage=postprocessing")
            default:
                break
            }
        }
        guard let first = results.first else { throw Error.imageDecode }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("quicktick-drawthings-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        NSLog("[QuickTick Anima] backend=drawthings stage=encoding-image")
        try first.write(to: destination, type: .png)
        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Error.imageDecode }
        NSLog("[QuickTick Anima] backend=drawthings stage=image-ready")
        return image
    }
}
#endif
