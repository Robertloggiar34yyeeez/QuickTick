import Foundation

enum VisualDomain: String, Codable, Sendable {
    case anime, threeD, realLife, mixed, uncertain
    static func classify(_ post: Post) -> Self? {
        let tags = Set((post.tags + [post.category].compactMap { $0 }).map { $0.lowercased().replacingOccurrences(of: " ", with: "_") })
        let normalized = Set(tags.map(RecommendationTagRules.canonical))
        let flat = !normalized.isDisjoint(with: ["2d", "2d_art", "illustration", "drawing", "manga", "2d_animation", "medium:2d"])
        let rendered = !normalized.isDisjoint(with: ["3d", "3d_art", "3dcg", "3d_animation", "render", "3d_render", "cgi", "medium:3d"])
        let photographic = !normalized.isDisjoint(with: ["photo", "photograph", "photography", "live_action", "real_person", "medium:live_action"])
        if normalized.contains("mixed_media") || [flat, rendered, photographic].filter({ $0 }).count > 1 { return .mixed }
        if rendered { return .threeD }
        if photographic { return .realLife }
        if flat || !normalized.isDisjoint(with: ["anime", "hentai", "watercolor", "sketch", "pixel_art"]) { return .anime }
        return .uncertain
    }
}

struct VisualEvidence: Codable, Sendable, Equatable {
    var impressions = 0.0, positive = 0.0, negative = 0.0
    var affinity: Double {
        // A conservative posterior, damped by exposure and evidence strength.
        (positive - negative) / (4 + impressions + positive + negative)
    }
}
struct VisualFeatures: Codable, Sendable, Equatable {
    var domain: VisualDomain
    var attributes: [String: Double] = [:]
    var subjects: [String] = []
    var artists: [String]? = nil
    var franchises: [String]? = nil
    var conceptEvidence: [String: ConceptEvidence]? = nil
    var creators: [String]? = nil
    var embedding: [Float] = []
    var fingerprint: UInt64?
    var pixelsAnalyzed = false
    var version = "metadata-vision-v1"
    private static let vocabulary: [String: Set<String>] = [
            "appearance": ["long_hair", "short_hair", "blonde_hair", "black_hair", "blue_eyes", "ponytail", "braid"],
            "clothing": ["dress", "uniform", "qipao", "jacket", "hat", "glasses", "boots"],
            "pose": ["sitting", "standing", "lying", "running", "dancing", "portrait"],
            "expression": ["smile", "smiling", "angry", "serious", "closed_eyes"],
            "setting": ["outdoors", "indoors", "beach", "bedroom", "forest", "city"],
            "color": ["red", "blue", "green", "black", "white", "pink", "monochrome"],
            "style": ["watercolor", "sketch", "pixel_art", "realistic", "soft_lighting", "backlighting", "close_up",
                "2d", "3d", "2d_art", "3d_art", "3dcg", "3d_animation", "animation", "animated",
                "furry", "anthro", "anthropomorphic"]
        ]
    static func metadata(_ post: Post, taxonomy: VisualTagTaxonomy? = nil) -> Self? {
        guard let domain = VisualDomain.classify(post) else { return nil }
        var result = Self(domain: domain)
        let concepts = TasteConcepts.resolve(post.tags, taxonomy: taxonomy)
        // A video provider's loose keywords are not verified fictional
        // identities. Keep taxonomy-based identity labels provider-scoped;
        // otherwise unrelated real-world content can inherit a liked character
        // or artist. Explicit typed identities remain available as metadata.
        if post.providerKey == .rule34 || domain == .anime || domain == .threeD {
            result.subjects = concepts.characters
            result.franchises = concepts.franchises
            result.conceptEvidence = concepts.evidence
        }
        if let creator = post.creator?.trimmingCharacters(in: .whitespacesAndNewlines), !creator.isEmpty, creator.count <= 80 {
            result.creators = [(post.providerKey?.rawValue ?? post.provider.lowercased()) + ":" + creator.lowercased()]
        }
        result.attributes["motion:" + (post.isImmersiveMedia ? "moving" : "still")] = 1
        for raw in post.tags.prefix(128) {
            let tag = raw.lowercased().replacingOccurrences(of: " ", with: "_")
            for (axis, known) in vocabulary where known.contains(tag) { result.attributes[axis + ":" + tag] = 0.9 }
            // Generic tags from the bundled typed provider taxonomy are
            // interests, not identity/species evidence. Keep a small bounded
            // feature budget for the on-device context model.
            if (result.attributes.count < 36),
               taxonomy?.kind(of: tag) == .interest,
               !["solo", "2d", "3d", "video", "animated", "highres"].contains(tag) {
                result.attributes["interest:" + TasteConcepts.canonical(tag)] = 0.75
            }
            let canonical = RecommendationTagRules.canonical(tag)
            if canonical != tag, vocabulary["style"]?.contains(canonical) == true {
                result.attributes["style:" + canonical] = 0.9
            }
            if canonical.hasPrefix("furry_") || canonical.hasPrefix("anthro_") {
                result.attributes["style:" + (canonical.hasPrefix("furry_") ? "furry" : "anthro")] = 0.85
            }
            // Identity is explicit provider metadata only, never inferred from a face.
            if tag.hasPrefix("character:") && domain != .realLife { result.subjects.append(TasteConcepts.canonical(String(tag.dropFirst(10)))) }
            if tag.hasPrefix("performer:") && domain == .realLife { result.subjects.append(tag) }
            if tag.hasPrefix("artist:"), post.providerKey == .rule34 || domain == .anime || domain == .threeD {
                result.artists = (result.artists ?? []) + [String(tag.dropFirst(7))]
            }
            if post.providerKey == .rule34 && domain != .realLife && domain != .mixed {
                if taxonomy?.artists.contains(tag) == true { result.artists = (result.artists ?? []) + [tag] }
                if taxonomy?.characters.contains(tag) == true { result.subjects.append(tag == "chun-li" ? "chun_li" : tag) }
            }
            if domain == .realLife {
                // Costume/franchise references are not the photographed person's identity.
                result.subjects.removeAll { !$0.hasPrefix("performer:") && concepts.characters.contains($0) }
            }
        }
        result.subjects = Array(Set(result.subjects)).sorted()
        if let artists = result.artists { result.artists = Array(Set(artists)).sorted() }
        return result
    }
}

