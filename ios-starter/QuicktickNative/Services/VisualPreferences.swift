import Foundation

enum VisualDomain: String, Codable, Sendable {
    case anime, realLife
    static func classify(_ post: Post) -> Self? {
        let tags = Set(post.tags.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") })
        switch post.providerKey {
        case .rule34:
            return tags.isDisjoint(with: ["photo", "photograph", "real_person", "mixed_media"]) ? .anime : nil
        case .pornhub, .eporner, .redgifs:
            return tags.isDisjoint(with: ["anime", "hentai", "animation", "animated", "3d", "mixed_media"]) ? .realLife : nil
        default: return nil // Preserve Hanime's existing engine without guessing a new profile.
        }
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
    var embedding: [Float] = []
    var fingerprint: UInt64?
    var pixelsAnalyzed = false
    var version = "metadata-vision-v1"
    static func metadata(_ post: Post, taxonomy: VisualTagTaxonomy? = nil) -> Self? {
        guard let domain = VisualDomain.classify(post) else { return nil }
        var result = Self(domain: domain)
        let vocabulary: [String: Set<String>] = [
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
        for raw in post.tags.prefix(128) {
            let tag = raw.lowercased().replacingOccurrences(of: " ", with: "_")
            for (axis, known) in vocabulary where known.contains(tag) { result.attributes[axis + ":" + tag] = 0.9 }
            let canonical = RecommendationTagRules.canonical(tag)
            if canonical != tag, vocabulary["style"]?.contains(canonical) == true {
                result.attributes["style:" + canonical] = 0.9
            }
            if canonical.hasPrefix("furry_") || canonical.hasPrefix("anthro_") {
                result.attributes["style:" + (canonical.hasPrefix("furry_") ? "furry" : "anthro")] = 0.85
            }
            // Identity is explicit provider metadata only, never inferred from a face.
            if tag.hasPrefix("character:") && domain == .anime { result.subjects.append(String(tag.dropFirst(10))) }
            if tag.hasPrefix("performer:") && domain == .realLife { result.subjects.append(String(tag.dropFirst(10))) }
            if tag.hasPrefix("artist:") { result.artists = (result.artists ?? []) + [String(tag.dropFirst(7))] }
            if domain == .anime, post.providerKey == .rule34 {
                if taxonomy?.artists.contains(tag) == true { result.artists = (result.artists ?? []) + [tag] }
                if taxonomy?.characters.contains(tag) == true { result.subjects.append(tag == "chun-li" ? "chun_li" : tag) }
            }
            if domain == .anime, ["chun-li", "chun_li", "chun-li_(street_fighter)"].contains(tag) { result.subjects.append("chun_li") }
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
}

struct VisualProfile: Codable, Sendable, Equatable {
    var attributes: [String: VisualEvidence] = [:]
    var subjects: [String: VisualEvidence] = [:]
    var artists: [String: VisualEvidence] = [:]
    var interactions: [String: VisualEvidence] = [:]
    var negativePresentations: [String: Set<String>] = [:]
    var clusters: [[Float]] = []
    var negativeClusters: [[Float]] = []
    var negativeContextClusters: [String: [[Float]]] = [:]
    var exposureClusters: [[Float]] = []
    init() {}
    enum CodingKeys: String, CodingKey { case attributes, subjects, artists, interactions, negativePresentations, clusters, negativeClusters, negativeContextClusters, exposureClusters }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attributes = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .attributes) ?? [:]
        subjects = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .subjects) ?? [:]
        artists = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .artists) ?? [:]
        interactions = try c.decodeIfPresent([String: VisualEvidence].self, forKey: .interactions) ?? [:]
        negativePresentations = try c.decodeIfPresent([String: Set<String>].self, forKey: .negativePresentations) ?? [:]
        clusters = try c.decodeIfPresent([[Float]].self, forKey: .clusters) ?? []
        negativeClusters = try c.decodeIfPresent([[Float]].self, forKey: .negativeClusters) ?? []
        negativeContextClusters = try c.decodeIfPresent([String: [[Float]]].self, forKey: .negativeContextClusters) ?? [:]
        exposureClusters = try c.decodeIfPresent([[Float]].self, forKey: .exposureClusters) ?? []
    }
    mutating func record(_ event: RecommendationEvent, features: VisualFeatures) {
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
        }
        for subject in features.subjects {
            if negative > 0, !features.attributes.isEmpty {
                let signature = features.attributes.keys.sorted().joined(separator: ",")
                if (negativePresentations[subject]?.count ?? 0) < 8 { negativePresentations[subject, default: []].insert(signature) }
            }
            // A single disliked presentation cannot undo positive identity evidence.
            let variedNegatives = (negativePresentations[subject]?.count ?? 0) >= 4
            update(&subjects[subject, default: VisualEvidence()], confidence: 0.7, penalize: variedNegatives)
        }
        for artist in features.artists ?? [] {
            let key = "artist:" + artist
            if negative > 0, !features.attributes.isEmpty, (negativePresentations[key]?.count ?? 0) < 8 {
                negativePresentations[key, default: []].insert(features.attributes.keys.sorted().joined(separator: ","))
            }
            update(&artists[artist, default: VisualEvidence()], confidence: 0.5,
                penalize: (negativePresentations[key]?.count ?? 0) >= 4)
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
                let keys = likedSubjects + likedArtists
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
        interactions = bounded(interactions, count: 4096)
        negativePresentations = negativePresentations.filter { subjects[$0.key] != nil || ($0.key.hasPrefix("artist:") && artists[String($0.key.dropFirst(7))] != nil) }
    }
    func score(_ features: VisualFeatures) -> Double {
        let attributesScore = features.attributes.reduce(0.0) { $0 + (attributes[$1.key]?.affinity ?? 0) * $1.value }
        let identity = features.subjects.reduce(0.0) { $0 + (subjects[$1]?.affinity ?? 0) }
        let artistAffinity = (features.artists ?? []).reduce(0.0) { $0 + (artists[$1]?.affinity ?? 0) }
        let context = features.subjects.reduce(0.0) { score, subject in
            score + features.attributes.keys.reduce(0.0) { $0 + (interactions[subject + "|" + $1]?.affinity ?? 0) }
        }
        let artistContext = (features.artists ?? []).reduce(0.0) { score, artist in
            score + features.attributes.keys.reduce(0.0) { $0 + (interactions["artist:" + artist + "|" + $1]?.affinity ?? 0) }
        }
        let similarity = clusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        let baseline = exposureClusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        let avoidance = negativeClusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        let keys = features.subjects.map { "subject:" + $0 } + (features.artists ?? []).map { "artist:" + $0 }
        let contextual = keys.flatMap { negativeContextClusters[$0] ?? [] }
            .map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        // Similarity lowers rank but is never a hard blacklist.
        let visual = similarity * 3 + max(-0.5, similarity - baseline) * 2
            - max(0, avoidance - 0.78) * 14 - max(0, contextual - 0.84) * 17
        // Keep a bounded contribution without flattening different outfits or
        // presentations into the same saturated score for a liked subject.
        return 4 * tanh((attributesScore + identity + context + artistAffinity + artistContext + visual) / 4)
    }
}
