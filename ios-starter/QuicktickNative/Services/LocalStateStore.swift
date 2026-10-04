import Foundation

struct LocalAppState: Codable {
    var version = 1
    var snapshot = QuicktickSyncSnapshot.empty
    var resumePositions: [String: Double] = [:]
    var immersionFraming = false
    var muted = false
    var audioPreferenceVersion: Int? = nil
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
