import Foundation

struct ProviderCredentials: Sendable {
    var rule34User = ""
    var rule34Key = ""
    var pornhubSession = ""
}

enum APIError: LocalizedError {
    case missingBaseURL, invalidResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Set QUICKTICK_API_BASE_URL to the existing Quicktick Vercel deployment."
        case .invalidResponse: "Invalid server response."
        case .server(let value): value
        }
    }
}

actor QuicktickAPIClient {
    let baseURL: URL?
    let session: URLSession
    var credentials = ProviderCredentials()

    init(baseURL: URL? = QuicktickAPIClient.configuredBaseURL(), session: URLSession = .shared) { self.baseURL = baseURL; self.session = session }

    static func configuredBaseURL() -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "QUICKTICK_API_BASE_URL") as? String,
              !raw.contains("YOUR-QUICKTICK"), let url = URL(string: raw) else { return nil }
        return url
    }

    func setCredentials(_ value: ProviderCredentials) { credentials = value }

    func request(path: String, query: [URLQueryItem] = [], method: String = "GET", jsonBody: Data? = nil) async throws -> Data {
        guard let baseURL else { throw APIError.missingBaseURL }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path), resolvingAgainstBaseURL: false) else { throw APIError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = jsonBody
        req.timeoutInterval = path == "/api/recommend" ? 5 : 20
        if jsonBody != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if path.hasPrefix("/api/rule34") || path.hasPrefix("/api/comments") {
            if !credentials.rule34User.isEmpty && !credentials.rule34Key.isEmpty {
                req.setValue(credentials.rule34User, forHTTPHeaderField: "x-r34-user")
                req.setValue(credentials.rule34Key, forHTTPHeaderField: "x-r34-key")
            }
        }
        if path.hasPrefix("/api/pornhub") && !credentials.pornhubSession.isEmpty {
            req.setValue(credentials.pornhubSession, forHTTPHeaderField: "x-ph-session")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(message ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    func posts(provider: Provider, query: ParsedQuery, page: Int, sort: String = "recommended", immersive: Bool = false) async throws -> PostPage {
        let path = "/api/\(provider.rawValue)"
        var items = [URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: "sort", value: sort)]
        let q = query.included.joined(separator: " ")
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if !query.excluded.isEmpty { items.append(URLQueryItem(name: "exclude", value: query.excluded.joined(separator: ","))) }
        if immersive { items.append(URLQueryItem(name: "mode", value: "video")) }
        let data = try await request(path: path, query: items)
        return try JSONDecoder().decode(PostPage.self, from: data)
    }

    func absoluteMediaURL(_ value: String) throws -> URL {
        guard let baseURL, let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw APIError.invalidResponse }
        return url
    }

    func comments(_ post: Post) async throws -> CommentPage {
        let data = try await request(path: "/api/comments", query: [URLQueryItem(name: "provider", value: post.providerKey?.rawValue ?? post.provider.lowercased()), URLQueryItem(name: "id", value: post.id)])
        return try JSONDecoder().decode(CommentPage.self, from: data)
    }

    func suggestions(provider: Provider, query: String) async throws -> [TagSuggestion] {
        struct Response: Decodable { let suggestions: [TagSuggestion] }
        let data = try await request(path: "/api/suggest", query: [URLQueryItem(name: "source", value: provider.rawValue), URLQueryItem(name: "q", value: query)])
        return try JSONDecoder().decode(Response.self, from: data).suggestions
    }


    func recommend<T: Encodable>(_ body: T) async throws -> Data {
        let encoded = try JSONEncoder().encode(body)
        return try await request(path: "/api/recommend", method: "POST", jsonBody: encoded)
    }

    func sync(action: String, recordID: String, verifier: String, payload: SyncEnvelope? = nil) async throws -> Data {
        var obj: [String: Any] = ["action": action, "id": recordID, "verifier": verifier]
        if let payload {
            let encoded = try JSONEncoder().encode(payload)
            obj["payload"] = try JSONSerialization.jsonObject(with: encoded)
        }
        let body = try JSONSerialization.data(withJSONObject: obj)
        return try await request(path: "/api/sync", method: "POST", jsonBody: body)
    }
}
