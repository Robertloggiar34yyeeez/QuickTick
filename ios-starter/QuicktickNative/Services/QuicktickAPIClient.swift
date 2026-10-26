import Foundation

struct ProviderCredentials: Sendable {
    var rule34User = ""
    var rule34Key = ""
    var pornhubSession = ""
}

struct ArchiveCreator: Codable, Sendable {
    let name: String
    let service: String
    let id: String
    let favorites: Int
    var reference: String { "creator:\(service):\(id)" }
}

enum APIError: LocalizedError {
    case missingBaseURL, invalidResponse, server(String), providerStatus(Provider, Int)
    case rateLimited(Provider, Date)
    var retryAfter: Date? {
        if case .rateLimited(_, let date) = self { return date }
        return nil
    }
    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Optional website Sync has no configured HTTPS server. Feeds do not need it."
        case .invalidResponse: "Invalid server response."
        case .server(let value): value
        case .rateLimited(let provider, let date): "\(provider.displayName) is temporarily limiting requests. \(date.timeIntervalSinceNow > 86400 ? "Please try again later." : "Try again in \(max(1, Int(ceil(date.timeIntervalSinceNow)))) seconds.")"
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
    private var archivePages: [String: (page: PostPage, expiry: Date)] = [:]
    private var archivePageTasks: [String: Task<PostPage, Error>] = [:]
    private var archiveCreators: [Provider: [ArchiveCreator]] = [:]
    private var archiveCreatorTasks: [Provider: Task<[ArchiveCreator], Error>] = [:]

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
        case .coomer, .kemono:
            return try await cachedArchivePosts(provider: provider, query: query, page: page, immersive: immersive)
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

    private func cachedArchivePosts(provider: Provider, query: ParsedQuery, page: Int,
                                    immersive: Bool) async throws -> PostPage {
        let key = "\(provider.rawValue)|\(page)|\(immersive)|\(QueryParser.formatted(query))"
        if let entry = archivePages[key], entry.expiry > .now { return entry.page }
        if let running = archivePageTasks[key] { return try await running.value }
        let session = self.session
        let task = Task {
            try await NativeProviderAPI.archivePosts(session: session, provider: provider,
                                                      query: query, page: page, immersive: immersive)
        }
        archivePageTasks[key] = task
        defer { archivePageTasks.removeValue(forKey: key) }
        let result = try await task.value
        // Archive APIs and attachment normalization can be slow. Keep a short
        // in-memory window for instant tab returns and for a broad query that
        // finished after the focused query was already shown to the user.
        archivePages[key] = (result, .now.addingTimeInterval(120))
        if archivePages.count > 40 { archivePages = archivePages.filter { $0.value.expiry > .now } }
        return result
    }

    private func creatorCacheURL(for provider: Provider) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("quicktick-\(provider.rawValue)-creators-v1.json")
    }

    private func creators(for provider: Provider) async throws -> [ArchiveCreator] {
        if let cached = archiveCreators[provider] { return cached }
        if let running = archiveCreatorTasks[provider] { return try await running.value }
        if let file = creatorCacheURL(for: provider),
           let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 3 * 86_400,
           let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode([ArchiveCreator].self, from: data), !cached.isEmpty {
            archiveCreators[provider] = cached
            return cached
        }
        let session = self.session
        let running = Task { try await NativeProviderAPI.archiveCreators(session: session, provider: provider) }
        archiveCreatorTasks[provider] = running
        defer { archiveCreatorTasks[provider] = nil }
        let result = try await running.value
        archiveCreators[provider] = result
        if let file = creatorCacheURL(for: provider), let data = try? JSONEncoder().encode(result) {
            try? data.write(to: file, options: .atomic)
        }
        return result
    }

    func prefetchArchiveCreators(for provider: Provider) async {
        guard provider == .kemono || provider == .coomer else { return }
        _ = try? await creators(for: provider)
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
        guard !query.isEmpty else { return [] }
        if provider == .coomer || provider == .kemono {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard needle.count >= 2 else { return [] }
            let entries = try await creators(for: provider)
            return entries.filter { $0.name.localizedLowercase.contains(needle) }
                .sorted {
                    let a = $0.name.localizedLowercase.hasPrefix(needle)
                    let b = $1.name.localizedLowercase.hasPrefix(needle)
                    if a != b { return a }
                    if $0.favorites != $1.favorites { return $0.favorites > $1.favorites }
                    return $0.name.localizedCompare($1.name) == .orderedAscending
                }
                .prefix(10).map {
                    TagSuggestion(value: $0.reference, label: "\($0.name) · \($0.service)", count: $0.favorites)
                }
        }
        guard provider == .rule34 else { return [] }
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
