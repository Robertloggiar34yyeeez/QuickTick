import Foundation

actor RecommendationEngine {
    private(set) var state = RecommendationState()
    let semantic: SemanticRecommender
    init(semantic: SemanticRecommender = SemanticRecommender()) { self.semantic = semantic }
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
        let queryExclusions = Array(Set(excluded + tasteTokens(source: provider.rawValue, values: taste.notInto))).sorted()
        let blocked = Set(queryExclusions.map { $0.lowercased() })
        let explicit = tasteTokens(source: provider.rawValue, values: taste.into).filter { !blocked.contains($0) }
        // Keep learned acquisition separate: adding many explicit tags must not
        // evict the established profile from candidate discovery.
        let learned = positiveTermEntries(source: provider.rawValue, taste: TasteChoice(), limit: 8)
            .filter { $0.1 >= 3 && !blocked.contains($0.0) && !explicit.contains($0.0) }.map { $0.0 }
        let roundKey = context + "|round"
        let round = max(0, (state.candidatePages[roundKey] ?? 1) - 1)
        advanceCandidatePage(context: roundKey, nextPage: (round + 1) % 12_000 + 1)
        var focused = !forceBroad && (!explicit.isEmpty || !learned.isEmpty) && round % 4 != 3
        var terms: [String]
        if !focused { terms = [] }
        else if !explicit.isEmpty && (learned.isEmpty || round % 4 == 0) { terms = [explicit[(round / 4 + (learned.isEmpty ? round % 4 : 0)) % explicit.count]] }
        else { terms = [learned[(round / 4 * 2 + max(0, round % 4 - 1)) % learned.count]] }
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

    func recordSearch(provider: Provider, query: String) {
        let parts = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return }
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
    }

    func record(_ event: RecommendationEvent, post: Post) async {
        var evidencePost = post
        if [.less, .unlike, .quickSkip].contains(event), let features = VisualFeatures.metadata(post), !features.subjects.isEmpty {
            // Ambiguous negative feedback describes this presentation first.
            evidencePost.tags.removeAll { tag in
                let normalized = tag.lowercased().replacingOccurrences(of: "-", with: "_")
                return normalized.hasPrefix("character:") || normalized.hasPrefix("performer:") || features.subjects.contains(where: { normalized.contains($0) })
            }
            evidencePost.caption = nil; evidencePost.category = nil
        }
        await semantic.record(event, post: evidencePost)
        let source = post.provider.lowercased()
        let signalTerms = terms(for: evidencePost)
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
        let profile = profile(for: source)
        let postTerms = terms(for: post)
        if RecommendationTagRules.rejects(post, exclusions: taste.notInto) { return true }

        for term in postTerms {
            let evidence = profile.termEvidence[term] ?? RecommendationTermEvidence()
            if evidence.negative >= 1.8,
               evidence.negative > evidence.positive * 1.15,
               effectiveTermScore(source: source, term: term, taste: taste) <= -4 { return true }
        }

        var strongThemeHits = 0
        for theme in themeSignatures(for: post) {
            let value = profile.negativeThemes[theme] ?? 0
            if value >= 6 { strongThemeHits += 1 }
            if value >= 10 { return true }
        }
        return strongThemeHits >= 2
    }

    func score(_ post: Post, taste: TasteChoice, recent: [Post], collaborativeScores: [String: Double] = [:]) -> Double {
        let source = post.provider.lowercased()
        let p = profile(for: source)
        let postTerms = terms(for: post)
        let into = Set(tasteTokens(source: source, values: taste.into))
        let notInto = Set(tasteTokens(source: source, values: taste.notInto))
        if RecommendationTagRules.rejects(post, exclusions: taste.notInto) { return -1_000 }
        var score = log1p(max(0, post.score)) * 0.07
        let collaborative = max(0, min(1, collaborativeScores[gorseItemID(post)] ?? 0))
        score += collaborative * 18

        let topPositive = positiveTermEntries(source: source, taste: taste, limit: 8)
        for term in postTerms {
            let own = effectiveTermScore(source: source, term: term, taste: taste)
            score += own * 1.7
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
        for anchor in positiveTermEntries(source: source, taste: taste, limit: 8).map(\.0) where matched.contains(anchor) {
            if let edges = p.related[anchor] {
                let strength = edges.filter {
                    matched.contains($0.key) && styles.contains(anchor) != styles.contains($0.key)
                }.map(\.value).max() ?? 0
                score += min(7.5, strength * 2)
            }
        }
        if p.recentSeen.contains(post.stableID) { score -= 1_000 }
        score -= negativeThemePenalty(profile: p, post: post)
        let negativeHits = postTerms.filter { effectiveTermScore(source: source, term: $0, taste: taste) < -0.5 }.count
        score -= Double(negativeHits) * 24
        let recentTerms = Set(recent.suffix(10).flatMap { terms(for: $0) })
        score -= min(6, Double(postTerms.filter(recentTerms.contains).count) * 0.42)
        return score
    }

    /// Cheap metadata ranking before publication: no ML, images, or network access.
    /// An untouched profile retains the provider's original order.
    func rankFast(_ candidates: [Post], taste: TasteChoice, recent: [Post]) -> [Post] {
        guard let first = candidates.first else { return [] }
        let p = profile(for: first.provider.lowercased())
        let hasSignal = !taste.into.isEmpty || !taste.notInto.isEmpty
            || !p.terms.isEmpty || !p.negativeThemes.isEmpty || !p.termEvidence.isEmpty
        guard hasSignal else { return candidates }
        var scored: [(post: Post, value: Double, offset: Int)] = []
        for (offset, post) in candidates.enumerated() {
            guard !isHardDisliked(post, taste: taste) else { continue }
            scored.append((post: post, value: score(post, taste: taste, recent: recent), offset: offset))
        }
        scored.sort { $0.value == $1.value ? $0.offset < $1.offset : $0.value > $1.value }
        return scored.map(\.post)
    }

    func rank(_ candidates: [Post], taste: TasteChoice, recent: [Post], collaborativeScores: [String: Double] = [:], visualScores: [String: Double] = [:], limit: Int? = nil) async -> [Post] {
        let start = Date(); defer { rankLatencyMs = Date().timeIntervalSince(start) * 1000 }
        let semanticScores = await semantic.scores(candidates, taste: taste)
        let vectors = await semantic.diversityVectors(candidates + recent)
        let weights = semantic.weights
        debugScores = [:]
        let themes = Dictionary(uniqueKeysWithValues:Set(candidates.map { $0.provider.lowercased() }).map { source in
            (source,positiveTermEntries(source:source,taste:taste,limit:3).map { $0.0 })
        })
        // Tokenize once, rather than for every comparison in the diversity loop.
        let termCache = Dictionary((candidates + recent).map { ($0.stableID, terms(for: $0)) }, uniquingKeysWith: { first, _ in first })
        var unique = Set<String>()
        var pool = candidates.filter { unique.insert($0.stableID).inserted && !isHardDisliked($0, taste: taste) }
            .enumerated()
             .map { entry in
                let raw = score(entry.element, taste: taste, recent: recent, collaborativeScores: collaborativeScores)
                let seen = profile(for: entry.element.provider.lowercased()).recentSeen.contains(entry.element.stableID) ? -weights.seen : 0
                let tags = tanh((raw - (seen == 0 ? 0 : -1000)) / 35) * weights.tag
                let semantic = semanticScores[entry.element.stableID] ?? SemanticScore()
                let visual = max(-4, min(4, visualScores[entry.element.stableID] ?? 0))
                return (post: entry.element, base: tags + semantic.total(weights) + visual + seen - Double(entry.offset) * 0.002, tags: tags, seen: seen)
            }
        var chosen: [Post] = []
        var similarityCache: [String: [String: Double]] = [:]
        // Bound look-ahead ranking as the endless feed grows. Hard filters still
        // apply to every candidate; the remainder retains acquisition order.
        let target = min(limit ?? 48, pool.count)

        while chosen.count < target, !pool.isEmpty {
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
        return limit == nil ? chosen + pool.map(\.post) : chosen
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

    private func effectiveTermScore(source: String, term: String, taste: TasteChoice) -> Double {
        guard isTermAllowed(source: source, term: term) else { return 0 }
        let p = profile(for: source)
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

    private func positiveTermEntries(source: String, taste: TasteChoice, limit: Int) -> [(String, Double)] {
        let p = profile(for: source)
        let candidates = Set(p.terms.keys).union(tasteTokens(source: source, values: taste.into)).union(tasteTokens(source: source, values: taste.notInto))
        return candidates.map { ($0, effectiveTermScore(source: source, term: $0, taste: taste)) }
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
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(high, value)) }
}
