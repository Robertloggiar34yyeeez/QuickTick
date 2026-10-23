import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
import StableDiffusion
import Mirage
import Darwin

enum StudioError: LocalizedError {
    case unsupportedModel, unsupportedLoRA, invalidArchive, invalidResponse, unavailableModel, noImage, imageFiltered, invalidFile, downloadBusy, renderBusy
    case insufficientMemory(required: Int64, available: Int64)
    var errorDescription: String? {
        switch self {
        case .unsupportedModel: "The archive does not contain a compiled Core ML Stable Diffusion pipeline. CivitAI .safetensors checkpoints and LoRAs need conversion before they can run here."
        case .unsupportedLoRA: "LoRA import is available, but this build's Mirage Metal library has no LoRA inference API. Disable the selected LoRAs to generate with Anima; native LoRA support needs a rebuilt backend."
        case .invalidArchive: "The model archive is invalid or contains unsafe paths."
        case .invalidResponse: "The model service did not return a valid download."
        case .unavailableModel: "Download the on-device starter model or import a compatible Core ML model first."
        case .noImage: "The diffusion pipeline did not return an image."
        case .imageFiltered: "Core ML finished rendering but the safety check withheld its image. Change the prompt or review the filter option in Advanced render settings. The 4× upscaler never started."
        case .invalidFile: "This download is not a supported model or LoRA file."
        case .downloadBusy: "Another model download is already running. Pause, finish or stop it first."
        case .renderBusy: "Another on-device image render is still running. Wait for it to finish before creating the next image."
        case .insufficientMemory(let needed, let available):
            "Anima needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .memory)) free memory; only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .memory)) is available. Close other apps or use a lighter device model."
        }
    }
}

/// Conservative jetsam headroom around Mirage's compressed model weights.
/// Mirrors its maintainer's recommendation to reserve at least 1 GB for
/// activations and accounts for the separate Qwen encoder / VAE downloads.
enum StudioAnimaMemoryBudget {
    static let requiredAfterLoad: Int64 = 900_000_000

    static func requiredBeforeLoad(diffusionBytes: Int64, auxiliaryBytes: Int64, upscale: Bool) -> Int64 {
        max(0, diffusionBytes) + max(0, auxiliaryBytes) + 1_100_000_000
            + (upscale ? 300_000_000 : 0)
    }

    static func check(available: Int64, required: Int64) throws {
        guard available == 0 || available >= required else {
            throw StudioError.insufficientMemory(required: required, available: available)
        }
    }
}

enum StudioAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case square, portrait, landscape, story
    var id: String { rawValue }
    var label: String {
        switch self {
        case .square: "1:1"
        case .portrait: "3:4"
        case .landscape: "4:3"
        case .story: "9:16"
        }
    }
    var dimensions: (Int, Int) {
        switch self {
        case .square: (1, 1)
        case .portrait: (3, 4)
        case .landscape: (4, 3)
        case .story: (9, 16)
        }
    }

    func nativePixelDimensions(longestEdge: Int) -> (width: Int, height: Int) {
        let edge = max(512, min(1024, longestEdge))
        let (widthUnits, heightUnits) = dimensions
        let divisor = max(widthUnits, heightUnits)
        return (max(256, edge * widthUnits / divisor / 16 * 16),
                max(256, edge * heightUnits / divisor / 16 * 16))
    }

    func crop(_ source: CGImage) -> CGImage {
        let (width, height) = dimensions
        let targetRatio = CGFloat(width) / CGFloat(height)
        let sourceRatio = CGFloat(source.width) / CGFloat(source.height)
        let cropWidth = sourceRatio > targetRatio ? Int(CGFloat(source.height) * targetRatio) : source.width
        let cropHeight = sourceRatio > targetRatio ? source.height : Int(CGFloat(source.width) / targetRatio)
        let rect = CGRect(x: CGFloat(source.width - cropWidth) / 2,
                          y: CGFloat(source.height - cropHeight) / 2,
                          width: CGFloat(cropWidth), height: CGFloat(cropHeight))
        return source.cropping(to: rect) ?? source
    }
}

enum StudioScheduler: String, CaseIterable, Identifiable, Sendable {
    case dpm, pndm
    var id: String { rawValue }
    var label: String { self == .dpm ? "DPM++" : "PNDM" }
}

enum StudioGenerationEngine: String, Sendable {
    case coreML, anima
}

struct StudioLoRA: Sendable {
    let file: URL
    let strength: Float
}

struct StudioRenderOutput: Sendable {
    let url: URL
    let enhanced: Bool
    let enhancementWarning: String?
}

