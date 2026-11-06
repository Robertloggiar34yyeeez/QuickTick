import Foundation
import CryptoKit

/// Optional transport for the user-supplied, self-hosted Hanime API.
/// The iOS app never assumes the Node service is running on the phone.
enum HanimeGeneratedAPI {
    static let settingKey = "quicktick-hanime-api-url"

    static func mediaHeaders(for url: URL) -> [String: String] {
        guard url.scheme == "https" else { return [:] }
        let isStream = permittedStreamURL(url)
        let isPoster = url.host == "cdn.hanime.tv" &&
            ["jpg", "jpeg", "png", "webp", "avif"].contains(url.pathExtension.lowercased())
        if isStream {
            return ["Referer": "https://player.hanime.tv/", "Origin": "https://player.hanime.tv"]
        }
        return isPoster ? ["Referer": "https://hanime.tv/"] : [:]
    }

    /// Self-hosted adapters may return either Hanime's HLS path or a signed
    /// playlist/file on its official media CDN. Both are first-party hosts;
    /// do not accept arbitrary third-party download URLs from an adapter.
    static func permittedStreamURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return false }
        if url.host == "hanime.tv", url.path.hasPrefix("/hls/") { return true }
        return url.host == "cdn.hanime.tv" &&
            ["m3u8", "mp4", "m4v"].contains(url.pathExtension.lowercased())
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
        guard let url = URL(string: media.mediaUrl), permittedStreamURL(url) else {
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


/// Matches the current first-party v11 player handshake token format.
/// Only authenticated AES-GCM payloads are accepted; malformed headers fail
/// closed rather than being interpreted as stream URLs.
enum HanimeHandshakeCodec {
    private static let key = SymmetricKey(data: Data(SHA256.hash(
        data: Data("htv-insecure-handshake-v1".utf8))))
    private static let associatedData = Data("htv-insecure-v1".utf8)

    static func seal(_ payload: Data) throws -> String {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(payload, using: key, nonce: nonce,
                                      authenticating: associatedData)
        let envelope: [String: Any] = [
            "v": 1, "alg": "AES-256-GCM",
            "iv": nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            "tag": sealed.tag.base64EncodedString(),
            "data": sealed.ciphertext.base64EncodedString()
        ]
        return try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
    }

    static func open(_ token: String) throws -> Data {
        guard let envelopeBytes = decodeBase64(token),
              let envelope = try JSONSerialization.jsonObject(with: envelopeBytes) as? [String: Any],
              envelope["v"] as? Int == 1, envelope["alg"] as? String == "AES-256-GCM",
              let ivText = envelope["iv"] as? String, let tagText = envelope["tag"] as? String,
              let ciphertextText = envelope["data"] as? String,
              let iv = decodeBase64(ivText), iv.count == 12,
              let tag = decodeBase64(tagText), tag.count == 16,
              let ciphertext = decodeBase64(ciphertextText) else {
            throw APIError.invalidResponse
        }
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: associatedData)
    }

    private static func decodeBase64(_ token: String) -> Data? {
        let normalized = token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        return Data(base64Encoded: normalized + String(repeating: "=", count: padding))
    }
}
