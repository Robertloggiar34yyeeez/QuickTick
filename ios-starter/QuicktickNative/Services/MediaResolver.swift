import Foundation

struct ResolvedMedia: Codable, Sendable {
    var mediaUrl: String
    var type: String
    var mediaUrlURL: URL? { URL(string: mediaUrl) }
}

actor MediaResolver {
    let api: QuicktickAPIClient
    private var cache: [String: (ResolvedMedia, Date)] = [:]
    private var waiters: [String:Set<UUID>] = [:]
    private var inFlight: [String: Task<ResolvedMedia, Error>] = [:]
    init(api: QuicktickAPIClient) { self.api = api }

    private func identity(_ post: Post) -> String { "\(post.stableID)|\(post.mediaUrl)|\(post.type)" }
    func resolve(_ post: Post) async throws -> ResolvedMedia {
        let key = identity(post)
        if let (media,date) = cache[key], Date().timeIntervalSince(date) < 180 { return media }
        let task: Task<ResolvedMedia,Error>
        if let shared = inFlight[key] { task = shared }
        else { task = Task { try await self.fetch(post) }; inFlight[key] = task }
        let waiter = UUID();waiters[key,default:[]].insert(waiter)
        return try await withTaskCancellationHandler {
            defer { finish(key,waiter:waiter,cancel:false) }
            let value = try await task.value;try Task.checkCancellation();return value
        } onCancel: { Task { await self.finish(key,waiter:waiter,cancel:true) } }
    }
    private func finish(_ key: String,waiter: UUID,cancel: Bool) {
        guard waiters[key]?.remove(waiter) != nil else { return }
        if waiters[key]?.isEmpty == true {
            if cancel { inFlight[key]?.cancel() }
            inFlight.removeValue(forKey:key);waiters.removeValue(forKey:key)
        }
    }

    private func fetch(_ post: Post) async throws -> ResolvedMedia {
        if let (media, date) = cache[identity(post)], Date().timeIntervalSince(date) < 180 { return media }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), URL(string: post.mediaUrl)?.isFileURL == true { return ResolvedMedia(mediaUrl: post.mediaUrl, type: post.type) }
        #endif
        let media = try await api.resolveMedia(post)
        cache[identity(post)] = (media, .now)
        if cache.count > 40 { cache.removeValue(forKey: cache.min { $0.value.1 < $1.value.1 }!.key) }
        return media
    }
}
