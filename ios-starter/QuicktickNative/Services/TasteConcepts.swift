import Foundation

/// Small, reviewed relationships; the larger credited-tag lookup stays optional.
/// Sources and ambiguity policy are recorded in TAXONOMY-v0.9.md.
enum TasteConcepts {
    static let version = "concepts-2026-10-20-v1"
    static let aliases: [String: String] = [
        "chunli": "chun_li", "chun_li_(street_fighter)": "chun_li",
        "chun_li_(street_fighter_series)": "chun_li", "streetfighter": "street_fighter",
        "street_fighter_(series)": "street_fighter", "brawlstars": "brawl_stars",
        "brawl_stars_(game)": "brawl_stars", "fortnite_battle_royale": "fortnite",
        "shelly_(brawl_stars)": "shelly_brawl_stars", "colette_(brawl_stars)": "colette_brawl_stars",
        "fishstick_(fortnite)": "fishstick_fortnite"
    ]
    static let franchises: Set<String> = ["street_fighter", "brawl_stars", "fortnite"]
    static let characterFranchises: [String: Set<String>] = [
        "chun_li": ["street_fighter"], "shelly_brawl_stars": ["brawl_stars"],
        "colette_brawl_stars": ["brawl_stars"], "fishstick_fortnite": ["fortnite"]
    ]
    static func canonical(_ raw: String) -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return aliases[value] ?? value
    }
    static func resolve(_ tags: [String]) -> (characters: [String], franchises: [String], evidence: [String: ConceptEvidence]) {
        let normalized = Set(tags.prefix(128).map(canonical))
        var characters = Set<String>(), found = normalized.intersection(franchises)
        found.formUnion(normalized.filter { $0.hasPrefix("franchise:") }.map { canonical(String($0.dropFirst(10))) }.filter { !$0.isEmpty })
        var evidence = Dictionary(uniqueKeysWithValues: found.map { ("franchise:" + $0, ConceptEvidence(confidence: 1, origin: "explicit")) })
        for tag in normalized {
            var character: String?
            if characterFranchises[tag] != nil { character = tag }
            else if found.contains("brawl_stars"), ["shelly", "colette"].contains(tag) { character = tag + "_brawl_stars" }
            else if tag.hasPrefix("character:") { character = canonical(String(tag.dropFirst(10))) }
            guard let character, !character.isEmpty else { continue }
            characters.insert(character)
            evidence["character:" + character] = ConceptEvidence(confidence: 0.98, origin: tag == character ? "explicit" : "alias_with_context")
            for franchise in characterFranchises[character] ?? [] {
                found.insert(franchise)
                if evidence["franchise:" + franchise] == nil { evidence["franchise:" + franchise] = ConceptEvidence(confidence: 0.95, origin: "reviewed_mapping") }
            }
        }
        // Crossovers retain both explicit and mapped franchises. Bare ambiguous
        // names such as Shelly, Colette or Raven never imply a franchise.
        return (characters.sorted(), found.sorted(), evidence)
    }
    static func profileKey(_ post: Post) -> String {
        (post.providerKey?.rawValue ?? post.provider.lowercased()) + "|" + (VisualDomain.classify(post)?.rawValue ?? "uncertain")
    }
    static func dimensions(_ features: VisualFeatures) -> [String: Double] {
        var result = features.attributes
        result["medium:" + features.domain.rawValue] = features.domain == .uncertain || features.domain == .mixed ? 0.5 : 1
        for subject in features.subjects { result[subject.hasPrefix("performer:") ? subject : "character:" + subject] = features.conceptEvidence?["character:" + subject]?.confidence ?? 0.9 }
        for artist in features.artists ?? [] { result["artist:" + artist] = 0.95 }
        for franchise in features.franchises ?? [] { result["franchise:" + franchise] = features.conceptEvidence?["franchise:" + franchise]?.confidence ?? 0.9 }
        for creator in features.creators ?? [] { result["uploader:" + creator] = 0.75 }
        return result
    }
    static func identity(_ key: String) -> Bool { ["character:", "artist:", "franchise:", "performer:", "uploader:"].contains(where: key.hasPrefix) }
    static func pairs(_ dimensions: [String: Double]) -> [(String, Double)] {
        let anchors = dimensions.keys.filter(identity).sorted().prefix(8)
        let presentation = dimensions.keys.filter { !identity($0) }.sorted().prefix(16)
        var result: [(String, Double)] = []
        for anchor in anchors {
            for item in presentation { result.append((anchor + "|" + item, min(dimensions[anchor] ?? 0, dimensions[item] ?? 0))) }
            for other in anchors where anchor < other { result.append((anchor + "|" + other, min(dimensions[anchor] ?? 0, dimensions[other] ?? 0))) }
        }
        return result
    }
}

