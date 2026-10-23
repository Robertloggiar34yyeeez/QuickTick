import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let quicktickProfile = UTType(exportedAs: "app.quicktick.recommendation-profile", conformingTo: .json)
}

/// Explicit, portable interests only. Never a Sync snapshot, credential store,
/// downloaded file, embedding cache or per-post viewing/search history.
struct RecommendationTransfer: Codable, Transferable, Sendable, Identifiable {
    var id: UUID = UUID()
    var format = "QuickTick recommendation profile"
    var version = 1
    var semanticVersion = "bge-micro-v2-3edf6d7-96-v1"
    var preferences: TasteSetup
    var exclusions: [String]
    var profiles: [String: RecommendationProfile]
    var semanticProfiles: [String: SemanticInterest]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .quicktickProfile)
            .suggestedFileName("QuickTick-Recommendations.quicktickprofile")
    }

    init(preferences: TasteSetup, exclusions: [String], state: RecommendationState, semanticProfiles: [String: SemanticInterest]) {
        self.preferences = preferences; self.exclusions = exclusions
        self.profiles = state.profiles.mapValues { profile in
            var safe = profile
            safe.recentSeen = []; safe.recentQueries = []; safe.stats = RecommendationStats()
            let retained = Set(safe.terms.keys)
            safe.related = safe.related.filter { retained.contains($0.key) }.mapValues { $0.filter { retained.contains($0.key) } }
            safe.negativeThemes = Dictionary(safe.negativeThemes.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            return safe
        }
        self.semanticProfiles = semanticProfiles
    }

    func validated() throws -> Self {
        let providers = Set(Provider.allCases.map(\.rawValue))
        func strings(_ values: [String], limit: Int) -> Bool { values.count <= limit && values.allSatisfy { !$0.isEmpty && $0.count <= 180 } }
        func numbers(_ values: [String: Double], limit: Int) -> Bool {
            values.count <= limit && values.allSatisfy { $0.key.count <= 180 && $0.value.isFinite && abs($0.value) <= 1_000_000 }
        }
        guard format == "QuickTick recommendation profile", version == 1,
              semanticVersion == "bge-micro-v2-3edf6d7-96-v1", (1...2).contains(preferences.version),
              Set(preferences.sources.keys).isSubset(of: providers), Set(profiles.keys).isSubset(of: providers),
              semanticProfiles.keys.allSatisfy({ key in providers.contains(key) || key.split(separator: "|").count == 2 && providers.contains(String(key.split(separator: "|").first ?? "")) && VisualDomain(rawValue: String(key.split(separator: "|").last ?? "")) != nil }), strings(exclusions, limit: 512) else {
            throw APIError.server("This is not a supported QuickTick recommendation profile.")
        }
        for taste in preferences.sources.values {
            guard strings(taste.into, limit: 40), strings(taste.notInto, limit: 40),
                  taste.into.allSatisfy({ $0.count <= 80 }), taste.notInto.allSatisfy({ $0.count <= 80 }) else { throw APIError.invalidResponse }
        }
        for p in profiles.values {
            guard numbers(p.terms, limit: 140), numbers(p.negativeThemes, limit: 512), p.related.count <= 140,
                  p.related.allSatisfy({ $0.key.count <= 180 && numbers($0.value, limit: 140) }), p.termEvidence.count <= 140,
                  p.termEvidence.allSatisfy({ item in
                      item.key.count <= 180 && [item.value.positive, item.value.negative, item.value.search].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
                  }) else { throw APIError.invalidResponse }
        }
        for p in semanticProfiles.values {
            guard [p.recent, p.longTerm, p.negative].allSatisfy({ vector in
                (vector.isEmpty || vector.count == 384) && vector.allSatisfy { $0.isFinite && abs($0) <= 100 }
            }), p.creators.count <= 48, p.creators.allSatisfy({ $0.key.count <= 180 && $0.value.isFinite && abs($0.value) <= 1 }),
                  p.updated.timeIntervalSince1970.isFinite, p.updated <= Date.now.addingTimeInterval(86400) else { throw APIError.invalidResponse }
        }
        // Strip any history/counters a foreign JSON file tried to include.
        var state = RecommendationState(); state.profiles = profiles
        return Self(preferences: preferences, exclusions: exclusions, state: state, semanticProfiles: semanticProfiles)
    }
}

