import Foundation

/// Value snapshot owned by AppStore: filtering never queues behind a model actor.
struct FeedExclusions: Sendable {
    private(set) var recent: [String] = []
    private var recentSet: Set<String> = []
    private(set) var fingerprints: [String: UInt64] = [:]
    mutating func restore(_ ids: [String]) {
        recent = Array(ids.suffix(2048)); recentSet = Set(recent)
    }
    mutating func viewed(_ post: Post) {
        let keys = Self.identifiers(post)
        recent.removeAll { keys.contains($0) }; recent.append(contentsOf: keys.sorted())
        recent = Array(recent.suffix(2048)); recentSet = Set(recent)
    }
    mutating func setFingerprints(_ values: [String: UInt64]) { fingerprints = values }
    static func identifiers(_ post: Post) -> Set<String> {
        var result: Set<String> = [post.stableID, "id:\(post.provider.lowercased()):\(post.id)"]
        // Compare complete canonical URLs, never a filename or an ID across hosts.
        for raw in [post.mediaUrl, post.pageUrl] where !raw.isEmpty {
            guard var url = URLComponents(string: raw), url.host != nil else { continue }
            url.scheme = "https"; url.host = url.host?.lowercased(); url.fragment = nil
            url.queryItems = url.queryItems?.filter { !["token", "expires", "signature"].contains($0.name.lowercased()) }
                .sorted { $0.name < $1.name }
            if url.queryItems?.isEmpty == true { url.query = nil }
            if let canonical = url.string { result.insert("url:" + canonical) }
        }
        return result
    }
    static func nearDuplicate(_ a: UInt64, _ b: UInt64) -> Bool { (a ^ b).nonzeroBitCount <= 3 }
    func filter(_ candidates: [Post], favorites: [Post], existing: [Post] = [], recommended: Bool) -> [Post] {
        var used = Set(existing.flatMap { Self.identifiers($0) })
        let liked = Set(favorites.flatMap { Self.identifiers($0) })
        let excludedHashes = (recommended ? favorites.map(\.stableID) + recent : []) + existing.map(\.stableID)
        var hashes = excludedHashes.compactMap { fingerprints[$0] }
        return candidates.filter { post in
            let ids = Self.identifiers(post)
            guard used.isDisjoint(with: ids), !recommended || (liked.isDisjoint(with: ids) && recentSet.isDisjoint(with: ids)) else { return false }
            if let hash = fingerprints[post.stableID] {
                guard !hashes.contains(where: { Self.nearDuplicate(hash, $0) }) else { return false }
                hashes.append(hash)
            }
            used.formUnion(ids); return true
        }
    }
}
