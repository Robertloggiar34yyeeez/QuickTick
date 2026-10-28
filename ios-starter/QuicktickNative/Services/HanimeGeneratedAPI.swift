import Foundation

/// Optional transport for the user-supplied, self-hosted Hanime API.
/// The iOS app never assumes the Node service is running on the phone.
enum HanimeGeneratedAPI {
    static let settingKey = "quicktick-hanime-api-url"

    static func mediaHeaders(for url: URL) -> [String: String] {
        url.scheme == "https" && url.host == "hanime.tv" && url.path.hasPrefix("/hls/")
            ? ["Referer": "https://hanime.tv/"] : [:]
    }

    static var configuredURL: URL? {
        let value = UserDefaults.standard.string(forKey: settingKey)
            ?? (Bundle.main.object(forInfoDictionaryKey: "QUICKTICK_HANIME_API_URL") as? String)
            ?? ""
        return validatedURL(value)
    }

    static func validatedURL(_ raw: String) -> URL? {
        guard let value = URL(string: raw), let host = value.host,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.scheme == "https" || (value.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
        return value
    }

    static func listingURL(base: URL, query: ParsedQuery, page: Int, sort: String) throws -> URL {
        guard (1...1000).contains(page) else { throw APIError.invalidResponse }
        var parts = URLComponents(url: base.appendingPathComponent("v1/posts"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "q", value: query.included.joined(separator: " ")),
                            .init(name: "include", value: ""),
                            .init(name: "exclude", value: query.excluded.joined(separator: ",")),
                            .init(name: "page", value: String(page)),
                            .init(name: "sort", value: sort == "recent" ? "recent" : (sort == "popular" ? "popular" : "recommended"))]
        guard let address = parts.url else { throw APIError.invalidResponse }
        return address
    }

    static func posts(session: URLSession, base: URL, query: ParsedQuery, page: Int, sort: String,
                      immersive: Bool) async throws -> PostPage {
        let bytes = try await fetch(session: session, url: listingURL(base: base, query: query, page: page, sort: sort))
        let response = try JSONDecoder().decode(PostPage.self, from: bytes)
        return NativeProviderAPI.page(response.items.filter { $0.providerKey == .hanime },
                                      hasMore: response.hasMore ?? false, query: query, immersive: immersive)
    }

    static func resolve(session: URLSession, base: URL, post: Post) async throws -> ResolvedMedia {
        guard post.id.count <= 160,
              post.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw APIError.invalidResponse
        }
        let bytes = try await fetch(session: session,
                                    url: base.appendingPathComponent("v1/resolve").appendingPathComponent(post.id))
        let media = try JSONDecoder().decode(ResolvedMedia.self, from: bytes)
        guard let url = URL(string: media.mediaUrl), url.scheme == "https",
              url.host == "hanime.tv", url.path.hasPrefix("/hls/") else {
            throw APIError.server("Hanime did not provide a permitted HLS stream.")
        }
        return media
    }

    private static func fetch(session: URLSession, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, bytes.count <= 2 * 1024 * 1024 else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["error"] as? String
            throw APIError.server(message ?? "Hanime API HTTP \(http.statusCode)")
        }
        return bytes
    }
}
