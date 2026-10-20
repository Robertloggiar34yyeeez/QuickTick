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
    var embedding: [Float] = []
    var fingerprint: UInt64?
    var pixelsAnalyzed = false
    var version = "metadata-vision-v1"
    static func metadata(_ post: Post) -> Self? {
        guard let domain = VisualDomain.classify(post) else { return nil }
        var result = Self(domain: domain)
        let vocabulary: [String: Set<String>] = [
            "appearance": ["long_hair", "short_hair", "blonde_hair", "black_hair", "blue_eyes", "ponytail", "braid"],
            "clothing": ["dress", "uniform", "qipao", "jacket", "hat", "glasses", "boots"],
            "pose": ["sitting", "standing", "lying", "running", "dancing", "portrait"],
            "expression": ["smile", "smiling", "angry", "serious", "closed_eyes"],
            "setting": ["outdoors", "indoors", "beach", "bedroom", "forest", "city"],
            "color": ["red", "blue", "green", "black", "white", "pink", "monochrome"],
            "style": ["watercolor", "sketch", "pixel_art", "realistic", "soft_lighting", "backlighting", "close_up"]
        ]
        for raw in post.tags.prefix(128) {
            let tag = raw.lowercased().replacingOccurrences(of: " ", with: "_")
            for (axis, known) in vocabulary where known.contains(tag) { result.attributes[axis + ":" + tag] = 0.9 }
            // Identity is explicit provider metadata only, never inferred from a face.
            if tag.hasPrefix("character:") && domain == .anime { result.subjects.append(String(tag.dropFirst(10))) }
            if tag.hasPrefix("performer:") && domain == .realLife { result.subjects.append(String(tag.dropFirst(10))) }
            if domain == .anime, ["chun-li", "chun_li", "chun-li_(street_fighter)"].contains(tag) { result.subjects.append("chun_li") }
        }
        result.subjects = Array(Set(result.subjects)).sorted()
        return result
    }
}
struct VisualProfile: Codable, Sendable, Equatable {
    var attributes: [String: VisualEvidence] = [:]
    var subjects: [String: VisualEvidence] = [:]
    var interactions: [String: VisualEvidence] = [:]
    var negativePresentations: [String: Set<String>] = [:]
    var clusters: [[Float]] = []
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
        if positive > 0, !features.embedding.isEmpty, features.embedding.count <= 1024, features.embedding.allSatisfy(\.isFinite) {
            if let i = clusters.indices.max(by: { SemanticRecommender.cosine(clusters[$0], features.embedding) < SemanticRecommender.cosine(clusters[$1], features.embedding) }),
               SemanticRecommender.cosine(clusters[i], features.embedding) > 0.75 {
                clusters[i] = SemanticRecommender.blend(clusters[i], features.embedding, alpha: 0.15)
            } else if clusters.count < 8 { clusters.append(features.embedding) }
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
        interactions = bounded(interactions, count: 4096)
        negativePresentations = negativePresentations.filter { subjects[$0.key] != nil }
    }
    func score(_ features: VisualFeatures) -> Double {
        let attributesScore = features.attributes.reduce(0.0) { $0 + (attributes[$1.key]?.affinity ?? 0) * $1.value }
        let identity = features.subjects.reduce(0.0) { $0 + (subjects[$1]?.affinity ?? 0) }
        let context = features.subjects.reduce(0.0) { score, subject in
            score + features.attributes.keys.reduce(0.0) { $0 + (interactions[subject + "|" + $1]?.affinity ?? 0) }
        }
        let similarity = clusters.map { SemanticRecommender.cosine($0, features.embedding) }.max() ?? 0
        return max(-4, min(4, attributesScore + identity + context + similarity))
    }
}
