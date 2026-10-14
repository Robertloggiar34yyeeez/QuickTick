import Foundation

struct ProviderCredentials: Sendable {
    var rule34User = ""
    var rule34Key = ""
    var pornhubSession = ""
}

enum APIError: LocalizedError {
    case missingBaseURL, invalidResponse, server(String), providerStatus(Provider, Int)
    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Optional website Sync has no configured HTTPS server. Feeds do not need it."
        case .invalidResponse: "Invalid server response."
        case .server(let value): value
        case .providerStatus(let provider, let status): "\(provider.displayName) returned HTTP \(status). Check provider access or try again later."
        }
    }
}

actor QuicktickAPIClient {
    let baseURL: URL?
    let session: URLSession
    var credentials = ProviderCredentials()
    private var cloudSyncEnabled = false
    private let redgifsAuth = RedgifsAuthentication()

    init(baseURL: URL? = QuicktickAPIClient.configuredBaseURL(), session: URLSession = .shared, credentials: ProviderCredentials = ProviderCredentials(), cloudSyncEnabled: Bool = false) {
        self.credentials = credentials
        self.cloudSyncEnabled = cloudSyncEnabled
        self.baseURL = baseURL
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-sync-login") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UITestSyncProtocol.self]
            self.session = URLSession(configuration: configuration)
        } else { self.session = session }
        #else
        self.session = session
        #endif
    }

    static func configuredBaseURL() -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "QUICKTICK_API_BASE_URL") as? String,
              !raw.contains("YOUR-QUICKTICK"), let url = URL(string: raw) else { return nil }
        return url
    }

    func setCredentials(_ value: ProviderCredentials) { credentials = value }
    func setCloudSyncEnabled(_ value: Bool) { cloudSyncEnabled = value }

    func request(path: String, query: [URLQueryItem] = [], method: String = "GET", jsonBody: Data? = nil) async throws -> Data {
        guard path == "/api/sync", cloudSyncEnabled else { throw APIError.server("Website Sync is off. Enable it explicitly in Settings.") }
        guard let baseURL else { throw APIError.missingBaseURL }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path), resolvingAgainstBaseURL: false) else { throw APIError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = jsonBody
        req.timeoutInterval = 20
        if jsonBody != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        #if DEBUG
        // URLProtocol may receive POST bodies as inaccessible streams. Preserve the
        // operation for the in-process UI test server, before Foundation adapts it.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-sync-login"), path == "/api/sync", let jsonBody,
           let body = (try? JSONSerialization.jsonObject(with: jsonBody)) as? [String: Any], let action = body["action"] as? String {
            req.setValue(action, forHTTPHeaderField: "x-quicktick-test-action")
        }
        #endif
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(message ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    func posts(provider: Provider, query: ParsedQuery, page: Int, sort: String = "recommended", immersive: Bool = false) async throws -> PostPage {
        switch provider {
        case .rule34: return try await NativeProviderAPI.rule34(session: session, credentials: credentials, query: query, page: page, sort: sort, immersive: immersive)
        case .eporner: return try await NativeProviderAPI.eporner(session: session, query: query, page: page, sort: sort, immersive: immersive)
        case .pornhub: return try await NativeProviderAPI.pornhub(session: session, credentials: credentials, query: query, page: page, sort: sort, immersive: immersive)
        case .hanime: return try await NativeProviderAPI.hanime(session: session, query: query, page: page, sort: sort, immersive: immersive)
        case .redgifs:
            let token = try await redgifsAuth.value(session: session)
            do { return try await NativeProviderAPI.redgifs(session: session, token: token, query: query, page: page, sort: sort, immersive: immersive) }
            catch {
                guard !Task.isCancelled, let failure = error as? APIError, case .providerStatus(.redgifs, 401) = failure else { throw error }
                await redgifsAuth.invalidate(expecting: token)
                return try await NativeProviderAPI.redgifs(session: session, token: redgifsAuth.value(session: session), query: query, page: page, sort: sort, immersive: immersive)
            }
        }
    }

    func absoluteMediaURL(_ value: String, provider: Provider? = nil) throws -> URL {
        guard let url = NativeProviderAPI.mediaURL(value, provider: provider) else { throw APIError.invalidResponse }
        return url
    }

    func resolveMedia(_ post: Post) async throws -> ResolvedMedia {
        let token = post.providerKey == .redgifs && NativeProviderAPI.mediaURL(post.mediaUrl, provider: .redgifs) == nil ? try await redgifsAuth.value(session: session) : nil
        return try await NativeProviderAPI.resolve(session: session, credentials: credentials, post: post, redgifsToken: token)
    }

    func comments(_ post: Post) async throws -> CommentPage {
        try await NativeProviderAPI.comments(session: session, credentials: credentials, post: post)
    }

    func suggestions(provider: Provider, query: String) async throws -> [TagSuggestion] {
        guard provider == .rule34, !query.isEmpty else { return [] }
        let bytes = try await NativeProviderAPI.data(session: session, url: NativeProviderAPI.url("https://api.rule34.xxx/autocomplete.php", [.init(name: "q", value: query.replacingOccurrences(of: " ", with: "_"))]), provider: provider)
        let rows = NativeProviderAPI.rows(try JSONSerialization.jsonObject(with: bytes))
        return rows.prefix(10).compactMap { row in
            guard let value = row["value"] as? String, !value.isEmpty else { return nil }
            return TagSuggestion(value: value, label: row["label"] as? String ?? value, count: Int(NativeProviderAPI.number(row["count"])))
        }
    }

    // Retained for decoding old test/profile identities. Remote ranking and
    // feedback are disabled: the app's recommender is entirely local.
    func recommend<T: Encodable>(_ body: T) async throws -> Data {
        throw APIError.server("Remote recommendation uploads are disabled.")
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
