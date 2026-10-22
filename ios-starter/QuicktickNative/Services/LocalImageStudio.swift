import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
import StableDiffusion

enum StudioError: LocalizedError {
    case unsupportedModel, invalidArchive, invalidResponse, unavailableModel, noImage, invalidFile
    var errorDescription: String? {
        switch self {
        case .unsupportedModel: "The archive does not contain a compiled Core ML Stable Diffusion pipeline. CivitAI .safetensors checkpoints and LoRAs need conversion before they can run here."
        case .invalidArchive: "The model archive is invalid or contains unsafe paths."
        case .invalidResponse: "The model service did not return a valid download."
        case .unavailableModel: "Download the on-device starter model or import a compatible Core ML model first."
        case .noImage: "The diffusion pipeline did not return an image."
        case .invalidFile: "This download is not a supported model or LoRA file."
        }
    }
}

struct StudioPromptSeed: Sendable, Equatable {
    var characters: [String]
    var artists: [String]
    var attributes: [String]
    var scenes: [String]

    var prompt: String {
        func spokenAttribute(_ attribute: String) -> String {
            let natural: [String: String] = [
                "at_viewer": "looking at viewer", "away": "looking away",
                "up": "looking up", "down": "looking down",
                "leaning_forward": "leaning forward", "leaning_back": "leaning back"
            ]
            return natural[attribute] ?? attribute.replacingOccurrences(of: "_", with: " ")
        }
        let phrases = characters.prefix(2).map { $0.replacingOccurrences(of: "_", with: " ") }
            + artists.prefix(1).map { "art by " + $0.replacingOccurrences(of: "_", with: " ") }
            + attributes.prefix(3).map(spokenAttribute)
            + scenes.prefix(2).map { $0.replacingOccurrences(of: "_", with: " ") }
        return (phrases + ["detailed illustration, beautiful composition"]).joined(separator: ", ")
    }

    static func build(favorites: [Post], taxonomy: VisualTagTaxonomy? = nil) -> Self {
        var characters: [String: Int] = [:], artists: [String: Int] = [:]
        var attributes: [String: Int] = [:], scenes: [String: Int] = [:]
        let placeTags: Set<String> = ["outdoors", "indoors", "beach", "bedroom", "forest", "city", "night", "sunset", "garden"]
        for post in favorites {
            let concepts = TasteConcepts.resolve(post.tags, taxonomy: taxonomy)
            for name in Set(concepts.characters) { characters[name, default: 0] += 1 }
            for tag in Set(post.tags.map(TasteConcepts.canonical)) {
                if tag.hasPrefix("artist:"), tag.count > 7 { artists[String(tag.dropFirst(7)), default: 0] += 1 }
                else if taxonomy?.artists.contains(tag) == true { artists[tag, default: 0] += 1 }
                if placeTags.contains(tag) { scenes[tag, default: 0] += 1 }
            }
            if let features = VisualFeatures.metadata(post, taxonomy: taxonomy) {
                for (key, confidence) in features.attributes where confidence >= 0.8 {
                    if key.hasPrefix("pose:") || key.hasPrefix("gaze:") || key.hasPrefix("appearance:") || key.hasPrefix("clothing:") {
                        let term = String(key.split(separator: ":", maxSplits: 1).last ?? "")
                        attributes[term, default: 0] += 1
                    }
                }
            }
        }
        func top(_ counts: [String: Int], _ limit: Int) -> [String] {
            counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(limit).map(\.key)
        }
        return Self(characters: top(characters, 4), artists: top(artists, 4),
                    attributes: top(attributes, 6), scenes: top(scenes, 4))
    }
}

struct CivitaiStudioModel: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let type: String
    let modelVersions: [Version]
    struct Version: Decodable, Sendable {
        let id: Int
        let baseModel: String?
        let downloadUrl: URL?
        let trainedWords: [String]?
    }
    var latest: Version? { modelVersions.first }
}

/// Metadata discovery and opt-in downloads only. No CivitAI inference API is
/// used and the bearer key is never encoded into URLs or app state JSON.
actor CivitaiStudioCatalog {
    func search(_ query: String, type: String, host: String, token: String? = nil) async throws -> [CivitaiStudioModel] {
        guard ["Checkpoint", "LORA"].contains(type), query.count <= 80,
              ["civitai.com", "civitai.red"].contains(host) else { return [] }
        var components = URLComponents(string: "https://\(host)/api/v1/models")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "types", value: type),
                                 URLQueryItem(name: "limit", value: "12")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 2_000_000 else { throw StudioError.invalidResponse }
        struct Page: Decodable { let items: [CivitaiStudioModel] }
        return try JSONDecoder().decode(Page.self, from: data).items
    }
}

