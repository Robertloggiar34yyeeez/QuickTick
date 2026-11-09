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

/// HHaven's Warden token is scoped to the Hentai Haven API. Coalesce initial
/// requests so search, Home and Immersive never compete to obtain a token.
actor HavenAuthentication {
    private var token: String?
    private var expires = Date.distantPast
    private var flight: Task<String, Error>?
    private var unavailableUntil = Date.distantPast

    func value(session: URLSession) async throws -> String {
        if let token, expires > .now { return token }
        if let flight { return try await flight.value }
        // The Warden endpoint often fails independently of the public site.
        // Do not spend another six seconds and another request on each Home
        // refresh while the first failure is still fresh.
        if unavailableUntil > .now {
            throw APIError.server("Hentai Haven authentication is temporarily unavailable; checking its public catalog.")
        }
        let pending = Task { try await NativeProviderAPI.havenToken(session: session) }
        flight = pending
        defer { flight = nil }
        do {
            let issued = try await pending.value
            token = issued
            expires = .now.addingTimeInterval(20 * 60)
            unavailableUntil = .distantPast
            return issued
        } catch {
            if !Task.isCancelled { unavailableUntil = .now.addingTimeInterval(30) }
            throw error
        }
    }

    func invalidate(expecting stale: String) {
        guard token == stale else { return }
        token = nil; expires = .distantPast
    }
}

