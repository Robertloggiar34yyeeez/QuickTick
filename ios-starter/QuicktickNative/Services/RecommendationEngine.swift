import Foundation

/// Cheap calibration of cached on-device appearance affinity. The visual
/// model is evaluated in its background worker; this policy only combines
/// scores that are already available, never runs Core ML while scrolling.
struct RecommendationQualityModel: Sendable {
    static func combined(metadata: Double, visual: Double?) -> Double {
        guard let visual, visual.isFinite else { return metadata }
        // Stronger negative evidence than positive evidence. The visual
        // pipeline's bounded [-4,4] scale must not drown out explicit likes.
        let appearance = visual < 0 ? max(-12, visual * 2.7) : min(6, visual * 1.5)
        return metadata + appearance
    }
}

// Native metadata-only interaction model learned from the FULL current
// Favorites collection. A loved subject doesn't imply every presentation:
// source + subject + medium must match, with credited artist modeled
// separately. The model never loads pixels or Core ML during paging.
struct ConditionalTasteModel: Sendable {
    private var subjectsByMedium: [String: Set<String>] = [:]
    private var artistsByMedium: [String: Set<String>] = [:]
    private var approvedPairs: [String: Set<String>] = [:]

    private static func mediumKey(_ post: Post) -> String {
        post.provider.lowercased() + "|" + (VisualDomain.classify(post)?.rawValue ?? "uncertain")
    }

    mutating func train(_ favorites: [Post], taxonomy: VisualTagTaxonomy?) {
        subjectsByMedium.removeAll(keepingCapacity: true)
        artistsByMedium.removeAll(keepingCapacity: true)
        approvedPairs.removeAll(keepingCapacity: true)
        for post in favorites {
            let key = Self.mediumKey(post)
            guard !key.hasSuffix("|uncertain"), !key.hasSuffix("|mixed"),
                  let features = VisualFeatures.metadata(post, taxonomy: taxonomy) else { continue }
            let subjects = Set(features.subjects)
            let artists = Set(features.artists ?? [])
            subjectsByMedium[key, default: []].formUnion(subjects)
            artistsByMedium[key, default: []].formUnion(artists)
            for subject in subjects where !artists.isEmpty {
                approvedPairs[key + "|" + subject, default: []].formUnion(artists)
            }
        }
    }

    func score(_ post: Post, taxonomy: VisualTagTaxonomy?) -> Double {
        let key = Self.mediumKey(post)
        guard !key.hasSuffix("|uncertain"), !key.hasSuffix("|mixed"),
              let features = VisualFeatures.metadata(post, taxonomy: taxonomy) else { return 0 }
        let subjects = Set(features.subjects)
        let artists = Set(features.artists ?? [])
        let exactSubject = !subjects.isDisjoint(with: subjectsByMedium[key] ?? [])
        let exactArtist = !artists.isDisjoint(with: artistsByMedium[key] ?? [])
        let approvedPair = subjects.contains { subject in
            !artists.isDisjoint(with: approvedPairs[key + "|" + subject] ?? [])
        }
        // One matched character alone cannot outweigh an unapproved credited
        // artist. Confident pairs win; unknown creators get no artist boost.
        return (exactSubject ? 2.0 : 0) + (exactArtist ? 3.0 : 0) + (approvedPair ? 4.0 : 0)
    }
}


/// Session-scale intent weights: cheap, private, bounded online updates.
/// These are deliberately not persisted; long-term preference history is
/// separately stored in RecommendationState.
struct SessionPreferenceModel: Sendable {
    private var termsByProvider: [String: [String: Double]] = [:]
    private var lastWatchCredit: [String: Double] = [:]
    private static let generic: Set<String> = [
        "solo", "video", "image", "photo", "highres", "2d", "3d",
        "animated", "animation", "rating:safe", "rating:explicit"
    ]

    mutating func record(_ event: RecommendationEvent, post: Post, terms: [String]) {
        let reward: Double
        switch event {
        case .like: reward = 2.8
        case .download: reward = 3.2
        case .less: reward = -4.4
        case .unlike: reward = -2.2
        case .complete: reward = 1.2
        case .replay: reward = 1.4
        case .watched(let seconds, let completion):
            guard seconds.isFinite, seconds > 0, completion.isFinite else { return }
            let qualified = max(0, (min(1, max(0, completion)) - 0.55) / 0.45)
            let previous = lastWatchCredit[post.stableID] ?? 0
            guard qualified > previous else { return }
            lastWatchCredit[post.stableID] = qualified
            if lastWatchCredit.count > 160 { lastWatchCredit.removeAll() }
            reward = (qualified - previous) * 1.0
        case .impression, .quickSkip:
            // Exposure is not approval. Quick skips remain separately reversible.
            return
        }
        let topics = Array(Set(terms.map(RecommendationTagRules.canonical)
            .filter { !$0.isEmpty && !Self.generic.contains($0) })).sorted().prefix(12)
        guard reward != 0, !topics.isEmpty else { return }
        let provider = post.provider.lowercased()
        var weights = termsByProvider[provider] ?? [:]
        for key in Array(weights.keys) {
            let faded = (weights[key] ?? 0) * 0.94
            if abs(faded) < 0.05 { weights.removeValue(forKey: key) }
            else { weights[key] = faded }
        }
        let share = reward / sqrt(Double(topics.count))
        for topic in topics {
            weights[topic] = max(-5.5, min(5.5, (weights[topic] ?? 0) + share))
        }
        if weights.count > 80 {
            let best = weights.sorted {
                let a = abs($0.value), b = abs($1.value)
                return a == b ? $0.key < $1.key : a > b
            }.prefix(80)
            weights = Dictionary(uniqueKeysWithValues: best.map { ($0.key, $0.value) })
        }
        termsByProvider[provider] = weights
    }

    func score(provider: String, terms: [String]) -> Double {
        let weights = termsByProvider[provider] ?? [:]
        let sum = Set(terms.map(RecommendationTagRules.canonical))
            .reduce(0.0) { $0 + (weights[$1] ?? 0) }
        return max(-11, min(9, sum * 1.6))
    }