/// All downloads and generated images stay in Application Support. The large
/// reference archive is fetched only on request, never during feed scrolling.
actor LocalImageStudio {
    static let shared = LocalImageStudio()
    private let root: URL
    private let models: URL
    private let assets: URL
    private let gallery: URL
    private let starterURL = URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized/resolve/main/coreml-stable-diffusion-v1-5-palettized_split_einsum_v2_compiled.zip")!

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuicktickStudio", isDirectory: true)
        models = root.appendingPathComponent("Models", isDirectory: true)
        assets = root.appendingPathComponent("CivitaiAssets", isDirectory: true)
        gallery = root.appendingPathComponent("Images", isDirectory: true)
    }

    func installedModelDirectories() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { Self.resources(in: $0) }.sorted { $0.path < $1.path }
    }

    private static func resources(in path: URL) -> URL? {
        let fileManager = FileManager.default
        var locations = [path]
        // Hugging Face ZIPs may wrap Resources in several version folders.
        for _ in 0..<6 {
            let matching = locations.first { directory in
                ["TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"].allSatisfy {
                    fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
                } && (fileManager.fileExists(atPath: directory.appendingPathComponent("Unet.mlmodelc").path)
                      || (fileManager.fileExists(atPath: directory.appendingPathComponent("UnetChunk1.mlmodelc").path)
                          && fileManager.fileExists(atPath: directory.appendingPathComponent("UnetChunk2.mlmodelc").path)))
            }
            if let matching { return matching }
            locations = locations.flatMap { (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return nil
    }

    func downloadStarter() async throws -> URL {
        try await installZip(from: starterURL, name: "Apple SD 1.5 · 6-bit")
    }

    func importModel(_ pickedURL: URL) throws -> URL {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
        if pickedURL.pathExtension.lowercased() == "zip" {
            return try installLocalZip(pickedURL, name: "Imported Core ML")
        }
        guard Self.resources(in: pickedURL) != nil else { throw StudioError.unsupportedModel }
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: pickedURL, to: destination)
        return Self.resources(in: destination) ?? destination
    }

    private func installZip(from url: URL, name: String) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.invalidResponse }
        return try installLocalZip(temp, name: name)
    }

    private func installLocalZip(_ zip: URL, name: String) throws -> URL {
        let archive: Archive
        do { archive = try Archive(url: zip, accessMode: .read) }
        catch { throw StudioError.invalidArchive }
        var expanded: UInt64 = 0, entries = 0
        for entry in archive {
            entries += 1
            let components = entry.path.split(separator: "/")
            guard entries <= 20_000, !entry.path.hasPrefix("/"),
                  !components.contains(".."), !components.contains("."),
                  entry.type == .file || entry.type == .directory else { throw StudioError.invalidArchive }
            expanded += UInt64(entry.uncompressedSize)
            guard expanded <= 12_000_000_000 else { throw StudioError.invalidArchive }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: models, withIntermediateDirectories: true)
        let staging = models.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.unzipItem(at: zip, to: staging)
        guard let resources = Self.resources(in: staging) else { throw StudioError.unsupportedModel }
        let relativePath = String(resources.path.dropFirst(staging.path.count))
        let destination = models.appendingPathComponent("model-" + UUID().uuidString, isDirectory: true)
        try manager.moveItem(at: staging, to: destination)
        // Swift's standard .name metadata is not required: directory identity
        // is intentionally stable when multiple model packages are installed.
        _ = name
        return URL(fileURLWithPath: destination.path + relativePath, isDirectory: true)
    }

    func downloadCivitaiAsset(_ version: CivitaiStudioModel.Version, type: String, host: String, token: String?) async throws -> URL {
        guard ["Checkpoint", "LORA"].contains(type), version.id > 0,
              ["civitai.com", "civitai.red"].contains(host) else { throw StudioError.invalidFile }
        // Construct a trusted API endpoint rather than follow arbitrary model
        // metadata URLs. Never append the token to a query string.
        let url = URL(string: "https://\(host)/api/download/models/\(version.id)")!
        var request = URLRequest(url: url)
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw StudioError.invalidResponse }
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 100_000 else { throw StudioError.invalidFile }
        let suggestedExtension = response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let extensionHint = suggestedExtension.isEmpty ? "safetensors" : suggestedExtension
        guard ["safetensors", "ckpt", "pt"].contains(extensionHint) else { throw StudioError.invalidFile }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let result = assets.appendingPathComponent("\(type.lowercased())-\(version.id).\(extensionHint)")
        if FileManager.default.fileExists(atPath: result.path) { return result }
        try FileManager.default.moveItem(at: temp, to: result)
        return result
    }

    func downloadedAssets() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["safetensors", "ckpt", "pt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func deleteDownloadedAsset(_ url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == assets.standardizedFileURL.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: resolved.path) else { throw StudioError.invalidFile }
        try FileManager.default.removeItem(at: resolved)
    }

    func generate(prompt: String, negative: String, modelURL: URL, steps: Int, guidance: Float, seed: UInt32,
                  onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        guard let resources = Self.resources(in: modelURL), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.unavailableModel }
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let pipeline = try StableDiffusionPipeline(resourcesAt: resources, controlNet: [],
            configuration: configuration, disableSafety: false, reduceMemory: true)
        try pipeline.loadResources()
        defer { pipeline.unloadResources() }
        var options = PipelineConfiguration(prompt: String(prompt.prefix(1200)))
        options.negativePrompt = String(negative.prefix(1200))
        options.stepCount = max(4, min(40, steps))
        options.guidanceScale = max(1, min(15, guidance))
        options.seed = seed
        options.schedulerType = .dpmSolverMultistepScheduler
        // Heavy computation occurs on this actor, outside the UI main actor.
        let images = try pipeline.generateImages(configuration: options) { progress in
            onProgress(progress.step + 1, progress.stepCount)
            return !withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
        try Task.checkCancellation()
        guard let result = images.compactMap({ $0 }).first else { throw StudioError.noImage }
        let buffer = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError.noImage
        }
        CGImageDestinationAddImage(imageDestination, result, nil)
        guard CGImageDestinationFinalize(imageDestination) else { throw StudioError.noImage }
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        let destination = gallery.appendingPathComponent(UUID().uuidString + ".png")
        try (buffer as Data).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return destination
    }

    func savedImages() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: gallery, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