actor QuicktickAPIClient {
    let baseURL: URL?
    let session: URLSession
    var credentials = ProviderCredentials()
    private var cloudSyncEnabled = false
    private let redgifsAuth = RedgifsAuthentication()
    private let havenAuth = HavenAuthentication()
    private var havenPages: [String: (page: PostPage, expiry: Date)] = [:]
    private var havenPageTasks: [String: Task<PostPage, Error>] = [:]
    private var nhentaiPages: [String: (page: PostPage, expiry: Date)] = [:]
    private var nhentaiPageTasks: [String: Task<PostPage, Error>] = [:]
    private var eromePages: [String: (page: PostPage, expiry: Date)] = [:]
    private var eromePageTasks: [String: Task<PostPage, Error>] = [:]
    private var hanimePages: [String: (page: PostPage, expiry: Date)] = [:]
    private var hanimePageTasks: [String: Task<PostPage, Error>] = [:]
    private var rule34WarmPage: (page: PostPage, expires: Date)?
    private var rule34WarmTask: Task<PostPage, Error>?
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

    func setCredentials(_ value: ProviderCredentials) {
        if credentials.rule34User != value.rule34User || credentials.rule34Key != value.rule34Key {
            rule34WarmTask?.cancel()
            rule34WarmTask = nil
            rule34WarmPage = nil
        }
        credentials = value
    }
    func setCloudSyncEnabled(_ value: Bool) { cloudSyncEnabled = value }

    /// Warm only the public first Rule34 page. Never publish it as the active
    /// provider: Home should remain on the user's last selected source.
    func prewarmRule34() async {
        if let warm = rule34WarmPage, warm.expires > .now { return }
        guard rule34WarmTask == nil else { return }
        let currentCredentials = credentials
        let currentSession = session
        let task = Task(priority: .background) {
            try await NativeProviderAPI.rule34(session: currentSession, credentials: currentCredentials,
                query: ParsedQuery(included: [], excluded: []), page: 1,
                sort: "recommended", immersive: false)
        }
        rule34WarmTask = task
        defer { rule34WarmTask = nil }
        if let page = try? await task.value, !Task.isCancelled {
            rule34WarmPage = (page, .now.addingTimeInterval(90))
        }
    }

    func pornhubCategories() async throws -> [String] {
        try await NativeProviderAPI.pornhubCategories(session: session, credentials: credentials)
    }

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
        case .rule34:
            if page == 1, query.included.isEmpty, query.excluded.isEmpty,
               sort == "recommended", !immersive {
                if let warm = rule34WarmPage, warm.expires > .now { return warm.page }
                if let running = rule34WarmTask, let result = try? await running.value {
                    try Task.checkCancellation()
                    return result
                }
            }
            return try await NativeProviderAPI.rule34(session: session, credentials: credentials,
                query: query, page: page, sort: sort, immersive: immersive)
        case .nhentai: return try await cachedNHentaiPosts(query: query, page: page, sort: sort, immersive: immersive)
        case .coomer, .kemono:
            return try await cachedArchivePosts(provider: provider, query: query, page: page, immersive: immersive)
        case .eporner: return try await NativeProviderAPI.eporner(session: session, query: query, page: page, sort: sort, immersive: immersive)
        case .erome:
            if let base = EromeGeneratedAPI.configuredURL {
                return try await EromeGeneratedAPI.posts(session: session, base: base,
                                                         query: query, page: page, sort: sort, immersive: immersive)
            }
            return try await cachedEromePosts(query: query, page: page, sort: sort, immersive: immersive)
        case .pornhub: return try await NativeProviderAPI.pornhub(session: session, credentials: credentials, query: query, page: page, sort: sort, immersive: immersive)
        case .hanime:
            if let base = HanimeGeneratedAPI.configuredURL {
                return try await HanimeGeneratedAPI.posts(session: session, base: base,
                                                          query: query, page: page, sort: sort, immersive: immersive)
            }
            return try await cachedHanimePosts(query: query, page: page, sort: sort, immersive: immersive)
        case .hhaven:
            return try await cachedHavenPosts(query: query, page: page, sort: sort, immersive: immersive)
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

    func redgifsNiches(limit: Int = 8) async throws -> [RedgifsNiche] {
        let token = try await redgifsAuth.value(session: session)
        do {
            return try await NativeProviderAPI.redgifsNiches(session: session, token: token, limit: limit)
        } catch APIError.providerStatus(.redgifs, 401) {
            await redgifsAuth.invalidate(expecting: token)
            let refreshed = try await redgifsAuth.value(session: session)
            return try await NativeProviderAPI.redgifsNiches(session: session, token: refreshed, limit: limit)
        }
    }

    func pornhubCategoryPreview(token: String) async throws -> String? {
        try await NativeProviderAPI.pornhubCategoryPreview(session: session,
            credentials: credentials, token: token)
    }

    func redgifsNichesPage(page: Int, limit: Int = 24) async throws -> RedgifsNichePage {
        let token = try await redgifsAuth.value(session: session)
        do {
            return try await NativeProviderAPI.redgifsNichesPage(session: session, token: token,
                                                                 page: page, limit: limit)
        } catch APIError.providerStatus(.redgifs, 401) {
            await redgifsAuth.invalidate(expecting: token)
            let refreshed = try await redgifsAuth.value(session: session)
            return try await NativeProviderAPI.redgifsNichesPage(session: session, token: refreshed,
                                                                 page: page, limit: limit)
        }
    }

    func mangaPages(bookID: String) async throws -> [URL] {
        try await NativeProviderAPI.nhentaiPages(session: session, bookID: bookID)
    }

    private func cachedEromePosts(query: ParsedQuery, page: Int, sort: String,
                                  immersive: Bool) async throws -> PostPage {
        let key = "\(page)|\(sort)|\(immersive)|\(QueryParser.formatted(query))"
        if let cached = eromePages[key], cached.expiry > .now { return cached.page }
        if let pending = eromePageTasks[key] { return try await pending.value }
        let clientSession = session
        let request = Task<PostPage, Error> {
            try await NativeProviderAPI.erome(session: clientSession, query: query,
                                              page: page, sort: sort, immersive: immersive)
        }
        eromePageTasks[key] = request
        defer { eromePageTasks[key] = nil }
        let result = try await request.value
        eromePages[key] = (result, .now.addingTimeInterval(90))
        if eromePages.count > 20 { eromePages = eromePages.filter { $0.value.expiry > .now } }
        return result
    }

    private func cachedHanimePosts(query: ParsedQuery, page: Int, sort: String,
                                   immersive: Bool) async throws -> PostPage {
        let key = "\(page)|\(sort)|\(immersive)|\(QueryParser.formatted(query))"
        if let saved = hanimePages[key], saved.expiry > .now { return saved.page }
        if let pending = hanimePageTasks[key] { return try await pending.value }
        let clientSession = session
        let request = Task<PostPage, Error> {
            try await NativeProviderAPI.hanime(session: clientSession, query: query,
                                               page: page, sort: sort, immersive: immersive)
        }
        hanimePageTasks[key] = request
        defer { hanimePageTasks[key] = nil }
        do {
            let result = try await request.value
            if page == 1 {
                // Hanime's public search often returns just slugs and titles.
                // Prime the first viewport's real first-party posters without
                // delaying the feed or fetching metadata for offscreen pages.
                let missingArtwork = Array(result.items.filter {
                    $0.providerKey == .hanime && $0.previewImageURLs.isEmpty
                }.prefix(8).map(\.id))
                if !missingArtwork.isEmpty {
                    Task(priority: .utility) {
                        await withTaskGroup(of: Void.self) { group in
                            for slug in missingArtwork {
                                group.addTask { _ = await HanimeArtworkCache.shared.posterURL(slug: slug) }
                            }
                        }
                    }
                }
            }
            // Avoid turning a transient empty first page into a cached result.
            if !result.items.isEmpty || page > 1 {
                hanimePages[key] = (result, .now.addingTimeInterval(120))
            }
            if hanimePages.count > 24 {
                hanimePages = hanimePages.filter { $0.value.expiry > .now.addingTimeInterval(-15 * 60) }
            }
            return result
        } catch {
            // Temporary browser verification or provider outages should not
            // wipe a previously loaded catalog while the user is browsing.
            if !Task.isCancelled, let saved = hanimePages[key],
               saved.expiry > .now.addingTimeInterval(-15 * 60) {
                return saved.page
            }
            throw error
        }
    }

    private func cachedNHentaiPosts(query: ParsedQuery, page: Int, sort: String,
                                    immersive: Bool) async throws -> PostPage {
        if immersive { return PostPage(items: [], hasMore: false) }
        let key = "\(page)|\(sort)|\(QueryParser.formatted(query))"
        if let saved = nhentaiPages[key], saved.expiry > .now { return saved.page }
        if let running = nhentaiPageTasks[key] { return try await running.value }
        let clientSession = session
        let request = Task<PostPage, Error> {
            try await NativeProviderAPI.nhentai(session: clientSession, query: query,
                page: page, sort: sort, immersive: false)
        }
        nhentaiPageTasks[key] = request
        defer { nhentaiPageTasks[key] = nil }
        do {
            let page = try await request.value
            nhentaiPages[key] = (page, .now.addingTimeInterval(90))
            if nhentaiPages.count > 32 {
                nhentaiPages = nhentaiPages.filter { $0.value.expiry > .now }
            }
            return page
        } catch {
            // A short outage must not immediately blank a catalog that was
            // fetched successfully during this app session.
            if let saved = nhentaiPages[key], saved.expiry > .now.addingTimeInterval(-15 * 60) {
                return saved.page
            }
            throw error
        }
    }

    private func cachedHavenPosts(query: ParsedQuery, page: Int, sort: String,
                                  immersive: Bool) async throws -> PostPage {
        let key = "\(page)|\(sort)|\(immersive)|\(QueryParser.formatted(query))"
        if let saved = havenPages[key], saved.expiry > .now { return saved.page }
        if let running = havenPageTasks[key] { return try await running.value }
        let session = self.session
        let auth = havenAuth
        let request = Task<PostPage, Error> {
            do {
                let token = try await auth.value(session: session)
                do {
                    let result = try await NativeProviderAPI.haven(session: session, token: token,
                        query: query, page: page, sort: sort, immersive: immersive)
                    // Some Warden deployments answer HTTP 200 with an empty
                    // catalog despite public website titles being available.
                    // Don't cache that as a successful first page.
                    if result.items.isEmpty && page == 1 && !immersive {
                        throw APIError.server("Hentai Haven's API returned an empty catalog.")
                    }
                    return result
                } catch APIError.providerStatus(.hhaven, 401) {
                    await auth.invalidate(expecting: token)
                    let replacement = try await auth.value(session: session)
                    let result = try await NativeProviderAPI.haven(session: session, token: replacement,
                        query: query, page: page, sort: sort, immersive: immersive)
                    if result.items.isEmpty && page == 1 && !immersive {
                        throw APIError.server("Hentai Haven's API returned an empty catalog.")
                    }
                    return result
                }
            } catch let apiFailure {
                try Task.checkCancellation()
                guard !immersive, NativeProviderAPI.havenWebsiteURL(sort: sort, query: query, page: page) != nil else { throw apiFailure }
                // API Anything's read-only strategy: try plain HTTP first,
                // then load the actual public site in iOS WebKit. The latter
                // can succeed when an upstream proxy replaces URLSession's
                // response with HTML saying "Site Unavailable".
                do {
                    let page = try await NativeProviderAPI.havenWebsiteCatalog(session: session,
                        query: query, page: page, sort: sort, immersive: immersive)
                    if !page.items.isEmpty { return page }
                } catch is CancellationError { throw CancellationError() }
                catch { }
                try Task.checkCancellation()
                // Injected URLProtocol sessions are deterministic unit/UI
                // tests. Do not escape their fixture transport by opening a
                // real WKWebView against the public internet.
                guard session.configuration.protocolClasses?.isEmpty != false else { throw apiFailure }
                do {
                    let html = try await HavenBrowserCatalog.html(query: query, sort: sort, page: page)
                    let webPage = try NativeProviderAPI.havenWebsitePage(html, query: query,
                        page: page, sort: sort)
                    if !webPage.items.isEmpty { return webPage }
                } catch is CancellationError { throw CancellationError() }
                catch { }
                // An inaccessible website is not proof the user searched
                // for something nonexistent. Preserve the upstream reason.
                throw APIError.server("Hentai Haven's API and public website could not load a usable catalog. Try Browse inside QuickTick. \(apiFailure.localizedDescription)")
            }
        }
        havenPageTasks[key] = request
        defer { havenPageTasks[key] = nil }
        do {
            let response = try await request.value
            // Successful catalogs remain usable for a short outage while
            // token refreshes and the source's upstream API recover.
            havenPages[key] = (response, .now.addingTimeInterval(90))
            if havenPages.count > 24 {
                havenPages = havenPages.filter { $0.value.expiry > .now.addingTimeInterval(-20 * 60) }
            }
            return response
        } catch {
            if let saved = havenPages[key], saved.expiry > .now.addingTimeInterval(-20 * 60) {
                return saved.page
            }
            throw error
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
        do {
            let result = try await task.value
            // Archive APIs and attachment normalization can be slow. Keep a
            // short window for instant tab returns and intermittent outages.
            archivePages[key] = (result, .now.addingTimeInterval(120))
            if archivePages.count > 40 { archivePages = archivePages.filter { $0.value.expiry > .now } }
            return result
        } catch {
            if let saved = archivePages[key], saved.expiry > .now.addingTimeInterval(-20 * 60) {
                return saved.page
            }
            throw error
        }
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

    func resolveMedia(_ post: Post, streamVariant: Int = 0) async throws -> ResolvedMedia {
        if post.providerKey == .hanime, post.mediaUrl.isEmpty,
           let base = HanimeGeneratedAPI.configuredURL {
            return try await HanimeGeneratedAPI.resolve(session: session, base: base, post: post)
        }
        if post.providerKey == .erome, post.mediaUrl.isEmpty,
           let base = EromeGeneratedAPI.configuredURL {
            return try await EromeGeneratedAPI.resolve(session: session, base: base, post: post)
        }
        // Public Haven catalog entries use stable watch-page slugs, not the
        // numeric IDs expected by Warden. Resolve the public player directly
        // inside QuickTick; never redirect the user to a website sheet.
        if post.providerKey == .hhaven, !post.id.isEmpty,
           !post.id.allSatisfy(\.isNumber), post.mediaUrl.isEmpty {
            return try await NativeProviderAPI.havenPublicResolve(session: session, post: post)
        }
        let token = post.providerKey == .redgifs && NativeProviderAPI.mediaURL(post.mediaUrl, provider: .redgifs) == nil ? try await redgifsAuth.value(session: session) : nil
        let havenToken = post.providerKey == .hhaven && NativeProviderAPI.mediaURL(post.mediaUrl, provider: .hhaven) == nil
            ? try await havenAuth.value(session: session) : nil
        do {
            return try await NativeProviderAPI.resolve(session: session, credentials: credentials,
                post: post, redgifsToken: token, havenToken: havenToken,
                streamVariant: streamVariant)
        } catch APIError.providerStatus(.hhaven, 401) {
            guard let havenToken else { throw APIError.invalidResponse }
            await havenAuth.invalidate(expecting: havenToken)
            let refreshed = try await havenAuth.value(session: session)
            return try await NativeProviderAPI.resolve(session: session, credentials: credentials,
                post: post, redgifsToken: token, havenToken: refreshed)
        }
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
