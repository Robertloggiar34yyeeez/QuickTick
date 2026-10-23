import Foundation

/// Small, reviewed relationships; the larger credited-tag lookup stays optional.
/// Sources and ambiguity policy are recorded in TAXONOMY-v0.9.md.
enum TasteConcepts {
    // Versions the per-favorite metadata/appearance cache. New action facets
    // must be revisited after an in-place IPA upgrade.
    static let version = "concepts-2026-10-23-actions-v2"
    static let aliases: [String: String] = [
        "chunli": "chun_li", "chun_li_(street_fighter)": "chun_li",
        "chun_li_(street_fighter_series)": "chun_li", "streetfighter": "street_fighter",
        "street_fighter_(series)": "street_fighter", "brawlstars": "brawl_stars",
        "brawl_stars_(game)": "brawl_stars", "fortnite_battle_royale": "fortnite",
        "shelly_(brawl_stars)": "shelly_brawl_stars", "colette_(brawl_stars)": "colette_brawl_stars",
        "fishstick_(fortnite)": "fishstick_fortnite",
        "rouge_(sonic)": "rouge_the_bat", "rouge_the_bat_(sonic)": "rouge_the_bat",
        "rouge_the_bat_(sonic_the_hedgehog)": "rouge_the_bat",
        "sonic_the_hedgehog_(series)": "sonic_the_hedgehog"
    ]
    static let franchises: Set<String> = [
        "street_fighter", "brawl_stars", "fortnite", "sonic_the_hedgehog",
        "final_fantasy", "metroid", "tomb_raider"
    ]
    static let characterFranchises: [String: Set<String>] = [
        "chun_li": ["street_fighter"], "cammy_white": ["street_fighter"],
        "juri_han": ["street_fighter"],
        "tifa_lockhart": ["final_fantasy"], "aerith_gainsborough": ["final_fantasy"],
        "samus_aran": ["metroid"], "lara_croft": ["tomb_raider"],
        "shelly_brawl_stars": ["brawl_stars"], "colette_brawl_stars": ["brawl_stars"],
        "fishstick_fortnite": ["fortnite"], "rouge_the_bat": ["sonic_the_hedgehog"]
    ]
    static func canonical(_ raw: String) -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return aliases[value] ?? value
    }
    static func resolve(_ tags: [String], taxonomy: VisualTagTaxonomy? = nil) -> (characters: [String], franchises: [String], evidence: [String: ConceptEvidence]) {
        let normalized = Set(tags.prefix(128).map(canonical))
        var characters = Set<String>(), found = normalized.intersection(franchises)
        found.formUnion(normalized.filter { $0.hasPrefix("franchise:") }.map { canonical(String($0.dropFirst(10))) }.filter { !$0.isEmpty })
        var evidence = Dictionary(uniqueKeysWithValues: found.map { ("franchise:" + $0, ConceptEvidence(confidence: 1, origin: "explicit")) })
        for tag in normalized {
            var character: String?
            if characterFranchises[tag] != nil { character = tag }
            else if taxonomy?.kind(of: tag) == .character { character = canonical(tag) }
            else if found.contains("brawl_stars"), ["shelly", "colette"].contains(tag) { character = tag + "_brawl_stars" }
            else if found.contains("sonic_the_hedgehog"), tag == "rouge" { character = "rouge_the_bat" }
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

/// Provider tags and high-confidence WD visual labels share an action taxonomy.
/// These are relationships, not identities; missing labels stay unknown.
enum ActionSemantics {
    static let aliases: [String: String] = [
        "leaning_over": "pose:leaning_forward", "leaning_forward": "pose:leaning_forward",
        "bending_forward": "pose:leaning_forward", "bent_over": "pose:leaning_forward",
        "leaning_back": "pose:leaning_back", "leaning_backwards": "pose:leaning_back",
        "looking_at_viewer": "gaze:at_viewer", "looking_at_camera": "gaze:at_viewer",
        "eye_contact": "gaze:at_viewer", "looking_away": "gaze:away",
        "looking_to_the_side": "gaze:away", "looking_to_side": "gaze:away",
        "looking_down": "gaze:down", "looking_up": "gaze:up",
        "sitting": "pose:sitting", "seated": "pose:sitting",
        "standing": "pose:standing", "kneeling": "pose:kneeling",
        "lying": "pose:lying", "lying_down": "pose:lying",
        "running": "pose:running", "dancing": "pose:dancing",
        // Canonical booru action tags, matched as whole tags only. Never infer
        // these from an artist, character, uploader or unverified video title.
        "kissing": "act:kissing", "kiss": "act:kissing", "deep_kiss": "act:kissing",
        "hugging": "act:hugging", "hug": "act:hugging",
        "sex": "act:intercourse", "vaginal": "act:intercourse", "vaginal_sex": "act:intercourse",
        "anal": "act:anal", "anal_sex": "act:anal",
        "oral": "act:oral", "oral_sex": "act:oral", "fellatio": "act:oral", "cunnilingus": "act:oral",
        "masturbation": "act:masturbation", "female_masturbation": "act:masturbation",
        "male_masturbation": "act:masturbation",
        "handjob": "act:manual_stimulation", "fingering": "act:manual_stimulation",
        "footjob": "act:footjob", "paizuri": "act:paizuri",
        "spanking": "act:spanking", "bondage": "act:bondage", "shibari": "act:bondage",
        "groping": "act:groping", "breast_grab": "act:groping",
        "grabbing_breast": "act:groping",
        "penetration": "act:penetration", "double_penetration": "act:double_penetration",
        "riding": "position:riding", "cowgirl_position": "position:riding",
        "reverse_cowgirl_position": "position:reverse_riding",
        "missionary": "position:missionary", "missionary_position": "position:missionary",
        "doggystyle": "position:rear_entry", "doggy_style": "position:rear_entry",
        "standing_sex": "position:standing", "standing_position": "position:standing"
    ]

    static func facet(_ raw: String) -> String? { aliases[TasteConcepts.canonical(raw)] }
    static func facets(_ tags: [String]) -> Set<String> { Set(tags.compactMap(facet)) }
    static func axis(_ facet: String) -> String { String(facet.split(separator: ":").first ?? "") }
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
        let pairs = TasteConcepts.pairs(values).reduce(0.0) { total, pair in
            // Motion and style:3d repeat medium evidence. A known franchise
            // also repeats its character identity; neither should drown out an
            // independently preferred artist, outfit or presentation.
            var weight = 3.0
            if pair.0.contains("|motion:") { weight = 0.15 }
            if ["|style:2d", "|style:3d", "|style:animation", "|style:animated", "|style:3d_animation"].contains(where: pair.0.hasSuffix) { weight = 0.3 }
            if !features.subjects.isEmpty && pair.0.contains("franchise:") { weight *= 0.25 }
            return total + (relationships[pair.0]?.affinity ?? 0) * pair.1 * weight
        }
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
