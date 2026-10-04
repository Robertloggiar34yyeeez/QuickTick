import Foundation

enum RecommendationEvent: Sendable, Equatable {
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

struct RecommendationState: Codable, Sendable, Equatable {
    var version: Int = 3
    var profiles: [String: RecommendationProfile] = [:]
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
