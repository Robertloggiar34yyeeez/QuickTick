import Foundation
import CryptoKit
import WebKit

// Shared by provider APIs and download preparation. A new screen or Retry tap
// cannot bypass a host's advertised cooldown. Entries are bounded and transient.
actor ProviderRequestGate {
    static let shared = ProviderRequestGate()
    private var deadlines: [String: Date] = [:]
    private var slots: [String: Date] = [:]
    func block(host: String, until: Date) {
        deadlines = deadlines.filter { $0.value > .now }
        if deadlines.count >= 64, deadlines[host] == nil { return }
        deadlines[host] = max(deadlines[host] ?? .distantPast, until)
    }
    func wait(host: String, provider: Provider) async throws {
        try Task.checkCancellation()
        if let date = deadlines[host], date > .now { throw APIError.rateLimited(provider, date) }
        slots = slots.filter { $0.value > .now }
        let slot = max(.now, slots[host] ?? .distantPast)
        if slots.count < 64 || slots[host] != nil { slots[host] = slot.addingTimeInterval(0.2) }
        if slot > .now { try await Task.sleep(for: .seconds(slot.timeIntervalSinceNow)) }
        try Task.checkCancellation()
        if let date = deadlines[host], date > .now { throw APIError.rateLimited(provider, date) }
    }
}