actor RecommendationTransferReader {
    static func decode(_ data: Data) throws -> RecommendationTransfer {
        guard data.count <= 2 * 1024 * 1024 else { throw APIError.server("Recommendation profile exceeds the 2 MB limit.") }
        return try JSONDecoder().decode(RecommendationTransfer.self, from: data).validated()
    }
    func read(_ url: URL) throws -> RecommendationTransfer {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2 * 1024 * 1024 else { throw APIError.server("Select a QuickTick profile smaller than 2 MB.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try Self.decode(file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data())
    }
}

enum RecommendationEvent: Codable, Sendable, Equatable {
    case impression
    case like
    case unlike
    case less
    case download
    case quickSkip
    case watched(seconds: Double, completion: Double)
    case replay
    case complete
}

struct RecommendationStats: Codable, Sendable, Equatable {
    var impressions = 0
    var likes = 0
    var unlikes = 0
    var downloads = 0
    var less = 0
    var skips = 0
    var replays = 0
    var completions = 0
    var watchSeconds: Double = 0
}

struct RecommendationTermEvidence: Codable, Sendable, Equatable {
    var positive: Double = 0
    var negative: Double = 0
    var search: Double = 0
}

struct RecommendationProfile: Codable, Sendable, Equatable {
    var terms: [String: Double] = [:]
    var related: [String: [String: Double]] = [:]
    var negativeThemes: [String: Double] = [:]
    var termEvidence: [String: RecommendationTermEvidence] = [:]
    var recentQueries: [String] = []
    var recentSeen: [String] = []
    var stats = RecommendationStats()
    init() {}
    enum CodingKeys: String, CodingKey { case terms, related, negativeThemes, termEvidence, recentQueries, recentSeen, stats }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = try c.decodeIfPresent([String: Double].self, forKey: .terms) ?? [:]
        related = try c.decodeIfPresent([String: [String: Double]].self, forKey: .related) ?? [:]
        negativeThemes = try c.decodeIfPresent([String: Double].self, forKey: .negativeThemes) ?? [:]
        termEvidence = try c.decodeIfPresent([String: RecommendationTermEvidence].self, forKey: .termEvidence) ?? [:]
        recentQueries = try c.decodeIfPresent([String].self, forKey: .recentQueries) ?? []
        recentSeen = try c.decodeIfPresent([String].self, forKey: .recentSeen) ?? []
        stats = try c.decodeIfPresent(RecommendationStats.self, forKey: .stats) ?? RecommendationStats()
    }
}

/// Small, fully local novelty model. Persisting what was *offered* (not just
/// watched) prevents page-one refreshes from serving the same cards again.
struct RecommendationNoveltyModel: Codable, Sendable, Equatable {
    var offered: [String] = []
    mutating func record(_ ids: [String]) {
        let incoming = Set(ids)
        offered.removeAll { incoming.contains($0) }
        offered.append(contentsOf: ids)
        if offered.count > 8192 { offered = Array(offered.suffix(8192)) }
    }
    func contains(_ id: String) -> Bool { offered.contains(id) }
}

/// Explicitly reversible negative feedback from fast vertical scrolling.
/// It is intentionally separate from irreversible thumbs-down and event-based
/// learning so scrolling back never produces a contradictory positive signal.
struct ReversibleSkipModel: Codable, Sendable, Equatable {
    struct Evidence: Codable, Sendable, Equatable {
        let id: String
        let provider: String
        let terms: [String]
    }
    var evidence: [Evidence] = []
    mutating func mark(_ sample: Evidence) {
        evidence.removeAll { $0.id == sample.id }
        evidence.append(sample)
        if evidence.count > 128 { evidence.removeFirst(evidence.count - 128) }
    }
    @discardableResult
    mutating func neutralize(_ id: String) -> Bool {
        let old = evidence.count
        evidence.removeAll { $0.id == id }
        return evidence.count != old
    }
    func contains(_ id: String) -> Bool { evidence.contains { $0.id == id } }
}

struct RecommendationState: Codable, Sendable, Equatable {
    static let currentVersion = 5
    var version: Int = currentVersion
    var profiles: [String: RecommendationProfile] = [:]
    var candidatePages: [String: Int] = [:]
    var contextualProfiles: [String: ContextTasteProfile] = [:]
    var scopedProfiles: [String: RecommendationProfile] = [:]
    var feedbackLedger: [String] = []
    var novelty = RecommendationNoveltyModel()
    var reversibleSkips = ReversibleSkipModel()
    init() {}
    enum CodingKeys: String, CodingKey { case version, profiles, candidatePages, contextualProfiles, scopedProfiles, feedbackLedger, novelty, reversibleSkips }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decodeIfPresent(Int.self, forKey: .version) ?? 3
        profiles = try fields.decodeIfPresent([String: RecommendationProfile].self, forKey: .profiles) ?? [:]
        candidatePages = try fields.decodeIfPresent([String: Int].self, forKey: .candidatePages) ?? [:]
        contextualProfiles = try fields.decodeIfPresent([String: ContextTasteProfile].self, forKey: .contextualProfiles) ?? [:]
        scopedProfiles = try fields.decodeIfPresent([String: RecommendationProfile].self, forKey: .scopedProfiles) ?? [:]
        feedbackLedger = try fields.decodeIfPresent([String].self, forKey: .feedbackLedger) ?? []
        novelty = try fields.decodeIfPresent(RecommendationNoveltyModel.self, forKey: .novelty) ?? RecommendationNoveltyModel()
        reversibleSkips = try fields.decodeIfPresent(ReversibleSkipModel.self, forKey: .reversibleSkips) ?? ReversibleSkipModel()
    }

    func upgradedForCurrentRanking() -> Self {
        guard version < Self.currentVersion else { return self }
        var result = self
        result.version = Self.currentVersion
        return result.rebuildingCandidates()
    }

    func rebuildingCandidates() -> Self {
        var result = self
        // Invalidate only acquisition/candidate exposure. User intent,
        // explicit dislikes, watched history and visual profiles survive.
        result.candidatePages.removeAll()
        result.novelty.offered.removeAll()
        return result
    }
}

struct RecommendationItemPayload: Codable, Sendable, Equatable {
    var itemId: String
    var source: String
    var title: String
    var tags: [String]
    var type: String
    var timestamp: Int64
}

struct RecommendationRankResponse: Codable, Sendable, Equatable {
    var enabled: Bool?
    var available: Bool?
    var fallback: Bool?
    var order: [String]?
    var scores: [String: Double]?
    var error: String?
}

struct RecommendationFeedbackResponse: Codable, Sendable, Equatable {
    var enabled: Bool?
    var available: Bool?
    var fallback: Bool?
    var recorded: Bool?
    var feedbackType: String?
    var deleted: Bool?
    var reset: Bool?
    var error: String?
}
