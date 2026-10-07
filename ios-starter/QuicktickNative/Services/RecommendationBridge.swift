import Foundation
import CryptoKit

private struct RecommendationRankRequest: Codable, Sendable {
    var action = "rank"
    var userId: String
    var source: String
    var items: [RecommendationItemPayload]
    var positiveTerms: [String]
    var negativeTerms: [String]
}

private struct RecommendationFeedbackRequest: Codable, Sendable {
    var action = "feedback"
    var userId: String
    var source: String
    var item: RecommendationItemPayload
    var type: String
    var value: Double
    var positiveTerms: [String]
    var negativeTerms: [String]
}

private struct RecommendationResetRequest: Codable, Sendable {
    var action = "reset"
    var userId: String
    var source: String
}

actor RecommendationBridge {
    private let api: QuicktickAPIClient
    private var backoffUntil = Date.distantPast

    init(api: QuicktickAPIClient) { self.api = api }

    func userID(syncID: String) throws -> String {
        let parsed = try QuicktickSyncCrypto.parse(syncID)
        let digest = SHA256.hash(data: Data("quicktick-gorse-user-v1:\(parsed.recordID)".utf8))
        return "qtg_\(QuicktickSyncCrypto.base64URL(Data(digest)).prefix(43))"
    }

    func rank(
        posts: [Post],
        provider: Provider,
        syncID: String,
        positiveTerms: [String],
        negativeTerms: [String]
    ) async -> [String: Double]? {
        guard posts.count >= 2, Date() >= backoffUntil else { return nil }
        do {
            let request = RecommendationRankRequest(
                userId: try userID(syncID: syncID),
                source: provider.rawValue,
                items: posts.prefix(40).map(payload),
                positiveTerms: Array(positiveTerms.prefix(16)),
                negativeTerms: Array(negativeTerms.prefix(16))
            )
            let data = try await api.recommend(request)
            let response = try JSONDecoder().decode(RecommendationRankResponse.self, from: data)
            updateBackoff(enabled: response.enabled, available: response.available)
            guard response.available != false else { return nil }
            return response.scores
        } catch {
            backoffUntil = Date().addingTimeInterval(90)
            return nil
        }
    }

    func feedback(
        post: Post,
        provider: Provider,
        syncID: String,
        type: String,
        value: Double = 1,
        positiveTerms: [String],
        negativeTerms: [String]
    ) async {
        guard Date() >= backoffUntil else { return }
        do {
            let request = RecommendationFeedbackRequest(
                userId: try userID(syncID: syncID),
                source: provider.rawValue,
                item: payload(post),
                type: type,
                value: value,
                positiveTerms: Array(positiveTerms.prefix(16)),
                negativeTerms: Array(negativeTerms.prefix(16))
            )
            let data = try await api.recommend(request)
            let response = try JSONDecoder().decode(RecommendationFeedbackResponse.self, from: data)
            updateBackoff(enabled: response.enabled, available: response.available)
        } catch {
            backoffUntil = Date().addingTimeInterval(90)
        }
    }

    func reset(provider: Provider, syncID: String) async -> Bool {
        backoffUntil = .distantPast
        do {
            let request = RecommendationResetRequest(userId: try userID(syncID: syncID), source: provider.rawValue)
            let data = try await api.recommend(request)
            let response = try JSONDecoder().decode(RecommendationFeedbackResponse.self, from: data)
            backoffUntil = .distantPast
            return response.reset == true
        } catch {
            backoffUntil = Date().addingTimeInterval(90)
            return false
        }
    }

    func clearBackoff() { backoffUntil = .distantPast }

    private func updateBackoff(enabled: Bool?, available: Bool?) {
        if enabled == false { backoffUntil = Date().addingTimeInterval(10 * 60) }
        else if available == false { backoffUntil = Date().addingTimeInterval(2 * 60) }
        else { backoffUntil = .distantPast }
    }

    private func payload(_ post: Post) -> RecommendationItemPayload {
        let source = post.provider.lowercased()
        let raw = post.id.isEmpty ? post.stableID : post.id
        return RecommendationItemPayload(
            itemId: "\(source):\(String(raw.prefix(180)))",
            source: source,
            title: String((post.tags.first ?? "").prefix(300)),
            tags: Array(post.tags.map { $0.lowercased() }.prefix(32)),
            type: String(post.type.prefix(24)),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
