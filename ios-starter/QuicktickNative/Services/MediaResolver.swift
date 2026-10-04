import Foundation

struct ResolvedMedia: Codable, Sendable {
    var mediaUrl: String
    var type: String
}

actor MediaResolver {
    let api: QuicktickAPIClient
    private var cache: [String: (ResolvedMedia, Date)] = [:]
    init(api: QuicktickAPIClient) { self.api = api }

    func resolve(_ post: Post) async throws -> ResolvedMedia {
        if let (media, date) = cache[post.stableID], Date().timeIntervalSince(date) < 180 { return media }
        if (post.providerKey == .rule34 || post.type == "image" || post.type == "gif"), !post.mediaUrl.isEmpty {
            return ResolvedMedia(mediaUrl: post.mediaUrl, type: post.type)
        }
        let path: String
        switch post.provider.lowercased() {
        case "pornhub": path = "/api/pornhub-media"
        case "eporner": path = "/api/eporner-media"
        case "hanime": path = "/api/hanime-media"
        case "redgifs": path = "/api/redgifs-media"
        default: return ResolvedMedia(mediaUrl: post.mediaUrl, type: post.type)
        }
        let data = try await api.request(path: path, query: [URLQueryItem(name: "id", value: post.id), URLQueryItem(name: "json", value: "1")])
        var media = try JSONDecoder().decode(ResolvedMedia.self, from: data)
        guard !media.mediaUrl.isEmpty else { throw APIError.invalidResponse }
        // RedGIFs always uses the validated, Range-compatible Vercel proxy.
        if post.providerKey == .redgifs {
            media.mediaUrl = "/api/redgifs-media?id=\(post.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? post.id)"
        }
        media.mediaUrl = try await api.absoluteMediaURL(media.mediaUrl).absoluteString
        cache[post.stableID] = (media, .now)
        if cache.count > 12 { cache.removeValue(forKey: cache.min { $0.value.1 < $1.value.1 }!.key) }
        return media
    }
}