/// Website-driven fallback inspired by API Anything's read-only browser tier.
/// The public page is rendered with iOS WebKit when the first-party API and a
/// plain HTTP catalog read fail. Nothing here bypasses a sign-in or access wall:
/// the parser only accepts public titles visible in the loaded document.
@MainActor
enum HavenBrowserCatalog {
    static func html(query: ParsedQuery, sort: String, page: Int = 1) async throws -> String {
        let config = WKWebViewConfiguration()
        // Reuse only WebKit's own in-app site state. Users who have already
        // accessed the provider inside QuickTick should not lose their public
        // catalog cookies every time the feed refreshes. Never copy Safari
        // cookies or manufacture an authenticated identity.
        config.websiteDataStore = .default()
        let browser = WKWebView(frame: .zero, configuration: config)
        guard let url = NativeProviderAPI.havenWebsiteURL(sort: sort, query: query, page: page) else {
            throw APIError.server("This Hentai Haven category is only available through its catalog API.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        _ = browser.load(request)
        defer { browser.stopLoading() }

        // API Anything's browser tier observes the page's useful response,
        // not every ad/tracker finishing. Read as soon as a real watch link
        // appears instead of waiting for the entire document's load event.
        var settled = 0
        for tick in 0..<48 {
            try Task.checkCancellation()
            guard let current = browser.url else {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard current.scheme == "https", ["hentaihaven.xxx", "www.hentaihaven.xxx"].contains(current.host?.lowercased() ?? "") else {
                throw APIError.server("Hentai Haven redirected to another website; QuickTick did not read it.")
            }
            if tick.isMultiple(of: 2), let markup = await renderedWatchMarkup(in: browser) {
                return markup
            }
            settled = browser.isLoading ? 0 : settled + 1
            if settled >= 8 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw APIError.server("Hentai Haven's in-app browser could not read a public catalog.")
    }

    private static func renderedWatchMarkup(in browser: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            browser.evaluateJavaScript(
                #"document.querySelector('a[href*="/watch/"]') ? document.documentElement.outerHTML : ''"#
            ) { value, _ in
                let html = value as? String
                continuation.resume(returning: html?.isEmpty == false ? html : nil)
            }
        }
    }
}

/// When the Hanime JSON catalog is unavailable, read the same public titles a
/// person can see on the first-party website. WebKit keeps only its own site
/// cookies; no verification tokens, Safari state or third-party mirrors are used.
@MainActor
enum HanimeBrowserCatalog {
    static func html(url: URL) async throws -> String {
        guard url.scheme == "https", url.host == "hanime.tv" else {
            throw APIError.invalidResponse
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let browser = WKWebView(frame: .zero, configuration: config)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        _ = browser.load(request)
        defer { browser.stopLoading() }

        var settled = 0
        for tick in 0..<40 {
            try Task.checkCancellation()
            if let current = browser.url {
                guard current.scheme == "https",
                      ["hanime.tv", "www.hanime.tv"].contains(current.host?.lowercased() ?? "") else {
                    throw APIError.server("Hanime redirected away from its public website.")
                }
                if tick.isMultiple(of: 2), let markup = await readableCatalog(in: browser) {
                    return markup
                }
            }
            settled = browser.isLoading ? 0 : settled + 1
            if settled >= 8 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw APIError.server("Hanime's public website did not expose a readable catalog.")
    }

    private static func readableCatalog(in browser: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            browser.evaluateJavaScript(
                #"document.querySelector('a[href*="/videos/hentai/"]') ? document.documentElement.outerHTML : ''"#
            ) { value, _ in
                let html = value as? String
                continuation.resume(returning: html?.isEmpty == false ? html : nil)
            }
        }
    }
}

/// Read a normal public Erome page through WebKit when URLSession receives a
/// site-unavailable response. This uses WebKit's own first-party cookie store
/// (not Safari's); it never fabricates verification or bypasses access controls.
@MainActor
enum EromeBrowserCatalog {
    private static var unavailableUntil = Date.distantPast

    static func html(url: URL) async throws -> String {
        guard url.scheme == "https", url.host == "www.erome.com" else {
            throw APIError.invalidResponse
        }
        // After a verification wall, do not create a new hidden WKWebView for
        // every album in the current immersive batch. Retry after cooldown.
        guard unavailableUntil <= .now else {
            throw APIError.server("Erome's public browser view is temporarily unavailable.")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let browser = WKWebView(frame: .zero, configuration: config)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        _ = browser.load(request)
        defer { browser.stopLoading() }

        var finishedTicks = 0
        for _ in 0..<48 {
            try Task.checkCancellation()
            if let current = browser.url {
                guard current.scheme == "https", current.host == "www.erome.com" else {
                    throw APIError.server("Erome redirected away from its public website.")
                }
                if let markup = await usefulMarkup(in: browser) { return markup }
            }
            finishedTicks = browser.isLoading ? 0 : finishedTicks + 1
            if finishedTicks >= 8 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        unavailableUntil = .now.addingTimeInterval(60)
        throw APIError.server("Erome's in-app browser could not read public media. Open Erome inside QuickTick to check access.")
    }

    private static func usefulMarkup(in browser: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            browser.evaluateJavaScript(
                #"document.querySelector('a.album-link, a.album-title, video source, div.img img') ? document.documentElement.outerHTML : ''"#
            ) { value, _ in
                let html = value as? String
                continuation.resume(returning: html?.isEmpty == false ? html : nil)
            }
        }
    }
}

// Provider networking lives on the API actor, never on a scrolling view. No
// requests in this service use the optional QuickTick Sync origin.
struct RedgifsNiche: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let imageURL: String
    let postCount: Int
}

struct RedgifsNichePage: Sendable {
    let items: [RedgifsNiche]
    let hasMore: Bool
}

enum NativeProviderAPI {
    static let userAgent = "QuickTickNative/1.0"
    // nHentai requests specifically ask clients for an identifying UA; keep
    // the project URL rather than impersonating a browser or official app.
    static let nhentaiHeaders = ["User-Agent": "QuickTick/1.0 (https://github.com/Robertloggiar34yyeeez/QuickTick)"]
    static let quicktickHost = "quick-tick-webb.vercel.app"

    static func origin(_ provider: Provider) -> URL {
        switch provider {
        case .rule34: URL(string: "https://rule34.xxx")!
        case .redgifs: URL(string: "https://www.redgifs.com")!
        case .eporner: URL(string: "https://www.eporner.com")!
        case .erome: URL(string: "https://www.erome.com")!
        case .pornhub: URL(string: "https://www.pornhub.com")!
        case .hanime: URL(string: "https://hanime.tv")!
        case .hhaven: URL(string: "https://hentaihaven.xxx")!
        case .coomer: URL(string: "https://coomer.st")!
        case .kemono: URL(string: "https://kemono.cr")!
        case .nhentai: URL(string: "https://nhentai.net")!
        }
    }

    static func mediaURL(_ raw: String, provider: Provider? = nil) -> URL? {
        guard !raw.isEmpty, !raw.hasPrefix("/api/") else { return nil }
        let base = provider.map(origin)
        let address = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: address, relativeTo: base)?.absoluteURL,
              url.scheme == "https", let host = url.host,
              host.lowercased() != quicktickHost else { return nil }
        return url
    }

    static func url(_ raw: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard var c = URLComponents(string: raw), c.scheme == "https" else { throw APIError.invalidResponse }
        if !query.isEmpty { c.queryItems = (c.queryItems ?? []) + query }
        guard let url = c.url else { throw APIError.invalidResponse }
        return url
    }

    static func data(session: URLSession, url: URL, provider: Provider, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], maxBytes: Int = 8 * 1024 * 1024, timeout: TimeInterval = 15) async throws -> Data {
        guard url.scheme == "https", let host = url.host, host.lowercased() != quicktickHost else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = method; request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/xml;q=0.9, text/html;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(origin(provider).absoluteString + "/", forHTTPHeaderField: "Referer")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        for attempt in 0..<3 {
            try await ProviderRequestGate.shared.wait(host: host, provider: provider)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            if http.statusCode == 429 {
                let advertised = retryDeadline(http, attempt: attempt)
                let deadline = attempt == 2 ? max(advertised, Date.now.addingTimeInterval(1)) : advertised
                await ProviderRequestGate.shared.block(host: host, until: deadline)
                // Short transient limits recover automatically. Long limits are
                // surfaced immediately, rather than leaving a feed spinner stuck.
                guard attempt < 2, deadline.timeIntervalSinceNow <= 3 else { throw APIError.rateLimited(provider, deadline) }
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw APIError.providerStatus(provider, http.statusCode) }
            guard data.count <= maxBytes else { throw APIError.server("Provider response is too large.") }
            return data
        }
        throw APIError.invalidResponse
    }

    static func retryDeadline(_ response: HTTPURLResponse, now: Date = .now, attempt: Int = 0) -> Date {
        if let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: raw) { return max(now, date) }
            }
        }
        return now.addingTimeInterval(pow(2, Double(min(2, max(0, attempt)))))
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.invalidResponse }
        return value
    }
    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        return Double(text(value)) ?? 0
    }
    static func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

    /// The previous /api/galleries/* endpoints were retired in 2026. The v2
    /// gallery list is intentionally lightweight; full image paths and tags
    /// arrive only from /api/v2/galleries/{id} when the reader is opened.
    static func nhentaiExtension(_ value: Any?) -> String {
        switch text(value).lowercased() {
        case "p": "png"
        case "w": "webp"
        case "g": "gif"
        default: "jpg"
        }
    }

    static func nhentaiImageURL(path raw: String, mediaID: String, thumbnail: Bool) -> URL? {
        guard !raw.isEmpty, !mediaID.isEmpty,
              mediaID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        if let absolute = URL(string: raw), absolute.scheme != nil {
            guard absolute.scheme == "https", let host = absolute.host?.lowercased(),
                  host == "nhentai.net" || host.hasSuffix(".nhentai.net") else { return nil }
            return absolute
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains(".."), !trimmed.contains("?"),
              !trimmed.contains("#"), !trimmed.contains("\\") else { return nil }
        let path = trimmed.hasPrefix("galleries/") ? trimmed : "galleries/\(mediaID)/\(trimmed)"
        return URL(string: "https://\(thumbnail ? "t1" : "i1").nhentai.net/\(path)")
    }

    static func nhentai(session: URLSession, query: ParsedQuery, page: Int,
                        sort: String, immersive: Bool) async throws -> PostPage {
        if immersive { return PostPage(items: [], hasMore: false) } // Books are read, not auto-played.
        // The v2 list omits human-readable tag names. Send explicit negatives
        // to the provider, as the local list cannot reliably filter tag IDs.
        let terms = (query.included + query.excluded.map { "-" + $0 }).joined(separator: " ")
        let popular = terms.isEmpty && sort == "popular"
        if popular && page > 1 { return PostPage(items: [], hasMore: false) }
        var parameters = [URLQueryItem(name: "page", value: String(max(1, page)))]
        if !terms.isEmpty {
            parameters.append(.init(name: "query", value: terms))
            parameters.append(.init(name: "sort", value: sort == "popular" ? "popular" : "date"))
        }
        let endpoint = popular ? "https://nhentai.net/api/v2/galleries/popular" :
            (terms.isEmpty ? "https://nhentai.net/api/v2/galleries" : "https://nhentai.net/api/v2/search")
        let bytes: Data
        do {
            bytes = try await data(session: session, url: url(endpoint, popular ? [] : parameters), provider: .nhentai,
                                   headers: nhentaiHeaders)
        } catch APIError.providerStatus(.nhentai, 403) {
            throw APIError.server("NHentai rejected API access (HTTP 403). Its public v2 endpoint may be restricted on this network. Open nhentai.net in Safari to check access.")
        }
        guard !unavailableHTML(bytes),
              let payload = try? JSONSerialization.jsonObject(with: bytes),
              (popular ? payload is [[String: Any]] : payload is [String: Any]) else {
            throw APIError.server("NHentai returned an unavailable v2 catalog page. Check access to its public API from this network.")
        }
        let json = payload as? [String: Any] ?? [:]
        let books = popular ? (payload as? [[String: Any]] ?? []) : rows(json["result"])
        let posts = books.compactMap { book -> Post? in
            let id = text(book["id"]), mediaID = text(book["media_id"])
            guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
                  !mediaID.isEmpty, mediaID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            guard let coverURL = nhentaiImageURL(path: text(book["thumbnail"]), mediaID: mediaID, thumbnail: true) else { return nil }
            let caption = [text(book["english_title"]), text(book["japanese_title"])].first { !$0.isEmpty } ?? "Manga #\(id)"
            // v2 list pages contain tag IDs, not tag names. Keep title terms
            // searchable until the full gallery metadata is requested.
            let tags = caption.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .prefix(16).map(String.init)
            var post = Post(key: "nhentai:\(id)", id: id, provider: Provider.nhentai.rawValue,
                            tags: tags, mediaUrl: coverURL.absoluteString, thumbUrl: coverURL.absoluteString,
                            pageUrl: "https://nhentai.net/g/\(id)/", type: "manga")
            post.caption = caption
            post.width = number(book["thumbnail_width"]); post.height = number(book["thumbnail_height"])
            return post
        }
        let filtered = self.page(posts,
            hasMore: !popular && page < max(1, Int(number(json["num_pages"]))), query: query, immersive: false)
        return filtered
    }

    static func nhentaiPages(session: URLSession, bookID: String) async throws -> [URL] {
        guard !bookID.isEmpty, bookID.count <= 12,
              bookID.utf8.allSatisfy({ (48...57).contains($0) }) else { throw APIError.invalidResponse }
        let bytes = try await data(session: session, url: url("https://nhentai.net/api/v2/galleries/" + bookID),
                                   provider: .nhentai, headers: nhentaiHeaders)
        guard !unavailableHTML(bytes), let gallery = try? object(bytes) else {
            throw APIError.server("Unable to load manga pages from NHentai.")
        }
        let mediaID = text(gallery["media_id"])
        guard !mediaID.isEmpty, mediaID.utf8.allSatisfy({ (48...57).contains($0) }) else { throw APIError.invalidResponse }
        let pages = Array(rows(gallery["pages"]).prefix(800))
        guard !pages.isEmpty else { throw APIError.server("This manga has no readable pages.") }
        let urls = pages.compactMap { descriptor in
            nhentaiImageURL(path: text(descriptor["path"]), mediaID: mediaID, thumbnail: false)
        }
        guard urls.count == pages.count else { throw APIError.server("NHentai returned invalid page image paths.") }
        return urls
    }

    /// Some provider/CDN failures arrive as a 200 HTML page, so HTTP status
    /// alone cannot distinguish a healthy catalog from an unavailable one.
    static func unavailableHTML(_ bytes: Data) -> Bool {
        let body = String(decoding: bytes.prefix(2_048), as: UTF8.self).lowercased()
        return (body.contains("<html") || body.contains("<!doctype html")) &&
            (body.contains("site unavailable") || body.contains("requested url was not found") ||
             body.contains("access to this site") || body.contains("404 not found"))
    }
    static func strings(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [[String: Any]] {
            return values.map { text($0["text"] ?? $0["name"] ?? $0["slug"] ?? $0["tag_name"] ?? $0["category"]) }.filter { !$0.isEmpty }
        }
        return text(value).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func type(_ value: String) -> String {
        switch URL(string: value)?.pathExtension.lowercased() {
        case "gif": "gif"
        case "mp4", "webm", "mov", "m3u8", "m4v": "video"
        case "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "ogg", "opus": "audio"
        default: "image"
        }
    }
    /// Booru providers use exact tags; video and keyword providers use title,
    /// captions, categories and creator names. Avoid substring exclusions:
    /// banning "bat" must not inadvertently ban "battle".
    static func containsKeyword(_ phrase: String, in post: Post) -> Bool {
        let text = ([post.caption, post.category, post.creator].compactMap { $0 } + post.tags)
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let needle = phrase.lowercased().replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !needle.isEmpty else { return false }
        guard needle.count <= tokens.count else { return false }
        return (0...(tokens.count - needle.count)).contains { offset in
            Array(tokens[offset..<(offset + needle.count)]) == needle
        }
    }
    /// A keyword source may index only titles while the post exposes richer
    /// metadata. Retain verifiable on-screen matches when that remote search
    /// returns no rows; never show unrelated cached posts as search results.
    static func matchingCachedPosts(_ posts: [Post], provider: Provider,
                                    query: ParsedQuery, immersive: Bool) -> [Post] {
        posts.filter { post in
            post.providerKey == provider && (!immersive || post.isImmersiveMedia)
                && query.included.allSatisfy { containsKeyword($0, in: post) }
                && !query.excluded.contains { containsKeyword($0, in: post) }
        }
    }
    static func page(_ rows: [Post], hasMore: Bool, query: ParsedQuery, immersive: Bool) -> PostPage {
        var seen = Set<String>()
        return PostPage(items: rows.filter { post in
            guard !post.id.isEmpty, seen.insert(post.stableID).inserted,
                  !immersive || post.isImmersiveMedia else { return false }
            if post.providerKey == .rule34 || post.providerKey == .kemono {
                // Apply canonical aliases and whole families (furry/anthro)
                // consistently with the feed and the user's explicit bans.
                return !RecommendationTagRules.rejects(post, exclusions: query.excluded)
            }
            return !query.excluded.contains { containsKeyword($0, in: post) }
        }, hasMore: hasMore)
    }

    static func rule34(session: URLSession, credentials: ProviderCredentials, query: ParsedQuery, page: Int, sort: String, immersive: Bool, id: String? = nil) async throws -> PostPage {
        guard !credentials.rule34User.isEmpty, !credentials.rule34Key.isEmpty else {
            throw APIError.server("Add your Rule34 user ID and API key in Settings. They are sent directly to Rule34.")
        }
        let limit = id == nil ? 40 : 1
        var tags = query.included
        if immersive { tags.append("( video ~ animated_gif )") }
        if sort == "popular", !tags.contains(where: { $0.lowercased().hasPrefix("sort:") }) { tags.append("sort:score") }
        // A heavily trained profile may contain dozens of exclusions. Sending
        // every one as a tag makes Rule34 reject the entire DAPI query. Apply
        // the complete set locally below; only a small subset belongs in the
        // provider request. Preserve the user's explicit positive tags.
        let remaining = max(0, 5 - tags.count)
        tags += query.excluded.prefix(remaining).map { "-" + $0 }
        let items = [URLQueryItem(name: "page", value: "dapi"), .init(name: "s", value: "post"), .init(name: "q", value: "index"),
                     .init(name: "pid", value: String(max(0, page - 1))), .init(name: "limit", value: String(limit)),
                     .init(name: "tags", value: tags.joined(separator: " ")), .init(name: "json", value: "1"),
                     .init(name: "user_id", value: credentials.rule34User), .init(name: "api_key", value: credentials.rule34Key)] + (id.map { [URLQueryItem(name: "id", value: $0)] } ?? [])
        let bytes = try await data(session: session, url: url("https://api.rule34.xxx/index.php", items), provider: .rule34)
        let result = try rule34Payload(bytes)
        let raw = result.posts
        let total = result.total
        let posts = raw.compactMap { row -> Post? in
            let id = text(row["id"]), rawMedia = text(row["file_url"] ?? row["sample_url"] ?? row["preview_url"])
            guard !id.isEmpty, let media = mediaURL(rawMedia, provider: .rule34) else { return nil }
            var post = Post(key: "rule34:\(id)", id: id, provider: "Rule34", score: number(row["score"]),
                            tags: text(row["tags"]).split(whereSeparator: \.isWhitespace).map(String.init), mediaUrl: media.absoluteString,
                            previewUrl: mediaURL(text(row["sample_url"]), provider: .rule34).flatMap { type($0.absoluteString) == "image" ? $0.absoluteString : nil }
                                ?? mediaURL(text(row["preview_url"]), provider: .rule34)?.absoluteString ?? "",
                            thumbUrl: mediaURL(text(row["preview_url"]), provider: .rule34)?.absoluteString ?? "",
                            pageUrl: "https://rule34.xxx/index.php?page=post&s=view&id=\(id)", type: type(media.absoluteString))
            let width = number(row["width"]), height = number(row["height"])
            if width > 0, height > 0 { post.width = width; post.height = height }
            post.createdAt = number(row["created_at"]); return post
        }
        return self.page(posts, hasMore: total > 0 ? page * limit < total : raw.count >= limit, query: query, immersive: immersive)
    }

    static func rule34Payload(_ bytes: Data) throws -> (posts: [[String: Any]], total: Int) {
        // DAPI returns either a JSON array or a wrapped JSON object, and some
        // deployments represent a zero-match search with `{}` or `{"count":0}`.
        // Neither case should turn into a broken feed with a generic error.
        if let json = try? JSONSerialization.jsonObject(with: bytes) {
            if let array = json as? [[String: Any]] { return (array, 0) }
            if let object = json as? [String: Any] {
                if object["success"] as? Bool == false || object["error"] != nil {
                    let reason = text(object["message"] ?? object["reason"] ?? object["error"])
                    let detail = reason.isEmpty ? "The source rejected this search." : String(reason.prefix(160))
                    throw APIError.server("Rule34 API: " + detail)
                }
                let total = Int(number(object["count"]))
                if let array = object["post"] as? [[String: Any]] { return (array, total) }
                if let single = object["post"] as? [String: Any] { return ([single], total) }
                if object.isEmpty || total == 0 && object["count"] != nil { return ([], 0) }
            }
            throw APIError.server("Rule34 API returned an unrecognized JSON format. Please retry shortly.")
        }
        if unavailableHTML(bytes) || String(decoding: bytes.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<html") {
            throw APIError.server("Rule34 returned a website error page instead of posts. Please retry shortly.")
        }
        let xml = try ProviderXML.parse(bytes)
        return (xml.posts.map { $0 as [String: Any] }, xml.total)
    }

    static func eporner(session: URLSession, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let order = sort == "recent" ? "latest" : sort == "popular" ? "top-weekly" : "top-monthly"
        func fetch(includeLowQuality: Bool) async throws -> [String: Any] {
            let bytes = try await data(session: session, url: url("https://www.eporner.com/api/v2/video/search/", [
                .init(name: "query", value: query.included.isEmpty ? "all" : query.included.joined(separator: " ")),
                .init(name: "page", value: String(page)), .init(name: "per_page", value: "40"), .init(name: "thumbsize", value: "big"),
                .init(name: "order", value: order), .init(name: "gay", value: "1"),
                .init(name: "lq", value: includeLowQuality ? "1" : "0"), .init(name: "format", value: "json")]), provider: .eporner)
            guard !unavailableHTML(bytes) else {
                throw APIError.server("Eporner returned an unavailable page instead of its video catalog.")
            }
            let result = try Self.object(bytes)
            guard result["videos"] is [Any] else {
                throw APIError.server("Eporner returned an unrecognized video catalog. Please retry shortly.")
            }
            return result
        }
        var object = try await fetch(includeLowQuality: false)
        // The default HD-only filter can produce an empty first page on some
        // catalog orderings. A broad, unfiltered Home catalog should still
        // be usable; an explicit keyword search must never be broadened.
        if page == 1, query.included.isEmpty, rows(object["videos"]).isEmpty {
            object = try await fetch(includeLowQuality: true)
        }
        let raw = rows(object["videos"])
        let posts = raw.map { row -> Post in
            let id = text(row["id"]), title = text(row["title"]), thumb = (row["default_thumb"] as? [String: Any]) ?? [:]
            var post = Post(key: "eporner:\(id)", id: id, provider: "Eporner", score: number(row["views"]), tags: strings(row["keywords"]),
                            thumbUrl: text(thumb["src"]), pageUrl: text(row["url"]), type: "video")
            post.caption = title; post.creator = text(row["uploader"])
            let width = number(row["width"]), height = number(row["height"])
            if width > 0, height > 0 { post.width = width; post.height = height }
            if let date = ISO8601DateFormatter().date(from: text(row["added"]).replacingOccurrences(of: " ", with: "T") + "Z") { post.createdAt = date.timeIntervalSince1970 }
            return post
        }
        return self.page(posts, hasMore: page < Int(number(object["total_pages"])), query: query, immersive: immersive)
    }

    static func erome(session: URLSession, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        try await EromePublicCatalog.posts(session: session, query: query, page: page,
                                           sort: sort, immersive: immersive)
    }

    private static func redgifsHeaders(token: String) -> [String: String] {
        ["Authorization": "Bearer " + token, "Referer": "https://www.redgifs.com/"]
    }

    static func redgifsNicheID(_ token: String) -> String? {
        guard token.hasPrefix("niche:") else { return nil }
        let id = String(token.dropFirst("niche:".count))
        guard id.count <= 70,
              id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    private static func redgifsPreview(_ raw: String) -> String {
        guard let address = mediaURL(raw, provider: .redgifs),
              let host = address.host?.lowercased(),
              host == "redgifs.com" || host.hasSuffix(".redgifs.com") else { return "" }
        return address.absoluteString
    }

    /// Genuine RedGIFs niches, with a poster from each niche's popular posts.
    /// A missing/unavailable niche preview is omitted instead of displaying
    /// a generic tag icon with misleading content.
    static func redgifsNiches(session: URLSession, token: String, limit: Int = 8) async throws -> [RedgifsNiche] {
        let page = try await redgifsNichesPage(session: session, token: token, page: 1,
                                               limit: max(1, min(limit, 32)))
        return Array(page.items.prefix(limit))
    }

    static func redgifsNichesPage(session: URLSession, token: String,
                                 page: Int = 1, limit: Int = 24) async throws -> RedgifsNichePage {
        guard (1...1000).contains(page), (1...32).contains(limit) else { throw APIError.invalidResponse }
        let response = try object(await data(session: session,
            url: url("https://api.redgifs.com/v2/niches",
                [.init(name: "page", value: String(page)), .init(name: "count", value: String(limit))]),
            provider: .redgifs, headers: redgifsHeaders(token: token)))
        let entries = rows(response["niches"] ?? response["items"])
        var chosen: [RedgifsNiche] = [], seen = Set<String>()
        for item in entries {
            let slug = text(item["slug"] ?? item["id"]).lowercased()
            guard let id = redgifsNicheID("niche:" + slug), seen.insert(id).inserted else { continue }
            let title = text(item["name"] ?? item["title"])
            guard !title.isEmpty else { continue }
            let thumbnail = redgifsPreview(text(item["thumbnail"] ?? item["cover"]))
            chosen.append(RedgifsNiche(id: id, name: title, imageURL: thumbnail,
                                      postCount: Int(number(item["gifs"] ?? item["count"]))))
            if chosen.count >= limit { break }
        }
        var covers: [Int: String] = [:]
        for start in stride(from: 0, to: chosen.count, by: 4) {
            try Task.checkCancellation()
            let indices = Array(start..<min(start + 4, chosen.count))
            let collected = await withTaskGroup(of: (Int, String?).self) { group in
                for index in indices {
                    let id = chosen[index].id
                    group.addTask {
                        do {
                            let sample = try object(await data(session: session,
                                url: url("https://api.redgifs.com/v2/niches/\(id)/gifs",
                                    [.init(name: "order", value: "top"), .init(name: "page", value: "1"), .init(name: "count", value: "4")]),
                                provider: .redgifs, headers: redgifsHeaders(token: token)))
                            let image = rows(sample["gifs"]).compactMap { gif -> String? in
                                let urls = gif["urls"] as? [String: Any] ?? [:]
                                let value = redgifsPreview(text(urls["poster"] ?? urls["thumbnail"] ?? urls["vthumbnail"]))
                                return value.isEmpty ? nil : value
                            }.first
                            return (index, image)
                        } catch { return (index, nil) }
                    }
                }
                var result: [(Int, String?)] = []
                for await entry in group { result.append(entry) }
                return result
            }
            for (index, image) in collected { if let image { covers[index] = image } }
        }
        let enriched = chosen.enumerated().compactMap { index, niche -> RedgifsNiche? in
            let image = covers[index] ?? niche.imageURL
            guard !image.isEmpty else { return nil }
            return RedgifsNiche(id: niche.id, name: niche.name, imageURL: image, postCount: niche.postCount)
        }
        let declaredPages = Int(number(response["pages"] ?? response["total_pages"]))
        return RedgifsNichePage(items: enriched,
                               hasMore: declaredPages > 0 ? page < declaredPages : entries.count >= limit)
    }

    static func redgifs(session: URLSession, token: String, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let result: [String: Any]
        let selectedNicheID = query.included.count == 1 ? redgifsNicheID(query.included[0]) : nil
        if let niche = selectedNicheID {
            let primaryOrder = sort == "recent" ? "latest" : "top"
            let orders = page == 1 ? [primaryOrder, primaryOrder == "top" ? "latest" : "top"] : [primaryOrder]
            var chosen: [String: Any] = [:]
            for order in orders {
                let response = try object(await data(session: session,
                    url: url("https://api.redgifs.com/v2/niches/\(niche)/gifs",
                        [.init(name: "order", value: order),
                         .init(name: "count", value: "40"), .init(name: "page", value: String(page))]),
                    provider: .redgifs, headers: redgifsHeaders(token: token)))
                chosen = response
                let nested = response["data"] as? [String: Any] ?? [:]
                let offered = rows(response["gifs"] ?? response["items"] ?? nested["gifs"])
                // A niche's top page may contain only still images, missing
                // streams or mislabeled clips. Try its latest feed once if
                // no actual video from this niche can be played.
                let playable = offered.contains { row in
                    guard !["i", "image"].contains(text(row["type"]).lowercased()),
                          number(row["type"]) != 2 else { return false }
                    let urls = row["urls"] as? [String: Any] ?? [:]
                    guard [urls["hd"], urls["sd"], urls["gif"]]
                        .contains(where: { !text($0).isEmpty }) else { return false }
                    let memberships = strings(row["niches"]) +
                        rows(row["niches"]).map { text($0["slug"] ?? $0["id"]) }
                    return memberships.isEmpty || memberships.contains {
                        redgifsNicheID("niche:" + $0.lowercased().replacingOccurrences(of: "niche:", with: "")) == niche
                    }
                }
                if playable { break }
            }
            result = chosen
        } else {
            guard !query.included.contains(where: { $0.hasPrefix("niche:") }) else { throw APIError.invalidResponse }
            let items = [URLQueryItem(name: "order", value: sort == "recent" ? "latest" : sort == "popular" ? "top7" : "trending"),
                         .init(name: "count", value: "40"), .init(name: "page", value: String(page))] + (query.included.isEmpty ? [] : [.init(name: "search_text", value: query.included.joined(separator: " "))])
            var found: [String: Any]?
            var lastError: Error = APIError.invalidResponse
            for path in ["https://api.redgifs.com/v2/gifs/search", "https://api.redgifs.com/v2/search/gifs"] {
                do {
                    let object = try Self.object(await data(session: session, url: url(path, items), provider: .redgifs, headers: redgifsHeaders(token: token)))
                    guard object["gifs"] is [[String: Any]] else { throw APIError.invalidResponse }
                    found = object; break
                } catch is CancellationError { throw CancellationError() } catch {
                    if (error as? APIError)?.retryAfter != nil { throw error }
                    if let failure = error as? APIError, case .providerStatus(.redgifs, 401) = failure { throw error }
                    lastError = error
                }
            }
            guard let found else { throw lastError }
            result = found
        }
        let nested = result["data"] as? [String: Any] ?? [:]
        let raw = rows(result["gifs"] ?? result["items"] ?? nested["gifs"])
        let posts = raw.compactMap { row -> Post? in
            let id = text(row["id"]), urls = row["urls"] as? [String: Any] ?? [:]
            guard !id.isEmpty else { return nil }
            let media = [urls["hd"], urls["sd"], urls["gif"]]
                .map { text($0) }.first(where: { !$0.isEmpty }) ?? ""
            let image = ["i", "image"].contains(text(row["type"]).lowercased()) || number(row["type"]) == 2
            var tags = strings(row["tags"])
            let nicheSlugs = strings(row["niches"]) + rows(row["niches"]).map { text($0["slug"] ?? $0["id"]) }
            let declaredNiches = Set(nicheSlugs.compactMap { value in
                redgifsNicheID("niche:" + value.lowercased().replacingOccurrences(of: "niche:", with: ""))
            })
            // The niche endpoint is the source of truth when rows omit their
            // memberships. But rows that explicitly name a *different* niche
            // must never be relabeled as the one the user selected.
            if let selectedNicheID, !declaredNiches.isEmpty,
               !declaredNiches.contains(selectedNicheID) { return nil }
            for value in nicheSlugs {
                let slug = value.lowercased().replacingOccurrences(of: "niche:", with: "")
                if let nicheID = redgifsNicheID("niche:" + slug), !tags.contains(nicheID) {
                    tags.append(nicheID)
                }
            }
            if let selectedNicheID, !tags.contains(selectedNicheID) { tags.append(selectedNicheID) }
            var post = Post(key: "redgifs:\(id)", id: id, provider: "RedGIFs", score: number(row["likes"]), tags: tags,
                            mediaUrl: media, thumbUrl: text(urls["poster"] ?? urls["thumbnail"] ?? urls["vthumbnail"]),
                            pageUrl: "https://www.redgifs.com/watch/\(id.lowercased())", type: image ? "image" : "video")
            let width = number(row["width"]), height = number(row["height"])
            if width > 0, height > 0 { post.width = width; post.height = height }
            post.caption = ["title", "name", "description"].map { text(row[$0]) }.first(where: { !$0.isEmpty })
            post.category = selectedNicheID
            post.creator = text(row["userName"]); post.createdAt = number(row["createDate"]); return post
        }
        return self.page(posts, hasMore: number(result["pages"]) > 0 ? page < Int(number(result["pages"])) : !raw.isEmpty, query: query, immersive: immersive)
    }

    static func hanimeSignature(claim: String) -> String {
        let signed = Data("9944822\(claim)8\(claim)113".utf8)
        return SHA256.hash(data: signed).map { String(format: "%02x", $0) }.joined()
    }

    static func hanimeRows(_ payload: Any) throws -> [[String: Any]] {
        var current: Any = payload
        for _ in 0..<4 {
            if let list = current as? [[String: Any]] { return list }
            if let encoded = current as? String, let bytes = encoded.data(using: .utf8) {
                current = try JSONSerialization.jsonObject(with: bytes); continue
            }
            guard let object = current as? [String: Any],
                  let next = object["hits"] ?? object["hentai_videos"] ?? object["videos"] ??
                    object["items"] ?? object["data"] ?? object["result"] else {
                throw APIError.invalidResponse
            }
            current = next
        }
        guard let list = current as? [[String: Any]] else { throw APIError.invalidResponse }
        return list
    }

    /// Resolve a current Hanime v11 player handshake into a first-party HLS
    /// stream. This uses the same guest transport as the official web player,
    /// and never treats 403/verification HTML as an authorized stream.
    static func hanimeHLSResolve(session: URLSession, post: Post,
                                 variant: Int = 0) async throws -> ResolvedMedia {
        guard post.id.count <= 160,
              post.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw APIError.invalidResponse
        }
        do {
            return try await hanimeHLSHandshake(session: session, slug: post.id, variant: variant)
        } catch APIError.providerStatus(.hanime, 403) {
            // A normal first-party page visit can establish an ordinary guest
            // session cookie. No challenge solving or access bypass is used.
            if let watch = URL(string: "https://hanime.tv/videos/hentai/" + post.id) {
                _ = try? await data(session: session, url: watch, provider: .hanime,
                                    maxBytes: 1024 * 1024, timeout: 8)
            }
            do {
                return try await hanimeHLSHandshake(session: session, slug: post.id, variant: variant)
            } catch APIError.providerStatus(.hanime, 403) {
                throw APIError.server("Hanime refused the native HLS handshake (HTTP 403). Open the original video in the browser or configure an authorized Hanime API in Settings.")
            }
        } catch APIError.server(let message) where message.contains("HLS playlist") {
            // Signed HLS paths can expire between the handshake and the first
            // request. Retry the legitimate first-party handshake once before
            // surfacing an unavailable stream to native playback.
            return try await hanimeHLSHandshake(session: session, slug: post.id, variant: variant)
        }
    }

    /// Older working releases resolved the public v8 video manifest. Some
    /// titles still expose a valid first-party HLS playlist there while their
    /// newer v11 handshake is empty, blocked, or produces an expired token.
    /// Use only official stream URLs and never accept a watch page as media.
    static func hanimeLegacyMediaResolve(session: URLSession, post: Post,
                                         variant: Int = 0) async throws -> ResolvedMedia {
        guard post.id.count <= 160,
              post.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw APIError.invalidResponse
        }
        let response = try object(await data(session: session,
            url: url("https://hanime.tv/api/v8/video", [.init(name: "id", value: post.id)]),
            provider: .hanime))
        let manifest = response["videos_manifest"] as? [String: Any] ?? [:]
        let ordered = rows(manifest["servers"])
            .flatMap { rows($0["streams"]) }
            .sorted { number($0["height"]) > number($1["height"]) }
        let valid = ordered.compactMap { row -> URL? in
            guard let address = mediaURL(text(row["url"]), provider: .hanime),
                  HanimeGeneratedAPI.permittedStreamURL(address) else { return nil }
            return address
        }
        guard !valid.isEmpty else { throw APIError.server("Hanime's public video manifest has no playable stream.") }
        let selected = valid[min(max(variant, 0), valid.count - 1)]
        return ResolvedMedia(mediaUrl: selected.absoluteString,
            type: ["mp4", "m4v"].contains(selected.pathExtension.lowercased()) ? "video" : "hls")
    }

    private static func hanimeHLSHandshake(session: URLSession, slug: String,
                                           variant: Int = 0) async throws -> ResolvedMedia {
        let time = Int(Date().timeIntervalSince1970)
        let timestamp = String(time)
        let signature = SHA256.hash(data: Data(
            "\(timestamp),Xkdi29,https://hanime.tv,mn2,\(timestamp)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let payload = try JSONSerialization.data(withJSONObject: [
            "timestamp_unix": time, "directive": "htv_player_handshake", "slug": slug
        ])
        let token = try HanimeHandshakeCodec.seal(payload)
        let body = try JSONSerialization.data(withJSONObject: ["token": token])
        let address = try url("https://auth.hanime.tv/api/v11/handshake")
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://hanime.tv", forHTTPHeaderField: "Origin")
        request.setValue("https://hanime.tv/", forHTTPHeaderField: "Referer")
        request.setValue("web2", forHTTPHeaderField: "x-signature-version")
        request.setValue(signature, forHTTPHeaderField: "x-signature")
        request.setValue(timestamp, forHTTPHeaderField: "x-time")
        request.setValue("null", forHTTPHeaderField: "x-csrf-token")
        try await ProviderRequestGate.shared.wait(host: "auth.hanime.tv", provider: .hanime)
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, bytes.count <= 1024 * 1024 else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.providerStatus(.hanime, http.statusCode)
        }
        let result: [String: Any]
        if let encrypted = http.value(forHTTPHeaderField: "x-token"), !encrypted.isEmpty {
            result = try object(HanimeHandshakeCodec.open(encrypted))
        } else if let plain = try? object(bytes), !rows(plain["sources"]).isEmpty {
            // Some authorized first-party player responses expose the stream
            // manifest directly rather than in an encrypted response header.
            // A valid 2xx response and official media host are still required.
            result = plain
        } else {
            throw APIError.server("Hanime did not return a playable HLS handshake. Use the original website or a configured authorized Hanime API in Settings.")
        }
        let streams = rows(result["sources"])
            .filter { text($0["kind"]).lowercased() == "normal" }
            .sorted { number($0["height"]) > number($1["height"]) }
        let playable = streams.compactMap { source -> URL? in
            let raw = text(source["src"])
            guard !raw.isEmpty,
                  let address = URL(string: raw, relativeTo: origin(.hanime))?.absoluteURL,
                  HanimeGeneratedAPI.permittedStreamURL(address) else { return nil }
            return address
        }
        guard !playable.isEmpty else {
            throw APIError.server("Hanime returned no playable HLS stream for this video. Use Browse inside QuickTick or configure an authorized Hanime API in Settings.")
        }
        // HLS URLs from the signed handshake must be handed straight to
        // AVPlayer. A separate GET preflight can consume a short-lived token
        // or use different headers from the native media loader, making a
        // previously playable video fail as "HLS stream error".
        // After a genuine AVPlayer failure, request a fresh handshake and
        // step down through the advertised variants without probing/using up
        // the playlist URL. Normal first playback still picks best quality.
        let selected = playable[min(max(0, variant), playable.count - 1)]
        let extensionName = selected.pathExtension.lowercased()
        return ResolvedMedia(mediaUrl: selected.absoluteString,
                             type: ["mp4", "m4v"].contains(extensionName) ? "video" : "hls")
    }

    /// Prefer native AVPlayer for catalog entries that legitimately include a
    /// first-party HLS/MP4 URL. The v11 catalog often omits streams entirely;
    /// never interpret a watch page or external link as playable media.
    static func hanimeCatalogStream(_ row: [String: Any]) -> String {
        let direct = ["stream_url", "hls_url", "video_url", "media_url", "streamUrl", "videoUrl"]
            .map { text(row[$0]) }
        let manifest = row["videos_manifest"] as? [String: Any] ?? [:]
        let embedded = rows(manifest["servers"])
            .flatMap { rows($0["streams"]) }
            .sorted { number($0["height"]) > number($1["height"]) }
            .map { text($0["url"]) }
        return (direct + embedded).compactMap { mediaURL($0, provider: .hanime) }
            .first(where: HanimeGeneratedAPI.permittedStreamURL)?.absoluteString ?? ""
    }

    /// Keep Hanime artwork tied to an actual title's first-party poster. The
    /// catalog has used both flat and nested thumbnail fields; choosing the
    /// first non-nil field misses newer nested covers and produces empty chips.
    static func hanimePosterURL(_ row: [String: Any]) -> String {
        let keys = ["poster_url", "cover_url", "thumbnail_url", "posterUrl", "coverUrl",
                    "thumbnail", "poster", "cover", "images"]
        var candidates: [String] = []
        for key in keys {
            if let raw = row[key] as? String { candidates.append(raw) }
            if let values = row[key] as? [String: Any] {
                for field in ["large", "original", "url", "src", "medium", "thumbnail"] {
                    if let raw = values[field] as? String { candidates.append(raw) }
                }
            }
            if let values = row[key] as? [String] { candidates.append(contentsOf: values) }
        }
        return candidates.compactMap { raw -> URL? in
            guard let url = URL(string: raw, relativeTo: origin(.hanime))?.absoluteURL,
                  url.scheme == "https", url.user == nil, url.password == nil,
                  let host = url.host?.lowercased(),
                  host == "hanime.tv" || host.hasSuffix(".hanime.tv") else {
                return nil
            }
            return url
        }.first?.absoluteString ?? ""
    }

    /// The public catalog is a useful read-only fallback when the first-party
    /// JSON API returns 403, an HTML error, or an unexpectedly empty response.
    /// Only genuine Hanime watch links are accepted; HTML is never passed to
    /// AVPlayer as a video stream.
    static func parseHanimeWebsiteCatalog(_ html: String) -> [Post] {
        let pattern = #"(?i)href\s*=\s*["'](?:https://(?:www\.)?hanime\.tv)?(/videos/hentai/([a-z0-9]+(?:-[a-z0-9]+)*)/?)(?:\?[^"']*)?["']"#
        guard let linkPattern = try? NSRegularExpression(pattern: pattern) else { return [] }
        let content = html as NSString
        let links = linkPattern.matches(in: html, range: NSRange(location: 0, length: content.length))
        let titlePattern = try? NSRegularExpression(pattern: #"(?i)(?:title|alt|aria-label)\s*=\s*["']([^"']{3,180})["']"#)
        let imagePattern = try? NSRegularExpression(pattern: #"(?i)(?:data-src|data-original|src|poster)\s*=\s*["']([^"']+)["']"#)
        var seen = Set<String>()
        var posts: [Post] = []
        for link in links.prefix(160) {
            let slug = content.substring(with: link.range(at: 2)).lowercased()
            guard seen.insert(slug).inserted else { continue }
            // Limit metadata to the link's own card, so a nearby unrelated
            // title or poster cannot be attributed to this video.
            let segment = content.substring(with: NSRange(location: link.range.location,
                length: min(3000, content.length - link.range.location)))
            let anchorEnd = segment.range(of: "</a>", options: .caseInsensitive)?.upperBound
            let anchor = String(anchorEnd.map { segment[..<$0] } ?? segment.prefix(1200))
            let anchorRange = NSRange(location: 0, length: (anchor as NSString).length)
            let namedTitle = titlePattern?.firstMatch(in: anchor, range: anchorRange).map {
                (anchor as NSString).substring(with: $0.range(at: 1))
            }
            let inlineText = anchor.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = slug.replacingOccurrences(of: "-", with: " ").capitalized
            let title = (namedTitle ?? (inlineText.count <= 180 ? inlineText : ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let caption = (title.isEmpty ? fallback : title)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            let poster = (imagePattern?.matches(in: anchor, range: anchorRange) ?? [])
                .compactMap { match -> String? in
                    let raw = (anchor as NSString).substring(with: match.range(at: 1))
                    guard let url = URL(string: raw, relativeTo: origin(.hanime))?.absoluteURL,
                          url.scheme == "https", url.user == nil, url.password == nil,
                          let host = url.host?.lowercased(),
                          host == "hanime.tv" || host.hasSuffix(".hanime.tv"),
                          ["jpg", "jpeg", "png", "webp", "avif"].contains(url.pathExtension.lowercased())
                    else { return nil }
                    return url.absoluteString
                }.first ?? ""
            var post = Post(key: "hanime:\(slug)", id: slug, provider: "Hanime",
                            tags: caption.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                                .prefix(16).map(String.init),
                            thumbUrl: poster, pageUrl: "https://hanime.tv/videos/hentai/\(slug)",
                            type: "video")
            post.caption = caption
            posts.append(post)
        }
        return posts
    }

    static func hanimeWebsitePage(_ html: String, query: ParsedQuery,
                                  immersive: Bool) throws -> PostPage {
        guard !unavailableHTML(Data(html.utf8)) else {
            throw APIError.server("Hanime's public website returned an unavailable page.")
        }
        let catalog = parseHanimeWebsiteCatalog(html)
        guard !catalog.isEmpty else {
            throw APIError.server("Hanime's public website did not expose video links.")
        }
        let matched = catalog.filter { post in
            query.included.allSatisfy { containsKeyword($0, in: post) }
        }
        return self.page(matched, hasMore: false, query: query, immersive: immersive)
    }

    static func hanimeWebsiteCatalog(session: URLSession, query: ParsedQuery,
                                     page: Int, immersive: Bool) async throws -> PostPage {
        // The public website has no verified paging contract. Do not repeat
        // the homepage as page two or silently invent pagination URLs.
        guard page == 1 else { return PostPage(items: [], hasMore: false) }
        let urls = [URL(string: "https://hanime.tv/")!,
                    URL(string: "https://hanime.tv/browse")!]
        var sawReadableCatalog = false
        for address in urls {
            do {
                let bytes = try await data(session: session, url: address, provider: .hanime,
                    headers: ["Accept": "text/html,application/xhtml+xml;q=0.9"],
                    maxBytes: 5 * 1024 * 1024, timeout: 8)
                let page = try hanimeWebsitePage(String(decoding: bytes, as: UTF8.self),
                                                 query: query, immersive: immersive)
                if !page.items.isEmpty { return page }
                sawReadableCatalog = true
            } catch is CancellationError { throw CancellationError() }
              catch { /* Try the next official catalog route. */ }
        }
        // The URLProtocol test session must never escape its fixtures by
        // contacting the real website through an independent WKWebView.
        if session.configuration.protocolClasses?.isEmpty != false {
            for address in urls {
                do {
                    let html = try await HanimeBrowserCatalog.html(url: address)
                    let page = try hanimeWebsitePage(html, query: query, immersive: immersive)
                    if !page.items.isEmpty { return page }
                    sawReadableCatalog = true
                } catch is CancellationError { throw CancellationError() }
                  catch { /* A normal verification wall stays a real failure. */ }
            }
        }
        if sawReadableCatalog { return PostPage(items: [], hasMore: false) }
        throw APIError.server("Hanime's public search, member catalog, v11 API and website are all unavailable on this connection. Open Hanime in Browse to check site access, or configure an authorized Hanime API in Settings.")
    }

    /// The search index and member catalog were the working feed transports
    /// before the v11 auth-only migration. Restore their public read routes;
    /// the v11 handshake remains the native *playback* resolver.
    static func hanimeSearchBody(query: ParsedQuery, page: Int, sort: String) throws -> Data {
        let body: [String: Any] = [
            "search_text": query.included.joined(separator: " "),
            "tags": [], "tags_mode": "AND", "brands": [], "blacklist": [],
            "order_by": sort == "recent" ? "released_at_unix" : "views",
            "ordering": "desc", "page": max(0, page - 1)
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func hanimeCatalogPost(_ row: [String: Any]) -> Post? {
        let id = text(row["slug"] ?? row["hentai_video_slug"] ?? row["id"])
        guard !id.isEmpty, id.count <= 160,
              id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        let tags = strings(row["hentai_tags"] ?? row["tags"] ?? row["genres"])
        var post = Post(key: "hanime:\(id)", id: id, provider: "Hanime",
                        score: number(row["views"] ?? row["views_count"]), tags: tags,
                        mediaUrl: hanimeCatalogStream(row), thumbUrl: hanimePosterURL(row),
                        pageUrl: "https://hanime.tv/videos/hentai/\(id)", type: "video")
        post.caption = text(row["name"] ?? row["title"])
        post.creator = text((row["brand"] as? [String: Any])?["name"] ?? row["brand"])
        post.createdAt = number(row["released_at_unix"] ?? row["created_at_unix"])
        return post
    }

    static func hanimePublicSearch(session: URLSession, query: ParsedQuery,
                                   page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let bytes = try await data(session: session,
            url: url("https://search.htv-services.com/"), provider: .hanime,
            method: "POST", body: hanimeSearchBody(query: query, page: page, sort: sort),
            maxBytes: 12 * 1024 * 1024, timeout: 12)
        let result = try object(bytes)
        let raw = try hanimeRows(result)
        guard raw.count <= 20_000 else { throw APIError.invalidResponse }
        let posts = raw.compactMap(hanimeCatalogPost)
        let count = Int(number(result["nbPages"] ?? result["pages"] ?? result["total_pages"]))
        return self.page(posts, hasMore: count > 0 ? page < count : raw.count >= 24,
                         query: query, immersive: immersive)
    }

    static func hanimeMembersCatalog(session: URLSession, query: ParsedQuery,
                                     page: Int, immersive: Bool) async throws -> PostPage {
        // The member listing does not implement a reliable title search. It
        // may only back up an unfiltered home/immersive feed.
        guard query.included.isEmpty else { throw APIError.invalidResponse }
        let bytes = try await data(session: session,
            url: url("https://members.hanime.tv/rapi/v7/hentai_videos", [
                .init(name: "source", value: "randomize"),
                .init(name: "r", value: String(page))
            ]), provider: .hanime, maxBytes: 12 * 1024 * 1024, timeout: 12)
        let raw = try hanimeRows(JSONSerialization.jsonObject(with: bytes))
        guard raw.count <= 20_000 else { throw APIError.invalidResponse }
        return self.page(raw.compactMap(hanimeCatalogPost), hasMore: !raw.isEmpty,
                         query: query, immersive: immersive)
    }

    static func hanime(session: URLSession, query: ParsedQuery, page: Int,
                       sort: String, immersive: Bool) async throws -> PostPage {
        guard (1...1000).contains(page) else { throw APIError.invalidResponse }
        do {
            let pageResult = try await hanimePublicSearch(session: session, query: query,
                page: page, sort: sort, immersive: immersive)
            if !pageResult.items.isEmpty || !query.included.isEmpty || page > 1 { return pageResult }
        } catch is CancellationError { throw CancellationError() }
          catch APIError.rateLimited(_, let deadline) { throw APIError.rateLimited(.hanime, deadline) }
          catch APIError.providerStatus(.hanime, 451) { throw APIError.providerStatus(.hanime, 451) }
          catch { try Task.checkCancellation() }

        if query.included.isEmpty {
            do {
                let pageResult = try await hanimeMembersCatalog(session: session, query: query,
                    page: page, immersive: immersive)
                if !pageResult.items.isEmpty || page > 1 { return pageResult }
            } catch is CancellationError { throw CancellationError() }
              catch APIError.rateLimited(_, let deadline) { throw APIError.rateLimited(.hanime, deadline) }
              catch APIError.providerStatus(.hanime, 451) { throw APIError.providerStatus(.hanime, 451) }
              catch { try Task.checkCancellation() }
        }

        // The supplied API describes the current first-party v11 catalog.
        // It may require legitimate browser verification; HTTP 403 is never bypassed.
        let claim = String(Int(Date().timeIntervalSince1970))
        let headers = ["Accept": "application/json", "Origin": "https://hanime.tv",
                       "Referer": "https://hanime.tv/", "x-signature-version": "app2",
                       "x-claim": claim, "x-signature": hanimeSignature(claim: claim), "x-session-token": ""]
        let bytes: Data
        do {
            bytes = try await data(session: session,
                url: url("https://auth.hanime.tv/api/v11/search_hvs"), provider: .hanime,
                headers: headers, maxBytes: 12 * 1024 * 1024, timeout: 20)
        } catch is CancellationError { throw CancellationError() }
          catch APIError.rateLimited(_, let deadline) { throw APIError.rateLimited(.hanime, deadline) }
          catch APIError.providerStatus(.hanime, 451) { throw APIError.providerStatus(.hanime, 451) }
          catch {
            return try await hanimeWebsiteCatalog(session: session, query: query,
                                                  page: page, immersive: immersive)
        }
        let raw: [[String: Any]]
        do { raw = try hanimeRows(JSONSerialization.jsonObject(with: bytes)) }
        catch {
            return try await hanimeWebsiteCatalog(session: session, query: query,
                                                  page: page, immersive: immersive)
        }
        if raw.isEmpty, page == 1 {
            return try await hanimeWebsiteCatalog(session: session, query: query,
                                                  page: page, immersive: immersive)
        }
        guard raw.count <= 20_000 else { throw APIError.invalidResponse }
        let posts = raw.compactMap(hanimeCatalogPost)
        if posts.isEmpty, page == 1, query.included.isEmpty {
            return try await hanimeWebsiteCatalog(session: session, query: query,
                                                  page: page, immersive: immersive)
        }
        let contains: (String, Post) -> Bool = { term, post in
            let needle = term.lowercased().replacingOccurrences(of: "_", with: " ")
            let haystack = ([post.caption ?? "", post.creator ?? ""] + post.tags)
                .joined(separator: " ").lowercased().replacingOccurrences(of: "_", with: " ")
            return haystack.contains(needle)
        }
        let matched = posts.filter { post in
            query.included.allSatisfy { contains($0, post) } &&
            !query.excluded.contains { contains($0, post) }
        }
        let ordered = matched.sorted {
            let left = sort == "recent" ? ($0.createdAt ?? 0) : $0.score
            let right = sort == "recent" ? ($1.createdAt ?? 0) : $1.score
            return left == right ? $0.id < $1.id : left > right
        }
        let start = (page - 1) * 24
        guard start < ordered.count else { return PostPage(items: [], hasMore: false) }
        let portion = Array(ordered[start..<min(start + 24, ordered.count)])
        return self.page(portion, hasMore: start + portion.count < ordered.count,
                         query: query, immersive: immersive)
    }

    /// HHaven documents Hentai Haven's v1 routes. The Warden endpoint issues a
    /// scoped API token for an app client; use an honest iOS client identity,
    /// never a fabricated Android emulator fingerprint.
    static func havenToken(session: URLSession) async throws -> String {
        let body = "sdkInt=0&board=ios&brand=Apple&display=QuickTick_iOS&fingerprint=QuickTick_iOS&manufacturer=Apple&model=iOS"
        let bytes = try await data(session: session,
            url: url("https://api.hentaihaven.app/v1/warden"), provider: .hhaven,
            method: "POST", body: Data(body.utf8), headers: [
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "User-Agent": "HH_xxx_APP", "warden": ""
            ], timeout: 6)
        guard !unavailableHTML(bytes) else {
            throw APIError.server("Hentai Haven's catalog API is currently unavailable. Its server returned an unavailable page instead of a token.")
        }
        guard !String(decoding: bytes.prefix(100), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
            throw APIError.server("Hentai Haven returned a web page instead of an API token. The catalog may require access through its official app.")
        }
        let response = try object(bytes)
        try checkHavenEmbeddedStatus(response)
        let payload = response["data"] as? [String: Any] ?? [:]
        let token = text(payload["token"])
        guard !token.isEmpty else {
            throw APIError.server("Hentai Haven did not issue a Warden token for this iOS client. Access may require its official app.")
        }
        return token
    }

    static func havenRequest(session: URLSession, token: String, path: String,
                             parameters: [URLQueryItem] = []) async throws -> [String: Any] {
        let bytes = try await data(session: session,
            url: url("https://api.hentaihaven.app/v1/" + path, parameters),
            provider: .hhaven, headers: ["User-Agent": "HH_xxx_APP", "warden": token], timeout: 7)
        guard !unavailableHTML(bytes) else {
            throw APIError.server("Hentai Haven's catalog API is currently unavailable. Try again when its server is reachable.")
        }
        guard !String(decoding: bytes.prefix(100), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
            throw APIError.server("Hentai Haven returned a web page instead of catalog data. It may be restricted from this client.")
        }
        let result = try object(bytes)
        try checkHavenEmbeddedStatus(result)
        return result
    }

    static func checkHavenEmbeddedStatus(_ result: [String: Any]) throws {
        // This API can return 200 HTTP with a string body beginning "502" or
        // "429". Treating those as a successful empty catalog caused repeated
        // blank feeds and needless refreshes.
        guard let message = result["data"] as? String,
              message.count >= 3, let code = Int(message.prefix(3)),
              (400...599).contains(code) else { return }
        if code == 429 { throw APIError.rateLimited(.hhaven, .now.addingTimeInterval(30)) }
        throw APIError.server("Hentai Haven's upstream API returned error \(code). Its catalog may be temporarily unavailable.")
    }

    static func haven(session: URLSession, token: String, query: ParsedQuery,
                      page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let selection = ProviderSearchCategories.split(query, provider: .hhaven)
        let section = selection.category?.hasPrefix("category:section:") == true
            ? String(selection.category!.dropFirst("category:section:".count)) : nil
        let genreID = selection.category?.hasPrefix("category:genre:") == true
            ? String(selection.category!.dropFirst("category:genre:".count)) : nil
        let searching = selection.category == nil && !selection.keywords.isEmpty
        if searching && page > 1 { return PostPage(items: [], hasMore: false) }
        let route: String
        let parameters: [URLQueryItem]
        if section != nil {
            route = "hentai/home"; parameters = []
        } else if let genreID {
            route = "genre/" + genreID
            parameters = [.init(name: "p", value: String(max(1, page)))]
        } else if searching {
            route = "search"
            parameters = [.init(name: "q", value: selection.keywords.joined(separator: " "))]
        } else if sort == "popular" && page == 1 {
            route = "hentai/home"
            parameters = []
        } else {
            route = "hentai/all"
            parameters = [.init(name: "p", value: String(max(1, page)))]
        }
        let result = try await havenRequest(session: session, token: token,
                                           path: route, parameters: parameters)
        let data = result["data"]
        let payload = data as? [String: Any] ?? [:]
        let entries: [[String: Any]]
        if searching { entries = rows(data) }
        else if route == "hentai/home" {
            if let section { entries = rows(payload[section]) }
            else {
                // The provider may leave its main index sections empty while
                // other public home categories remain populated. Merge all
                // available sections instead of treating that as a blank feed.
                let sections = ["trending_month", "last", "yuri", "ecchi", "uncensored", "tentacle", "incest"]
                var seen = Set<String>()
                entries = sections.flatMap { rows(payload[$0]) }.filter { item in
                    let id = text(item["post_id"] ?? item["id"])
                    return !id.isEmpty && seen.insert(id).inserted
                }
            }
        } else { entries = rows(payload["hentais"]) }
        if route == "hentai/all", page == 1, selection.category == nil, entries.isEmpty {
            // The catalog endpoint has sometimes returned an empty first page
            // while the Home sections were populated. Try that independent
            // first-party index once before declaring the entire source empty.
            return try await haven(session: session, token: token, query: query,
                                   page: 1, sort: "popular", immersive: immersive)
        }
        if selection.category == nil, !searching, page == 1, entries.isEmpty {
            throw APIError.server("Hentai Haven returned an empty catalog. Its provider API may be unavailable or may have changed its response format.")
        }
        let posts: [Post] = entries.compactMap { entry in
            let id = text(entry["post_id"] ?? entry["id"])
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            let title = text(entry["post_title"] ?? entry["title"])
            var post = Post(key: "hhaven:\(id)", id: id, provider: Provider.hhaven.rawValue,
                            tags: ["hentai"] + title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init),
                            thumbUrl: text(entry["post_thumbnail"] ?? entry["thumbnail"]),
                            pageUrl: "https://hentaihaven.xxx/", type: "video")
            post.caption = title
            if let section { post.category = section }
            return post
        }.filter { post in
            selection.category == nil || selection.keywords.allSatisfy { containsKeyword($0, in: post) }
        }
        let pages = Int(number(payload["total_pages"]))
        return self.page(posts, hasMore: !searching && route != "hentai/home" &&
            (pages > 0 ? page < pages : !entries.isEmpty), query: query, immersive: immersive)
    }

    /// The third-party Warden API can reject independent iOS clients. When it
    /// does, show the titles on Hentai Haven's public website using their real
    /// watch URLs. Web posts open in the in-app browser; never pretend an HTML
    /// watch page is an AVPlayer-compatible stream or downloadable media file.
    static func havenWebsiteCatalog(session: URLSession, query: ParsedQuery,
                                    page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        guard !immersive else { return PostPage(items: [], hasMore: false) }
        guard let website = havenWebsiteURL(sort: sort, query: query, page: page) else {
            throw APIError.server("This Hentai Haven category is only available through its catalog API.")
        }
        let bytes = try await data(session: session, url: website, provider: .hhaven,
                                   headers: ["Accept": "text/html,application/xhtml+xml"], maxBytes: 5 * 1024 * 1024,
                                   timeout: 5)
        return try havenWebsitePage(String(decoding: bytes, as: UTF8.self), query: query,
                                    page: page, sort: sort)
    }

    static func havenWebsiteURL(sort: String, query: ParsedQuery, page: Int = 1) -> URL? {
        guard (1...50).contains(page) else { return nil }
        let section = ProviderSearchCategories.split(query, provider: .hhaven).category
        if let section, section.hasPrefix("category:genre:") { return nil }
        let slug = section?.replacingOccurrences(of: "category:section:", with: "") ?? ""
        let path: String
        switch slug {
        case "trending_month": path = "/browse/trending/"
        case "last": guard page == 1 else { return nil }; path = "/"
        case "" where sort == "popular": path = "/browse/trending/"
        case "": guard page == 1 else { return nil }; path = "/"
        default: guard page == 1 else { return nil }; path = "/series/\(slug)/"
        }
        // Verified against Hentai Haven's public page-two link. Do not assume
        // the site's other category or search routes use this pagination.
        let suffix = page > 1 ? "page/\(page)/" : ""
        return URL(string: "https://hentaihaven.xxx" + path + suffix)
    }

    /// The same strict parser is used for a normal HTTP response and, if the
    /// website blocks raw URLSession requests, the page loaded by WebKit.
    /// Browser-generated HTML is still untrusted input: only canonical watch
    /// links become catalog entries, and unrelated search results are dropped.
    static func havenWebsitePage(_ html: String, query: ParsedQuery,
                                 page: Int = 1, sort: String = "recommended") throws -> PostPage {
        guard !unavailableHTML(Data(html.utf8)) else {
            throw APIError.server("Hentai Haven's public site returned an unavailable page.")
        }
        let selection = ProviderSearchCategories.split(query, provider: .hhaven)
        let posts = parseHavenWebsiteCatalog(html).map { item -> Post in
            var post = item
            if let category = selection.category { post.category = category }
            return post
        }
        guard !posts.isEmpty else {
            throw APIError.server("Hentai Haven's website did not expose readable watch links.")
        }
        // The public homepage is not a search endpoint. Filtering locally is
        // essential: otherwise a failed search silently turns into unrelated
        // homepage recommendations and teaches the taste model false positives.
        let matched = posts.filter { post in
            selection.keywords.allSatisfy { containsKeyword($0, in: post) }
        }
        let trending = selection.category == "category:section:trending_month" ||
            selection.category == nil && sort == "popular"
        return self.page(matched, hasMore: trending && matched.count >= 20 && page < 50,
                         query: query, immersive: false)
    }

    static func parseHavenWebsiteCatalog(_ html: String) -> [Post] {
        let pattern = #"(?i)href\s*=\s*["'](?:https://(?:www\.)?hentaihaven\.xxx)?(/watch/([a-z0-9-]+)/?)["']"#
        guard let linkPattern = try? NSRegularExpression(pattern: pattern) else { return [] }
        let content = html as NSString
        let matches = linkPattern.matches(in: html, range: NSRange(location: 0, length: content.length))
        let imagePattern = try? NSRegularExpression(pattern:
            #"(?i)(?:data-src|src)\s*=\s*["'](https://(?:img\.hentaihaven\.xxx|coverlanyvd\.org)/[^"']+)["']"#)
        let titlePattern = try? NSRegularExpression(pattern: #"(?i)(?:alt|title)\s*=\s*["']([^"']{3,180})["']"#)
        var unique = Set<String>()
        var posts: [Post] = []
        for match in matches.prefix(160) {
            let slug = content.substring(with: match.range(at: 2)).lowercased()
            guard unique.insert(slug).inserted else { continue }
            let path = content.substring(with: match.range(at: 1))
            let section = NSRange(location: match.range.location,
                length: min(1300, content.length - match.range.location))
            let snippet = content.substring(with: section)
            let snippetRange = NSRange(location: 0, length: (snippet as NSString).length)
            let title = titlePattern?.firstMatch(in: snippet, range: snippetRange).map {
                (snippet as NSString).substring(with: $0.range(at: 1))
            } ?? slug.replacingOccurrences(of: "-", with: " ").capitalized
            let image = imagePattern?.firstMatch(in: snippet, range: snippetRange).map {
                (snippet as NSString).substring(with: $0.range(at: 1))
            } ?? ""
            let caption = title.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            let tags = caption.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .prefix(16).map(String.init)
            let pageURL = "https://hentaihaven.xxx" + path
            // The public catalog only supplies watch-page metadata. Treat it
            // as an unresolved *video*: the player resolves media privately
            // in the app and never navigates the user to a web browser.
            var post = Post(key: "hhaven:web:\(slug)", id: slug, provider: Provider.hhaven.rawValue,
                            tags: tags, thumbUrl: image, pageUrl: pageURL, type: "video")
            post.caption = caption
            posts.append(post)
        }
        return posts
    }

    static func havenResolve(session: URLSession, token: String, post: Post) async throws -> ResolvedMedia {
        guard !post.id.isEmpty, post.id.allSatisfy(\.isNumber) else { throw APIError.invalidResponse }
        let details = try await havenRequest(session: session, token: token, path: "hentai/\(post.id)")
        let payload = details["data"] as? [String: Any] ?? [:]
        let episodes = rows(payload["episodes"])
        guard let episode = episodes.first,
              let episodeID = [text(episode["chapter_id"]), text(episode["id"])].first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { throw APIError.server("Hentai Haven returned no available episode for this title.") }
        let result = try await havenRequest(session: session, token: token,
                                             path: "hentai/\(post.id)/episode/\(episodeID)")
        let info = result["data"] as? [String: Any] ?? [:]
        guard let media = havenEpisodeMedia(info) else {
            throw APIError.server("Hentai Haven did not return a playable episode stream.")
        }
        return media
    }

    /// Warden responses vary between a direct URL, embedded <video> markup,
    /// and JSON-encoded player sources. All three describe the same episode.
    /// Never hand AVPlayer an HTML document or an unsupported embed URL.
    static func havenEpisodeMedia(_ info: [String: Any]) -> ResolvedMedia? {
        let base = URL(string: "https://hentaihaven.xxx/")!
        for key in ["chapter_content", "content", "stream_url", "video_url", "file", "hls"] {
            let value = text(info[key])
            if let asset = mediaURL(value, provider: .hhaven),
               ["mp4", "m4v", "mov", "m3u8"].contains(asset.pathExtension.lowercased()) {
                return ResolvedMedia(mediaUrl: asset.absoluteString,
                                     type: asset.pathExtension.lowercased() == "m3u8" ? "hls" : "video")
            }
            if let result = havenWatchMedia(value, page: base) { return result }
        }
        for key in ["sources", "streams", "videos"] {
            for source in rows(info[key]) {
                if let result = havenEpisodeMedia(source) { return result }
                for value in source.values {
                    if let raw = value as? String,
                       let result = havenWatchMedia("file: '\(raw)'", page: base) { return result }
                }
            }
        }
        return nil
    }

    /// Read a public watch page only for a canonical Haven catalog entry.
    /// It is a best-effort fallback when Warden is inaccessible; it never
    /// returns the HTML page as a video URL or follows a cross-site redirect.
    static func havenPublicResolve(session: URLSession, post: Post) async throws -> ResolvedMedia {
        guard let page = URL(string: post.pageUrl), page.scheme == "https",
              ["hentaihaven.xxx", "www.hentaihaven.xxx"].contains(page.host?.lowercased() ?? ""),
              page.path.hasPrefix("/watch/"), page.user == nil, page.password == nil else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: page)
        request.timeoutInterval = 10
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let status = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard status.statusCode == 200 else { throw APIError.providerStatus(.hhaven, status.statusCode) }
        guard let destination = status.url,
              ["hentaihaven.xxx", "www.hentaihaven.xxx"].contains(destination.host?.lowercased() ?? ""),
              destination.path.hasPrefix("/watch/") else {
            throw APIError.server("Hentai Haven redirected its player outside the provider; no external website was opened.")
        }
        guard data.count < 2 * 1024 * 1024 else { throw APIError.invalidResponse }
        let html = String(decoding: data, as: UTF8.self)
        guard !unavailableHTML(data), let media = havenWatchMedia(html, page: destination) else {
            throw APIError.server("Hentai Haven did not expose a playable in-app stream for this title.")
        }
        return media
    }

    static func havenWatchMedia(_ html: String, page: URL) -> ResolvedMedia? {
        guard !unavailableHTML(Data(html.utf8)) else { return nil }
        // Prefer player-specific sources over unrelated promotional links.
        // The fallback deliberately accepts only direct HTTPS video assets.
        let patterns = [
            #"(?is)<source\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
            #"(?is)<video\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
            #"(?i)["'](?:file|hls|video_url|stream_url|contentUrl)["']\s*:\s*["']([^"']+)["']"#,
            #"(?i)(?:file|src|url|playlist)\s*:\s*["']([^"']+)["']"#
        ]
        for pattern in patterns {
            for raw in matches(html, pattern).prefix(12) {
                let decoded = raw.replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "&amp;", with: "&")
                guard let asset = URL(string: decoded, relativeTo: page)?.absoluteURL,
                      asset.scheme == "https", asset.user == nil, asset.password == nil,
                      ["mp4", "m4v", "mov", "m3u8"].contains(asset.pathExtension.lowercased()) else { continue }
                return ResolvedMedia(mediaUrl: asset.absoluteString,
                                     type: asset.pathExtension.lowercased() == "m3u8" ? "hls" : "video")
            }
        }
        return nil
    }

    static func pornhubCategories(session: URLSession, credentials: ProviderCredentials) async throws -> [String] {
        let bytes = try await data(session: session, url: url("https://www.pornhub.com/webmasters/categories"),
                                   provider: .pornhub, headers: cookieHeaders(credentials))
        let result = try object(bytes)
        let values = rows(result["categories"]).map { text($0["category"] ?? $0["name"]) }
        return Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Artwork comes from the first-party category page or from a video whose
    /// structured category metadata independently confirms membership. A
    /// matching title alone must never supply a category's cover image.
    static func pornhubCategoryPreview(session: URLSession, credentials: ProviderCredentials,
                                       token: String) async throws -> String? {
        guard ProviderSearchCategories.valid(token, provider: .pornhub) else { return nil }
        let slug = String(token.dropFirst("category:".count))
        let source = try url("https://www.pornhub.com/categories/" + slug)
        let bytes: Data?
        do {
            bytes = try await data(session: session, url: source, provider: .pornhub,
                headers: cookieHeaders(credentials).merging([
                    "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.7"
                ]) { _, html in html }, maxBytes: 2 * 1024 * 1024)
        } catch APIError.providerStatus(.pornhub, let status)
            where [404, 410].contains(status) { bytes = nil }
        if let bytes, !unavailableHTML(bytes),
           let preview = pornhubHTMLPosts(String(decoding: bytes, as: UTF8.self))
                .map(\.cardPreviewURL)
                .first(where: { URL(string: $0)?.scheme == "https" }) {
            return preview
        }
        // Some first-party category HTML routes are retired even while the
        // ordinary webmaster catalog still supplies category-specific media
        // metadata. Use only a verified category association from that API.
        let listing = try await pornhubWebmasterJSON(session: session, credentials: credentials,
            parameters: [.init(name: "category", value: slug),
                         .init(name: "thumbsize", value: "large_hd"),
                         .init(name: "page", value: "1")])
        let normalized = slug.replacingOccurrences(of: "-", with: "")
        for video in rows(listing?["videos"]) {
            let confirmed = strings(video["categories"]).contains { label in
                label.lowercased().filter(\.isLetter) == normalized
            }
            guard confirmed else { continue }
            let options = [text(video["hd_thumb"]), text(video["default_thumb"]), text(video["thumb"])]
                + rows(video["thumbs"]).map { text($0["src"] ?? $0["url"]) }
            if let preview = options.compactMap({ mediaURL($0, provider: .pornhub) })
                .first(where: { ["jpg", "jpeg", "png", "webp", "avif"].contains($0.pathExtension.lowercased()) }) {
                return preview.absoluteString
            }
        }
        return nil
    }

    static func pornhubSearchParameters(query: ParsedQuery, page: Int, sort: String) -> [URLQueryItem] {
        let selection = ProviderSearchCategories.split(query, provider: .pornhub)
        let filters = (query.pornhub ?? PornhubSearchFilters()).normalized
        let ordering = query.pornhub == nil
            ? (sort == "recent" ? "newest" : sort == "popular" ? "mostviewed" : "featured")
            : filters.order.ordering
        var params = [URLQueryItem(name: "page", value: String(max(1, page))),
                      URLQueryItem(name: "ordering", value: ordering),
                      URLQueryItem(name: "thumbsize", value: "large_hd")]
        if !selection.keywords.isEmpty {
            params.insert(.init(name: "search", value: selection.keywords.joined(separator: " ")), at: 0)
        }
        if let category = filters.includedCategory ?? selection.category.map({ String($0.dropFirst("category:".count)) }) {
            params.append(.init(name: "category", value: category))
        }
        if ordering != "featured" { params.append(.init(name: "period", value: "monthly")) }
        if filters.production != .all { params.append(.init(name: "production", value: filters.production.rawValue)) }
        if filters.minimumMinutes > 0 { params.append(.init(name: "min_duration", value: String(filters.minimumMinutes))) }
        if filters.maximumMinutes < 40 { params.append(.init(name: "max_duration", value: String(filters.maximumMinutes))) }
        for category in filters.excludedCategories { params.append(.init(name: "exclude_category[]", value: category)) }
        return params
    }

    static func pornhubDurationSeconds(_ raw: Any?) -> Int? {
        if let value = raw as? NSNumber { return max(0, value.intValue) }
        let parts = text(raw).split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func pornhubMatches(_ row: [String: Any], filters: PornhubSearchFilters) -> Bool {
        let options = filters.normalized
        if options.minimumMinutes > 0 || options.maximumMinutes < 40 {
            guard let seconds = pornhubDurationSeconds(row["duration"]) else { return false }
            if seconds < options.minimumMinutes * 60 { return false }
            if options.maximumMinutes < 40 && seconds > options.maximumMinutes * 60 { return false }
        }
        func key(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        let available = Set(strings(row["categories"]).map(key))
        if let category = options.includedCategory, !available.isEmpty, !available.contains(key(category)) { return false }
        if options.excludedCategories.contains(where: { available.contains(key($0)) }) { return false }
        let production = text(row["production"] ?? row["production_type"]).lowercased()
        if options.production != .all, !production.isEmpty, production != options.production.rawValue { return false }
        return true
    }

    static func pornhub(session: URLSession, credentials: ProviderCredentials, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let selection = ProviderSearchCategories.split(query, provider: .pornhub)
        // The public webmaster API accepts browsing without a search term.
        // An explicit `search=` with an empty value is not equivalent on all
        // deployments and has returned the site's generic 404 page.
        let parameters = pornhubSearchParameters(query: query, page: page, sort: sort)
        // The legacy webmaster path sometimes responds with HTTP 200 and an
        // Apache "requested URL was not found" HTML body. Recognize that as
        // a dead API route and try first-party alternatives before parsing.
        guard let result = try await pornhubWebmasterJSON(session: session,
                credentials: credentials, parameters: parameters) else {
            return try await pornhubPublicCatalog(session: session, credentials: credentials,
                query: query, page: page, sort: sort, immersive: immersive)
        }
        let raw = rows(result["videos"])
        if raw.isEmpty, page == 1, selection.keywords.isEmpty {
            return try await pornhubPublicCatalog(session: session, credentials: credentials,
                query: query, page: page, sort: sort, immersive: immersive)
        }
        let options = query.pornhub ?? PornhubSearchFilters()
        var filtered = raw.filter { pornhubMatches($0, filters: options) }
        if options.order == .longest {
            filtered.sort { (pornhubDurationSeconds($0["duration"]) ?? 0) > (pornhubDurationSeconds($1["duration"]) ?? 0) }
        }
        let posts = filtered.map { row -> Post in
            let id = text(row["video_id"] ?? row["id"])
            let images = [text(row["default_thumb"]), text(row["thumb"]), text(row["hd_thumb"])]
                + rows(row["thumbs"]).map { text($0["src"] ?? $0["url"]) }
            var posters: [String] = []
            for candidate in images where !candidate.isEmpty {
                if let valid = mediaURL(candidate)?.absoluteString, !posters.contains(valid) { posters.append(valid) }
            }
            var post = Post(key: "pornhub:\(id)", id: id, provider: "Pornhub", score: number(row["views"]),
                            tags: strings(row["tags"]) + strings(row["categories"]),
                            previewUrl: posters.first ?? "", thumbUrl: posters.dropFirst().first ?? posters.first ?? "",
                            pageUrl: text(row["url"]), type: "video")
            // A category thumbnail is trustworthy only if the provider's
            // structured categories actually establish that membership.
            if let requested = selection.category.map({ String($0.dropFirst("category:".count)) }),
               strings(row["categories"]).contains(where: {
                   $0.lowercased().replacingOccurrences(of: " ", with: "-") == requested
               }) {
                post.category = "category:" + requested
            }
            post.caption = text(row["title"]); post.creator = text(row["username"]); return post
        }
        return self.page(posts, hasMore: raw.count >= 20, query: query, immersive: immersive)
    }

    /// No third-party scraping service or proxy is used. Only fall back for
    /// missing/malformed webmaster routes; a 403/451 access restriction must
    /// still be surfaced to the user rather than routed around.
    static func pornhubWebmasterJSON(session: URLSession, credentials: ProviderCredentials,
                                     parameters: [URLQueryItem]) async throws -> [String: Any]? {
        for endpoint in ["https://www.pornhub.com/webmasters/search",
                         "https://www.pornhub.com/webmasters/search/",
                         "https://api.pornhub.com/webmasters/search"] {
            let bytes: Data
            do {
                bytes = try await data(session: session, url: url(endpoint, parameters),
                                       provider: .pornhub, headers: cookieHeaders(credentials))
            } catch APIError.providerStatus(.pornhub, let status)
                where [404, 410, 500, 502, 503, 504].contains(status) {
                // Retired webmaster endpoints should never block the public
                // first-party catalog fallback.
                continue
            }
            guard !unavailableHTML(bytes),
                  let result = try? object(bytes), result["videos"] is [Any] else { continue }
            return result
        }
        return nil
    }

    /// Best-effort catalog fallback for deployments where the public webmaster
    /// API has been removed. This only reads Pornhub's own public browse HTML;
    /// it never follows third-party mirrors or works around a regional block.
    static func pornhubPublicCatalog(session: URLSession, credentials: ProviderCredentials,
                                     query: ParsedQuery, page: Int, sort: String,
                                     immersive: Bool) async throws -> PostPage {
        let selection = ProviderSearchCategories.split(query, provider: .pornhub)
        let filters = (query.pornhub ?? PornhubSearchFilters()).normalized
        let searching = !selection.keywords.isEmpty
        let category = filters.includedCategory ?? selection.category.map { String($0.dropFirst("category:".count)) }
        let route = searching ? "https://www.pornhub.com/video/search" :
            category.map { "https://www.pornhub.com/categories/" + $0 } ?? "https://www.pornhub.com/video"
        var parameters: [URLQueryItem] = [.init(name: "page", value: String(max(1, page)))]
        let selectedOrder = query.pornhub?.order ?? (sort == "recent" ? .newest : sort == "popular" ? .mostViewed : .relevance)
        let browserOrder: String
        switch selectedOrder {
        case .relevance: browserOrder = "relevance"
        case .newest: browserOrder = "mr"
        case .mostViewed: browserOrder = "mv"
        case .topRated: browserOrder = "tr"
        case .longest: browserOrder = "lg"
        }
        if searching {
            parameters.append(.init(name: "search", value: selection.keywords.joined(separator: " ")))
            if let category { parameters.append(.init(name: "category", value: category)) }
            if selectedOrder != .relevance { parameters.append(.init(name: "o", value: browserOrder)) }
        } else {
            parameters.append(.init(name: "o", value: browserOrder))
        }
        if filters.production != .all { parameters.append(.init(name: "p", value: filters.production.rawValue)) }
        if filters.minimumMinutes > 0 { parameters.append(.init(name: "min_duration", value: String(filters.minimumMinutes))) }
        if filters.maximumMinutes < 40 { parameters.append(.init(name: "max_duration", value: String(filters.maximumMinutes))) }
        for excluded in filters.excludedCategories { parameters.append(.init(name: "exclude_category[]", value: excluded)) }
        // A first-page URL with page=1 or a sort key can itself be rejected
        // even when the canonical browse route still works. Try clean URL
        // variants on the *same first-party site*, but never turn a search or
        // category request into an unrelated generic feed.
        var candidates = [try url(route, parameters)]
        if page == 1 {
            candidates.append(try url(route, parameters.filter { $0.name != "page" }))
            candidates.append(try url(route, parameters.filter { $0.name != "page" && $0.name != "o" }))
        }
        // Some first-party deployments return "requested URL was not found"
        // for supported catalog pages when an optional filter query is
        // present. Retry only the same search/category route with canonical
        // parameters; apply the user's duration/production filters locally.
        let essential = parameters.filter { ["page", "search", "category"].contains($0.name) }
        candidates.append(try url(route, essential))
        if page == 1 {
            candidates.append(try url(route, essential.filter { $0.name != "page" }))
            if !searching && category == nil {
                candidates.append(try url("https://www.pornhub.com/"))
            }
        }
        var tried = Set<URL>()
        let htmlHeaders = cookieHeaders(credentials).merging([
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"
        ]) { _, explicit in explicit }
        for candidate in candidates {
            guard tried.insert(candidate).inserted else { continue }
            let bytes: Data
            do {
                bytes = try await data(session: session, url: candidate,
                                       provider: .pornhub, headers: htmlHeaders)
            } catch APIError.providerStatus(.pornhub, let status)
                where [404, 410, 500, 502, 503, 504].contains(status) {
                continue
            }
            // Some upstream missing routes produce HTTP 200 with an HTML 404.
            // Never pass that page into the feed or stop before checking the
            // canonical first-party browse URL.
            guard !unavailableHTML(bytes) else { continue }
            let html = String(decoding: bytes.prefix(2 * 1024 * 1024), as: UTF8.self)
            var posts = pornhubHTMLPosts(html, filters: filters)
            if !posts.isEmpty {
                if let category, !searching, candidate.path.hasPrefix("/categories/" + category) {
                    // A first-party category page is source evidence for its
                    // own cards; title words in a generic feed are not.
                    for index in posts.indices { posts[index].category = "category:" + category }
                }
                return self.page(posts, hasMore: posts.count >= 20,
                                 query: query, immersive: immersive)
            }
        }
        throw APIError.server("Pornhub returned missing or unreadable public catalog pages. Its first-party API may be temporarily unavailable on this network.")
    }

    /// Extract only public listing metadata, not player scripts, cookies, or
    /// embedded media URLs. An unrecognized markup version fails explicitly.
    static func pornhubHTMLPosts(_ html: String, filters: PornhubSearchFilters = PornhubSearchFilters()) -> [Post] {
        let blocks = matches(html,
            #"<li\b[^>]*(?:videoblock|videoBox)[^>]*>.*?</li>"#, group: 0)
        let candidates = blocks.isEmpty
            ? matches(html, #"<a\b[^>]*href=["'][^"']*view_video\.php\?viewkey=[^"']*["'][^>]*>.*?</a>"#, group: 0)
            : blocks
        var seen = Set<String>()
        let options = filters.normalized
        return candidates.prefix(100).compactMap { block -> Post? in
            let durationLabel = matches(block, #"\bduration[^>]*>\s*([0-9:]+)"#).first
                ?? matches(block, #"\bdata-duration\s*=\s*["']([0-9:]+)["']"#).first
            if let durationLabel, !pornhubMatches(["duration": durationLabel], filters: options) { return nil }
            let key = matches(block, #"data-video-vkey\s*=\s*["']([a-zA-Z0-9_]+)["']"#).first
                ?? matches(block, #"view_video\.php\?viewkey=([a-zA-Z0-9_]+)"#).first
            guard let key, seen.insert(key).inserted else { return nil }
            let rawTitle = matches(block, #"\btitle\s*=\s*["']([^"']+)["']"#).first
                ?? matches(block, #"\balt\s*=\s*["']([^"']+)["']"#).first ?? ""
            let title = rawTitle.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            let posterCandidates = [#"data-thumb_url\s*=\s*["']([^"']+)["']"#,
                          #"data-mediumthumb\s*=\s*["']([^"']+)["']"#,
                          #"\bsrc\s*=\s*["']([^"']+)["']"#]
                .compactMap { matches(block, $0).first }
                .compactMap { mediaURL($0.replacingOccurrences(of: "&amp;", with: "&")) }
                .map(\.absoluteString)
            let poster = posterCandidates.reduce(into: [String]()) { result, candidate in
                if !result.contains(candidate) { result.append(candidate) }
            }
            var post = Post(key: "pornhub:\(key)", id: key, provider: Provider.pornhub.rawValue,
                            tags: title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init),
                            previewUrl: poster.first ?? "", thumbUrl: poster.dropFirst().first ?? poster.first ?? "",
                            pageUrl: "https://www.pornhub.com/view_video.php?viewkey=\(key)", type: "video")
            post.caption = title
            return post
        }.prefix(40).map { $0 }
    }

    static func cookieHeaders(_ credentials: ProviderCredentials) -> [String: String] {
        guard !credentials.pornhubSession.isEmpty,
              let data = QuicktickSyncCrypto.decodeBase64URL(credentials.pornhubSession),
              let cookie = String(data: data, encoding: .utf8), !cookie.contains("\r"), !cookie.contains("\n") else { return [:] }
        return ["Cookie": cookie]
    }

    static func matches(_ text: String, _ pattern: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard $0.numberOfRanges > group, let range = Range($0.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }

    static func jsonFragment(_ text: String, after marker: String, opening: Character = "[") -> Data? {
        guard let range = text.range(of: marker), let begin = text[range.upperBound...].firstIndex(of: opening) else { return nil }
        var depth = 0, quoted = false, escaped = false
        let closing: Character = opening == "[" ? "]" : "}"
        for index in text[begin...].indices {
            let c = text[index]
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                continue
            }
            if c == "\"" { quoted = true }
            else if c == opening { depth += 1 }
            else if c == closing { depth -= 1; if depth == 0 { return Data(text[begin...index].utf8) } }
        }
        return nil
    }

    /// Players embed mediaDefinitions as either JSON or escaped JavaScript.
    /// Keep the structured parser as the primary path, then recover only
    /// explicit HTTPS video URLs when an otherwise valid embed page uses the
    /// alternate encoding. No generic page links or thumbnail URLs qualify.
    static func pornhubPlayerDefinitions(_ html: String) -> [[String: Any]] {
        let normalized = html.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        // Some watch pages serialize mediaDefinitions as a JSON-encoded
        // string inside flashvars rather than as an array literal. Decode
        // its inner array before resorting to a conservative URL scan.
        for page in [html, normalized] {
            if let json = jsonFragment(page, after: "mediaDefinitions"),
               let definitions = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]],
               !definitions.isEmpty { return definitions }
        }
        let urls = matches(normalized, #"videoUrl\s*["']?\s*:\s*["'](https://[^"']+)["']"#)
        return urls.compactMap { raw -> [String: Any]? in
            guard let address = mediaURL(raw, provider: .pornhub) else { return nil }
            switch address.pathExtension.lowercased() {
            case "mp4", "m4v": return ["format": "mp4", "videoUrl": address.absoluteString]
            case "m3u8": return ["format": "hls", "videoUrl": address.absoluteString]
            default: return nil
            }
        }
    }

    /// Signed CDN media URLs frequently have no .mp4 or .m3u8 suffix.
    /// Only a provider-declared stream on its recognized CDN is accepted;
    /// opaque main-site URLs remain metadata endpoints to resolve separately.
    static func pornhubDeclaredMedia(_ definition: [String: Any]) -> ResolvedMedia? {
        guard let address = mediaURL(text(definition["videoUrl"]), provider: .pornhub),
              let host = address.host?.lowercased() else { return nil }
        let ext = address.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "m3u8"].contains(ext) {
            return ResolvedMedia(mediaUrl: address.absoluteString,
                                 type: ext == "m3u8" ? "hls" : "video")
        }
        let allowedCDN = host.hasSuffix(".phncdn.com") || host == "phncdn.com" ||
            (host.hasSuffix(".pornhub.com") && host != "www.pornhub.com")
        guard allowedCDN else { return nil }
        let format = text(definition["format"] ?? definition["type"]).lowercased()
        if ["hls", "application/x-mpegurl", "application/vnd.apple.mpegurl"].contains(format) {
            return ResolvedMedia(mediaUrl: address.absoluteString, type: "hls")
        }
        if ["mp4", "video", "video/mp4", "m4v"].contains(format) {
            return ResolvedMedia(mediaUrl: address.absoluteString, type: "video")
        }
        return nil
    }

    static func pornhubImageHeaders(for url: URL) -> [String: String] {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "pornhub.com" || host.hasSuffix(".pornhub.com") ||
              host == "phncdn.com" || host.hasSuffix(".phncdn.com") else { return [:] }
        return ["Referer": "https://www.pornhub.com/"]
    }
}

// XMLParser handles entity escaping and malformed upstream XML safely, rather
// than treating an HTML error page as an empty feed.
private final class ProviderXML: NSObject, XMLParserDelegate {
    var posts: [[String: String]] = []
    var total = 0
    var errorText = ""
    private var inError = false
    private var hasRoot = false
    static func parse(_ data: Data) throws -> ProviderXML {
        let value = ProviderXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = value
        guard parser.parse(), value.hasRoot, value.errorText.isEmpty else { throw APIError.invalidResponse }
        return value
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "post" || name == "comment" { posts.append(attributes) }
        if name == "posts" || name == "comments" { hasRoot = true }
        if name == "posts" { total = Int(attributes["count"] ?? "0") ?? 0 }
        inError = name == "error"
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inError { errorText += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "error" { inError = false } }
}

extension NativeProviderAPI {
    // Archive CDNs may serve JSON with a legacy `text/css` content type.
    // Accept both without depending on MIME sniffing or a single deployment.
    static let archiveAcceptHeaders = ["Accept": "application/json, text/css;q=0.9, */*;q=0.5"]

    static func resolve(session: URLSession, credentials: ProviderCredentials, post: Post,
                        redgifsToken: String?, havenToken: String? = nil,
                        streamVariant: Int = 0) async throws -> ResolvedMedia {
        // A valid direct media URL can outlive its provider metadata (for
        // example an imported/restored post with a legacy or unknown site).
        // Only use this fallback for actual file/playlist paths, never an
        // HTML post page masquerading as a downloadable video.
        let direct = mediaURL(post.mediaUrl, provider: post.providerKey)
        let directTypes: Set<String> = ["mp4", "m4v", "mov", "webm", "m3u8", "gif", "jpg", "jpeg", "png", "webp", "heic", "avif", "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "ogg", "opus"]
        if post.providerKey == .hanime, let direct,
           HanimeGeneratedAPI.permittedStreamURL(direct) {
            let isHLS = direct.path.hasPrefix("/hls/") || direct.pathExtension.lowercased() == "m3u8"
            return ResolvedMedia(mediaUrl: direct.absoluteString, type: isHLS ? "hls" : "video")
        }
        // Hanime catalog posters are JPEG/WebP images, not downloadable videos.
        // Never let the generic direct-file shortcut accept those thumbnails:
        // resolve the first-party HLS handshake for the original post instead.
        if post.providerKey != .hanime, let direct,
           directTypes.contains(direct.pathExtension.lowercased()) {
            return ResolvedMedia(mediaUrl: direct.absoluteString, type: direct.pathExtension.lowercased() == "m3u8" ? "hls" : post.type)
        }
        guard let provider = post.providerKey else {
            throw APIError.server("This post has no recognized source or downloadable media URL. Try opening the original post again.")
        }
        // Some provider CDNs use opaque signed URLs without an extension.
        // Keep supporting those only after the provider has been identified.
        if provider != .hanime, let direct {
            return ResolvedMedia(mediaUrl: direct.absoluteString, type: post.type)
        }
        switch provider {
        case .nhentai:
            throw APIError.server("Open this manga in the full-screen reader to browse its pages.")
        case .hhaven:
            guard let havenToken else { throw APIError.invalidResponse }
            return try await havenResolve(session: session, token: havenToken, post: post)
        case .rule34:
            let page = try await rule34(session: session, credentials: credentials, query: QueryParser.parse(""), page: 1, sort: "recent", immersive: false, id: post.id)
            guard let media = page.items.first?.mediaUrl else { throw APIError.invalidResponse }
            return ResolvedMedia(mediaUrl: media, type: page.items.first?.type ?? "video")
        case .coomer, .kemono:
            // Posts retain a validated absolute archive attachment URL when
            // available. A missing/removed file is not silently replaced by HTML.
            throw APIError.server("This archive attachment is unavailable. Open the original post to check whether its file is still hosted.")
        case .erome:
            return try await EromePublicCatalog.resolve(session: session, post: post)
        case .redgifs:
            guard let redgifsToken else { throw APIError.invalidResponse }
            let value = try object(await data(session: session, url: url("https://api.redgifs.com/v2/gifs/\(post.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"), provider: provider, headers: ["Authorization": "Bearer " + redgifsToken]))
            let gif = value["gif"] as? [String: Any] ?? [:], urls = gif["urls"] as? [String: Any] ?? [:]
            guard let media = mediaURL(text(urls["hd"] ?? urls["sd"]), provider: provider) else { throw APIError.invalidResponse }
            return ResolvedMedia(mediaUrl: media.absoluteString, type: "video")
        case .eporner:
            let embed = try url("https://www.eporner.com/embed/\(post.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")/")
            let html = String(decoding: try await data(session: session, url: embed, provider: provider), as: UTF8.self)
            guard let hash = matches(html, #"hash\s*[:=]\s*["']([\da-f]{32})["']"#).first else { throw APIError.server("Eporner did not expose a public player source.") }
            var encoded = ""
            for offset in stride(from: 0, to: hash.count, by: 8) {
                let begin = hash.index(hash.startIndex, offsetBy: offset), end = hash.index(begin, offsetBy: 8)
                guard let value = UInt32(hash[begin..<end], radix: 16) else { throw APIError.invalidResponse }
                encoded += String(value, radix: 36)
            }
            let response = try object(await data(session: session, url: url("https://www.eporner.com/xhr/video/\(post.id)", [
                .init(name: "hash", value: encoded), .init(name: "device", value: "generic"), .init(name: "domain", value: "www.eporner.com"),
                .init(name: "fallback", value: "false"), .init(name: "embed", value: "true"), .init(name: "supportedFormats", value: "mp4,hls"),
                .init(name: "playerWidth", value: "1920"), .init(name: "playerHeight", value: "1080")]), provider: provider, headers: ["Referer": embed.absoluteString]))
            let groups = response["sources"] as? [String: [String: [String: Any]]] ?? [:]
            for kind in ["mp4", "hls"] {
                let ordered = (groups[kind] ?? [:]).sorted { quality($0.key) > quality($1.key) }
                for (_, entry) in ordered {
                    if let media = mediaURL(text(entry["src"] ?? entry["url"]), provider: provider) { return ResolvedMedia(mediaUrl: media.absoluteString, type: kind == "hls" ? "hls" : "video") }
                }
            }
            throw APIError.server("Eporner returned no playable public stream.")
        case .hanime:
            // When AVPlayer rejects the first signed playlist, the retry must
            // be able to change transport, not merely request another token
            // for the same failing manifest. Try the older public v8 media
            // route before stepping down to a lower v11 HLS quality.
            if streamVariant > 0,
               let legacy = try? await hanimeLegacyMediaResolve(session: session,
                                                                post: post, variant: streamVariant - 1) {
                try Task.checkCancellation()
                return legacy
            }
            do {
                return try await hanimeHLSResolve(session: session, post: post,
                                                  variant: streamVariant)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A successful public v8 response is an independent, ordinary
                // provider-supported stream source. Do not try unverified CDNs
                // or alter the user's authentication to bypass a denied route.
                if let legacy = try? await hanimeLegacyMediaResolve(session: session, post: post) {
                    try Task.checkCancellation()
                    return legacy
                }
                if let failure = error as? APIError {
                    switch failure {
                    case .providerStatus(.hanime, 404):
                        throw APIError.server("Hanime's HLS handshake was unavailable. Native playback needs an authorized stream; use Browse inside QuickTick or configure a Hanime API in Settings.")
                    case .providerStatus(.hanime, 410):
                        throw APIError.server("Hanime's HLS handshake was removed. Native playback needs an authorized stream; use Browse inside QuickTick or configure a Hanime API in Settings.")
                    default: break
                    }
                }
                throw error
            }
        case .pornhub:
            let canonical = mediaURL(post.pageUrl, provider: provider)
            let page: URL
            if let canonical, ["pornhub.com", "www.pornhub.com"].contains(canonical.host ?? ""), canonical.path == "/view_video.php" {
                page = canonical
            } else { page = try url("https://www.pornhub.com/view_video.php", [.init(name: "viewkey", value: post.id)]) }
            // The canonical watch URL can disappear while the first-party
            // embed still exposes an ordinary public media definition.
            // A 403/451 is deliberately NOT bypassed: respect provider access.
            let encodedID = post.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? post.id
            let pages = [page, try url("https://www.pornhub.com/embed/\(encodedID)"),
                         try url("https://pornhub.com/embed/\(encodedID)")]
            // If the first quality/format fails in AVPlayer, a fresh retry
            // must try a different declared source, not the same broken URL.
            // Deduplicate sources across the watch and embed pages so even a
            // different page returning the identical stream does not waste a
            // retry. No blocked or removed media endpoint is bypassed.
            var remainingVariant = max(0, streamVariant)
            var seenSources = Set<String>()
            for candidatePage in pages {
                let bytes: Data
                do {
                    bytes = try await data(session: session, url: candidatePage,
                                           provider: provider,
                                           headers: cookieHeaders(credentials).merging([
                                            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.7"
                                           ]) { _, html in html })
                } catch APIError.providerStatus(.pornhub, let status) where status == 404 || status == 410 {
                    continue
                }
                guard !unavailableHTML(bytes) else { continue }
                let html = String(decoding: bytes, as: UTF8.self)
                let raw = pornhubPlayerDefinitions(html)
                guard !raw.isEmpty else { continue }
                let sorted = raw.sorted { number($0["quality"]) > number($1["quality"]) }
                // A player can label a source "hls", "HLS", "video/mp4" or
                // omit format entirely. Trust the validated URL extension
                // first, retaining nested first-party definitions as a fallback.
                for definition in sorted {
                    if let media = pornhubDeclaredMedia(definition) {
                        if seenSources.insert(media.mediaUrl).inserted {
                            if remainingVariant == 0 { return media }
                            remainingVariant -= 1
                        }
                        continue
                    }
                    guard let candidate = mediaURL(text(definition["videoUrl"]), provider: provider) else { continue }
                    guard candidate.host == "pornhub.com" || candidate.host?.hasSuffix(".pornhub.com") == true else { continue }
                    let details: Data
                    do { details = try await data(session: session, url: candidate,
                                                      provider: provider, headers: cookieHeaders(credentials)) }
                    catch APIError.providerStatus(.pornhub, let status) where status == 404 || status == 410 { continue }
                    let list = rows(try JSONSerialization.jsonObject(with: details))
                        .sorted { number($0["quality"]) > number($1["quality"]) }
                    for media in list.compactMap(pornhubDeclaredMedia) where seenSources.insert(media.mediaUrl).inserted {
                        if remainingVariant == 0 { return media }
                        remainingVariant -= 1
                    }
                }
            }
            throw APIError.server(streamVariant > 0
                ? "Pornhub has no more distinct public stream options for this post. Open the original in QuickTick to check whether it plays in the provider's browser."
                : "Pornhub has no available public stream. The post may have been removed or be unavailable in your region.")
        }
    }
    static func quality(_ value: String) -> Int { Int(value.filter(\.isNumber)) ?? 0 }

    static func comments(session: URLSession, credentials: ProviderCredentials, post: Post) async throws -> CommentPage {
        if post.providerKey == .coomer || post.providerKey == .kemono {
            return try await archiveComments(session: session, post: post)
        }
        guard post.providerKey == .rule34 else { return CommentPage(items: [], available: false, message: "This provider has no supported direct comments API.") }
        guard !credentials.rule34Key.isEmpty, !credentials.rule34User.isEmpty else { throw APIError.server("Add Rule34 API credentials to load comments.") }
        let bytes = try await data(session: session, url: url("https://api.rule34.xxx/index.php", [
            .init(name: "page", value: "dapi"), .init(name: "s", value: "comment"), .init(name: "q", value: "index"),
            .init(name: "post_id", value: post.id), .init(name: "user_id", value: credentials.rule34User), .init(name: "api_key", value: credentials.rule34Key)]), provider: .rule34)
        let rows = try ProviderXML.parse(bytes).posts
        return CommentPage(items: rows.map { PostComment(id: $0["id"] ?? "", author: $0["creator"] ?? "Rule34 user", body: $0["body"] ?? "", score: 0, createdAt: $0["created_at"] ?? "") }.filter { !$0.body.isEmpty }, available: true, message: nil)
    }
}

/// Free, read-only public catalog extraction, based on the documented page
/// structure in Kiny-Kiny/EromeAPI (BSD-2-Clause). No Apify actor, credentials,
/// paid proxy, sign-in bypass or server-side QuickTick service is involved.
enum EromePublicCatalog {
    private static let origin = URL(string: "https://www.erome.com")!
    private static let headers = [
        "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.7",
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
    ]
    private static let albums = AlbumMediaCache()

    /// Album HTML is shared by Home's Play action, Immersive hydration and
    /// subsequent visits. Coalesce identical requests and keep decoded media
    /// links briefly so a return swipe doesn't hit Erome/WebKit again.
    private actor AlbumMediaCache {
        private final class SessionIdentity {
            weak var session: URLSession?
            let number: Int
            init(session: URLSession, number: Int) {
                self.session = session; self.number = number
            }
        }
        private var sessionIdentities: [ObjectIdentifier: SessionIdentity] = [:]
        private var nextSessionNumber = 0
        private var completed: [String: (posts: [Post], expiry: Date)] = [:]
        private var pending: [String: Task<[Post], Error>] = [:]

        func posts(session: URLSession, url: URL) async throws -> [Post] {
            // Separate session transports, including deterministic test
            // sessions and distinct cookie stores, must never share results.
            let sessionID = ObjectIdentifier(session)
            let number: Int
            if let current = sessionIdentities[sessionID], current.session === session {
                number = current.number
            } else {
                nextSessionNumber += 1
                number = nextSessionNumber
                sessionIdentities[sessionID] = SessionIdentity(session: session, number: number)
                if sessionIdentities.count > 48 {
                    sessionIdentities = sessionIdentities.filter { $0.value.session != nil }
                }
            }
            let key = "\(number)|\(url.absoluteString)"
            if let cached = completed[key], cached.expiry > .now { return cached.posts }
            if let request = pending[key] { return try await request.value }
            let request = Task<[Post], Error> {
                let html = try await EromePublicCatalog.pageHTML(session: session, url: url)
                return EromePublicCatalog.albumMedia(html, albumURL: url)
            }
            pending[key] = request
            defer { pending[key] = nil }
            let found = try await request.value
            // A blank verification/interstitial page must remain retryable.
            if !found.isEmpty {
                completed[key] = (found, .now.addingTimeInterval(7 * 60))
            }
            if completed.count > 48 {
                completed = completed.filter { $0.value.expiry > .now }
                if completed.count > 48,
                   let oldest = completed.min(by: { $0.value.expiry < $1.value.expiry })?.key {
                    completed.removeValue(forKey: oldest)
                }
            }
            return found
        }
    }

    static func posts(session: URLSession, query: ParsedQuery, page: Int,
                      sort: String, immersive: Bool) async throws -> PostPage {
        guard page > 0, page <= 100 else { throw APIError.invalidResponse }
        let terms = query.included.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let route = terms.isEmpty ? (sort == "recent" ? "/explore/new" : "/explore") : "/search"
        let parameters: [URLQueryItem] = (terms.isEmpty ? [] : [.init(name: "q", value: terms)])
            + [.init(name: "page", value: String(page))]
        let address = try NativeProviderAPI.url(origin.absoluteString + route, parameters)
        let html = try await pageHTML(session: session, url: address)
        let summaries = albumSummaries(html)
        // Home used to return only album posters when summaries existed,
        // so videos were invisible until entering Immersive. Resolve a bounded
        // set of albums in both feeds and reuse AlbumMediaCache for playback.
        // Summaries are thumbnail-only, and not every album-link has a
        // matching summary (or even a thumbnail). In particular, choosing
        // only summaries can silently discard the page's video albums.
        // Prefer known video albums and links not identified as photo-only;
        // keep photo summaries as a last-resort fallback because some older
        // listings omit their video-count badge entirely.
        let videoLinks = summaries.filter { $0.type == "video" }.compactMap { URL(string: $0.pageUrl) }
        let photoLinks = summaries.filter { $0.type != "video" }.compactMap { URL(string: $0.pageUrl) }
        let photoURLs = Set(photoLinks.map(\.absoluteString))
        let unknownLinks = albumLinks(html).filter { !photoURLs.contains($0.absoluteString) }
        var seenAlbumURLs = Set<String>()
        let albums = (videoLinks + unknownLinks + photoLinks)
            .filter { seenAlbumURLs.insert($0.absoluteString).inserted }
        if albums.isEmpty {
            if page == 1, !html.lowercased().contains("id=\"albums\"") &&
                !html.lowercased().contains("id='albums'") {
                throw APIError.server("Erome did not return a public album catalog. The site may be unavailable in your region.")
            }
            return PostPage(items: [], hasMore: false)
        }

        // Hydrate only a small first deck. Requesting 32 albums (often 32
        // HTML pages plus 32 hidden browser fallbacks) made Erome painfully
        // slow to open, especially on iPad. Users can page for more clips.
        let selected = Array(albums.prefix(immersive ? 16 : 9))
        var items: [Post] = []
        var albumFailure: String?
        var successfulAlbums = 0
        for start in stride(from: 0, to: selected.count, by: 3) {
            try Task.checkCancellation()
            let batch = Array(selected[start..<min(start + 3, selected.count)])
            let fetched = await withTaskGroup(of: (Int, [Post], String?).self) { group in
                for (index, album) in batch.enumerated() {
                    group.addTask {
                        do {
                            let posts = try await albumPosts(session: session, url: album)
                            return (index, immersive ? posts.filter(\.isImmersiveMedia) : posts, nil)
                        }
                        catch { return (index, [], error.localizedDescription) }
                    }
                }
                var results: [(Int, [Post], String?)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            items.append(contentsOf: fetched.flatMap { $0.1 })
            successfulAlbums += fetched.filter { $0.2 == nil }.count
            if albumFailure == nil { albumFailure = fetched.compactMap { $0.2 }.first }
            // An immersive page needs playable media, not every image in a
            // large album. Stop after a useful initial deck to save data.
            if immersive && items.count >= 3 { break }
            if !immersive && items.filter({ $0.type == "video" }).count >= 3 { break }
        }
        try Task.checkCancellation()
        if successfulAlbums == 0, let albumFailure {
            throw APIError.server("Could not load Erome's public albums: \(albumFailure)")
        }
        guard !items.isEmpty else {
            throw APIError.server("Erome's public albums did not expose playable media. Try again later or check access in Safari.")
        }
        let hasMore = hasNextPage(html) || albums.count >= 24
        // Keep video cards ahead of photo-only albums in Home, so users see
        // real playable clips rather than a wall of unresolved covers.
        let ordered = immersive ? items : items.sorted { left, right in
            (left.type == "video" ? 1 : 0) > (right.type == "video" ? 1 : 0)
        }
        return NativeProviderAPI.page(ordered, hasMore: hasMore, query: query, immersive: immersive)
    }

    static func resolve(session: URLSession, post: Post) async throws -> ResolvedMedia {
        let albumID = String(post.id.split(separator: ":", maxSplits: 1).first ?? "")
        guard validAlbumID(albumID), let album = albumURL("/a/" + albumID) else {
            throw APIError.invalidResponse
        }
        let media = try await albumPosts(session: session, url: album)
        guard let current = media.first(where: { $0.id == post.id })
                ?? (post.id == albumID ? media.first(where: { $0.type == "video" }) ?? media.first : nil) else {
            throw APIError.server("This Erome media item is no longer available on its public album page.")
        }
        return ResolvedMedia(mediaUrl: current.mediaUrl, type: current.type)
    }

    static func hasNextPage(_ html: String) -> Bool {
        html.contains("rel=\"next\"") || html.contains("rel='next'")
    }

    /// Read album metadata from listing cards without fetching album bodies.
    /// Existing sparse/older listings still use albumLinks + albumMedia.
    static func albumSummaries(_ html: String) -> [Post] {
        let pattern = #"<div\b(?=[^>]*\bclass\s*=\s*["'][^"']*\balbum(?=\s|["']))[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = html as NSString
        let starts = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var seen = Set<String>()
        return starts.enumerated().compactMap { index, match -> Post? in
            let end = index + 1 < starts.count ? starts[index + 1].range.location : source.length
            guard end > match.range.location else { return nil }
            let block = source.substring(with: NSRange(location: match.range.location,
                                                       length: min(end - match.range.location, 12_000)))
            let titleAnchor = NativeProviderAPI.matches(block,
                #"<a\b(?=[^>]*\bclass\s*=\s*["'][^"']*\balbum-title\b)[^>]*>"#, group: 0).first
            guard let link = titleAnchor.flatMap({ attribute($0, "href") }),
                  let album = albumURL(link), let id = albumID(album), seen.insert(id).inserted else { return nil }
            let imageTag = NativeProviderAPI.matches(block,
                #"<img\b(?=[^>]*\bclass\s*=\s*["'][^"']*\balbum-thumbnail\b)[^>]*>"#, group: 0).first
            guard let imageTag,
                  let image = attribute(imageTag, "data-src") ?? attribute(imageTag, "src"),
                  let thumbnail = mediaURL(image) else { return nil }
            let name = NativeProviderAPI.matches(block,
                #"<a\b(?=[^>]*\bclass\s*=\s*["'][^"']*\balbum-title\b)[^>]*>([\s\S]*?)</a>"#).first ?? ""
            let videos = NativeProviderAPI.matches(block,
                #"class\s*=\s*["'][^"']*\balbum-videos\b[^"']*["'][^>]*>\s*([0-9]+)"#).first
            let creator = NativeProviderAPI.matches(block,
                #"class\s*=\s*["'][^"']*\balbum-user\b[^"']*["'][^>]*>\s*([^<]+)"#).first
            let numberOfVideos = Int(videos ?? "0") ?? 0
            var post = Post(key: "erome:\(id)", id: id, provider: "Erome",
                            thumbUrl: thumbnail.absoluteString, pageUrl: album.absoluteString,
                            type: numberOfVideos > 0 ? "video" : "image")
            post.caption = decode(name.replacingOccurrences(of: #"<[^>]+>"#,
                                                             with: "", options: .regularExpression))
            post.creator = creator.map(decode)
            return post
        }
    }

    static func albumLinks(_ html: String) -> [URL] {
        let known = NativeProviderAPI.matches(html,
            #"<a\b(?=[^>]*\bclass\s*=\s*["'][^"']*\balbum-link\b)[^>]*>"#, group: 0)
        let anchors = known.isEmpty ? NativeProviderAPI.matches(html, #"<a\b[^>]*>"#, group: 0) : known
        var seen = Set<String>()
        return anchors.compactMap { anchor in
            guard let raw = attribute(anchor, "href"), let url = albumURL(raw),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    static func albumMedia(_ html: String, albumURL: URL) -> [Post] {
        guard let albumID = albumID(albumURL) else { return [] }
        let title = decode(NativeProviderAPI.matches(html,
            #"<title\b[^>]*>(.*?)</title>"#).first ?? albumID)
            .replacingOccurrences(of: #"\s*[-|]\s*Erome.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let ogImage = NativeProviderAPI.matches(html,
            #"<meta\b(?=[^>]*\bproperty\s*=\s*["']og:image["'])[^>]*>"#, group: 0).first
        let thumbnail = ogImage.flatMap { attribute($0, "content") }.flatMap(mediaURL)?.absoluteString ?? ""
        let authorTag = NativeProviderAPI.matches(html,
            #"<meta\b(?=[^>]*\bname\s*=\s*["']author["'])[^>]*>"#, group: 0).first
        let creator = authorTag.flatMap { attribute($0, "content") }.map(decode)
        var seen = Set<String>()
        func makePost(_ media: URL, kind: String, preview: String = "") -> Post? {
            let id = albumID + ":" + media.lastPathComponent
            guard seen.insert(id).inserted else { return nil }
            let sourceImage = kind == "image" || kind == "gif" ? media.absoluteString : ""
            var post = Post(key: "erome:" + id, id: id, provider: Provider.erome.rawValue,
                            mediaUrl: media.absoluteString,
                            previewUrl: preview.isEmpty ? (sourceImage.isEmpty ? thumbnail : sourceImage) : preview,
                            thumbUrl: preview.isEmpty ? thumbnail : preview,
                            pageUrl: albumURL.absoluteString, type: kind)
            post.caption = title
            post.creator = creator
            return post
        }

        var result: [Post] = []
        let videos = NativeProviderAPI.matches(html, #"<video\b[^>]*>[\s\S]*?</video>"#, group: 0)
        for video in videos {
            let source = NativeProviderAPI.matches(video, #"<source\b[^>]*>"#, group: 0).first
            let raw = source.flatMap { attribute($0, "src") } ?? attribute(video, "src")
            guard let raw, let media = mediaURL(raw), media.host?.hasPrefix("v") == true,
                  ["mp4", "m4v", "mov"].contains(media.pathExtension.lowercased()) else { continue }
            let poster = attribute(video, "poster") ??
                NativeProviderAPI.matches(decode(video), #"["']poster["']\s*:\s*["']([^"']+)["']"#).first
            let preview = poster.flatMap(mediaURL)?.absoluteString ?? thumbnail
            if let post = makePost(media, kind: "video", preview: preview) { result.append(post) }
        }
        let imageBlocks = NativeProviderAPI.matches(html,
            #"<div\b(?=[^>]*\bclass\s*=\s*["'][^"']*\bimg\b)[^>]*>[\s\S]*?<img\b[^>]*>"#, group: 0)
        for block in imageBlocks {
            guard let tag = NativeProviderAPI.matches(block, #"<img\b[^>]*>"#, group: 0).first,
                  let src = attribute(tag, "data-src") ?? attribute(tag, "src"),
                  let media = mediaURL(src), media.host?.hasPrefix("s") == true,
                  ["jpg", "jpeg", "png", "webp", "gif"].contains(media.pathExtension.lowercased()) else { continue }
            if let post = makePost(media, kind: media.pathExtension.lowercased() == "gif" ? "gif" : "image") {
                result.append(post)
            }
        }
        return result
    }

    private static func albumPosts(session: URLSession, url: URL) async throws -> [Post] {
        try await albums.posts(session: session, url: url)
    }

    private static func pageHTML(session: URLSession, url: URL) async throws -> String {
        guard url.host == origin.host else { throw APIError.invalidResponse }
        let failure: Error
        do {
            let bytes = try await NativeProviderAPI.data(session: session, url: url,
                provider: .erome, headers: headers, maxBytes: 4 * 1024 * 1024, timeout: 12)
            guard !NativeProviderAPI.unavailableHTML(bytes) else {
                throw APIError.server("Erome returned an unavailable page instead of a public album.")
            }
            return String(decoding: bytes, as: UTF8.self)
        } catch APIError.providerStatus(.erome, 403) {
            failure = APIError.server("Erome denied this connection (HTTP 403). Check access in its in-app browser or configure your own authorized Erome API in Settings.")
        } catch {
            failure = error
        }
        // URLProtocol sessions are deterministic tests. Never escape a test's
        // fixture transport by opening the real public website in WebKit.
        if session.configuration.protocolClasses?.isEmpty != false,
           let html = try? await EromeBrowserCatalog.html(url: url) {
            return html
        }
        throw failure
    }

    private static func albumURL(_ raw: String) -> URL? {
        guard let url = URL(string: decode(raw), relativeTo: origin)?.absoluteURL,
              url.scheme == "https", url.host == origin.host, albumID(url) != nil else { return nil }
        return url
    }

    private static func albumID(_ url: URL) -> String? {
        let components = url.pathComponents
        guard components.count == 3, components[1] == "a", validAlbumID(components[2]) else { return nil }
        return components[2]
    }

    private static func validAlbumID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 60 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func mediaURL(_ raw: String) -> URL? {
        guard let url = NativeProviderAPI.mediaURL(decode(raw), provider: .erome), let host = url.host else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count == 3, parts[1] == "erome", parts[2] == "com",
              let first = parts.first, first.count > 1, first.first == "s" || first.first == "v",
              first.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return url
    }

    private static func attribute(_ tag: String, _ name: String) -> String? {
        NativeProviderAPI.matches(tag, #"\b"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*["']([^"']+)["']"#).first.map(decode)
    }

    private static func decode(_ html: String) -> String {
        html.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor RedgifsAuthentication {
    private var token = ""
    private var expiry = Date.distantPast
    private var flight: Task<String, Error>?
    func value(session: URLSession) async throws -> String {
        if Date() < expiry, !token.isEmpty { return token }
        if let flight { return try await flight.value }
        let task = Task {
            let data = try await NativeProviderAPI.data(session: session, url: NativeProviderAPI.url("https://api.redgifs.com/v2/auth/temporary"), provider: .redgifs)
            let object = try NativeProviderAPI.object(data)
            guard let value = object["token"] as? String, !value.isEmpty else { throw APIError.invalidResponse }
            return value
        }
        flight = task
        defer { flight = nil }
        token = try await task.value; expiry = Date().addingTimeInterval(450)
        return token
    }
    func invalidate(expecting previous: String) { if token == previous { token = ""; expiry = .distantPast } }
}


extension NativeProviderAPI {
    // Creator identities are exact service/user pairs. They are never put into
    // arbitrary URL paths without this validation.
    static func archiveCreatorRoute(_ value: String) -> (service: String, id: String)? {
        let pieces = value.split(separator: ":").map(String.init)
        guard pieces.count == 3, pieces[0] == "creator" else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard [pieces[1], pieces[2]].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return (pieces[1], pieces[2])
    }

    static func archiveCreators(session: URLSession, provider: Provider) async throws -> [ArchiveCreator] {
        guard provider == .kemono || provider == .coomer else { return [] }
        // /creators is used by the archive's current frontend; older instances
        // publish the same JSON list as /creators.txt.
        var lastError: Error = APIError.invalidResponse
        for suffix in ["/api/v1/creators", "/api/v1/creators.txt"] {
            do {
                let bytes = try await data(session: session, url: url(origin(provider).absoluteString + suffix),
                    provider: provider, headers: archiveAcceptHeaders, maxBytes: 32 * 1024 * 1024)
                let json = try JSONSerialization.jsonObject(with: bytes)
                let entries: [[String: Any]]
                if let list = json as? [[String: Any]] { entries = list }
                else { entries = rows((json as? [String: Any])?["creators"]) }
                guard !entries.isEmpty else { throw APIError.invalidResponse }
                return entries.compactMap { entry in
                    let name = text(entry["name"]), service = text(entry["service"]), id = text(entry["id"])
                    guard !name.isEmpty, !service.isEmpty, !id.isEmpty,
                          archiveCreatorRoute("creator:\(service):\(id)") != nil else { return nil }
                    return ArchiveCreator(name: name, service: service, id: id,
                                          favorites: Int(number(entry["favorited"])))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    // Both public archives expose Kemono API v1-style post lists. Treat them
    // as content sources, never as login credentials or automatic upload targets.
    static func archivePosts(session: URLSession, provider: Provider,
                             query: ParsedQuery, page: Int, immersive: Bool) async throws -> PostPage {
        guard provider == .kemono || provider == .coomer else { throw APIError.invalidResponse }
        let origin = origin(provider).absoluteString
        // The API uses 50 source posts per page, not 150. Skipping by 150
        // silently lost two pages and made searches appear exhausted. Public
        // archive pagination can also return 404 for deep offsets: rotate a
        // bounded discovery window rather than persisting broken page URLs.
        let offset = max(0, page - 1) % 60 * 50
        var parameters: [URLQueryItem] = [.init(name: "o", value: String(offset))]
        let creator = query.included.count == 1 ? archiveCreatorRoute(query.included[0]) : nil
        if creator == nil, !query.included.isEmpty {
            parameters.append(.init(name: "q", value: query.included.joined(separator: " ")))
        }
        // The archive endpoint is publication-ordered; it does not expose
        // a supported popularity sort, so QuickTick reranks locally.
        let path = creator.map { "/api/v1/\($0.service)/user/\($0.id)/posts" } ?? "/api/v1/posts"
        let endpoint = try url(origin + path, parameters)
        let data: Data
        var usedFallback = false
        do {
            data = try await self.data(session: session, url: endpoint, provider: provider,
                                       headers: archiveAcceptHeaders)
        } catch APIError.providerStatus(_, 403) {
            throw APIError.server("\(provider.displayName) denied anonymous API access (HTTP 403). Its source currently requires site access; browse it in QuickTick to sign in if supported.")
        } catch APIError.providerStatus(_, 404) {
            usedFallback = true
            // Kemono's own global search UI can receive a 404 on `?q=...`.
            // Reuse the documented recent-post endpoint without its optional
            // query, then apply the ORIGINAL terms locally. Never show posts
            // that do not match an explicitly typed search.
            let fallbackPath = creator == nil ? "/api/v1/posts" : path
            let retryParameters: [URLQueryItem] = [.init(name: "o", value: "0")]
            do {
                data = try await self.data(session: session,
                    url: url(origin + fallbackPath, retryParameters), provider: provider,
                    headers: archiveAcceptHeaders)
            } catch APIError.providerStatus(_, 404) where creator == nil {
                do {
                    data = try await self.data(session: session,
                        url: url(origin + "/api/v1/posts/popular"), provider: provider,
                        headers: archiveAcceptHeaders)
                } catch APIError.providerStatus(_, 404) {
                    throw APIError.server("\(provider.displayName)'s public recent and popular APIs are unavailable (404). Try again later.")
                }
            }
        }
        let decoded = try JSONSerialization.jsonObject(with: data)
        let raw: [[String: Any]]
        if let array = decoded as? [[String: Any]] { raw = array }
        else if let object = decoded as? [String: Any],
                let posts = object["posts"] as? [[String: Any]] { raw = posts }
        else { throw APIError.invalidResponse }
        let normalized = raw.flatMap { archiveItems($0, provider: provider) }
        // A fallback without server-side `q` must still honor the user's
        // search. Otherwise a recoverable 404 silently becomes a wrong feed.
        let visible = usedFallback && creator == nil
            ? normalized.filter { post in query.included.allSatisfy { containsKeyword($0, in: post) } }
            : normalized
        let total = (decoded as? [String: Any]).map { number($0["true_count"]) } ?? 0
        // A recovery page is deliberately bounded; do not keep requesting a
        // broken deep cursor or synthesize infinite duplicates.
        let hasMore = usedFallback ? false : (total > 0 ? Double(offset + raw.count) < total : raw.count >= 50)
        return self.page(visible, hasMore: hasMore, query: query, immersive: immersive)
    }

    // Typed creator routes are embedded into the canonical post URL. Never
    // use arbitrary URLs from feed JSON for API requests.
    static func archivePostRoute(_ post: Post) -> (service: String, user: String, id: String)? {
        guard let provider = post.providerKey, provider == .coomer || provider == .kemono,
              let link = URL(string: post.pageUrl),
              link.scheme == "https", link.host?.lowercased() == origin(provider).host,
              link.pathComponents.count == 6,
              link.pathComponents[2] == "user", link.pathComponents[4] == "post"
        else { return nil }
        let parts = link.pathComponents
        let service = parts[1], user = parts[3], id = parts[5]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard [service, user, id].allSatisfy({
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return (service, user, id)
    }

    static func archiveComments(session: URLSession, post: Post) async throws -> CommentPage {
        guard let provider = post.providerKey, let route = archivePostRoute(post) else {
            return CommentPage(items: [], available: false, message: "This archive post has no supported comments route.")
        }
        let endpoint = try url(origin(provider).absoluteString
            + "/api/v1/\(route.service)/user/\(route.user)/post/\(route.id)/comments")
        let bytes = try await data(session: session, url: endpoint, provider: provider,
                                   headers: archiveAcceptHeaders)
        let decoded = try JSONSerialization.jsonObject(with: bytes)
        let comments: [[String: Any]]
        if let array = decoded as? [[String: Any]] { comments = array }
        else if let object = decoded as? [String: Any] { comments = rows(object["comments"]) }
        else { throw APIError.invalidResponse }
        let items = comments.prefix(150).enumerated().compactMap { index, entry -> PostComment? in
            let textBody = text(entry["content"] ?? entry["body"])
            guard !textBody.isEmpty else { return nil }
            return PostComment(id: text(entry["id"]).isEmpty ? String(index) : text(entry["id"]),
                               author: text(entry["author"] ?? entry["username"] ?? entry["user"]),
                               body: textBody, score: number(entry["score"]),
                               createdAt: text(entry["created_at"] ?? entry["published"]))
        }
        return CommentPage(items: items, available: true, message: nil)
    }

    static func archiveItems(_ row: [String: Any], provider: Provider) -> [Post] {
        guard provider == .kemono || provider == .coomer else { return [] }
        let service = text(row["service"]).lowercased(), user = text(row["user"])
        let id = text(row["id"]), title = text(row["title"])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !service.isEmpty, !user.isEmpty, !id.isEmpty,
              [service, user, id].allSatisfy({
                $0.unicodeScalars.allSatisfy(allowed.contains)
              }) else { return [] }

        var attachments: [[String: Any]] = []
        if let main = row["file"] as? [String: Any] { attachments.append(main) }
        attachments.append(contentsOf: self.rows(row["attachments"]))
        // Artist/title metadata is useful but does not prove the identities
        // of people in real-life images or the content of opaque attachments.
        let author = text(row["artist"] ?? row["creator"] ?? row["user"])
        var tags = strings(row["tags"])
        let words = title.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map(String.init).filter { $0.count >= 3 && $0.count <= 40 }
        tags.append(contentsOf: words.prefix(12))
        if !author.isEmpty, author.count < 80 {
            tags.append(author.lowercased().replacingOccurrences(of: " ", with: "_"))
        }
        // Sort/dedupe to keep visual and text taste snapshots stable.
        tags = Array(Set(tags)).sorted().prefix(32).map { $0 }
        let prefix = origin(provider).absoluteString
        let pageURL = "\(prefix)/\(service)/user/\(user)/post/\(id)"
        let published = text(row["published"])
        let timestamp = ISO8601DateFormatter().date(from: published)?.timeIntervalSince1970
        var seen = Set<String>()
        var result: [Post] = []
        for (index, file) in attachments.prefix(12).enumerated() {
            let name = text(file["name"]), path = text(file["path"])
            let ext = (name as NSString).pathExtension.lowercased().isEmpty
                ? (path as NSString).pathExtension.lowercased() : (name as NSString).pathExtension.lowercased()
            let kind: String
            switch ext {
            case "mp4", "webm", "mov", "m4v": kind = "video"
            case "gif": kind = "gif"
            case "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "ogg", "opus": kind = "audio"
            case "jpg", "jpeg", "png", "webp", "avif", "heic": kind = "image"
            default: continue
            }
            guard let media = archiveMediaURL(path: path, provider: provider), seen.insert(media.absoluteString).inserted else { continue }
            let thumbnail = kind == "image"
                ? archiveMediaURL(path: path, provider: provider, thumbnail: true)
                : (kind == "video" ? archiveMediaURL(path: text(file["thumbnail"]), provider: provider) : nil)
            // A video thumbnail may not exist, but an absent poster should not
            // prevent valid playback or download.
            var post = Post(key: "\(provider.rawValue):\(service):\(user):\(id):\(index)",
                            id: id, provider: provider.rawValue, tags: tags,
                            mediaUrl: media.absoluteString,
                            previewUrl: thumbnail?.absoluteString ?? "",
                            thumbUrl: thumbnail?.absoluteString ?? "",
                            pageUrl: pageURL, type: kind)
            post.caption = title
            post.creator = author
            post.category = service
            post.createdAt = timestamp
            result.append(post)
        }
        return result
    }

    static func archiveMediaURL(path: String, provider: Provider, thumbnail: Bool = false) -> URL? {
        guard provider == .coomer || provider == .kemono,
              !path.isEmpty, !path.contains("\\"),
              !path.contains("..") else { return nil }
        let domain = provider == .coomer ? "coomer.st" : "kemono.cr"
        var suffix = path
        if let parsed = URL(string: path), parsed.scheme != nil {
            guard parsed.scheme == "https", let host = parsed.host?.lowercased(),
                  host == domain || host.hasSuffix("." + domain) else { return nil }
            suffix = parsed.path
        }
        if suffix.hasPrefix("/data/") { suffix = String(suffix.dropFirst(5)) }
        if suffix.hasPrefix("data/") { suffix = String(suffix.dropFirst(4)) }
        guard suffix.hasPrefix("/"), !suffix.hasPrefix("//") else { return nil }
        let base = thumbnail ? "https://img.\(domain)/thumbnail/data" : "https://\(domain)/data"
        return URL(string: base + suffix)
    }
}
