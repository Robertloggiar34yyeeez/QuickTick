import Foundation

/// Optional read-only API built from the user-supplied Erome adapter package.
/// Default browsing still talks to Erome directly when no endpoint is configured.
enum EromeGeneratedAPI {
    static let settingKey = "quicktick-erome-api-url"

    static var configuredURL: URL? {
        let raw = UserDefaults.standard.string(forKey: settingKey) ?? ""
        return HanimeGeneratedAPI.validatedURL(raw)
    }

    static func mediaHeaders(for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased(), url.scheme == "https",
              host == "erome.com" || host.hasSuffix(".erome.com") else { return [:] }
        return ["Referer": "https://www.erome.com/"]
    }

    static func listingURL(base: URL, query: ParsedQuery, page: Int, sort: String,
                           immersive: Bool) throws -> URL {
        guard (1...1000).contains(page) else { throw APIError.invalidResponse }
        var parts = URLComponents(url: base.appendingPathComponent("v1/posts"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "q", value: query.included.joined(separator: " ")),
                            .init(name: "exclude", value: query.excluded.joined(separator: ",")),
                            .init(name: "page", value: String(page)),
                            .init(name: "sort", value: sort == "recent" ? "recent" : "recommended"),
                            .init(name: "immersive", value: immersive ? "true" : "false")]
        guard let address = parts.url else { throw APIError.invalidResponse }
        return address
    }

    static func posts(session: URLSession, base: URL, query: ParsedQuery, page: Int,
                      sort: String, immersive: Bool) async throws -> PostPage {
        let bytes = try await fetch(session: session, url: listingURL(base: base, query: query,
                                                                      page: page, sort: sort, immersive: immersive))
        let response = try JSONDecoder().decode(PostPage.self, from: bytes)
        return NativeProviderAPI.page(response.items.filter { $0.providerKey == .erome },
                                      hasMore: response.hasMore ?? false, query: query, immersive: immersive)
    }

    static func resolve(session: URLSession, base: URL, post: Post) async throws -> ResolvedMedia {
        let id = String(post.id.split(separator: ":", maxSplits: 1).first ?? "")
        guard id.range(of: #"^[A-Za-z0-9]{6,16}$"#, options: .regularExpression) != nil else {
            throw APIError.invalidResponse
        }
        let bytes = try await fetch(session: session, url: base.appendingPathComponent("v1/albums").appendingPathComponent(id))
        let albums = try JSONDecoder().decode(PostPage.self, from: bytes)
        guard let candidate = albums.items.first(where: { $0.type == "video" }) ?? albums.items.first,
              NativeProviderAPI.mediaURL(candidate.mediaUrl, provider: .erome) != nil else {
            throw APIError.server("Erome has no accessible media in this album.")
        }
        return ResolvedMedia(mediaUrl: candidate.mediaUrl, type: candidate.type)
    }

    private static func fetch(session: URLSession, url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, bytes.count <= 3 * 1024 * 1024 else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["error"] as? String
            throw APIError.server(message ?? "Erome API HTTP \(http.statusCode)")
        }
        return bytes
    }
}