    func strongInterests(provider: String, limit: Int = 8) -> [(String, Double)] {
        (termsByProvider[provider] ?? [:]).filter { $0.value >= 1.5 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}

actor RecommendationEngine {
    private(set) var state = RecommendationState()
    let semantic: SemanticRecommender
    private let contextualRanking: Bool
    init(semantic: SemanticRecommender = SemanticRecommender(), contextualRanking: Bool = true) {
        self.semantic = semantic; self.contextualRanking = contextualRanking
    }
    struct DebugScore: Sendable {
        let semantic: SemanticScore
        let tags: Double
        let diversity: Double
        let seen: Double
        let interestThemes: [String]
        let final: Double
    }
    private(set) var debugScores: [String: DebugScore] = [:]
    private(set) var rankLatencyMs = 0.0
    private var drainedCandidateQueries: [String: Date] = [:]
    private var taxonomy: VisualTagTaxonomy?
    // Non-persisted, deduplicated affinity from every CURRENT saved favorite.
    // Rebuilding on changes avoids replaying old likes into the event ledger.
    private var savedFavoriteAffinity: [String: [String: Double]] = [:]
    private var conditionalTaste = ConditionalTasteModel()
    private var sessionTaste = SessionPreferenceModel()
    private var currentFavorites: [Post] = []
    // Unlike generic tag weights, these preserve *which* 3D artists were
    // liked. Unknown 3D creators never inherit a character's positive score.
    private var trusted3DCredits: [String: Set<String>] = [:]
    private var trusted3DArtistTags: [String: [String]] = [:]
    private var sourcesWithRougeLikes: Set<String> = []
    private var sourcesWithFictionalCharacters: Set<String> = []
    private var sourcesWithWildlifeLikes: Set<String> = []

    private static let wildlifeOnlyTerms: Set<String> = [
        "bat", "bats", "wildlife", "wild_animal", "animals", "animal",
        "fox", "foxes", "wolf", "wolves", "dog", "dogs", "cat", "cats",
        "pet", "pets", "zoo", "nature_documentary", "real_animal"
    ]

    private func credits(for post: Post) -> Set<String> {
        var result: Set<String> = []
        for raw in post.tags {
            let term = TasteConcepts.canonical(raw)
            if term.hasPrefix("artist:") {
                result.insert("artist:" + String(term.dropFirst("artist:".count)))
            } else if taxonomy?.artists.contains(term) == true {
                result.insert("artist:" + term)
            }
        }
        if let creator = post.creator?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !creator.isEmpty {
            result.insert("uploader:" + creator)
        }
        return result
    }

    private func fictionalWildlifeConfusion(_ post: Post, taste: TasteChoice) -> Bool {
        let source = post.provider.lowercased()
        guard sourcesWithFictionalCharacters.contains(source),
              !sourcesWithWildlifeLikes.contains(source),
              Set(taste.into.map(TasteConcepts.canonical)).isDisjoint(with: Self.wildlifeOnlyTerms) else { return false }
        let normalized = Set((post.tags + [post.category].compactMap { $0 }).map(TasteConcepts.canonical))
        guard !normalized.isDisjoint(with: Self.wildlifeOnlyTerms) else { return false }
        if !TasteConcepts.resolve(post.tags, taxonomy: taxonomy).characters.isEmpty { return false }
        if !normalized.isDisjoint(with: ["anthro", "anthropomorphic", "furry", "sonic_the_hedgehog"]) { return false }
        return true
    }

    private func explicitlyOther3DArtist(_ post: Post, taste: TasteChoice) -> Bool {
        let source = post.provider.lowercased()
        guard VisualDomain.classify(post) == .threeD,
              let trusted = trusted3DCredits[source] else { return false }
        let trustedArtists = trusted.filter { $0.hasPrefix("artist:") }
        guard !trustedArtists.isEmpty else { return false }
        let candidate = credits(for: post).filter { $0.hasPrefix("artist:") }
        guard !candidate.isEmpty, candidate.isDisjoint(with: trustedArtists) else { return false }
        let explicit = Set(taste.into.map(TasteConcepts.canonical))
        // Never override a user-selected exception.
        return candidate.allSatisfy {
            !explicit.contains($0) && !explicit.contains(String($0.dropFirst("artist:".count)))
        }
    }

    func preferenceGuardPenalty(_ post: Post) -> Double {
        let source = post.provider.lowercased()
        guard VisualDomain.classify(post) == .threeD,
              let trusted = trusted3DCredits[source], !trusted.isEmpty else { return 0 }
        let credited = credits(for: post)
        let trustedArtists = trusted.filter { $0.hasPrefix("artist:") }
        let candidateArtists = credited.filter { $0.hasPrefix("artist:") }
        if !trustedArtists.isEmpty && !candidateArtists.isEmpty {
            // A shared aggregator/uploader cannot override the credited artist.
            return candidateArtists.isDisjoint(with: trustedArtists) ? -50 : 20
        }
        if !credited.isDisjoint(with: trusted) { return 9 }
        // Unknown artist = uncertainty, not a global 3D dislike.
        return credited.isEmpty ? -18 : -34
    }

    func configureFavorites(_ favorites: [Post]) {
        currentFavorites = favorites
        conditionalTaste.train(favorites, taxonomy: taxonomy)
        trusted3DCredits = [:]
        trusted3DArtistTags = [:]
        sourcesWithRougeLikes = []
        sourcesWithFictionalCharacters = []
        sourcesWithWildlifeLikes = []
        for post in favorites {
            let source = post.provider.lowercased()
            let normalized = Set(post.tags.map(TasteConcepts.canonical))
            let characters = TasteConcepts.resolve(post.tags, taxonomy: taxonomy).characters
            if !characters.isEmpty { sourcesWithFictionalCharacters.insert(source) }
            if characters.contains("rouge_the_bat") { sourcesWithRougeLikes.insert(source) }
            if !normalized.isDisjoint(with: Self.wildlifeOnlyTerms),
               characters.isEmpty,
               (VisualDomain.classify(post) == .realLife || normalized.contains("wildlife")) {
                sourcesWithWildlifeLikes.insert(source)
            }
            guard VisualDomain.classify(post) == .threeD else { continue }
            let artistCredits = credits(for: post)
            trusted3DCredits[source, default: []].formUnion(artistCredits)
            trusted3DArtistTags[source, default: []].append(contentsOf: artistCredits.compactMap {
                $0.hasPrefix("artist:") ? String($0.dropFirst("artist:".count)) : nil
            })
        }
        trusted3DArtistTags = trusted3DArtistTags.mapValues { Array(Set($0)).sorted() }
        var counts: [String: [String: Int]] = [:]
        var totals: [String: Int] = [:]
        for post in favorites {
            let source = post.provider.lowercased()
            totals[source, default: 0] += 1
            for term in Set(terms(for: post)) {
                counts[source, default: [:]][term, default: 0] += 1
            }
        }
        savedFavoriteAffinity = [:]
        for source in counts.keys {
            let total = Double(max(1, totals[source] ?? 1))
            savedFavoriteAffinity[source] = counts[source]!.mapValues { count in
                // Strong repeat preferences, but dampen broad tags and large libraries.
                min(5.0, log1p(Double(count)) * 2.3) *
                    min(1.0, sqrt(Double(count) / total) * 2.0)
            }
        }
    }

    private func savedFavoriteTerms(source: String, limit: Int) -> [(String, Double)] {
        (savedFavoriteAffinity[source] ?? [:]).sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(limit).map { ($0.key, $0.value) }
    }
    func configureTaxonomy(_ value: VisualTagTaxonomy?) {
        // The idle worker can restart after foregrounding. Recompute large
        // favorites snapshots only when the credited-artist taxonomy changes.
        guard taxonomy?.version != value?.version else { return }
        taxonomy = value
        if !currentFavorites.isEmpty { configureFavorites(currentFavorites) }
    }
    // Both models are metadata-only, so ranking stays safe on the scrolling path.
    func unseenRecommendations(_ posts: [Post]) -> [Post] {
        let offered = Set(state.novelty.offered)
        let seen = Set(state.profiles.values.flatMap(\.recentSeen))
        return posts.filter {
            !seen.contains($0.stableID) && offered.isDisjoint(with: FeedExclusions.identifiers($0))
        }
    }
    func recordOffered(_ posts: [Post]) {
        // Cross-provider mirrors, signed CDN URLs and API aliases should not
        // reappear as "new" content under different stable post IDs.
        state.novelty.record(posts.flatMap { FeedExclusions.identifiers($0).sorted() })
    }
    func recordReversibleSkip(_ post: Post) {
        guard !state.reversibleSkips.contains(post.stableID) else { return }
        let source = post.provider.lowercased()
        let terms = Array(Set(terms(for: post).map(RecommendationTagRules.canonical)
            .filter { !Self.genericTasteTerms.contains($0) })).sorted().prefix(24)
        state.reversibleSkips.mark(.init(id: post.stableID, provider: source, terms: Array(terms)))
    }
    @discardableResult
    func neutralizeReversibleSkip(_ id: String) -> Bool {
        state.reversibleSkips.neutralize(id)
    }
    func hasReversibleSkip(_ id: String) -> Bool { state.reversibleSkips.contains(id) }

    private func repeatedlyRejectedTerms(source: String) -> [String] {
        let general = profile(for: source)
        return general.termEvidence.compactMap { term, evidence -> String? in
            let canonical = RecommendationTagRules.canonical(term)
            guard !Self.genericTasteTerms.contains(canonical),
                  evidence.negative >= 2.2,
                  evidence.negative > evidence.positive * 2.5 + 1.2 else { return nil }
            return canonical
        }.sorted()
    }

    func markCandidateDrained(context: String) {
        drainedCandidateQueries = drainedCandidateQueries.filter { $0.value > .now }
        if drainedCandidateQueries.count < 96 || drainedCandidateQueries[context] != nil {
            drainedCandidateQueries[context] = Date.now.addingTimeInterval(60)
        }
    }
    func releaseSemanticModel() async { await semantic.releaseModel() }
    func prepareSemantic(_ posts: [Post], taste: TasteChoice = TasteChoice()) async {
        guard !Task.isCancelled else { return }
        await semantic.preparePreferences(taste)
        await semantic.prepare(posts)
    }


    private static let genericTasteTerms: Set<String> = [
        "2d", "3d", "3d_animation", "animation", "animated", "video",
        "image", "photo", "solo", "highres", "rating:safe", "rating:explicit"
    ]
    private let maxTerms = 140
    private let maxSeen = 2048
    private let maxQueries = 14
    private let stopwords: Set<String> = [
        "the","and","for","with","this","that","from","your","you","are","was","were","has","have","had",
        "into","out","over","under","more","most","very","just","only","video","videos","watch","full","new",
        "best","hot","hd","www","com","xxx"
    ]

    func load(_ value: RecommendationState) {
        drainedCandidateQueries.removeAll()
        sessionTaste = SessionPreferenceModel()
        state = value
        if state.version < 3 { state.version = 3 }
        for key in state.profiles.keys { state.profiles[key] = normalized(state.profiles[key] ?? RecommendationProfile()) }
    }

    func snapshot() -> RecommendationState {
        pruneAll()
        return state
    }

    // Candidate acquisition must advance too: ranking page one cannot discover
    // new posts, regardless of the already-seen penalty.
    func candidatePage(context: String) -> Int { max(1, state.candidatePages[context] ?? 1) }
    struct CandidateRequest: Sendable {
        let context: String
        let query: ParsedQuery
        let page: Int
        let focused: Bool
    }
    // Acquisition, not only reranking, follows engagement. Three of four
    // requests rotate across strong interests; the fourth browses broadly.
    // Each query owns its cursor in the existing persisted recommendation state.
    func candidateRequest(context: String, provider: Provider, taste: TasteChoice, excluded: [String], forceBroad: Bool = false) -> CandidateRequest {
        let queryExclusions = RecommendationTagRules.queryExclusions(
            excluded + tasteTokens(source: provider.rawValue, values: taste.notInto)
            + repeatedlyRejectedTerms(source: provider.rawValue))
        let blocked = Set(queryExclusions.map { $0.lowercased() })
        let explicit = tasteTokens(source: provider.rawValue, values: taste.into).filter { !blocked.contains($0) }
        // Keep learned acquisition separate: adding many explicit tags must not
        // evict the established profile from candidate discovery.
        let learnedHistory = positiveTermEntries(source: provider.rawValue, taste: TasteChoice(), limit: 12)
            .filter {
                $0.1 >= 3 && !blocked.contains($0.0) && !explicit.contains($0.0)
                // "3d" alone should never become a provider discovery query
                // just because a few favorite artists work in that medium.
                && !Self.genericTasteTerms.contains(RecommendationTagRules.canonical($0.0))
                && !(sourcesWithFictionalCharacters.contains(provider.rawValue)
                    && !sourcesWithWildlifeLikes.contains(provider.rawValue)
                    && Self.wildlifeOnlyTerms.contains(RecommendationTagRules.canonical($0.0)))
            }
        let sessionInterests = sessionTaste.strongInterests(provider: provider.rawValue)
            .filter {
                !blocked.contains($0.0) && !explicit.contains($0.0)
                && !Self.genericTasteTerms.contains(RecommendationTagRules.canonical($0.0))
            }
        let saved = savedFavoriteTerms(source: provider.rawValue, limit: 14)
            .filter {
                !blocked.contains($0.0) && !explicit.contains($0.0)
                && !Self.genericTasteTerms.contains(RecommendationTagRules.canonical($0.0))
                && !(sourcesWithFictionalCharacters.contains(provider.rawValue)
                    && !sourcesWithWildlifeLikes.contains(provider.rawValue)
                    && Self.wildlifeOnlyTerms.contains(RecommendationTagRules.canonical($0.0)))
            }
        // Both explicit feedback history and the entire current favorites library
        // contribute to acquisition, without re-training existing events.
        // Accumulate weighted scores once, then sort the small dictionary.
        // Avoid a nested tuple/map/filter/sort expression: Swift's compiler
        // can time out type-checking that expression on device archives.
        var interestWeights: [String: Double] = [:]
        for (term, weight) in learnedHistory {
            interestWeights[term, default: 0] += weight
        }
        for (term, weight) in saved {
            interestWeights[term, default: 0] += weight * 2
        }
        for (term, weight) in sessionInterests {
            interestWeights[term, default: 0] += weight * 3
        }
        let sortedInterests: [String] = interestWeights.keys.sorted { left, right in
            let a: Double = interestWeights[left] ?? 0
            let b: Double = interestWeights[right] ?? 0
            if a == b { return left < right }
            return a > b
        }
        let learned: [String] = Array(sortedInterests.prefix(16))
        let roundKey = context + "|round"
        let round = max(0, (state.candidatePages[roundKey] ?? 1) - 1)
        advanceCandidatePage(context: roundKey, nextPage: (round + 1) % 12_000 + 1)
        // Three focused searches followed by one broad discovery page.
        // Persisting this four-step rotation ensures exploration still occurs.
        var focused = !forceBroad && (!explicit.isEmpty || !learned.isEmpty) && round % 4 != 3
        var terms: [String]
        if !focused { terms = [] }
        else if !explicit.isEmpty && (learned.isEmpty || round % 4 == 0) { terms = [explicit[(round / 4 + (learned.isEmpty ? round % 4 : 0)) % explicit.count]] }
        else { terms = [learned[round % learned.count]] }
        // A subset of focused discoveries explicitly includes a previously
        // liked 3D artist. Artist/medium context must survive candidate retrieval.
        if focused, provider == .rule34, round % 6 == 4,
           let artists = trusted3DArtistTags[provider.rawValue], !artists.isEmpty {
            terms = [artists[(round / 6) % artists.count], "3d"]
        }
        if focused, (explicit.isEmpty || round % 4 != 0) && round % 3 == 0 {
            let queries = state.contextualProfiles.filter { $0.key.hasPrefix(provider.rawValue + "|") }
                .sorted { $0.key < $1.key }.flatMap { $0.value.discoveryQueries() }
                .filter { !$0.contains(where: { blocked.contains(RecommendationTagRules.canonical($0)) }) }
            if !queries.isEmpty { terms = queries[round % queries.count] }
        }
        // Prefer co-liked character/artist + medium instead of isolated generic 3D.
        if focused, provider == .rule34, let anchor = terms.first {
            let styles: Set<String> = ["2d", "3d", "2d_art", "3d_art", "3dcg",
                "3d_animation", "animation", "animated", "watercolor", "sketch", "pixel_art"]
            let related = profile(for: provider.rawValue).related
            if let partner = (explicit + learned).first(where: { term in
                let complements = term != anchor && styles.contains(anchor) != styles.contains(term)
                let chosen = explicit.contains(anchor) && explicit.contains(term)
                let likedTogether = (related[anchor]?[term] ?? related[term]?[anchor] ?? 0) >= 0.6
                return complements && (chosen || likedTogether)
            }) { terms.append(partner) }
        }
        if focused, let deadline = drainedCandidateQueries[context + "|query:" + terms.joined(separator: " ")], deadline > .now {
            focused = false; terms = []
        }
        let key = context + "|query:" + terms.joined(separator: " ")
        return CandidateRequest(context: key, query: ParsedQuery(included: terms, excluded: queryExclusions), page: candidatePage(context: key), focused: focused)
    }
    func advanceCandidatePage(context: String, nextPage: Int) {
        if state.candidatePages.count >= 96, state.candidatePages[context] == nil {
            state.candidatePages.removeValue(forKey: state.candidatePages.keys.sorted().first!)
        }
        state.candidatePages[context] = max(1, nextPage)
    }
    func unseen(_ posts: [Post]) -> [Post] {
        posts.filter { !profile(for: $0.provider.lowercased()).recentSeen.contains($0.stableID) }
    }

    func reset(provider: Provider? = nil) async {
        drainedCandidateQueries.removeAll()
        sessionTaste = SessionPreferenceModel()
        await semantic.reset()
        if let provider {
            state.profiles[provider.rawValue] = RecommendationProfile()
            state.candidatePages = state.candidatePages.filter { !$0.key.hasPrefix(provider.rawValue + "|") }
        }
        else { state = RecommendationState() }
    }

    func terms(for post: Post) -> [String] {
        let source = post.provider.lowercased()
        let raw = (post.tags + [post.caption, post.category].compactMap { $0 }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if source == Provider.rule34.rawValue {
            let values = raw.flatMap { value in
                let tag = value.lowercased()
                let canonical = RecommendationTagRules.canonical(tag)
                return canonical == tag ? [tag] : [tag, canonical]
            }
            return Array(Set(values)).sorted().prefix(48).map { $0 }
        }
        var out: [String] = []
        for value in raw.prefix(24) {
            for token in value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(whereSeparator: { $0.isWhitespace }) {
                let clean = String(token).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
                guard clean.count >= 3, !stopwords.contains(clean), Int(clean) == nil, !out.contains(clean) else { continue }
                out.append(clean)
                if out.count >= 30 { return out }
            }
        }
        return out
    }

    func themeSignatures(for post: Post) -> [String] {
        let source = post.provider.lowercased()
        var result: [String] = []
        for raw in (post.tags + [post.caption, post.category].compactMap { $0 }).prefix(24) {
            let normalized = raw.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            let words = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                .map(String.init)
                .filter { isTermAllowed(source: source, term: $0) }
            if words.isEmpty { continue }
            if words.count <= 4 {
                let phrase = words.joined(separator: " ")
                if phrase.count >= 3 && phrase.count <= 48 && !result.contains(phrase) { result.append(phrase) }
            }
            if words.count > 1 {
                for index in 0..<(words.count - 1) {
                    let pair = "\(words[index]) \(words[index + 1])"
                    if !result.contains(pair) { result.append(pair) }
                    if result.count >= 28 { break }
                }
            }
            if result.count >= 28 { break }
        }
        return Array(result.prefix(28))
    }

    func recordSearch(provider: Provider, query: String, eventID: String? = nil) {
        if let eventID {
            guard !state.feedbackLedger.contains(eventID) else { return }
            state.feedbackLedger.append(eventID); state.feedbackLedger = Array(state.feedbackLedger.suffix(2048))
        }
        let parts = SearchFilters.split(query).tags.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return }
        let searchPost = Post(key: "search", id: "search", provider: provider.rawValue,
            tags: parts.filter { !$0.hasPrefix("-") && !$0.hasPrefix("sort:") && !$0.hasPrefix("score:") && !$0.hasPrefix("rating:") }, type: "image")
        if let features = VisualFeatures.metadata(searchPost, taxonomy: taxonomy) {
            state.contextualProfiles[TasteConcepts.profileKey(searchPost), default: ContextTasteProfile()].record(.download, features: features)
        }
        var profile = profile(for: provider.rawValue)
        let positives = tasteTokens(source: provider.rawValue, values: parts.filter { !$0.hasPrefix("-") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "~")) })
        let negatives = tasteTokens(source: provider.rawValue, values: parts.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) })
        if !positives.isEmpty {
            applyTermDelta(&profile, terms: positives, delta: 8)
            recordEvidence(&profile, terms: positives, positive: 0.7, negative: 0, search: 1)
        }
        if !negatives.isEmpty {
            applyTermDelta(&profile, terms: negatives, delta: -5)
            recordEvidence(&profile, terms: negatives, positive: 0, negative: 0.6, search: 0)
        }
        let normalizedQuery = parts.joined(separator: " ")
        if !normalizedQuery.isEmpty {
            profile.recentQueries.removeAll { $0 == normalizedQuery }
            profile.recentQueries.append(normalizedQuery)
            profile.recentQueries = Array(profile.recentQueries.suffix(maxQueries))
        }
        state.profiles[provider.rawValue] = normalized(profile)
        let searchKey = TasteConcepts.profileKey(searchPost)
        var scoped = state.scopedProfiles[searchKey] ?? RecommendationProfile()
        applyTermDelta(&scoped, terms: positives, delta: 8); applyTermDelta(&scoped, terms: negatives, delta: -5)
        recordEvidence(&scoped, terms: positives, positive: 0.7, negative: 0, search: 1)
        recordEvidence(&scoped, terms: negatives, positive: 0, negative: 0.6, search: 0)
        state.scopedProfiles[searchKey] = normalized(scoped)
    }

    func record(_ event: RecommendationEvent, post: Post, eventID: String? = nil) async {
        if let eventID {
            guard !state.feedbackLedger.contains(eventID) else { return }
            state.feedbackLedger.append(eventID); state.feedbackLedger = Array(state.feedbackLedger.suffix(2048))
        }
        if let features = VisualFeatures.metadata(post, taxonomy: taxonomy) {
            state.contextualProfiles[TasteConcepts.profileKey(post), default: ContextTasteProfile()].record(event, features: features)
        }
        var evidencePost = post
        if [.less, .unlike, .quickSkip].contains(event), let features = VisualFeatures.metadata(post, taxonomy: taxonomy) {
            // Ambiguous negative feedback describes this presentation first.
            evidencePost.tags.removeAll { tag in
                let normalized = tag.lowercased().replacingOccurrences(of: "-", with: "_")
                let canonical = TasteConcepts.canonical(normalized)
                return ["character:", "performer:", "artist:", "franchise:", "uploader:"].contains(where: normalized.hasPrefix)
                    || features.subjects.contains(canonical) || (features.artists ?? []).contains(canonical)
                    || (features.franchises ?? []).contains(canonical)
            }
            evidencePost.caption = nil; evidencePost.category = nil
            evidencePost.creator = nil
        }
        let source = post.provider.lowercased()
        let signalTerms = terms(for: evidencePost)
        sessionTaste.record(event, post: post, terms: signalTerms)
        var profile = profile(for: source)
        let negativeShare = 1 / sqrt(Double(max(1, min(signalTerms.count, 12))))
        var delta = 0.0
        var negativeThemeDelta = 0.0

        switch event {
        case .impression:
            profile.stats.impressions += 1
            profile.recentSeen.removeAll { $0 == post.stableID }
            profile.recentSeen.append(post.stableID)
            profile.recentSeen = Array(profile.recentSeen.suffix(maxSeen))
        case .like:
            profile.stats.likes += 1; delta = 14; negativeThemeDelta = -5
            recordEvidence(&profile, terms: signalTerms, positive: 1, negative: 0, search: 0)
        case .unlike:
            profile.stats.unlikes += 1; delta = -8; negativeThemeDelta = 3
            recordEvidence(&profile, terms: signalTerms, positive: 0, negative: 0.8 * negativeShare, search: 0)
        case .less:
            profile.stats.less += 1; delta = -10; negativeThemeDelta = 6
            profile.recentSeen.removeAll { $0 == post.stableID }; profile.recentSeen.append(post.stableID)
            profile.recentSeen = Array(profile.recentSeen.suffix(maxSeen))
            recordEvidence(&profile, terms: signalTerms, positive: 0, negative: 1.35 * negativeShare, search: 0)
        case .download:
            profile.stats.downloads += 1; delta = 16; negativeThemeDelta = -6
            recordEvidence(&profile, terms: signalTerms, positive: 1.25, negative: 0, search: 0)
        case .quickSkip:
            profile.stats.skips += 1; delta = -2.5; negativeThemeDelta = 1.2
            recordEvidence(&profile, terms: signalTerms, positive: 0, negative: 0.35 * negativeShare, search: 0)
        case .replay:
            profile.stats.replays += 1; delta = 6
            recordEvidence(&profile, terms: signalTerms, positive: 0.35, negative: 0, search: 0)
        case .complete:
            profile.stats.completions += 1; delta = 5
            recordEvidence(&profile, terms: signalTerms, positive: 0.35, negative: 0, search: 0)
        case .watched(let seconds, let completion):
            let seconds = max(0, seconds)
            profile.stats.watchSeconds += seconds
            delta = min(5.2, log1p(seconds) * 1.05)
            if completion >= 0.82 {
                profile.stats.completions += 1
                recordEvidence(&profile, terms: signalTerms, positive: 0.35, negative: 0, search: 0)
            }
        }

        if delta != 0 { applyTermDelta(&profile, terms: signalTerms, delta: delta) }
        if negativeThemeDelta != 0 { adjustNegativeThemes(&profile, post: evidencePost, delta: negativeThemeDelta) }
        state.profiles[source] = normalized(profile)
        let key = TasteConcepts.profileKey(post)
        var scoped = state.scopedProfiles[key] ?? RecommendationProfile()
        if delta != 0 { applyTermDelta(&scoped, terms: signalTerms, delta: delta) }
        if negativeThemeDelta != 0 { adjustNegativeThemes(&scoped, post: evidencePost, delta: negativeThemeDelta) }
        recordEvidence(&scoped, terms: signalTerms, positive: max(0, delta / 14), negative: max(0, -delta / 10) * negativeShare, search: 0)
        if event == .impression || event == .less {
            scoped.recentSeen.removeAll { $0 == post.stableID }; scoped.recentSeen.append(post.stableID)
        }
        state.scopedProfiles[key] = normalized(scoped)
        await semantic.record(event, post: evidencePost, eventID: eventID)
    }

    func positiveTerms(provider: Provider, taste: TasteChoice, limit: Int = 16) -> [String] {
        let source = provider.rawValue
        let p = profile(for: source)
        let terms = Set(p.terms.keys).union(tasteTokens(source: source, values: taste.into)).union(tasteTokens(source: source, values: taste.notInto))
        return terms.map { ($0, effectiveTermScore(source: source, term: $0, taste: taste)) }
            .filter { $0.1 > 0.2 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func negativeTerms(provider: Provider, taste: TasteChoice, limit: Int = 16) -> [String] {
        let source = provider.rawValue
        let p = profile(for: source)
        let terms = Set(p.terms.keys).union(tasteTokens(source: source, values: taste.notInto))
        return terms.map { ($0, effectiveTermScore(source: source, term: $0, taste: taste)) }
            .filter { $0.1 < -0.35 }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func isHardDisliked(_ post: Post, taste: TasteChoice) -> Bool {
        let source = post.provider.lowercased()
        return fictionalWildlifeConfusion(post, taste: taste)
            || explicitlyOther3DArtist(post, taste: taste)
            || RecommendationTagRules.rejects(post, exclusions: taste.notInto)
            || RecommendationTagRules.rejects(post, exclusions: repeatedlyRejectedTerms(source: source))
    }

    func score(_ post: Post, taste: TasteChoice, recent: [Post], collaborativeScores: [String: Double] = [:],
               cachedTerms: [String]? = nil) -> Double {
        let source = post.provider.lowercased()
        let scopedKey = contextualRanking ? TasteConcepts.profileKey(post) : source
        let general = profile(for: source)
        let p = contextualRanking ? (state.scopedProfiles[scopedKey] ?? RecommendationProfile()) : general
        let postTerms = cachedTerms ?? terms(for: post)
        let into = Set(tasteTokens(source: source, values: taste.into))
        let notInto = Set(tasteTokens(source: source, values: taste.notInto))
        if isHardDisliked(post, taste: taste) { return -1_000 }
        var score = log1p(max(0, post.score)) * 0.07
        let collaborative = max(0, min(1, collaborativeScores[gorseItemID(post)] ?? 0))
        score += collaborative * 18
        // Historical likes are a weak tie-breaker, not a second dominant
        // recommender. Avoid saturated +12 boosts that collapsed variation.
        let savedWeights = savedFavoriteAffinity[source] ?? [:]
        let savedScore = Set(postTerms).reduce(0.0) { sum, term in
            let generic = Self.genericTasteTerms.contains(RecommendationTagRules.canonical(term))
            return sum + (savedWeights[term] ?? 0) * (generic ? 0.08 : 1)
        }
        score += min(3.0, log1p(savedScore) * 0.9)
        score += preferenceGuardPenalty(post)
        score += conditionalTaste.score(post, taxonomy: taxonomy)
        // An instant swipe away is an explicitly reversible negative; unlike a
        // thumbs-down it does not change permanent term evidence or visual profiles.
        let candidateTerms = Set(postTerms.map(RecommendationTagRules.canonical))
        let recentSkips = state.reversibleSkips.evidence.suffix(24).filter { $0.provider == source }
        let skipPenalty = recentSkips.reduce(0.0) { total, skip in
            let common = candidateTerms.intersection(skip.terms)
            return total + min(5, Double(common.count) * 1.8)
        }
        // Several independent quick skips expressing the same aversion
        // outweigh one accidental swipe, without permanently blacklisting it.
        score -= min(24, skipPenalty)
        if state.reversibleSkips.contains(post.stableID) { score -= 20 }

        let topPositive = positiveTermEntries(source: source, taste: taste, limit: 8, learned: p)
        for term in postTerms {
            let contextual = effectiveTermScore(source: source, term: term, taste: taste, learned: p)
            let overall = effectiveTermScore(source: source, term: term, taste: taste, learned: general)
            // Learn from the medium-specific context while respecting global
            // negative presentation feedback even on previously unseen contexts.
            let own = overall < -0.5 ? min(contextual, overall) :
                (contextualRanking ? contextual * 0.72 + overall * 0.28 : overall)
            let genericMedium = ["2d", "3d", "3d_animation", "animation", "animated"].contains(RecommendationTagRules.canonical(term))
            score += own * (contextualRanking && genericMedium && own > 0 && !into.contains(term) ? 0.15 : 1.7)
            if into.contains(term) { score += 8 }
            if notInto.contains(term) { score -= 22 }
            if abs(own) < 0.05 {
                for (anchor, anchorScore) in topPositive {
                    let edge = p.related[anchor]?[term] ?? 0
                    if edge > 0 { score += min(6.5, edge * 0.62 + sqrt(max(0, anchorScore)) * 0.1) }
                }
            }
        }

        // Identity+style co-occurrence beats an isolated generic style tag.
        let styles: Set<String> = ["2d", "3d", "2d_art", "3d_art", "3dcg",
            "3d_animation", "animation", "animated", "watercolor", "sketch", "pixel_art"]
        let matched = Set(postTerms)
        for anchor in positiveTermEntries(source: source, taste: taste, limit: 8, learned: p).map(\.0) where matched.contains(anchor) {
            if let edges = p.related[anchor] {
                let strength = edges.filter {
                    matched.contains($0.key) && styles.contains(anchor) != styles.contains($0.key)
                }.map(\.value).max() ?? 0
                score += min(7.5, strength * 2)
            }
        }
        if p.recentSeen.contains(post.stableID) { score -= 1_000 }
        score -= negativeThemePenalty(profile: p, post: post)
        if contextualRanking {
            score -= negativeThemePenalty(profile: general, post: post)
        }
        let negativeHits = postTerms.filter {
            effectiveTermScore(source: source, term: $0, taste: taste, learned: p) < -0.5 ||
            effectiveTermScore(source: source, term: $0, taste: taste, learned: general) < -0.5
        }.count
        score -= Double(negativeHits) * 24
        let recentTerms = Set(recent.suffix(10).flatMap { terms(for: $0) })
        score -= min(6, Double(postTerms.filter(recentTerms.contains).count) * 0.42)
        if contextualRanking, let context = state.contextualProfiles[scopedKey], let features = VisualFeatures.metadata(post, taxonomy: taxonomy) {
            score += context.score(features) * 4
        }
        score += sessionTaste.score(provider: source, terms: postTerms)
        return score
    }

    /// Serving gate: user-selected interests determine which broad discovery
    /// candidates qualify to appear in Recommended. Retrieval itself can remain
    /// broad for novelty and future preference exploration.
    private func matchesExplicitInterest(_ post: Post, taste: TasteChoice, visual: Double?) -> Bool {
        let source = post.provider.lowercased()
        let chosen = Set(tasteTokens(source: source, values: taste.into)
            .map(RecommendationTagRules.canonical))
        // Legacy Simple onboarding saved a chosen character AND its parent
        // franchise as two equally strong explicit preferences. Treat that
        // inherited franchise as context, not an open-ended recommendation.
        let inherited = Set(chosen.flatMap { TasteConcepts.characterFranchises[$0] ?? [] })
        let selected = chosen.subtracting(inherited)
        let observed = Set(terms(for: post).map(RecommendationTagRules.canonical))
        if !selected.isEmpty && !selected.isDisjoint(with: observed) { return true }

        // For profiles built from real Likes/Favorites, demand repeated,
        // independently saved evidence before narrowing an otherwise empty
        // explicit profile. One favorite must not overfit the entire feed.
        let favored = savedFavoriteAffinity[source] ?? [:]
        let reinforced = Set(favored.compactMap { term, strength -> String? in
            let canonical = RecommendationTagRules.canonical(term)
            guard strength >= 2.5, !Self.genericTasteTerms.contains(canonical),
                  !inherited.contains(canonical) else { return nil }
            return canonical
        })
        let recent = Set(sessionTaste.strongInterests(provider: source, limit: 12)
            .filter { $0.1 >= 2.7 }.map { $0.0 })
        guard !selected.isEmpty || !reinforced.isEmpty || !recent.isEmpty else { return true }
        if !reinforced.isDisjoint(with: observed) || !recent.isDisjoint(with: observed) { return true }
        return visual.map { $0.isFinite && $0 >= 3.0 } ?? false
    }

    /// Cheap metadata ranking before publication: no inference or network.
    /// In strict serving mode the feed is not padded with unrelated items.
    func rankFast(_ candidates: [Post], taste: TasteChoice, recent: [Post], visualScores: [String: Double] = [:], strict: Bool = false) -> [Post] {
        let start = Date(); defer { FeedPerformance.emit("rank_fast", started: start, count: min(384, candidates.count)) }
        guard let first = candidates.first else { return [] }
        let p = profile(for: first.provider.lowercased())
        let hasSignal = !state.contextualProfiles.isEmpty || !state.scopedProfiles.isEmpty || !savedFavoriteAffinity.isEmpty || !taste.into.isEmpty || !taste.notInto.isEmpty
            || !p.terms.isEmpty || !p.negativeThemes.isEmpty || !p.termEvidence.isEmpty
        guard hasSignal || !state.reversibleSkips.evidence.isEmpty || !visualScores.isEmpty else {
            return candidates.filter { post in
                !isHardDisliked(post, taste: taste) &&
                (!strict || matchesExplicitInterest(post, taste: taste, visual: visualScores[post.stableID]))
            }
        }
        var scored: [(post: Post, value: Double, offset: Int, topics: Set<String>)] = []
        for (offset, post) in candidates.prefix(384).enumerated() {
            guard !isHardDisliked(post, taste: taste),
                  !strict || matchesExplicitInterest(post, taste: taste,
                                                       visual: visualScores[post.stableID]) else { continue }
            // Tokenize once for the metadata score and the diversity pass.
            let postTerms = terms(for: post)
            let metadata = score(post, taste: taste, recent: recent, cachedTerms: postTerms)
            let calibrated = RecommendationQualityModel.combined(metadata: metadata,
                visual: visualScores[post.stableID])
            let topics = Set(postTerms).subtracting(Self.genericTasteTerms)
            scored.append((post: post, value: calibrated, offset: offset, topics: topics))
        }
        scored.sort { $0.value == $1.value ? $0.offset < $1.offset : $0.value > $1.value }
        // Lightweight, bounded diversification without model inference:
        // compare the next 20 candidates against recent chosen themes so
        // adjacent cards do not repeat the same near-identical subjects.
        var output: [Post] = []
        var termWindow: [Set<String>] = []
        let previous = recent.suffix(5).map { Set(terms(for: $0)).subtracting(Self.genericTasteTerms) }
        let maxDiversified = min(48, scored.count)
        while output.count < maxDiversified {
            let count = min(20, scored.count)
            let context = Array((previous + termWindow).suffix(5))
            var best = 0
            var bestScore = -Double.infinity
            for index in 0..<count {
                let topics = scored[index].topics
                let overlap = context.map { seen -> Double in
                    guard !topics.isEmpty, !seen.isEmpty else { return 0 }
                    return Double(topics.intersection(seen).count) / Double(max(1, min(topics.count, seen.count)))
                }.max() ?? 0
                let adjusted = scored[index].value - overlap * 6.5
                if adjusted > bestScore { best = index; bestScore = adjusted }
            }
            let item = scored.remove(at: best)
            output.append(item.post)
            termWindow.append(item.topics)
        }
        output += scored.map(\.post)
        return output + candidates.dropFirst(384).filter { post in
            !isHardDisliked(post, taste: taste) &&
            (!strict || matchesExplicitInterest(post, taste: taste, visual: visualScores[post.stableID]))
        }
    }

    func rank(_ candidates: [Post], taste: TasteChoice, recent: [Post], collaborativeScores: [String: Double] = [:], visualScores: [String: Double] = [:], limit: Int? = nil) async -> [Post] {
        guard !Task.isCancelled else { return candidates }
        let start = Date(); defer { rankLatencyMs = Date().timeIntervalSince(start) * 1000 }
        // Query the existing on-device embedding cache BEFORE trimming the 512
        // candidates to 128. Otherwise a semantically excellent match that had
        // sparse metadata could never compete in the final reranker.
        // scores() is cache-only; no network or Core ML inference runs here.
        var scored: [(offset: Int, post: Post, metadata: Double)] = []
        for (offset, post) in candidates.prefix(512).enumerated() {
            guard !isHardDisliked(post, taste: taste) else { continue }
            scored.append((offset, post, score(post, taste: taste, recent: recent,
                                               collaborativeScores: collaborativeScores)))
        }
        let semanticScores = await semantic.scores(scored.map(\.post), taste: taste)
        let weights = semantic.weights
        // Compare features on the same scales used by the final reranker.
        // Collaborative, semantic and cached appearance signals may all rescue
        // a candidate previously discarded by metadata-only shortlisting.
        // Explicit intermediate types avoid exponential Swift 6 inference cost
        // on a heterogeneous numeric expression containing optional scores.
        var shortlistScores: [(offset: Int, post: Post, value: Double)] = []
        shortlistScores.reserveCapacity(scored.count)
        for entry in scored {
            let metadataValue: Double = tanh(entry.metadata / 35.0) * weights.tag
            let semanticValue: Double = semanticScores[entry.post.stableID]?.total(weights) ?? 0.0
            let cachedAppearance: Double = visualScores[entry.post.stableID] ?? 0.0
            let visualValue: Double = max(-4.0, min(4.0, cachedAppearance))
            let combined: Double = metadataValue + semanticValue + visualValue
            shortlistScores.append((offset: entry.offset, post: entry.post, value: combined))
        }
        shortlistScores.sort { left, right in
            if left.value == right.value { return left.offset < right.offset }
            return left.value > right.value
        }
        let shortlist: [Post] = shortlistScores.prefix(128).map { entry in entry.post }
        let selected = Set(shortlist.map(\.stableID))
        let overflow = candidates.filter { !selected.contains($0.stableID) }
        let candidates = shortlist
        let vectors = await semantic.diversityVectors(candidates + recent)
        debugScores = [:]
        let themes = Dictionary(uniqueKeysWithValues:Set(candidates.map { $0.provider.lowercased() }).map { source in
            (source,positiveTermEntries(source:source,taste:taste,limit:3).map { $0.0 })
        })
        // Tokenize once, rather than for every comparison in the diversity loop.
        let termCache = Dictionary((candidates + recent).map { ($0.stableID, terms(for: $0)) }, uniquingKeysWith: { first, _ in first })
        var unique = Set<String>()
        var pool: [(post: Post, base: Double, tags: Double, seen: Double)] = []
        for (offset, post) in candidates.enumerated() {
            guard unique.insert(post.stableID).inserted, !isHardDisliked(post, taste: taste) else { continue }
            let raw = score(post, taste: taste, recent: recent, collaborativeScores: collaborativeScores)
            let seen: Double = profile(for: post.provider.lowercased()).recentSeen.contains(post.stableID) ? -weights.seen : 0
            let tagScore = tanh((raw - (seen == 0 ? 0 : -1000)) / 35) * weights.tag
            let semanticScore = semanticScores[post.stableID] ?? SemanticScore()
            let visualScore = max(-4, min(4, visualScores[post.stableID] ?? 0))
            let base = tagScore + semanticScore.total(weights) + visualScore + seen - Double(offset) * 0.002
            pool.append((post: post, base: base, tags: tagScore, seen: seen))
        }
        var chosen: [Post] = []
        var similarityCache: [String: [String: Double]] = [:]
        // Bound look-ahead ranking as the endless feed grows. Hard filters still
        // apply to every candidate; the remainder retains acquisition order.
        let target = min(limit ?? 48, pool.count)

        while chosen.count < target, !pool.isEmpty {
            guard !Task.isCancelled else { return candidates }
            let context = Array((recent + chosen).suffix(8))
            let contextTerms = Set(context.flatMap { termCache[$0.stableID] ?? [] })
            let lastTerms = Set(context.last.flatMap { termCache[$0.stableID] } ?? [])
            var bestIndex = 0
            var bestScore = -Double.infinity

            for (index, entry) in pool.enumerated() {
                let candidateTerms = termCache[entry.post.stableID] ?? []
                let overlap = candidateTerms.filter(contextTerms.contains).count
                let immediate = candidateTerms.filter(lastTerms.contains).count
                var diversity = min(weights.tagDiversityCap, Double(overlap) * weights.overlap + Double(immediate) * weights.immediate)
                if let vector = vectors[entry.post.stableID] {
                    let similar = context.compactMap { other -> Double? in
                        guard let otherVector = vectors[other.stableID] else { return nil }
                        if let cached = similarityCache[entry.post.stableID]?[other.stableID] { return cached }
                        let value = SemanticRecommender.cosine(vector, otherVector)
                        similarityCache[entry.post.stableID, default: [:]][other.stableID] = value
                        return value
                    }.max() ?? 0
                    diversity += max(0, similar - 0.70) * weights.semanticDiversity
                    if similar > 0.94 { diversity += weights.nearDuplicate }
                }
                if let creator = entry.post.creator, !creator.isEmpty, context.suffix(3).contains(where: { $0.creator == creator }) { diversity += weights.creatorRepeat }
                var value = entry.base - diversity
                // Every eighth slot favors an unseen lower-affinity candidate, bounded by negative preferences.
                if chosen.count % 8 == 7, entry.seen == 0 { value += weights.exploration * (1 - (semanticScores[entry.post.stableID]?.recent ?? 0)) }
                if immediate >= 2 { value -= weights.immediateTwo }
                if immediate >= 3 { value -= weights.immediateThree }
                if overlap >= 4 { value -= weights.overlapFour }
                if overlap >= 6 { value -= weights.overlapSix }
                debugScores[entry.post.stableID] = DebugScore(semantic: semanticScores[entry.post.stableID] ?? SemanticScore(), tags: entry.tags, diversity: diversity, seen: entry.seen, interestThemes: themes[entry.post.provider.lowercased()] ?? [], final: value)
                if value > bestScore { bestScore = value; bestIndex = index }
            }
            chosen.append(pool.remove(at: bestIndex).post)
        }
        let remainder = overflow.filter { !isHardDisliked($0, taste: taste) && unique.insert($0.stableID).inserted }
        return limit == nil ? chosen + pool.map(\.post) + remainder : chosen
    }

    func gorseItemID(_ post: Post) -> String {
        let raw = post.id.isEmpty ? post.stableID : post.id
        return "\(post.provider.lowercased()):\(String(raw.prefix(180)))"
    }

    private func profile(for source: String) -> RecommendationProfile {
        normalized(state.profiles[source] ?? RecommendationProfile())
    }

    private func normalized(_ value: RecommendationProfile) -> RecommendationProfile {
        var p = value
        p.recentQueries = Array(p.recentQueries.suffix(maxQueries))
        p.recentSeen = Array(p.recentSeen.suffix(maxSeen))
        return p
    }

    private func isTermAllowed(source: String, term: String) -> Bool {
        if source == Provider.rule34.rawValue { return !term.isEmpty }
        return term.count >= 3 && !stopwords.contains(term) && Int(term) == nil
    }

    private func tasteTokens(source: String, values: [String]) -> [String] {
        if source == Provider.rule34.rawValue {
            var used = Set<String>()
            return values.map { RecommendationTagRules.canonical($0) }
                .filter { !$0.isEmpty && used.insert($0).inserted }
        }
        var out: [String] = []
        for value in values {
            for raw in value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(whereSeparator: { $0.isWhitespace }) {
                let clean = String(raw).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
                if isTermAllowed(source: source, term: clean), !out.contains(clean) { out.append(clean) }
            }
        }
        return out
    }

    private func effectiveTermScore(source: String, term: String, taste: TasteChoice, learned: RecommendationProfile? = nil) -> Double {
        guard isTermAllowed(source: source, term: term) else { return 0 }
        // An old Rouge like may have trained bare "bat" before character
        // disambiguation. Never use that accidental association positively
        // unless the user explicitly asked for the animal itself.
        if sourcesWithFictionalCharacters.contains(source), !sourcesWithWildlifeLikes.contains(source),
           Self.wildlifeOnlyTerms.contains(RecommendationTagRules.canonical(term)),
           !taste.into.map(TasteConcepts.canonical).contains(RecommendationTagRules.canonical(term)) {
            return min(0, learned?.terms[term] ?? profile(for: source).terms[term] ?? 0)
        }
        let p = learned ?? profile(for: source)
        var score = p.terms[term] ?? 0
        let e = p.termEvidence[term] ?? RecommendationTermEvidence()
        score += min(24, e.positive * 3.2 + e.search * 4.5)
        score -= min(30, e.negative * 5.2)
        let into = tasteTokens(source: source, values: taste.into)
        let notInto = tasteTokens(source: source, values: taste.notInto)
        if into.contains(term) { score += 16 }
        if notInto.contains(term) { score -= 28 }
        return score
    }

    private func positiveTermEntries(source: String, taste: TasteChoice, limit: Int, learned: RecommendationProfile? = nil) -> [(String, Double)] {
        let p = learned ?? profile(for: source)
        let candidates = Set(p.terms.keys).union(tasteTokens(source: source, values: taste.into)).union(tasteTokens(source: source, values: taste.notInto))
        return candidates.map { ($0, effectiveTermScore(source: source, term: $0, taste: taste, learned: p)) }
            .filter { $0.1 > 0.2 }.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    private func applyTermDelta(_ profile: inout RecommendationProfile, terms: [String], delta: Double) {
        let scale = terms.isEmpty ? 1 : 1 / sqrt(Double(min(terms.count, 16)))
        for term in terms { profile.terms[term] = clamp((profile.terms[term] ?? 0) + delta * scale, -30, 70) }
        if delta > 0 { updateRelated(&profile, terms: terms, strength: min(1.2, delta * 0.16)) }
    }

    private func recordEvidence(_ profile: inout RecommendationProfile, terms: [String], positive: Double, negative: Double, search: Double) {
        for term in terms {
            var e = profile.termEvidence[term] ?? RecommendationTermEvidence()
            e.positive = clamp(e.positive + positive, 0, 50)
            e.negative = clamp(e.negative + negative, 0, 50)
            e.search = clamp(e.search + search, 0, 50)
            profile.termEvidence[term] = e
        }
    }

    private func updateRelated(_ profile: inout RecommendationProfile, terms: [String], strength: Double) {
        guard strength > 0 else { return }
        let sample = Array(terms.prefix(10))
        for a in sample {
            var edges = profile.related[a] ?? [:]
            for b in sample where b != a { edges[b] = clamp((edges[b] ?? 0) + strength, 0, 30) }
            profile.related[a] = edges
        }
    }

    private func adjustNegativeThemes(_ profile: inout RecommendationProfile, post: Post, delta: Double) {
        let themes = themeSignatures(for: post)
        let shared = delta / sqrt(Double(max(1, min(themes.count, 12))))
        for theme in themes {
            let value = clamp((profile.negativeThemes[theme] ?? 0) + shared, 0, 40)
            if value < 0.08 { profile.negativeThemes.removeValue(forKey: theme) }
            else { profile.negativeThemes[theme] = value }
        }
    }

    private func negativeThemePenalty(profile: RecommendationProfile, post: Post) -> Double {
        var total = 0.0
        var hits = 0
        for theme in themeSignatures(for: post) {
            let value = profile.negativeThemes[theme] ?? 0
            if value > 0.1 { total += value; hits += 1 }
        }
        return min(70, total * (hits > 1 ? 1.15 : 0.8))
    }

    private func pruneAll() {
        for source in state.profiles.keys {
            var p = profile(for: source)
            let termEntries = p.terms.filter { abs($0.value) > 0.03 }.sorted { abs($0.value) > abs($1.value) }.prefix(maxTerms)
            p.terms = Dictionary(uniqueKeysWithValues: termEntries.map { ($0.key, $0.value) })
            let keep = Set(p.terms.keys)
            p.termEvidence = p.termEvidence.filter { keep.contains($0.key) && ($0.value.positive != 0 || $0.value.negative != 0 || $0.value.search != 0) }
            p.recentQueries = Array(p.recentQueries.suffix(maxQueries))
            p.recentSeen = Array(p.recentSeen.suffix(maxSeen))
            state.profiles[source] = p
        }
        for key in state.scopedProfiles.keys {
            var p = normalized(state.scopedProfiles[key] ?? RecommendationProfile())
            p.terms = Dictionary(uniqueKeysWithValues: p.terms.filter { abs($0.value) > 0.03 }.sorted { abs($0.value) > abs($1.value) }.prefix(maxTerms).map { ($0.key, $0.value) })
            let keep = Set(p.terms.keys)
            p.termEvidence = p.termEvidence.filter { keep.contains($0.key) }
            p.related = p.related.filter { keep.contains($0.key) }.mapValues { $0.filter { keep.contains($0.key) } }
            state.scopedProfiles[key] = p
        }
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(high, value)) }
}
