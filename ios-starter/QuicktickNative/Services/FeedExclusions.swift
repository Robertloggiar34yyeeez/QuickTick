import Foundation

/// Small, offline concept database shared by all provider filters. Booru
/// species labels are often shorthand for anthropomorphic art; keep those
/// separate from explicit furry labels so wildlife photos are not blocked.
enum FurryTagAliases {
    static let explicit: Set<String> = [
        "furry", "furries", "furry_art", "furry_character", "furry_fandom",
        "anthro", "anthropomorphic", "anthropomorphism", "anthropomorphic_animal",
        "anthropomorphic_character", "anthro_character", "anthro_furry",
        "feral", "feral_furry", "scalie", "scaly", "scalie_furry",
        "fursona", "fur_sona", "fursuit", "fursuiting", "fursuiter",
        "kemono_furry", "furry_anthro", "furry_ears", "furry_tail",
        "animal_humanoid", "humanoid_animal", "animal_person", "beast_person",
        "anthropomorphic_mammal", "anthropomorphic_reptile", "anthropomorphic_bird"
    ]
    static let artSpecies: Set<String> = [
        "carnivore", "carnivora", "carnivoran", "canid", "canidae", "canine",
        "felid", "felidae", "feline", "vulpine", "ursid", "ursidae", "ursine",
        "mustelid", "mustelidae", "lupine", "hyaenid", "hyenidae",
        "equid", "equidae", "equine", "bovid", "bovidae", "bovine",
        "caprine", "cervid", "cervidae", "rodent", "rodentia", "murine",
        "lagomorph", "lagomorpha", "leporid", "leporidae", "procyonid",
        "procyonidae", "avian", "reptilian", "draconic", "serpentine",
        "wolf", "fox", "jackal", "coyote", "dog", "cat", "lion",
        "tiger", "hyena", "bear", "raccoon", "otter", "ferret",
        "rabbit", "hare", "deer", "horse", "dragon", "lizard"
    ]
    private static let variants = ["furry_", "anthro_", "anthropomorphic_", "feral_", "scalie_"]

    static func matches(_ post: Post) -> Bool {
        let tags = Set((post.tags + [post.category].compactMap { $0 })
            .map(RecommendationTagRules.canonical))
        if tags.contains(where: { tag in explicit.contains(tag) || variants.contains(where: { tag.hasPrefix($0) }) }) { return true }
        // Species and biology words are insufficient evidence on their own
        // for photos or mixed-content providers.
        let illustrated = post.providerKey.map { [Provider.rule34, .kemono, .nhentai, .hhaven].contains($0) } ?? false
        let domain = VisualDomain.classify(post)
        return (illustrated || domain == .anime || domain == .threeD) && domain != .realLife
            && !tags.isDisjoint(with: artSpecies)
    }
}

/// Match exclusions locally without fuzzy-blocking unrelated provider content.
enum RecommendationTagRules {
    static func canonical(_ raw: String) -> String {
        let tag = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch tag {
        case "chun_li_(street_fighter)", "chun_li_(street_fighter_series)": return "chun_li"
        case "2d_art", "2d_artwork", "2d_(artwork)": return "2d"
        case "3d_art", "3d_artwork", "3d_(artwork)", "3dcg": return "3d"
        case "anthro", "anthropomorphic": return "furry"
        default:
            for prefix in ["anthro_", "anthropomorphic_"] where tag.hasPrefix(prefix) { return "furry_" + tag.dropFirst(prefix.count) }
            return TasteConcepts.canonical(tag)
        }
    }
    static func queryExclusions(_ values: [String]) -> [String] {
        var tokens = Set(values.map(canonical))
        if tokens.contains("furry") { tokens.formUnion(["anthro", "anthropomorphic"]) }
        return tokens.sorted()
    }
    static func rejects(_ post: Post, exclusions: [String]) -> Bool {
        guard !exclusions.isEmpty else { return false }
        let blocked = Set(exclusions.map(canonical))
        if blocked.contains("furry"), FurryTagAliases.matches(post) { return true }
        if post.providerKey == .redgifs, exclusions.contains(where: { raw in
            guard let id = NativeProviderAPI.redgifsNicheID(raw) else { return false }
            return post.category == id || post.tags.contains { canonical($0) == canonical(id) }
        }) { return true }
        // On keyword providers a banned topic may appear only in the title,
        // category or credited creator. Preserve whole-word boundaries, so
        // banning "bat" does not hide "battle".
        if post.providerKey != .rule34 {
            return !ActionSemantics.facets(post).isDisjoint(with: ActionSemantics.facets(exclusions))
                || exclusions.contains { NativeProviderAPI.containsKeyword($0, in: post) }
        }
        // Semantically equivalent provider tags must share explicit blocks:
        // e.g. blocking "leaning over" also excludes tagged "bent_over".
        if !ActionSemantics.facets(post.tags).isDisjoint(with: ActionSemantics.facets(exclusions)) {
            return true
        }
        return post.tags.contains { raw in
            let tag = canonical(raw)
            if blocked.contains(tag) { return true }
            if blocked.contains("furry"),
               tag.hasPrefix("furry_") || tag == "anthro" || tag.hasPrefix("anthro_")
                || tag == "anthropomorphic" || tag.hasPrefix("anthropomorphic_") { return true }
            if blocked.contains("anthro"), tag.hasPrefix("anthro_") { return true }
            return false
        }
    }
}

