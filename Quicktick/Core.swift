import Foundation
import Security

enum SourceID: String, CaseIterable, Codable, Identifiable {
    case danbooru = "Danbooru"
    case redgifs = "RedGIFs"
    var id: String { rawValue }
}

enum MediaKind: String, Codable { case image, animation, video }
enum FeedSort: String, CaseIterable, Codable, Identifiable {
    case recommended = "Recommended", popular = "Popular", score = "Score", recent = "Recent"
    var id: String { rawValue }
}

struct Post: Identifiable, Codable, Hashable {
    let id: String
    let source: SourceID
    let sourceID: String
    let kind: MediaKind
    let previewURL: URL
    let mediaURL: URL
    let pageURL: URL
    let tags: [String]
    let score: Int
    let rating: String?
    let width: Int
    let height: Int
    var title: String { tags.prefix(4).joined(separator: " · ").replacingOccurrences(of: "_", with: " ") }
}

struct Page { let posts: [Post]; let nextCursor: String? }
struct FeedQuery {
    var tags: [String] = []
    var exclusions: [String] = []
    var sort: FeedSort = .popular
    var animatedOnly = false
    var cursor: String? = nil
}

enum NetworkError: LocalizedError {
    case invalidResponse, http(Int), rateLimited, offline, badData, noMedia
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The service returned an invalid response."
        case .http(let code): "The service returned HTTP \(code)."
        case .rateLimited: "The service is rate limiting requests. Please retry shortly."
        case .offline: "You appear to be offline."
        case .badData: "The service returned data Quicktick could not read."
        case .noMedia: "This post has no accessible media."
        }
    }
}

struct HTTPClient {
    var session: URLSession = .shared
    func data(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
            if http.statusCode == 429 { throw NetworkError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw NetworkError.http(http.statusCode) }
            return data
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw NetworkError.offline
        }
    }
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Quicktick/1.0 (iOS media browser)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await data(request)
    }
}

protocol MediaProvider {
    var id: SourceID { get }
    var supportedSorts: [FeedSort] { get }
    func fetch(_ query: FeedQuery) async throws -> Page
    func suggestions(for prefix: String) async throws -> [String]
    func testConnection() async throws
}

enum Keychain {
    static func set(_ value: String, for key: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.quicktick.ios", kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NetworkError.http(Int(status)) }
    }
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.quicktick.ios", kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.quicktick.ios", kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

enum TagRules {
    static func normalized(_ tag: String) -> String { tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
    static func allowed(_ post: Post, exclusions: [String]) -> Bool {
        let blocked = Set(exclusions.map(normalized))
        return blocked.isDisjoint(with: post.tags.map(normalized))
    }
    static func terms(_ input: String) -> [String] {
        input.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { normalized(String($0)) }.filter { !$0.isEmpty }
    }
}

struct RecommendationEngine {
    static func topTags(from signals: [String: Double], excluded: [String], limit: Int = 2) -> [String] {
        let blocked = Set(excluded.map(TagRules.normalized))
        return signals.filter { $0.value > 1 && !blocked.contains($0.key) }.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
    static func record(_ post: Post, weight: Double, into signals: inout [String: Double]) {
        for tag in post.tags.prefix(30) { signals[TagRules.normalized(tag), default: 0] += weight }
    }
}
