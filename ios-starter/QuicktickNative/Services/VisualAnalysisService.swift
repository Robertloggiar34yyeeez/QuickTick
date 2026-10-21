import Foundation
import Vision
import CoreGraphics
import CryptoKit

struct FeedbackEnvelope: Codable, Sendable {
    var id: String = UUID().uuidString
    var post: Post
    var event: RecommendationEvent
    var query: String? = nil
}
struct PendingVisualWork: Codable, Sendable {
    var post: Post
    var priority: Int
    var retryAfter = Date.distantPast
    var attempts = 0
    var created = Date()
}

/// One bounded worker; metadata feedback is independent of model execution.
actor VisualAnalysisService {
    struct State: Codable, Sendable {
        var version = 1
        var profiles: [String: VisualProfile] = [:]
        var features: [String: VisualFeatures] = [:]
        var liked: Set<String> = []
        // Maps liked stable IDs to their source/visual-domain profile for reversible learning.
        var likedProfileKeys: [String: String]? = nil
        // Sparse per-like feature snapshots survive the bounded preview cache.
        var likedEvidence: [String: VisualFeatures]? = nil
        var seen: Set<String> = []
        var disliked: Set<String> = []
        var analysisVersions: [String: String]? = nil
        var pending: [PendingVisualWork]? = nil
        var outbox: [FeedbackEnvelope]? = nil
        var schema: Int? = 2
        var archivedProfiles: [String: VisualProfile]? = nil
    }
    private var state = State()
    private var restored = false
    private var writeBlocked = false
    private var diskTask: Task<Void, Never>?
    private var lastPreviewAttempt = Date.distantPast
    private let animeTagger = WDAnimeTagger()
    private var taxonomy: VisualTagTaxonomy?
    private var taxonomyAttempted = false
    private var analyzing = false
    private var lightVersions: [String: String] = [:]
    private(set) var inferenceRuns = 0
    private(set) var cacheHits = 0
    func metadataTaxonomy() -> VisualTagTaxonomy? { loadTaxonomy(); return taxonomy }
    private func profileKey(_ post: Post) -> String { TasteConcepts.profileKey(post) }
    private func likeEvidence(_ features: VisualFeatures) -> VisualFeatures {
        // Record non-pixel vectors separately; they are not needed for undo and
        // keeping every large embedding would overgrow the saved visual state.
        var saved = features
        saved.embedding = []
        saved.fingerprint = nil
        return saved
    }
    private func loadTaxonomy() {
        guard !taxonomyAttempted else { return }; taxonomyAttempted = true
        guard let url = Bundle.main.url(forResource: "visual-tag-taxonomy", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024 else { return }
        taxonomy = try? JSONDecoder().decode(VisualTagTaxonomy.self, from: data)
    }
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
            if state.schema == nil {
                // Old provider-derived anime/real weights cannot safely seed a
                // content-derived medium. Preserve them and rebuild from favorites.
                state.archivedProfiles = state.profiles; state.profiles = [:]
                state.liked = []; state.seen = []; state.disliked = []
                state.analysisVersions = [:]; state.schema = 2
            }
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
    func record(_ event: RecommendationEvent, post: Post, queueAnalysis: Bool = true) {
        restore()
        guard !Task.isCancelled, let metadata = VisualFeatures.metadata(post, taxonomy: taxonomy) else { return }
        let cached = state.features[post.stableID]
        let features = (event == .unlike ? state.likedEvidence?[post.stableID] : nil)
            ?? (cached?.domain == metadata.domain ? cached! : metadata)
        switch event {
        case .like:
            guard state.liked.insert(post.stableID).inserted else {
                // Reconciled metadata can precede the asynchronous tap event.
                // Queue its pixel scan without adding the same like twice.
                if queueAnalysis { _ = enqueue(post, priority: 4) }
                return
            }
            if state.likedProfileKeys == nil { state.likedProfileKeys = [:] }
            state.likedProfileKeys?[post.stableID] = profileKey(post)
            if state.likedEvidence == nil { state.likedEvidence = [:] }
            state.likedEvidence?[post.stableID] = likeEvidence(features)
        case .unlike:
            guard state.liked.remove(post.stableID) != nil else { return }
            state.likedProfileKeys?.removeValue(forKey: post.stableID)
            state.likedEvidence?.removeValue(forKey: post.stableID)
        case .impression:
            guard state.seen.insert(post.stableID).inserted else { return }
            if state.seen.count > 4096 { state.seen = [post.stableID] }
        case .less: guard state.disliked.insert(post.stableID).inserted else { return }
        default:
            if queueAnalysis { _ = enqueue(post, priority: event == .download ? 3 : 1) }
            return
        }
        state.features[post.stableID] = features
        state.profiles[profileKey(post), default: VisualProfile()].record(event, features: features)
        if queueAnalysis, event != .unlike { _ = enqueue(post, priority: event == .less ? 5 : (event == .like ? 4 : 1)) }
        trimFeatures(); persist()
    }
    func stage(_ envelope: FeedbackEnvelope, queueAnalysis: Bool) {
        restore()
        if state.outbox?.contains(where: { $0.id == envelope.id }) == true { return }
        if state.outbox == nil { state.outbox = [] }
        // Prefer durable explicit feedback over high-frequency watch ticks.
        if state.outbox!.count >= 128 {
            if let index = state.outbox!.firstIndex(where: { ![.like, .less, .unlike].contains($0.event) }) { state.outbox!.remove(at: index) }
            else { state.outbox!.removeFirst() }
        }
        state.outbox!.append(envelope)
        record(envelope.event, post: envelope.post, queueAnalysis: queueAnalysis)
        flush()
    }
    // Synchronize exactly the current saved likes, including unlikes made while
    // offline or during a sync. Never replay a like already in the ledger.
    // Preserve learned dislikes and impressions in their respective profiles.
    func reconcileFavorites(_ favorites: [Post]) {
        restore()
        loadTaxonomy()
        let current = Set(favorites.map(\.stableID))
        var changed = false
        for id in state.liked.subtracting(current) {
            if let previous = state.likedEvidence?[id] ?? state.features[id] {
                // Old state versions did not store a profile key; recover it
                // from the stable provider ID and the cached visual domain.
                let prefix = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                let key = state.likedProfileKeys?[id] ?? prefix + "|" + previous.domain.rawValue
                state.profiles[key, default: VisualProfile()].record(.unlike, features: previous)
            }
            state.liked.remove(id)
            state.likedProfileKeys?.removeValue(forKey: id)
            state.likedEvidence?.removeValue(forKey: id)
            changed = true
        }
        for post in favorites {
            guard let metadata = VisualFeatures.metadata(post, taxonomy: taxonomy) else { continue }
            let cached = state.features[post.stableID]
            let features = cached?.domain == metadata.domain ? cached! : metadata
            let key = profileKey(post)
            if state.likedProfileKeys == nil { state.likedProfileKeys = [:] }
            if state.liked.insert(post.stableID).inserted {
                state.features[post.stableID] = features
                state.profiles[key, default: VisualProfile()].record(.like, features: features)
                if state.likedEvidence == nil { state.likedEvidence = [:] }
                state.likedEvidence?[post.stableID] = likeEvidence(features)
                changed = true
            } else if state.likedEvidence?[post.stableID] == nil {
                if state.likedEvidence == nil { state.likedEvidence = [:] }
                state.likedEvidence?[post.stableID] = likeEvidence(features)
                changed = true
            }
            if state.likedProfileKeys?[post.stableID] != key {
                state.likedProfileKeys?[post.stableID] = key
                changed = true
            }
        }
        if changed { trimFeatures(); persist() }
    }

    func pendingFeedback() -> [FeedbackEnvelope] { restore(); return state.outbox ?? [] }
    func acknowledge(_ id: String) { state.outbox?.removeAll { $0.id == id }; persist() }
    func pendingCount() -> Int { restore(); return state.pending?.count ?? 0 }
    @discardableResult func enqueue(_ post: Post, priority: Int) -> Bool {
        restore()
        if state.analysisVersions?[post.stableID] == revision(post) { return true }
        if state.pending == nil { state.pending = [] }
        if let index = state.pending!.firstIndex(where: { $0.post.stableID == post.stableID }) {
            state.pending![index].priority = max(priority, state.pending![index].priority)
            state.pending![index].post = post
            if priority >= 4 { state.pending![index].retryAfter = .distantPast }
        } else {
            if state.pending!.count >= 64 {
                guard priority > 1, let index = state.pending!.indices.min(by: { state.pending![$0].priority < state.pending![$1].priority }), state.pending![index].priority <= priority else { return false }
                state.pending!.remove(at: index)
            }
            state.pending!.append(PendingVisualWork(post: post, priority: priority))
        }
        persist(); return true
    }
    func waitForWorker() async {
        while analyzing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(25)) }
    }
    /// Lightweight cache-only attributes can run during browsing. Heavy models
    /// and bounded thumbnail requests require an uncontended resource window.
    func processNext(heavy: Bool) async -> Bool {
        restore()
        guard !analyzing, resourcesAllowAnalysis(), let work = state.pending?.filter({ $0.retryAfter <= .now })
            .sorted(by: { a, b in a.priority == b.priority ? (a.priority >= 4 ? a.created > b.created : a.created < b.created) : a.priority > b.priority }).first else { return false }
        let started = Date()
        defer { FeedPerformance.emit(heavy ? "visual_heavy_slice" : "visual_cached_slice", started: started, count: 1) }
        let before = state.features[work.post.stableID]
        await analyze(work.post, favorite: state.liked.contains(work.post.stableID), useVision: heavy,
            disliked: state.disliked.contains(work.post.stableID), lightweight: !heavy)
        guard !Task.isCancelled else { return false }
        let complete = state.analysisVersions?[work.post.stableID] == revision(work.post)
        if complete { state.pending?.removeAll { $0.post.stableID == work.post.stableID } }
        else if let index = state.pending?.firstIndex(where: { $0.post.stableID == work.post.stableID }) {
            state.pending![index].attempts += 1
            state.pending![index].retryAfter = .now.addingTimeInterval(heavy ? 30 : 3)
        }
        persist(); return before != state.features[work.post.stableID]
    }
    private func revision(_ post: Post) -> String {
        let sources = [post.mediaUrl, post.previewUrl, post.thumbUrl].map { FeedExclusions.canonicalMediaURL($0) ?? $0 }
        let content = (sources + [post.tags.sorted().joined(separator: " "), post.category ?? "", post.type, post.creator ?? ""]).joined(separator: "|")
        return TasteConcepts.version + "|appearance-wd-v3-fp16|" + (taxonomy?.version ?? "no-taxonomy") + "|" + SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Called for every favorite over successive idle slices. Ledger prevents repeated learning.
    func analyzeFavorite(_ post: Post, useVision: Bool) async {
        await analyze(post, favorite: true, useVision: useVision)
    }
    func analyzeCachedPost(_ post: Post, useVision: Bool) async {
        await analyze(post, favorite: false, useVision: useVision)
    }
    func analyzeDisliked(_ post: Post, useVision: Bool) async {
        await analyze(post, favorite: false, useVision: useVision, disliked: true)
    }
    func historicalQueue(_ posts: [Post]) -> [Post] {
        restore(); loadTaxonomy()
        return posts.filter { state.analysisVersions?[$0.stableID] != revision($0) }.sorted { $0.stableID < $1.stableID }
    }
    private func analyze(_ post: Post, favorite: Bool, useVision: Bool, disliked: Bool = false, lightweight: Bool = false) async {
        guard !analyzing, resourcesAllowAnalysis() else { return }
        analyzing = true; defer { analyzing = false }
        restore()
        loadTaxonomy() // Only reached by deferred analysis, never feed publication.
        guard let metadata = VisualFeatures.metadata(post, taxonomy: taxonomy) else { return }
        if let old = state.features[post.stableID], old.domain == metadata.domain {
            var updated = old
            updated.subjects = Array(Set(old.subjects + metadata.subjects)).sorted()
            updated.artists = Array(Set((old.artists ?? []) + (metadata.artists ?? []))).sorted()
            if updated != old {
                if state.liked.contains(post.stableID) {
                    state.profiles[profileKey(post), default: VisualProfile()].record(.unlike, features: old)
                    state.profiles[profileKey(post), default: VisualProfile()].record(.like, features: updated)
                }
                state.features[post.stableID] = updated
                if state.liked.contains(post.stableID) { state.likedEvidence?[post.stableID] = likeEvidence(updated) }
                persist()
            }
        }
        if favorite { record(.like, post: post) }
        let revision = revision(post)
        if state.analysisVersions?[post.stableID] == revision { cacheHits += 1; return }
        guard (useVision || lightweight), resourcesAllowAnalysis() else { return }
        if lightweight, lightVersions[post.stableID] == revision { return }
        let before = state.features[post.stableID]?.domain == metadata.domain ? state.features[post.stableID]! : metadata
        var preview = await MediaImagePipeline.shared.cachedAnalysisImage(raw: post.cardPreviewURL)
        if preview == nil, !lightweight, (favorite || disliked), resourcesAllowAnalysis(), VisualPreviewLoader.thumbnailURL(post) != nil {
            // Keep requests bounded while avoiding a three-second penalty per
            // favorite during an explicit idle/manual refresh.
            let delay = 0.9 - Date().timeIntervalSince(lastPreviewAttempt)
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            guard resourcesAllowAnalysis() else { return }
            lastPreviewAttempt = .now
            preview = await VisualPreviewLoader.shared.image(post)
        }
        guard let image = preview else { return }
        guard resourcesAllowAnalysis() else { return }
        var enriched = metadata
        let taggerCoolingDown = !lightweight && before.domain == .anime ? await animeTagger.cooldownDelay() > 0 : false
        enriched.pixelsAnalyzed = true
        enriched.version = "cached-appearance-v2"
        enriched.fingerprint = Self.fingerprint(image.image)
        enriched.attributes.merge(VisualAppearanceEncoder.attributes(image.image), uniquingKeysWith: max)
        if !before.embedding.isEmpty, lightVersions[post.stableID] == revision {
            enriched.embedding = before.embedding; enriched.attributes.merge(before.attributes, uniquingKeysWith: max)
            enriched.version = before.version
        } else if !lightweight, let encoded = try? await VisualAppearanceEncoder.embedding(image) {
            enriched.embedding = encoded.vector; enriched.version = encoded.version
        }
        guard resourcesAllowAnalysis() else { return }
        if !lightweight, !taggerCoolingDown, before.domain == .anime, let tagged = await animeTagger.analyze(image, domain: .anime) {
            enriched.attributes.merge(tagged.attributes, uniquingKeysWith: max)
            if enriched.subjects.isEmpty { enriched.subjects = tagged.subjects }
            for subject in tagged.subjects where enriched.conceptEvidence?["character:" + subject] == nil {
                if enriched.conceptEvidence == nil { enriched.conceptEvidence = [:] }
                enriched.conceptEvidence?["character:" + subject] = ConceptEvidence(confidence: 0.9, origin: "wd-v3-high-confidence")
            }
            enriched.version += "+wd-vit-v3-7f6b584-fp16"
            let mapped = TasteConcepts.resolve(tagged.subjects)
            enriched.franchises = Array(Set((enriched.franchises ?? []) + mapped.franchises)).sorted()
            for franchise in mapped.franchises {
                enriched.conceptEvidence?["franchise:" + franchise] = ConceptEvidence(confidence: 0.85, origin: "wd-v3+reviewed_mapping")
            }
        }
        guard resourcesAllowAnalysis() else { return }
        if !lightweight, before.domain == .realLife {
            // Vision labels describe presentation. Faces are never identity evidence.
            enriched.attributes.merge(await VisualAppearanceEncoder.sceneAttributes(image), uniquingKeysWith: max)
        }
        guard resourcesAllowAnalysis() else { return }
        // Reconcile a like rather than counting it again when cached pixels become available.
        var profile = state.profiles[profileKey(post)] ?? VisualProfile()
        if state.liked.contains(post.stableID) {
            profile.record(.unlike, features: before); profile.record(.like, features: enriched)
        } else {
            var added = enriched
            added.attributes = enriched.attributes.filter { before.attributes[$0.key] == nil }; added.subjects = []; added.artists = []
            if state.seen.contains(post.stableID) { profile.record(.impression, features: added) }
            if state.disliked.contains(post.stableID) {
                // Metadata was already penalized; only new attributes and the
                // feature print are learned now. Keep identities for context.
                added.subjects = before.subjects
                added.artists = before.artists
                profile.record(.less, features: added, identityEvidence: false)
            }
        }
        state.profiles[profileKey(post)] = profile
        state.features[post.stableID] = enriched
        if state.liked.contains(post.stableID) { state.likedEvidence?[post.stableID] = likeEvidence(enriched) }
        if state.analysisVersions == nil { state.analysisVersions = [:] }
        if !lightweight, !taggerCoolingDown { state.analysisVersions?[post.stableID] = revision; inferenceRuns += 1 }
        lightVersions[post.stableID] = revision
        if lightVersions.count > 512 { lightVersions.removeValue(forKey: lightVersions.keys.sorted()[0]) }
        trimFeatures()
        persist()
    }
    func scores(_ posts: [Post]) -> [String: Double] {
        restore()
        return Dictionary(posts.prefix(128).compactMap { post -> (String, Double)? in
            guard let metadata = VisualFeatures.metadata(post, taxonomy: taxonomy),
                  let p = state.profiles[profileKey(post)] else { return nil }
            let cached = state.features[post.stableID]
            let f = cached?.domain == metadata.domain ? cached! : metadata
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
        if let versions = state.analysisVersions, versions.count > 8192 {
            state.analysisVersions = Dictionary(uniqueKeysWithValues: versions.sorted { $0.key < $1.key }.suffix(8192).map { ($0.key, $0.value) })
        }
    }
    func discoveryTerms(provider: Provider) -> [String] {
        restore()
        let profiles = state.profiles.filter { $0.key.hasPrefix(provider.rawValue + "|") }.map(\.value)
        return Array(Set(profiles.flatMap { profile in
            profile.attributes.filter { $0.value.positive >= 1.4 && $0.value.affinity > 0.08 }
                .sorted { $0.value.affinity > $1.value.affinity }.prefix(6)
                .map { String($0.key.split(separator: ":").last ?? "") }
        })).sorted().prefix(8).map { $0 }
    }
    func discoveryQueries(provider: Provider) -> [[String]] {
        restore()
        guard provider == .rule34 else { return [] }
        return state.profiles.keys.sorted().filter { $0.hasPrefix(provider.rawValue + "|") }.flatMap { key -> [[String]] in
            guard let profile = state.profiles[key], let medium = key.split(separator: "|").last,
                  let tag = ["anime": "2d", "threeD": "3d", "realLife": "photo"][String(medium)] else { return [] }
            let identities = [profile.artists, profile.subjects, profile.franchises].flatMap { values in
                values.filter { $0.value.positive >= 1.4 && $0.value.affinity > 0.08 }
                    .sorted { $0.value.affinity > $1.value.affinity }.prefix(2).map(\.key)
            }
            return identities.prefix(4).map { [$0 == "chun_li" ? "chun-li" : $0, tag] }
        }.prefix(12).map { $0 }
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
