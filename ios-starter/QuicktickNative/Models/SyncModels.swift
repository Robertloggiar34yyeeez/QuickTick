import Foundation

struct SyncEnvelope: Codable, Equatable, Sendable {
    var v: Int
    var alg: String
    var iv: String
    var data: String
}

struct FavoriteMeta: Codable, Equatable, Sendable {
    var liked: Bool
    var updatedAt: Int64
}

struct Rule34Credentials: Codable, Equatable, Sendable {
    var userId: String = ""
    var apiKey: String = ""
    var remember: Bool = false
}

struct PornhubAuth: Codable, Equatable, Sendable {
    var username: String = ""
    var session: String = ""
}

struct TasteChoice: Codable, Equatable, Sendable {
    var done: Bool = false
    var into: [String] = []
    var notInto: [String] = []
}

struct TasteSetup: Codable, Equatable, Sendable {
    var version: Int = 2
    var done: Bool = false
    var sources: [String: TasteChoice] = [:]
}

struct SyncStamped<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var updatedAt: Int64
    var value: Value
}

struct Rule34SyncSection: Codable, Equatable, Sendable {
    var updatedAt: Int64
    var credentials: Rule34Credentials
}

struct PornhubSyncSection: Codable, Equatable, Sendable {
    var updatedAt: Int64
    var auth: PornhubAuth
}

struct ExclusionsSyncSection: Codable, Equatable, Sendable {
    var updatedAt: Int64
    var tags: [String]
}

struct PreferencesSyncSection: Codable, Equatable, Sendable {
    var updatedAt: Int64
    var value: TasteSetup
}

struct QuicktickSyncSnapshot: Codable, Equatable, Sendable {
    var version: Int = 1
    var updatedAt: Int64
    var favorites: [String: Post]
    var favoriteMeta: [String: FavoriteMeta]
    var rule34: Rule34SyncSection
    var pornhub: PornhubSyncSection
    var exclusions: ExclusionsSyncSection
    var preferences: PreferencesSyncSection
}

// Older web v1 profiles may omit metadata or sections added after their last
// upload. Preserve strict types for fields that exist and reject future schema
// versions before the store changes the connected Sync identity.
extension QuicktickSyncSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else { throw APIError.server("Unsupported Sync snapshot version") }
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        favorites = try c.decodeIfPresent([String: Post].self, forKey: .favorites) ?? [:]
        favoriteMeta = try c.decodeIfPresent([String: FavoriteMeta].self, forKey: .favoriteMeta) ?? [:]
        rule34 = try c.decodeIfPresent(Rule34SyncSection.self, forKey: .rule34) ?? .init(updatedAt: 0, credentials: .init())
        pornhub = try c.decodeIfPresent(PornhubSyncSection.self, forKey: .pornhub) ?? .init(updatedAt: 0, auth: .init())
        exclusions = try c.decodeIfPresent(ExclusionsSyncSection.self, forKey: .exclusions) ?? .init(updatedAt: 0, tags: [])
        preferences = try c.decodeIfPresent(PreferencesSyncSection.self, forKey: .preferences) ?? .init(updatedAt: 0, value: .init())
    }
}
