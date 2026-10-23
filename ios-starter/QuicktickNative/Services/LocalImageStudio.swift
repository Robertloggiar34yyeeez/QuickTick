import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
import StableDiffusion

enum StudioError: LocalizedError {
    case unsupportedModel, invalidArchive, invalidResponse, unavailableModel, noImage, invalidFile, downloadBusy
    var errorDescription: String? {
        switch self {
        case .unsupportedModel: "The archive does not contain a compiled Core ML Stable Diffusion pipeline. CivitAI .safetensors checkpoints and LoRAs need conversion before they can run here."
        case .invalidArchive: "The model archive is invalid or contains unsafe paths."
        case .invalidResponse: "The model service did not return a valid download."
        case .unavailableModel: "Download the on-device starter model or import a compatible Core ML model first."
        case .noImage: "The diffusion pipeline did not return an image."
        case .invalidFile: "This download is not a supported model or LoRA file."
        case .downloadBusy: "Another model download is already running. Pause, finish or stop it first."
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
    private let gallery: URL
    private var activeTransfer: StudioDownloadTransfer?
    private let starterURL = URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized/resolve/main/coreml-stable-diffusion-v1-5-palettized_split_einsum_v2_compiled.zip")!

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuicktickStudio", isDirectory: true)
        models = root.appendingPathComponent("Models", isDirectory: true)
        assets = root.appendingPathComponent("CivitaiAssets", isDirectory: true)
        upscalers = root.appendingPathComponent("Upscalers", isDirectory: true)
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
                  aspect: StudioAspectRatio = .square, scheduler: StudioScheduler = .dpm,
                  upscale: Bool = false,
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
        options.schedulerType = scheduler == .dpm ? .dpmSolverMultistepScheduler : .pndmScheduler
        // Heavy computation occurs on this actor, outside the UI main actor.
        let images = try pipeline.generateImages(configuration: options) { progress in
            onProgress(progress.step + 1, progress.stepCount)
            return !withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
        try Task.checkCancellation()
        guard let output = images.compactMap({ $0 }).first else { throw StudioError.noImage }
        let cropped = aspect.crop(output)
        let result: CGImage
        if upscale {
            guard hasAnimeUpscaler() else { throw StudioError.unavailableModel }
            result = try StudioAnimeUpscaler.upscale(cropped, using: animeUpscalerURL)
        } else {
            result = cropped
        }
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