struct VisualTagTaxonomy: Decodable, Sendable {
    let version: String
    let artists: Set<String>
    let characters: Set<String>
    // Decodes old v1 bundles too. No network or user data required.
    let general: Set<String>?

    // Keep the three-argument initializer used by existing tests and callers.
    // The bundled v2 taxonomy can additionally supply typed general tags.
    init(version: String, artists: Set<String>, characters: Set<String>,
         general: Set<String>? = nil) {
        self.version = version
        self.artists = artists
        self.characters = characters
        self.general = general
    }

    enum Kind: Sendable, Equatable { case character, artist, interest, unknown }
    func kind(of raw: String) -> Kind {
        let canonical = TasteConcepts.canonical(raw)
        let variants = [canonical, raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        canonical.replacingOccurrences(of: "_", with: "-")]
        if variants.contains(where: characters.contains) { return .character }
        if variants.contains(where: artists.contains) { return .artist }
        if variants.contains(where: { general?.contains($0) == true }) { return .interest }
        return .unknown
    }
}

struct VisualProfile: Codable, Sendable, Equatable {
    var attributes: [String: VisualEvidence] = [:]
    var subjects: [String: VisualEvidence] = [:]
    var artists: [String: VisualEvidence] = [:]
    var franchises: [String: VisualEvidence] = [:]
    var interactions: [String: VisualEvidence] = [:]
    var negativePresentations: [String: Set<String>] = [:]
    var clusters: [[Float]] = []
    var negativeClusters: [[Float]] = []
    var negativeContextClusters: [String: [[Float]]] = [:]
    var exposureClusters: [[Float]] = []
    init() {}
    enum CodingKeys: String, CodingKey { case attributes, subjects, artists, franchises, interactions, negativePresentations, clusters, negativeClusters, negativeContextClusters, exposureClusters }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attributes = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .attributes) ?? [:]
        subjects = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .subjects) ?? [:]
        artists = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .artists) ?? [:]
        franchises = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .franchises) ?? [:]
        interactions = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .interactions) ?? [:]
        negativePresentations = try c.decodeIfPresent([String: Set<String>].self, forKey: .negativePresentations) ?? [:]
        clusters = try c.decodeIfPresent([[Float]].self, forKey: .clusters) ?? []
        negativeClusters = try c.decodeIfPresent([[Float]].self, forKey: .negativeClusters) ?? []
        negativeContextClusters = try c.decodeIfPresent([String: [[Float]]].self, forKey: .negativeContextClusters) ?? [:]
        exposureClusters = try c.decodeIfPresent([[Float]].self, forKey: .exposureClusters) ?? []
    }
    mutating func record(_ event: RecommendationEvent, features: VisualFeatures, identityEvidence: Bool = true) {
        let positive: Double, negative: Double, exposure: Double
        switch event {
        case .impression: positive = 0; negative = 0; exposure = 1
        case .like: positive = 1; negative = 0; exposure = 0
        case .less: positive = 0; negative = 0.5; exposure = 0
        case .unlike: positive = -1; negative = 0; exposure = 0
        default: return
        }
        func update(_ evidence: inout VisualEvidence, confidence: Double, penalize: Bool = true) {
            evidence.impressions += exposure * confidence
            evidence.positive = max(0, evidence.positive + positive * confidence)
            if penalize { evidence.negative += negative * confidence }
        }
        for (key, confidence) in features.attributes where confidence.isFinite && confidence >= 0.5 {
            update(&attributes[key, default: VisualEvidence()], confidence: min(1, confidence))
            for subject in features.subjects {
                update(&interactions[subject + "|" + key, default: VisualEvidence()], confidence: min(1, confidence))
            }
            for artist in features.artists ?? [] {
                update(&interactions["artist:" + artist + "|" + key, default: VisualEvidence()], confidence: min(1, confidence))
            }
            for franchise in features.franchises ?? [] {
                update(&interactions["franchise:" + franchise + "|" + key, default: VisualEvidence()], confidence: min(1, confidence))
            }
        }
        for subject in features.subjects {
            if negative > 0, !features.attributes.isEmpty {
                let signature = features.attributes.keys.sorted().joined(separator: ",")
                if (negativePresentations[subject]?.count ?? 0) < 8 { negativePresentations[subject, default: []].insert(signature) }
            }
            // A single disliked presentation cannot undo positive identity evidence.
            let variedNegatives = (negativePresentations[subject]?.count ?? 0) >= 4
            if identityEvidence { update(&subjects[subject, default: VisualEvidence()], confidence: 0.7, penalize: variedNegatives) }
        }
        for artist in features.artists ?? [] {
            let key = "artist:" + artist
            if negative > 0, !features.attributes.isEmpty, (negativePresentations[key]?.count ?? 0) < 8 {
                negativePresentations[key, default: []].insert(features.attributes.keys.sorted().joined(separator: ","))
            }
            if identityEvidence { update(&artists[artist, default: VisualEvidence()], confidence: 0.5,
                penalize: (negativePresentations[key]?.count ?? 0) >= 4) }
        }
        for franchise in features.franchises ?? [] {
            let key = "franchise:" + franchise
            if negative > 0, !features.attributes.isEmpty, (negativePresentations[key]?.count ?? 0) < 8 {
                negativePresentations[key, default: []].insert(features.attributes.keys.sorted().joined(separator: ","))
            }
            if identityEvidence { update(&franchises[franchise, default: VisualEvidence()], confidence: 0.5, penalize: (negativePresentations[key]?.count ?? 0) >= 4) }
        }
        if !features.embedding.isEmpty, features.embedding.count <= 2048, features.embedding.allSatisfy(\.isFinite) {
            func learn(_ values: inout [[Float]]) {
                if let i = values.indices.max(by: { SemanticRecommender.cosine(values[$0], features.embedding) < SemanticRecommender.cosine(values[$1], features.embedding) }),
                   SemanticRecommender.cosine(values[i], features.embedding) > 0.82 {
                    values[i] = SemanticRecommender.blend(values[i], features.embedding, alpha: 0.12)
                } else if values.count < 8 { values.append(features.embedding) }
            }
            if positive > 0 { learn(&clusters) }
            if exposure > 0 { learn(&exposureClusters) }
            if negative > 0 {
                let likedSubjects = features.subjects.filter { (subjects[$0]?.positive ?? 0) > 0 }.map { "subject:" + $0 }
                let likedArtists = (features.artists ?? []).filter { (artists[$0]?.positive ?? 0) > 0 }.map { "artist:" + $0 }
                let likedFranchises = (features.franchises ?? []).filter { (franchises[$0]?.positive ?? 0) > 0 }.map { "franchise:" + $0 }
                let keys = likedSubjects + likedArtists + likedFranchises
                if keys.isEmpty { learn(&negativeClusters) }
                else {
                    for key in keys.prefix(4) {
                        var values = negativeContextClusters[key] ?? []
                        learn(&values)
                        negativeContextClusters[key] = values
                    }
                    if negativeContextClusters.count > 64 {
                        let keep = Set(negativeContextClusters.keys.sorted().prefix(64))
                        negativeContextClusters = negativeContextClusters.filter { keep.contains($0.key) }
                    }
                }
            }
        }
        func bounded(_ values: [String: VisualEvidence], count: Int) -> [String: VisualEvidence] {
            guard values.count > count else { return values }
            let retained = values.sorted { a, b in
                let left = a.value.positive + a.value.negative, right = b.value.positive + b.value.negative
                return left == right ? a.key < b.key : left > right
            }.prefix(count)
            return Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        attributes = bounded(attributes, count: 512); subjects = bounded(subjects, count: 512)
        artists = bounded(artists, count: 512)
        franchises = bounded(franchises, count: 128)
        interactions = bounded(interactions, count: 4096)
        negativePresentations = negativePresentations.filter { subjects[$0.key] != nil || ($0.key.hasPrefix("artist:") && artists[String($0.key.dropFirst(7))] != nil) || ($0.key.hasPrefix("franchise:") && franchises[String($0.key.dropFirst(10))] != nil) }
    }
    func score(_ features: VisualFeatures) -> Double {
        let attributesScore = features.attributes.reduce(0.0) { $0 + (attributes[$1.key]?.affinity ?? 0) * $1.value }
        let identity = features.subjects.reduce(0.0) { $0 + (subjects[$1]?.affinity ?? 0) }
        let artistAffinity = (features.artists ?? []).reduce(0.0) { $0 + (artists[$1]?.affinity ?? 0) }
        let franchiseAffinity = (features.franchises ?? []).reduce(0.0) { $0 + (franchises[$1]?.affinity ?? 0) * 0.5 }
        let franchiseContext = (features.franchises ?? []).reduce(0.0) { score, franchise in
            score + features.attributes.keys.reduce(0.0) { $0 + (interactions["franchise:" + franchise + "|" + $1]?.affinity ?? 0) }
        }
        let context = features.subjects.reduce(0.0) { score, subject in
            score + features.attributes.keys.reduce(0.0) { $0 + (interactions[subject + "|" + $1]?.affinity ?? 0) }
        }
        let artistContext = (features.artists ?? []).reduce(0.0) { score, artist in
            score + features.attributes.keys.reduce(0.0) { $0 + (interactions["artist:" + artist + "|" + $1]?.affinity ?? 0) }
        }
        let similarity = clusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        let baseline = exposureClusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        let avoidance = negativeClusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        let keys = features.subjects.map { "subject:" + $0 } + (features.artists ?? []).map { "artist:" + $0 } + (features.franchises ?? []).map { "franchise:" + $0 }
        let contextual = keys.flatMap { negativeContextClusters[$0] ?? [] }
            .map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        // Similarity lowers rank but is never a hard blacklist.
        let visual = similarity * 3 + max(-0.5, similarity - baseline) * 2
            - max(0, avoidance - 0.78) * 14 - max(0, contextual - 0.84) * 17
        // Keep a bounded contribution without flattening different outfits or
        // presentations into the same saturated score for a liked subject.
        return 4 * tanh((attributesScore + identity + context + artistAffinity + artistContext + franchiseAffinity + franchiseContext + visual) / 4)
    }
}
