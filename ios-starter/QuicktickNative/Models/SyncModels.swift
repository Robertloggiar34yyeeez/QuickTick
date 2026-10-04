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
