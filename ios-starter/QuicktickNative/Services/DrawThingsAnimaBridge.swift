import Foundation
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
        case checkpointFormat, checkpointProvenance, checkpointVersion, insufficientDisk, missingConvertedModel, imageDecode, incompatibleLoRA

        var errorDescription: String? {
            switch self {
            case .checkpointFormat: "Draw Things requires the original Anima Turbo v1.1 .safetensors checkpoint, not a GGUF preview model."
            case .checkpointProvenance: "Select the Civitai-downloaded Anima Turbo v1.1 checkpoint (model version 3263843) to verify the exact release."
            case .checkpointVersion: "The imported checkpoint was not recognized as Anima/Cosmos 2.5 2B."
            case .insufficientDisk: "Free at least 7 GB before converting Anima; the original checkpoint is retained for Mirage."
            case .missingConvertedModel: "Convert the exact Anima Turbo v1.1 checkpoint before selecting the Draw Things engine."
            case .imageDecode: "Draw Things rendered an image but its output could not be decoded."
            case .incompatibleLoRA: "This LoRA is not an Anima/Cosmos 2.5 2B LoRA. Choose an Anima-compatible LoRA; other model families cannot alter this checkpoint."
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

    /// Register *both* the converted tensor file and its version specification.
    /// Without a LoRAZoo entry the local pipeline can silently skip a LoRA,
    /// even though the file exists and the UI says it is selected.
    private func convertedLoRA(_ source: URL) async throws -> URL {
        // Include the file size so different revisions do not silently share a converted LoRA.
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let key = source.deletingPathExtension().lastPathComponent + "_\(size)"
        let destination = URL(fileURLWithPath: ModelZoo.filePathForModelDownloaded("quicktick_\(key)_lora_f16.ckpt"))
        if let registered = LoRAZoo.specificationForModel(destination.lastPathComponent),
           FileManager.default.fileExists(atPath: destination.path) {
            guard registered.version == .cosmos2_5_2b else { throw Error.incompatibleLoRA }
            return destination
        }
        do {
            var importer = _MediaGenerationKit.LoRAImporter(file: source)
            try importer.import(to: destination)
            guard let version = importer.version, version == .cosmos2_5_2b else {
                try? FileManager.default.removeItem(at: destination)
                throw Error.incompatibleLoRA
            }
            let specification = LoRAZoo.Specification(
                name: source.deletingPathExtension().lastPathComponent,
                file: destination.lastPathComponent, prefix: "", version: version)
            await MainActor.run { LoRAZoo.appendCustomSpecification(specification) }
        } catch {
            // Do not allow a missing/invalid conversion to proceed as a
            // mysteriously ineffective selected style.
            throw error
        }
        return destination
    }

    func generate(prompt: String, negative: String, steps: Int, guidance: Float, seed: UInt32,
                  width: Int, height: Int, checkpoint: URL?, loras: [StudioLoRA],
                  onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        guard isReady(checkpoint: checkpoint) else { throw Error.missingConvertedModel }
        var pipeline = try await MediaGenerationPipeline.fromPretrained(Self.modelID, backend: .local)
        pipeline.configuration.width = width
        pipeline.configuration.height = height
        // A 9:16 canvas must be one continuous diffusion region. Inherited
        // tiled-diffusion defaults can generate the same square independently
        // in adjacent tiles (a repeated four-panel image).
        pipeline.configuration.tiledDiffusion = false
        pipeline.configuration.hiresFix = false
        pipeline.configuration.batchCount = 1
        pipeline.configuration.batchSize = 1
        // VAE tiling only reconstructs one latent; reserve it for large
        // canvases to reduce the iPhone's peak decoder memory.
        pipeline.configuration.tiledDecoding = width * height > 768 * 768
        if pipeline.configuration.tiledDecoding {
            pipeline.configuration.decodingTileWidth = 512
            pipeline.configuration.decodingTileHeight = 512
            pipeline.configuration.decodingTileOverlap = 64
        }
        pipeline.configuration.steps = steps
        pipeline.configuration.guidanceScale = guidance
        pipeline.configuration.seed = seed
        pipeline.configuration.sampler = .eulerASubstep
        var configuredLoRAs: [LoRA] = []
        for item in loras {
            let converted = try await convertedLoRA(item.file)
            configuredLoRAs.append(LoRA(file: converted.lastPathComponent, weight: item.strength, mode: .all))
        }
        pipeline.configuration.loras = configuredLoRAs
        NSLog("[QuickTick Anima] canvas=%dx%d tiledDiffusion=off tiledDecoding=%@ loras=%d",
              width, height, pipeline.configuration.tiledDecoding ? "on" : "off", configuredLoRAs.count)
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
        NSLog("[QuickTick Anima] backend=drawthings stage=encoding-image")
        do {
            try first.write(to: destination, type: .png)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // Hand the encoded PNG to the caller, which owns its lifetime.
        // Decoding it into a lazy CGImage and deleting the backing file before
        // the gallery saves it could make the second PNG encode fail.
        NSLog("[QuickTick Anima] backend=drawthings stage=image-ready")
        return destination
    }
}
#endif