/// Value snapshot owned by AppStore: filtering never queues behind a model actor.
struct FeedExclusions: Sendable {
    private(set) var recent: [String] = []
    private var recentSet: Set<String> = []
    func hasViewed(_ id: String) -> Bool { recentSet.contains(id) }
    private(set) var fingerprints: [String: UInt64] = [:]
    mutating func restore(_ ids: [String]) {
        recent = Array(ids.suffix(2048)); recentSet = Set(recent)
    }
    mutating func viewed(_ post: Post) {
        let keys = Self.identifiers(post)
        recent.removeAll { keys.contains($0) }; recent.append(contentsOf: keys.sorted())
        recent = Array(recent.suffix(2048)); recentSet = Set(recent)
    }
    mutating func registerFingerprint(_ id: String, hash: UInt64) {
        fingerprints[id] = hash
        if fingerprints.count > 2048, let key = fingerprints.keys.first { fingerprints.removeValue(forKey: key) }
    }
    mutating func setFingerprints(_ values: [String: UInt64]) {
        for (id, hash) in values { registerFingerprint(id, hash: hash) }
    }
    private static let signingKeys: Set<String> = ["token", "expires", "signature", "sig", "auth", "auth_key", "auth_token", "access_token", "secure", "policy", "key-pair-id", "x-amz-algorithm", "x-amz-credential", "x-amz-date", "x-amz-expires", "x-amz-signature", "x-amz-security-token", "x-amz-signedheaders"]
    static func canonicalMediaURL(_ raw: String) -> String? {
        guard var url = URLComponents(string: raw), url.host != nil else { return nil }
            url.scheme = "https"; url.host = url.host?.lowercased(); url.fragment = nil
            if url.host?.hasPrefix("www.") == true { url.host = String(url.host!.dropFirst(4)) }
            if url.path.count > 1, url.path.hasSuffix("/") { url.path.removeLast() }
            url.queryItems = url.queryItems?.filter { !signingKeys.contains($0.name.lowercased()) }
                .sorted { $0.name < $1.name }
            if url.queryItems?.isEmpty == true { url.query = nil }
        return url.string
    }
    static func identifiers(_ post: Post) -> Set<String> {
        let provider = post.providerKey?.rawValue ?? post.provider.lowercased()
        let rawID = post.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = provider == "redgifs" ? rawID.lowercased() : (UInt64(rawID).map(String.init) ?? rawID)
        var result: Set<String> = [post.stableID]
        if !normalizedID.isEmpty { result.insert("id:\(provider):\(normalizedID)") }
        // Keep content query parameters. Remove only recognized transport signatures.
        for raw in [post.mediaUrl, post.pageUrl] where !raw.isEmpty {
            if let canonical = canonicalMediaURL(raw) { result.insert("url:" + canonical) }
            if let media = URL(string: raw), ["jpg", "jpeg", "png", "webp", "gif", "avif", "mp4", "webm", "mov"].contains(media.pathExtension.lowercased()) {
                let stem = media.deletingPathExtension().lastPathComponent.lowercased()
                let hash = stem.hasPrefix("sample_") ? String(stem.dropFirst(7)) : stem
                // Cryptographic asset filenames survive provider/CDN changes.
                // Ordinary filenames are never treated as cross-host identities.
                if [32, 64].contains(hash.count), hash.allSatisfy({ "0123456789abcdef".contains($0) }) {
                    result.insert("asset-hash:" + hash)
                }
            }
        }
        return result
    }
    static func nearDuplicate(_ a: UInt64, _ b: UInt64) -> Bool { (a ^ b).nonzeroBitCount <= 3 }
    func filter(_ candidates: [Post], favorites: [Post], existing: [Post] = [], recommended: Bool, favoriteIDs: Set<String>? = nil) -> [Post] {
        var used = Set(existing.flatMap { Self.identifiers($0) })
        let liked = favoriteIDs ?? Set(favorites.flatMap { Self.identifiers($0) })
        let excludedHashes = (recommended ? favorites.map(\.stableID) + recent : []) + existing.map(\.stableID)
        var hashes = excludedHashes.compactMap { fingerprints[$0] }
        return candidates.filter { post in
            let ids = Self.identifiers(post)
            guard used.isDisjoint(with: ids), !recommended || (liked.isDisjoint(with: ids) && recentSet.isDisjoint(with: ids)) else { return false }
            if let hash = fingerprints[post.stableID] {
                guard !hashes.contains(where: { Self.nearDuplicate(hash, $0) }) else { return false }
                hashes.append(hash)
            }
            used.formUnion(ids); return true
        }
    }
}
