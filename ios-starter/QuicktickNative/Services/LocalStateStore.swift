import Foundation

struct LocalAppState: Codable {
    var version = 1
    var snapshot = QuicktickSyncSnapshot.empty
    var resumePositions: [String: Double] = [:]
    var immersionFraming = false
    var muted = false
    var audioPreferenceVersion: Int? = nil
    // Missing in older state files deliberately means OFF on upgrade.
    var cloudSyncEnabled: Bool? = nil
}

struct LocalStateStore {
    let url: URL
    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quicktick")
        url = directory.appendingPathComponent("app-state-v1.json")
    }
    func load() throws -> LocalAppState {
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalAppState() }
        let state = try JSONDecoder().decode(LocalAppState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw APIError.server("Unsupported local state version. The original file has been preserved.") }
        return state
    }
    func save(_ state: LocalAppState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Fast launch metadata snapshot. This is distinct from recommendation
/// training state: a feed preview can be discarded without losing taste,
/// dislikes, downloads, or user settings.
struct FeedPreviewSnapshot: Codable, Sendable {
    let provider: Provider
    let query: String
    let sort: String
    let mediaOnly: Bool
    let savedAt: Date
    let posts: [Post]
}

actor FeedPreviewPersistence {
    private let url: URL
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quicktick", isDirectory: true)
        url = base.appendingPathComponent("feed-preview-v1.json")
    }

    func load(provider: Provider, query: String, sort: String, mediaOnly: Bool) -> [Post] {
        guard let snapshot = validSnapshot(at: providerURL(provider)) ?? validSnapshot(),
              snapshot.provider == provider, snapshot.query == query,
              snapshot.sort == sort, snapshot.mediaOnly == mediaOnly else { return [] }
        return Array(snapshot.posts.prefix(48))
    }

    private func providerURL(_ provider: Provider) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("feed-preview-v1-\(provider.rawValue).json")
    }

    func recentProvider() -> Provider? {
        guard let snapshot = validSnapshot(), snapshot.query.isEmpty,
              snapshot.sort == "recommended", !snapshot.mediaOnly else { return nil }
        return snapshot.provider
    }

    private func validSnapshot() -> FeedPreviewSnapshot? {
        validSnapshot(at: url)
    }

    private func validSnapshot(at path: URL) -> FeedPreviewSnapshot? {
        guard let data = try? Data(contentsOf: path),
              let snapshot = try? JSONDecoder().decode(FeedPreviewSnapshot.self, from: data),
              snapshot.savedAt > Date().addingTimeInterval(-30 * 24 * 60 * 60) else { return nil }
        return snapshot
    }

    func save(_ posts: [Post], provider: Provider, query: String, sort: String, mediaOnly: Bool) {
        // Only the normal Recommended Home feed is restored at launch. A
        // temporary search, Popular tab or immersive clip page must not evict
        // the last usable startup snapshot.
        guard !posts.isEmpty, query.isEmpty, sort == "recommended", !mediaOnly else { return }
        let snapshot = FeedPreviewSnapshot(provider: provider, query: query, sort: sort,
                                           mediaOnly: mediaOnly, savedAt: .now,
                                           posts: Array(posts.prefix(48)))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(snapshot)
            try bytes.write(to: providerURL(provider), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // Retain the legacy last-successful snapshot for existing installs
            // and old builds. New builds also keep each provider independently.
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A temporary disk/file-protection failure must never make a
            // healthy network feed fail to render on its first paint.
        }
    }
}

extension QuicktickSyncSnapshot {
    static var empty: Self {
        Self(updatedAt: 0, favorites: [:], favoriteMeta: [:], rule34: .init(updatedAt: 0, credentials: .init()), pornhub: .init(updatedAt: 0, auth: .init()), exclusions: .init(updatedAt: 0, tags: []), preferences: .init(updatedAt: 0, value: .init()))
    }

    func merging(_ remote: Self) throws -> Self {
        guard remote.version == 1 else { throw APIError.server("Unsupported Sync snapshot version") }
        var result = self
        let keys = Set(favoriteMeta.keys).union(remote.favoriteMeta.keys).union(favorites.keys).union(remote.favorites.keys)
        for key in keys {
            let local = favoriteMeta[key] ?? (favorites[key] == nil ? nil : FavoriteMeta(liked: true, updatedAt: 0))
            let other = remote.favoriteMeta[key] ?? (remote.favorites[key] == nil ? nil : FavoriteMeta(liked: true, updatedAt: max(1, remote.updatedAt)))
            guard let other, local == nil || other.updatedAt > local!.updatedAt else { continue }
            result.favoriteMeta[key] = other
            result.favorites[key] = other.liked ? remote.favorites[key] : nil
        }
        if remote.rule34.updatedAt > rule34.updatedAt || ((rule34.credentials.userId + rule34.credentials.apiKey).isEmpty && !(remote.rule34.credentials.userId + remote.rule34.credentials.apiKey).isEmpty) { result.rule34 = remote.rule34 }
        if remote.pornhub.updatedAt > pornhub.updatedAt || ((pornhub.auth.username + pornhub.auth.session).isEmpty && !(remote.pornhub.auth.username + remote.pornhub.auth.session).isEmpty) { result.pornhub = remote.pornhub }
        if remote.exclusions.updatedAt > exclusions.updatedAt { result.exclusions = remote.exclusions }
        if remote.preferences.updatedAt > preferences.updatedAt { result.preferences = remote.preferences }
        result.updatedAt = max(updatedAt, remote.updatedAt)
        return result
    }
}