/// Mobile-size, fixed-download Anima Q4 bundle. Anima is a Qwen-Image-family
/// diffusion model, not a compatible Core ML Stable Diffusion checkpoint.
enum StudioAnimaBundle {
    struct Component: Sendable {
        let file: String
        let url: URL
        let bytes: Int64
    }
    static let components: [Component] = [
        .init(file: "anima-preview-Q4_K_M.gguf",
              url: URL(string: "https://huggingface.co/Bedovyy/Anima-GGUF/resolve/main/anima-preview-Q4_K_M.gguf")!,
              bytes: 1_421_648_000),
        .init(file: "Qwen3-0.6B-Base.Q4_K_M.gguf",
              url: URL(string: "https://huggingface.co/mradermacher/Qwen3-0.6B-Base-GGUF/resolve/main/Qwen3-0.6B-Base.Q4_K_M.gguf")!,
              bytes: 396_704_960),
        .init(file: "qwen_image_vae.safetensors",
              url: URL(string: "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors")!,
              bytes: 253_806_246)
    ]
    static let totalBytes = components.reduce(Int64(0)) { $0 + $1.bytes }
}

/// A foreground URLSession transfer. `suspend` and `resume` keep its existing
/// bytes and HTTP connection; Stop cancels it. Progress is derived from the
/// real URLSession download task, never an estimated timer.
final class StudioDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progressHandler: @Sendable (Int64, Int64) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var finishedURL: URL?
    private var finishedError: Error?
    private var lastReportedAt = Date.distantPast
    private var lastReportedBytes: Int64 = 0

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        progressHandler = onProgress
    }

    func fetch(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                lock.lock()
                self.session = session
                self.task = task
                self.continuation = continuation
                lock.unlock()
                if Task.isCancelled { task.cancel() }
                else { task.resume() }
            }
        } onCancel: { self.stop() }
    }

    func pause() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.suspend()
    }

    func resume() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.resume()
    }

    func stop() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // SwiftUI must not re-render a full studio screen for every tiny
        // network chunk of a multi-gigabyte checkpoint.
        let now = Date()
        lock.lock()
        let shouldReport = now.timeIntervalSince(lastReportedAt) >= 0.16
            || totalBytesWritten - lastReportedBytes >= 8_000_000
            || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite)
        if shouldReport { lastReportedAt = now; lastReportedBytes = totalBytesWritten }
        lock.unlock()
        guard shouldReport else { return }
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktick-studio-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); finishedURL = destination; lock.unlock()
        } catch {
            lock.lock(); finishedError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let completion = continuation
        let location = finishedURL
        let fileError = finishedError
        continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        if let completion {
            if let error { completion.resume(throwing: error) }
            else if let fileError { completion.resume(throwing: fileError) }
            else if let location, let response = task.response as? HTTPURLResponse {
                completion.resume(returning: (location, response))
            } else { completion.resume(throwing: StudioError.invalidResponse) }
        }
        session.finishTasksAndInvalidate()
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
        // A single favorite supplies the subject. Mixing the traits of many
        // different favorites is how we got e.g. "Chun-Li, blonde hair".
        // A single coherent setting also avoids "indoors, outdoors".
        let character = characters.first.map { $0.replacingOccurrences(of: "_", with: " ") }
        var phrases = ["masterpiece", "best quality", "detailed anime illustration"]
        if let character { phrases.append(character) }
        if let artist = artists.first { phrases.append("art by " + artist.replacingOccurrences(of: "_", with: " ")) }
        var seenKinds: Set<String> = []
        for raw in attributes {
            let term = raw.lowercased().replacingOccurrences(of: " ", with: "_")
            let kind: String
            if term.contains("hair") || term.contains("eye_color") { kind = "appearance" }
            else if term.contains("looking") || ["at_viewer", "away", "up", "down"].contains(term) { kind = "gaze" }
            else if term.contains("leaning") || ["standing", "sitting", "lying", "kneeling", "walking"].contains(term) { kind = "pose" }
            else if term.contains("smile") || term.contains("crying") || term.contains("frown") { kind = "expression" }
            else { kind = "other:" + term }
            // Do not override a named character's recognizable appearance.
            if character != nil && kind == "appearance" { continue }
            if !seenKinds.insert(kind).inserted { continue }
            phrases.append(spokenAttribute(term))
            if seenKinds.count >= 2 { break }
        }
        if let scene = scenes.first { phrases.append(scene.replacingOccurrences(of: "_", with: " ")) }
        phrases.append("coherent composition")
        return phrases.joined(separator: ", ")
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
        let files: [ModelFile]?
        struct ModelFile: Decodable, Sendable {
            let sizeKB: Double?
        }
        var displaySize: String? {
            guard let kb = files?.compactMap(\.sizeKB).first, kb > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(kb * 1024), countStyle: .file)
        }
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
    private let upscalers: URL
    private let anima: URL
    private let gallery: URL
    private var activeTransfer: StudioDownloadTransfer?
    private var renderInProgress = false
    private let starterURL = URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized/resolve/main/coreml-stable-diffusion-v1-5-palettized_split_einsum_v2_compiled.zip")!

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuicktickStudio", isDirectory: true)
        models = root.appendingPathComponent("Models", isDirectory: true)
        assets = root.appendingPathComponent("CivitaiAssets", isDirectory: true)
        upscalers = root.appendingPathComponent("Upscalers", isDirectory: true)
        anima = root.appendingPathComponent("Anima", isDirectory: true)
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

    func downloadStarter(onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        try await installZip(from: starterURL, name: "Apple SD 1.5 · 6-bit", onProgress: onProgress)
    }

    func hasAnimeUpscaler() -> Bool {
        FileManager.default.fileExists(atPath: animeUpscalerURL.path)
    }

    func hasAnimaBundle() -> Bool {
        hasAnimaFiles(StudioAnimaBundle.components)
    }

    func hasAnimaAuxiliaryFiles() -> Bool {
        hasAnimaFiles(Array(StudioAnimaBundle.components.dropFirst()))
    }

    private func hasAnimaFiles(_ components: [StudioAnimaBundle.Component]) -> Bool {
        components.allSatisfy { component in
            let path = anima.appendingPathComponent(component.file)
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
            return size == component.bytes
        }
    }

    func downloadAnimaBundle(useExistingCheckpoint: Bool = false,
                             onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        try FileManager.default.createDirectory(at: anima, withIntermediateDirectories: true)
        let components = useExistingCheckpoint ? Array(StudioAnimaBundle.components.dropFirst()) : StudioAnimaBundle.components
        let totalBytes = components.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for component in components {
            try Task.checkCancellation()
            let destination = anima.appendingPathComponent(component.file)
            let priorSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            if priorSize == component.bytes {
                completed += component.bytes
                onProgress(completed, totalBytes)
                continue
            }
            let preceding = completed
            let (download, response) = try await fetchDownload(URLRequest(url: component.url), onProgress: { received, _ in
                onProgress(preceding + received, totalBytes)
            })
            defer { try? FileManager.default.removeItem(at: download) }
            try Task.checkCancellation()
            let actual = (try FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard response.statusCode == 200, actual == component.bytes else { throw StudioError.invalidResponse }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: download)
            } else {
                try FileManager.default.moveItem(at: download, to: destination)
            }
            completed += component.bytes
            onProgress(completed, totalBytes)
        }
    }

    func generateAnima(prompt: String, negative: String, steps: Int, guidance: Float, seed: UInt32,
                       aspect: StudioAspectRatio, longestEdge: Int = 512,
                       upscale: Bool, checkpoint: URL? = nil, loras: [StudioLoRA] = [],
                       onProgress: @escaping @Sendable (Int, Int) -> Void,
                       onPreview: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> StudioRenderOutput {
        guard !renderInProgress else { throw StudioError.renderBusy }
        renderInProgress = true
        defer { renderInProgress = false }
        guard hasAnimaAuxiliaryFiles() else { throw StudioError.unavailableModel }
        guard !upscale || hasAnimeUpscaler() else { throw StudioError.unavailableModel }
        // Mirage's public C bridge passes `prompt` through verbatim and never
        // populates sd_img_gen_params_t.loras. Passing <lora:...> would
        // silently create an image WITHOUT applying the requested LoRA.
        // Fail explicitly until the native bridge exposes real weight loading.
        guard loras.isEmpty else { throw StudioError.unsupportedLoRA }
        let diffusionURL: URL
        if let checkpoint {
            let resolved = checkpoint.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == assets.standardizedFileURL.resolvingSymlinksInPath(),
                  ["safetensors", "gguf"].contains(resolved.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: resolved.path) else { throw StudioError.invalidFile }
            diffusionURL = resolved
        } else {
            guard hasAnimaBundle() else { throw StudioError.unavailableModel }
            diffusionURL = anima.appendingPathComponent(StudioAnimaBundle.components[0].file)
        }
        // Check the remaining *process* memory before every render. A new
        // context is required while Mirage cannot reliably reuse one across
        // generations on all iPhones. Leave room for Metal activations and
        // the image decoder, not just the on-disk weight size.
        let diffusionBytes = (try? FileManager.default.attributesOfItem(atPath: diffusionURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let auxiliaryBytes = StudioAnimaBundle.components.dropFirst().reduce(Int64(0)) { $0 + $1.bytes }
        let memoryRequired = StudioAnimaMemoryBudget.requiredBeforeLoad(
            diffusionBytes: diffusionBytes, auxiliaryBytes: auxiliaryBytes, upscale: upscale)
        let available = Int64(os_proc_available_memory())
        try StudioAnimaMemoryBudget.check(available: available, required: memoryRequired)
        let parts = StudioAnimaBundle.components
        let (width, height) = aspect.nativePixelDimensions(longestEdge: longestEdge)
        let result = try await Self.renderWithFreshAnimaEngine(
            models: ModelFiles(diffusionModel: diffusionURL,
                               vae: anima.appendingPathComponent(parts[2].file),
                               textEncoder: anima.appendingPathComponent(parts[1].file)),
            request: GenerationRequest(
                prompt: String(prompt.prefix(1000)), negativePrompt: String(negative.prefix(1200)),
                width: width, height: height, steps: max(4, min(40, steps)),
                cfgScale: guidance, seed: Int64(seed)), onProgress: onProgress)
        try Task.checkCancellation()
        return try finishImage(result, upscale: upscale, onPreview: onPreview)
    }

    /// Scoping the Engine here guarantees its C++/Metal context is released
    /// before the caller starts upscaling or begins another render.
    private static func renderWithFreshAnimaEngine(
        models: ModelFiles, request: GenerationRequest,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> CGImage {
        let engine = try Engine(models: models)
        // The model load itself may consume all remaining jetsam allowance.
        // Bail out before the temporary diffusion graph pushes the app over.
        try StudioAnimaMemoryBudget.check(
            available: Int64(os_proc_available_memory()),
            required: StudioAnimaMemoryBudget.requiredAfterLoad)
        Mirage.setProgressCallback { step, total, _ in onProgress(step, total) }
        defer { Mirage.setProgressCallback(nil) }
        return try await engine.generate(request)
    }

    private var animeUpscalerURL: URL {
        upscalers.appendingPathComponent("RealESRGANAnime.mlmodelc", isDirectory: true)
    }

    func downloadAnimeUpscaler(onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        if hasAnimeUpscaler() { return }
        let (temp, response) = try await fetchDownload(URLRequest(url: StudioAnimeUpscaler.downloadURL), onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw StudioError.invalidResponse }
        _ = try StudioAnimeUpscaler.install(zip: temp, in: upscalers)
    }

    func pauseActiveDownload() { activeTransfer?.pause() }
    func resumeActiveDownload() { activeTransfer?.resume() }
    func stopActiveDownload() { activeTransfer?.stop() }

    private func fetchDownload(_ request: URLRequest,
                               onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        guard activeTransfer == nil else { throw StudioError.downloadBusy }
        let transfer = StudioDownloadTransfer(onProgress: onProgress)
        activeTransfer = transfer
        defer { activeTransfer = nil }
        return try await transfer.fetch(request)
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

    private func installZip(from url: URL, name: String,
                            onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let (temp, response) = try await fetchDownload(URLRequest(url: url), onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw StudioError.invalidResponse }
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

    func downloadCivitaiAsset(_ version: CivitaiStudioModel.Version, type: String, host: String, token: String?,
                              onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        guard ["Checkpoint", "LORA"].contains(type), version.id > 0,
              ["civitai.com", "civitai.red"].contains(host) else { throw StudioError.invalidFile }
        // Construct a trusted API endpoint rather than follow arbitrary model
        // metadata URLs. Never append the token to a query string.
        let url = URL(string: "https://\(host)/api/download/models/\(version.id)")!
        var request = URLRequest(url: url)
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (temp, response) = try await fetchDownload(request, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw StudioError.invalidResponse }
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 100_000 else { throw StudioError.invalidFile }
        let suggestedExtension = response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let extensionHint = suggestedExtension.isEmpty ? "safetensors" : suggestedExtension
        guard ["safetensors", "gguf", "ckpt", "pt"].contains(extensionHint) else { throw StudioError.invalidFile }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let result = assets.appendingPathComponent("\(type.lowercased())-\(version.id).\(extensionHint)")
        if FileManager.default.fileExists(atPath: result.path) { return result }
        try FileManager.default.moveItem(at: temp, to: result)
        return result
    }

    func importCivitaiAsset(_ pickedURL: URL, type: String) throws -> URL {
        guard ["checkpoint", "lora"].contains(type) else { throw StudioError.invalidFile }
        let ext = pickedURL.pathExtension.lowercased()
        guard (type == "lora" && ext == "safetensors") ||
              (type == "checkpoint" && ["safetensors", "gguf"].contains(ext)) else {
            throw StudioError.invalidFile
        }
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
        let size = (try FileManager.default.attributesOfItem(atPath: pickedURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 100_000 else { throw StudioError.invalidFile }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let result = assets.appendingPathComponent("\(type)-import-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: pickedURL, to: result)
        return result
    }

    func downloadedAssets() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["safetensors", "gguf", "ckpt", "pt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func deleteDownloadedAsset(_ url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == assets.standardizedFileURL.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: resolved.path) else { throw StudioError.invalidFile }
        try FileManager.default.removeItem(at: resolved)
    }

    func generate(prompt: String, negative: String, modelURL: URL, steps: Int, guidance: Float, seed: UInt32,
                  aspect: StudioAspectRatio = .square, scheduler: StudioScheduler = .dpm,
                  upscale: Bool = false, safetyCheck: Bool = true,
                  onProgress: @Sendable (Int, Int) -> Void = { _, _ in },
                  onPreview: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> StudioRenderOutput {
        guard !renderInProgress else { throw StudioError.renderBusy }
        renderInProgress = true
        defer { renderInProgress = false }
        guard let resources = Self.resources(in: modelURL), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.unavailableModel }
        try Task.checkCancellation()
        let cropped = try renderCoreML(prompt: prompt, negative: negative, resources: resources,
                                       steps: steps, guidance: guidance, seed: seed,
                                       aspect: aspect, scheduler: scheduler,
                                       safetyCheck: safetyCheck, onProgress: onProgress)
        return try finishImage(cropped, upscale: upscale, onPreview: onPreview)
    }

    private func renderCoreML(prompt: String, negative: String, resources: URL,
                              steps: Int, guidance: Float, seed: UInt32,
                              aspect: StudioAspectRatio, scheduler: StudioScheduler,
                              safetyCheck: Bool,
                              onProgress: @Sendable (Int, Int) -> Void) throws -> CGImage {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let pipeline = try StableDiffusionPipeline(resourcesAt: resources, controlNet: [],
            configuration: configuration, disableSafety: !safetyCheck, reduceMemory: true)
        try pipeline.loadResources()
        defer { pipeline.unloadResources() }
        var options = PipelineConfiguration(prompt: String(prompt.prefix(1200)))
        options.negativePrompt = String(negative.prefix(1200))
        options.stepCount = max(4, min(40, steps))
        options.guidanceScale = max(1, min(15, guidance))
        options.seed = seed
        options.schedulerType = scheduler == .dpm ? .dpmSolverMultistepScheduler : .pndmScheduler
        // Heavy computation occurs on this actor, outside the UI main actor.
        let images = try pipeline.generateImages(configuration: options) { progress in
            onProgress(progress.step + 1, progress.stepCount)
            return !withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
        try Task.checkCancellation()
        guard let output = images.compactMap({ $0 }).first else { throw StudioError.imageFiltered }
        return aspect.crop(output)
    }

    /// Publish the real diffusion result before the optional (potentially long)
    /// 4× pass. A failed enhancement must never discard a successful render.
    private func finishImage(_ original: CGImage, upscale: Bool,
                             onPreview: @Sendable (URL) -> Void) throws -> StudioRenderOutput {
        try Task.checkCancellation()
        let originalURL = try saveImage(original)
        onPreview(originalURL)
        guard upscale else { return StudioRenderOutput(url: originalURL, enhanced: false, enhancementWarning: nil) }
        do {
            guard hasAnimeUpscaler() else { throw StudioError.unavailableModel }
            try Task.checkCancellation()
            let enlarged = try StudioAnimeUpscaler.upscale(original, using: animeUpscalerURL)
            try Task.checkCancellation()
            let enhancedURL = try saveImage(enlarged)
            // Keep just the final image in the gallery if enhancement succeeded.
            try? FileManager.default.removeItem(at: originalURL)
            return StudioRenderOutput(url: enhancedURL, enhanced: true, enhancementWarning: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return StudioRenderOutput(url: originalURL, enhanced: false,
                                      enhancementWarning: error.localizedDescription)
        }
    }

    private func saveImage(_ result: CGImage) throws -> URL {
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