struct ConceptEvidence: Codable, Sendable, Equatable {
    var confidence: Double
    var origin: String
}

struct ContextTasteProfile: Codable, Sendable, Equatable {
    var dimensions: [String: VisualEvidence] = [:]
    var relationships: [String: VisualEvidence] = [:]
    var negativePresentations: [String: Set<String>] = [:]
    mutating func record(_ event: RecommendationEvent, features: VisualFeatures) {
        let positive: Double, negative: Double, exposure: Double
        switch event {
        case .like: positive = 1; negative = 0; exposure = 0
        case .unlike: positive = -1; negative = 0; exposure = 0
        case .less: positive = 0; negative = 0.6; exposure = 0
        case .download: positive = 0.7; negative = 0; exposure = 0
        case .replay, .complete: positive = 0.2; negative = 0; exposure = 0
        case .watched(let seconds, let completion): positive = completion >= 0.8 ? min(0.25, max(0, seconds) / 120) : 0; negative = 0; exposure = 0
        case .quickSkip: positive = 0; negative = 0.05; exposure = 0
        case .impression: positive = 0; negative = 0; exposure = 1
        }
        let values = TasteConcepts.dimensions(features)
        let signature = values.keys.filter { !TasteConcepts.identity($0) }.sorted().joined(separator: ",")
        func update(_ value: inout VisualEvidence, confidence: Double, penalize: Bool) {
            value.positive = min(1000, max(0, value.positive + positive * confidence))
            value.negative = min(1000, value.negative + (penalize ? negative * confidence : 0))
            value.impressions = min(4000, value.impressions + exposure * confidence)
        }
        for (key, confidence) in values where confidence >= 0.5 && confidence.isFinite {
            if TasteConcepts.identity(key), negative > 0, !signature.isEmpty, (negativePresentations[key]?.count ?? 0) < 8 {
                negativePresentations[key, default: []].insert(signature)
            }
            let penalize = !TasteConcepts.identity(key) || (negativePresentations[key]?.count ?? 0) >= 4
            update(&dimensions[key, default: VisualEvidence()], confidence: confidence, penalize: penalize)
        }
        for (key, confidence) in TasteConcepts.pairs(values) {
            // Identity-to-identity edges also require varied negative evidence.
            let identitiesOnly = key.split(separator: "|").allSatisfy { TasteConcepts.identity(String($0)) }
            update(&relationships[key, default: VisualEvidence()], confidence: confidence, penalize: !identitiesOnly)
        }
        func bound(_ source: [String: VisualEvidence], _ limit: Int) -> [String: VisualEvidence] {
            guard source.count > limit else { return source }
            return Dictionary(uniqueKeysWithValues: source.sorted {
                let a = $0.value.positive + $0.value.negative, b = $1.value.positive + $1.value.negative
                return a == b ? $0.key < $1.key : a > b
            }.prefix(limit).map { ($0.key, $0.value) })
        }
        dimensions = bound(dimensions, 512); relationships = bound(relationships, 2048)
        negativePresentations = negativePresentations.filter { dimensions[$0.key] != nil }
    }
    func score(_ features: VisualFeatures) -> Double {
        let values = TasteConcepts.dimensions(features)
        let singles = values.reduce(0.0) { $0 + (dimensions[$1.key]?.affinity ?? 0) * $1.value * (TasteConcepts.identity($1.key) ? 0.5 : 0.15) }
        let pairs = TasteConcepts.pairs(values).reduce(0.0) { $0 + (relationships[$1.0]?.affinity ?? 0) * $1.1 * 3 }
        return 8 * tanh((singles + pairs) / 8)
    }
    func discoveryQueries() -> [[String]] {
        relationships.filter { $0.value.positive >= 1.5 && $0.value.affinity > 0.08 }.sorted {
            $0.value.affinity == $1.value.affinity ? $0.key < $1.key : $0.value.affinity > $1.value.affinity
        }.prefix(12).compactMap { entry in
            let parts = entry.key.components(separatedBy: "|")
            guard parts.count == 2 else { return nil }
            let terms = parts.map { part -> String in
                let value = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                if part.hasPrefix("medium:") { return ["anime": "2d", "threeD": "3d", "realLife": "photo"][value] ?? "" }
                if value == "chun_li" { return "chun-li" }
                if value.hasSuffix("_brawl_stars") { return value.replacingOccurrences(of: "_brawl_stars", with: "_(brawl_stars)") }
                return value
            }
            return terms.allSatisfy { !$0.isEmpty && !$0.contains(":") } ? terms : nil
        }
    }
}
