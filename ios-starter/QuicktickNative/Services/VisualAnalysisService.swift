import Foundation
import Vision
import CoreGraphics

/// Serial, idle-only analysis. No provider, resolver, video download or model download access.
actor VisualAnalysisService {
    struct State: Codable, Sendable {
        var version = 1
        var profiles: [String: VisualProfile] = [:]
        var features: [String: VisualFeatures] = [:]
        var liked: Set<String> = []
        var seen: Set<String> = []
        var disliked: Set<String> = []
        var analysisVersions: [String: String]? = nil
    }
    private var state = State()
    private var restored = false
    private var writeBlocked = false
    private var diskTask: Task<Void, Never>?
    private var lastPreviewAttempt = Date.distantPast
    private let animeTagger = WDAnimeTagger()
    func releaseModels() async { await animeTagger.release() }
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuicktickVisual-v1", isDirectory: true)
    }
    private func restore() {
        guard !restored else { return }; restored = true
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 32 * 1024 * 1024 else { writeBlocked = true; return }
            let saved = try JSONDecoder().decode(State.self, from: data)
            guard saved.version == 1 else { writeBlocked = true; return }
            state = saved
        } catch { writeBlocked = true } // Preserve unreadable private user data.
    }
    func snapshot() -> State { restore(); flush(); return state }
    func reset() { diskTask?.cancel(); state = State(); restored = true; writeBlocked = false; flush() }
    static func resourcesAllowAnalysis(lowPower: Bool, thermal: Int, playback: Bool, loading: Bool) -> Bool {
        !lowPower && thermal < ProcessInfo.ThermalState.serious.rawValue && !playback && !loading
    }
    private func resourcesAllowAnalysis() -> Bool {
        Self.resourcesAllowAnalysis(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ProcessInfo.processInfo.thermalState.rawValue, playback: false, loading: false) && !Task.isCancelled
    }
    func record(_ event: RecommendationEvent, post: Post) {
        restore()
        guard !Task.isCancelled, let features = state.features[post.stableID] ?? VisualFeatures.metadata(post),
              features.domain == VisualDomain.classify(post) else { return }
        switch event {
        case .like: guard state.liked.insert(post.stableID).inserted else { return }
        case .unlike: guard state.liked.remove(post.stableID) != nil else { return }
        case .impression:
            guard state.seen.insert(post.stableID).inserted else { return }
            if state.seen.count > 4096 { state.seen = [post.stableID] }
        case .less: guard state.disliked.insert(post.stableID).inserted else { return }
        default: return
        }
        state.features[post.stableID] = features
        state.profiles[features.domain.rawValue, default: VisualProfile()].record(event, features: features)
        trimFeatures(); persist()
    }
    /// Called for every favorite over successive idle slices. Ledger prevents repeated learning.
    func analyzeFavorite(_ post: Post, useVision: Bool) async {
        await analyze(post, favorite: true, useVision: useVision)
    }
    func analyzeCachedPost(_ post: Post, useVision: Bool) async {
        await analyze(post, favorite: false, useVision: useVision)
    }
    func historicalQueue(_ posts: [Post]) -> [Post] { posts.sorted { $0.stableID < $1.stableID } }
    private func analyze(_ post: Post, favorite: Bool, useVision: Bool) async {
        guard resourcesAllowAnalysis() else { return }
        restore()
        if favorite { record(.like, post: post) }
        guard useVision, resourcesAllowAnalysis(), state.analysisVersions?[post.stableID] != "appearance-wd-v3",
              let before = state.features[post.stableID] ?? VisualFeatures.metadata(post) else { return }
        var preview = await MediaImagePipeline.shared.cachedAnalysisImage(raw: post.cardPreviewURL)
        if preview == nil, favorite, resourcesAllowAnalysis() {
            let delay = 3 - Date().timeIntervalSince(lastPreviewAttempt)
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            guard resourcesAllowAnalysis() else { return }
            lastPreviewAttempt = .now
            preview = await VisualPreviewLoader.shared.image(post)
        }
        guard let image = preview else { return }
        guard resourcesAllowAnalysis() else { return }
        var enriched = before
        enriched.pixelsAnalyzed = true
        enriched.version = "cached-appearance-v2"
        enriched.fingerprint = Self.fingerprint(image.image)
        enriched.attributes.merge(VisualAppearanceEncoder.attributes(image.image), uniquingKeysWith: max)
        if let encoded = try? await VisualAppearanceEncoder.embedding(image) {
            enriched.embedding = encoded.vector; enriched.version = encoded.version
        }
        guard resourcesAllowAnalysis() else { return }
        if before.domain == .anime {
            let delay = await animeTagger.cooldownDelay()
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            guard resourcesAllowAnalysis() else { return }
        }
        if before.domain == .anime, let tagged = await animeTagger.analyze(image, domain: .anime) {
            enriched.attributes.merge(tagged.attributes, uniquingKeysWith: max)
            if enriched.subjects.isEmpty { enriched.subjects = tagged.subjects }
            enriched.version += "+wd-vit-v3-7f6b584-int8"
        }
        guard resourcesAllowAnalysis() else { return }
        if before.domain == .realLife {
            // Vision labels describe presentation. Faces are never identity evidence.
            let request = VNClassifyImageRequest()
            request.preferBackgroundProcessing = true
            request.usesCPUOnly = true
            let handler = VNImageRequestHandler(cgImage: image.image, options: [:])
            if (try? handler.perform([request])) != nil {
                let allowed: Set<String> = ["beach", "forest", "outdoor", "indoor", "portrait", "night", "sunset"]
                for label in (request.results ?? []).prefix(12) where label.confidence >= 0.8 && allowed.contains(label.identifier) {
                    enriched.attributes["setting:" + label.identifier] = Double(label.confidence) * 0.7
                }
            }
        }
        guard resourcesAllowAnalysis() else { return }
        // Reconcile a like rather than counting it again when cached pixels become available.
        var profile = state.profiles[before.domain.rawValue] ?? VisualProfile()
        if state.liked.contains(post.stableID) {
            profile.record(.unlike, features: before); profile.record(.like, features: enriched)
        } else {
            var added = enriched
            added.attributes = enriched.attributes.filter { before.attributes[$0.key] == nil }; added.subjects = []
            if state.seen.contains(post.stableID) { profile.record(.impression, features: added) }
            if state.disliked.contains(post.stableID) { profile.record(.less, features: added) }
        }
        state.profiles[before.domain.rawValue] = profile
        state.features[post.stableID] = enriched
        if state.analysisVersions == nil { state.analysisVersions = [:] }
        state.analysisVersions?[post.stableID] = "appearance-wd-v3"
        trimFeatures()
        persist()
    }
    func scores(_ posts: [Post]) -> [String: Double] {
        restore()
        return Dictionary(posts.compactMap { post -> (String, Double)? in
            guard let f = state.features[post.stableID] ?? VisualFeatures.metadata(post),
                  f.domain == VisualDomain.classify(post), let p = state.profiles[f.domain.rawValue] else { return nil }
            return (post.stableID, p.score(f))
        }, uniquingKeysWith: { first, _ in first })
    }
    func fingerprints() -> [String: UInt64] {
        restore(); return state.features.compactMapValues(\.fingerprint)
    }
    private func trimFeatures() {
        if state.features.count > 512 {
            let removable = state.features.keys.sorted()
            for key in removable.prefix(state.features.count - 512) { state.features.removeValue(forKey: key) }
        }
    }
    func discoveryTerms(provider: Provider) -> [String] {
        restore()
        let domain: VisualDomain = provider == .rule34 ? .anime : .realLife
        guard provider != .hanime, let profile = state.profiles[domain.rawValue] else { return [] }
        return profile.attributes.filter { entry in
            entry.value.positive >= 1.4 && entry.value.affinity > 0.08 &&
                ["appearance:", "clothing:", "setting:", "style:"].contains(where: entry.key.hasPrefix)
        }.sorted { $0.value.affinity > $1.value.affinity }.prefix(6).map { entry in
            let raw = String(entry.key.split(separator: ":").last ?? "")
            return provider == .rule34 ? raw : raw.replacingOccurrences(of: "_", with: " ")
        }.filter { !$0.contains("composition") && !$0.contains("lighting") && !$0.contains("contrast") }
    }
    private func persist() {
        diskTask?.cancel()
        diskTask = Task(priority: .background) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            await self?.flush()
        }
    }
    private func flush() {
        guard !writeBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        } catch { /* Existing engine remains the immediate fallback. */ }
    }
    /// 64-bit difference hash, conservative distance threshold; never used as identity.
    static func fingerprint(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 72)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8)); return true
        }
        guard rendered else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= UInt64(1) << (y * 8 + x) } }
        // Flat placeholders are not useful duplicate evidence.
        return hash == 0 || hash == UInt64.max ? nil : hash
    }
}
