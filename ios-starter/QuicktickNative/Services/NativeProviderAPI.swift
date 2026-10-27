import Foundation
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
        config.websiteDataStore = .nonPersistent()
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

// Provider networking lives on the API actor, never on a scrolling view. No
// requests in this service use the optional QuickTick Sync origin.
enum NativeProviderAPI {
    static let userAgent = "QuickTickNative/0.9.6"
    // nHentai requests specifically ask clients for an identifying UA; keep
    // the project URL rather than impersonating a browser or official app.
    static let nhentaiHeaders = ["User-Agent": "QuickTick/0.9.9 (https://github.com/Robertloggiar34yyeeez/QuickTick)"]
    static let quicktickHost = "quick-tick-webb.vercel.app"

    static func origin(_ provider: Provider) -> URL {
        switch provider {
        case .rule34: URL(string: "https://rule34.xxx")!
        case .redgifs: URL(string: "https://www.redgifs.com")!
        case .eporner: URL(string: "https://www.eporner.com")!
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
        let bytes = try await data(session: session, url: url("https://www.eporner.com/api/v2/video/search/", [
            .init(name: "query", value: query.included.isEmpty ? "all" : query.included.joined(separator: " ")),
            .init(name: "page", value: String(page)), .init(name: "per_page", value: "40"), .init(name: "thumbsize", value: "big"),
            .init(name: "order", value: order), .init(name: "gay", value: "1"), .init(name: "lq", value: "0"), .init(name: "format", value: "json")]), provider: .eporner)
        let object = try Self.object(bytes), raw = rows(object["videos"])
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

    static func redgifs(session: URLSession, token: String, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let items = [URLQueryItem(name: "order", value: sort == "recent" ? "latest" : sort == "popular" ? "top7" : "trending"),
                     .init(name: "count", value: "40"), .init(name: "page", value: String(page))] + (query.included.isEmpty ? [] : [.init(name: "search_text", value: query.included.joined(separator: " "))])
        var result: [String: Any]?
        var lastError: Error = APIError.invalidResponse
        for path in ["https://api.redgifs.com/v2/gifs/search", "https://api.redgifs.com/v2/search/gifs"] {
            do {
                let object = try Self.object(await data(session: session, url: url(path, items), provider: .redgifs, headers: ["Authorization": "Bearer " + token]))
                guard object["gifs"] is [[String: Any]] else { throw APIError.invalidResponse }
                result = object; break
            } catch is CancellationError { throw CancellationError() } catch {
                if (error as? APIError)?.retryAfter != nil { throw error }
                if let failure = error as? APIError, case .providerStatus(.redgifs, 401) = failure { throw error }
                lastError = error
            }
        }
        guard let result else { throw lastError }
        let raw = rows(result["gifs"])
        let posts = raw.map { row -> Post in
            let id = text(row["id"]), urls = row["urls"] as? [String: Any] ?? [:]
            let media = text(urls["hd"] ?? urls["sd"] ?? urls["gif"])
            let image = text(row["type"]) == "i" || number(row["type"]) == 2
            var post = Post(key: "redgifs:\(id)", id: id, provider: "RedGIFs", score: number(row["likes"]), tags: strings(row["tags"]),
                            mediaUrl: media, thumbUrl: text(urls["poster"] ?? urls["thumbnail"] ?? urls["vthumbnail"]),
                            pageUrl: "https://www.redgifs.com/watch/\(id.lowercased())", type: image ? "image" : "video")
            let width = number(row["width"]), height = number(row["height"])
            if width > 0, height > 0 { post.width = width; post.height = height }
            post.creator = text(row["userName"]); post.createdAt = number(row["createDate"]); return post
        }
        return self.page(posts, hasMore: number(result["pages"]) > 0 ? page < Int(number(result["pages"])) : !raw.isEmpty, query: query, immersive: immersive)
    }

    static func hanimeSearchBody(query: ParsedQuery, page: Int, sort: String) throws -> Data {
        let body: [String: Any] = ["search_text": query.included.joined(separator: " "), "tags": [], "tags_mode": "AND", "brands": [], "blacklist": [],
                                   "order_by": sort == "recent" ? "released_at_unix" : "views", "ordering": "desc", "page": max(0, page - 1)]
        return try JSONSerialization.data(withJSONObject: body)
    }
    static func hanime(session: URLSession, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let result: [String: Any]
        do {
            result = try object(await data(session: session, url: url("https://search.htv-services.com/"), provider: .hanime, method: "POST", body: hanimeSearchBody(query: query, page: page, sort: sort)))
        } catch {
            if (error as? APIError)?.retryAfter != nil { throw error }
            guard query.included.isEmpty, !Task.isCancelled else { throw error }
            result = try object(await data(session: session, url: url("https://members.hanime.tv/rapi/v7/hentai_videos", [.init(name: "source", value: "randomize"), .init(name: "r", value: String(page))]), provider: .hanime))
        }
        var raw = rows(result["hits"] ?? result["hentai_videos"] ?? result["videos"] ?? result["data"])
        if let text = result["hits"] as? String, let bytes = text.data(using: .utf8) { raw = rows(try JSONSerialization.jsonObject(with: bytes)) }
        let posts = raw.map { row -> Post in
            let id = text(row["slug"] ?? row["hentai_video_slug"] ?? row["id"])
            var post = Post(key: "hanime:\(id)", id: id, provider: "Hanime", score: number(row["views"]),
                            tags: strings(row["hentai_tags"] ?? row["tags"] ?? row["genres"]),
                            thumbUrl: text(row["poster_url"] ?? row["cover_url"] ?? row["thumbnail"]),
                            pageUrl: "https://hanime.tv/videos/hentai/\(id)", type: "video")
            post.caption = text(row["name"] ?? row["title"]); post.creator = text(row["brand"])
            post.createdAt = number(row["released_at_unix"]); return post
        }
        return self.page(posts, hasMore: number(result["nbPages"]) > 0 ? page < Int(number(result["nbPages"])) : !raw.isEmpty, query: query, immersive: immersive)
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
        guard let media = mediaURL(text(info["chapter_content"] ?? info["content"]), provider: .hhaven) else {
            throw APIError.server("Hentai Haven did not return a playable episode stream.")
        }
        return ResolvedMedia(mediaUrl: media.absoluteString,
                             type: media.pathExtension.lowercased() == "m3u8" ? "hls" : "video")
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
            #"(?i)(?:file|src)\s*:\s*["']([^"']+)["']"#
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

    static func pornhub(session: URLSession, credentials: ProviderCredentials, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let selection = ProviderSearchCategories.split(query, provider: .pornhub)
        // The public webmaster API accepts browsing without a search term.
        // An explicit `search=` with an empty value is not equivalent on all
        // deployments and has returned the site's generic 404 page.
        var parameters: [URLQueryItem] = [
            .init(name: "page", value: String(max(1, page))),
            .init(name: "ordering", value: sort == "recent" ? "newest" : sort == "popular" ? "mostviewed" : "featured"),
            .init(name: "thumbsize", value: "large_hd")]
        if !selection.keywords.isEmpty {
            parameters.insert(.init(name: "search", value: selection.keywords.joined(separator: " ")), at: 0)
        }
        if let category = selection.category {
            parameters.append(.init(name: "category", value: String(category.dropFirst("category:".count))))
        }
        if sort == "recent" || sort == "popular" {
            parameters.append(.init(name: "period", value: "monthly"))
        }
        let bytes: Data
        do { bytes = try await data(session: session, url: url("https://www.pornhub.com/webmasters/search", parameters), provider: .pornhub, headers: cookieHeaders(credentials)) }
        catch APIError.providerStatus(.pornhub, 404) {
            // Same public API and host; some deployments require the canonical
            // trailing slash. If both public webmaster paths have gone away,
            // use Pornhub's own public listing HTML. No proxy or bypass.
            do {
                bytes = try await data(session: session, url: url("https://www.pornhub.com/webmasters/search/", parameters), provider: .pornhub, headers: cookieHeaders(credentials))
            } catch APIError.providerStatus(.pornhub, 404) {
                return try await pornhubPublicCatalog(session: session, credentials: credentials,
                    query: query, page: page, sort: sort, immersive: immersive)
            }
        }
        // A removed webmaster route can return a 200 HTML error. If so, try
        // the site's documented public browsing pages before giving up.
        guard let result = try? object(bytes), result["videos"] != nil else {
            return try await pornhubPublicCatalog(session: session, credentials: credentials,
                query: query, page: page, sort: sort, immersive: immersive)
        }
        let raw = rows(result["videos"])
        if raw.isEmpty, page == 1, selection.keywords.isEmpty {
            return try await pornhubPublicCatalog(session: session, credentials: credentials,
                query: query, page: page, sort: sort, immersive: immersive)
        }
        let posts = raw.map { row -> Post in
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
            post.caption = text(row["title"]); post.creator = text(row["username"]); return post
        }
        return self.page(posts, hasMore: raw.count >= 20, query: query, immersive: immersive)
    }

    /// Best-effort catalog fallback for deployments where the public webmaster
    /// API has been removed. This only reads Pornhub's own public browse HTML;
    /// it never follows third-party mirrors or works around a regional block.
    static func pornhubPublicCatalog(session: URLSession, credentials: ProviderCredentials,
                                     query: ParsedQuery, page: Int, sort: String,
                                     immersive: Bool) async throws -> PostPage {
        let selection = ProviderSearchCategories.split(query, provider: .pornhub)
        let searching = !selection.keywords.isEmpty
        let category = selection.category.map { String($0.dropFirst("category:".count)) }
        let route = searching ? "https://www.pornhub.com/video/search" :
            category.map { "https://www.pornhub.com/categories/" + $0 } ?? "https://www.pornhub.com/video"
        var parameters: [URLQueryItem] = [.init(name: "page", value: String(max(1, page)))]
        if searching {
            parameters.append(.init(name: "search", value: selection.keywords.joined(separator: " ")))
            if let category { parameters.append(.init(name: "category", value: category)) }
        } else {
            parameters.append(.init(name: "o", value: sort == "recent" ? "mr" : "mv"))
        }
        let bytes: Data
        do {
            bytes = try await data(session: session, url: url(route, parameters),
                                   provider: .pornhub, headers: cookieHeaders(credentials))
        } catch APIError.providerStatus(.pornhub, 404) {
            throw APIError.server("Pornhub's public webmaster API and public listing are both unavailable (404). Try again later or open the provider directly.")
        }
        guard !unavailableHTML(bytes) else {
            throw APIError.server("Pornhub is returning an unavailable page from this network. QuickTick cannot load its catalog until access is restored.")
        }
        // Bound regex work on pages with large inline player/state scripts.
        let html = String(decoding: bytes.prefix(2 * 1024 * 1024), as: UTF8.self)
        let posts = pornhubHTMLPosts(html)
        guard !posts.isEmpty else {
            throw APIError.server("Pornhub's public webmaster API is unavailable, and its public page returned no readable videos. The provider may be restricted in your region.")
        }
        return self.page(posts, hasMore: posts.count >= 20, query: query, immersive: immersive)
    }

    /// Extract only public listing metadata, not player scripts, cookies, or
    /// embedded media URLs. An unrecognized markup version fails explicitly.
    static func pornhubHTMLPosts(_ html: String) -> [Post] {
        let blocks = matches(html,
            #"<li\b[^>]*(?:videoblock|videoBox)[^>]*>.*?</li>"#, group: 0)
        let candidates = blocks.isEmpty
            ? matches(html, #"<a\b[^>]*href=["'][^"']*view_video\.php\?viewkey=[^"']*["'][^>]*>.*?</a>"#, group: 0)
            : blocks
        var seen = Set<String>()
        return candidates.prefix(100).compactMap { block -> Post? in
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
                        redgifsToken: String?, havenToken: String? = nil) async throws -> ResolvedMedia {
        // A valid direct media URL can outlive its provider metadata (for
        // example an imported/restored post with a legacy or unknown site).
        // Only use this fallback for actual file/playlist paths, never an
        // HTML post page masquerading as a downloadable video.
        let direct = mediaURL(post.mediaUrl, provider: post.providerKey)
        let directTypes: Set<String> = ["mp4", "m4v", "mov", "webm", "m3u8", "gif", "jpg", "jpeg", "png", "webp", "heic", "avif", "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "ogg", "opus"]
        if let direct, directTypes.contains(direct.pathExtension.lowercased()) {
            return ResolvedMedia(mediaUrl: direct.absoluteString, type: direct.pathExtension.lowercased() == "m3u8" ? "hls" : post.type)
        }
        guard let provider = post.providerKey else {
            throw APIError.server("This post has no recognized source or downloadable media URL. Try opening the original post again.")
        }
        // Some provider CDNs use opaque signed URLs without an extension.
        // Keep supporting those only after the provider has been identified.
        if let direct { return ResolvedMedia(mediaUrl: direct.absoluteString, type: post.type) }
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
            let response = try object(await data(session: session, url: url("https://hanime.tv/api/v8/video", [.init(name: "id", value: post.id)]), provider: provider))
            let manifest = response["videos_manifest"] as? [String: Any] ?? [:]
            let streams = rows(manifest["servers"]).flatMap { rows($0["streams"]) }.sorted { number($0["height"]) > number($1["height"]) }
            guard let media = streams.compactMap({ mediaURL(text($0["url"]), provider: provider) }).first else { throw APIError.server("Hanime returned no public stream.") }
            return ResolvedMedia(mediaUrl: media.absoluteString, type: media.pathExtension == "m3u8" ? "hls" : "video")
        case .pornhub:
            let canonical = mediaURL(post.pageUrl, provider: provider)
            let page: URL
            if let canonical, ["pornhub.com", "www.pornhub.com"].contains(canonical.host ?? ""), canonical.path == "/view_video.php" {
                page = canonical
            } else { page = try url("https://www.pornhub.com/view_video.php", [.init(name: "viewkey", value: post.id)]) }
            let html = String(decoding: try await data(session: session, url: page, provider: provider, headers: cookieHeaders(credentials)), as: UTF8.self)
            guard let json = jsonFragment(html, after: "mediaDefinitions"), let raw = try JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { throw APIError.server("Pornhub did not expose public media. Check your provider access.") }
            let sorted = raw.sorted { number($0["quality"]) > number($1["quality"]) }
            for format in ["mp4", "hls"] {
                for definition in sorted where text(definition["format"]) == format {
                    guard let candidate = mediaURL(text(definition["videoUrl"]), provider: provider) else { continue }
                    if ["mp4", "m3u8"].contains(candidate.pathExtension.lowercased()) { return ResolvedMedia(mediaUrl: candidate.absoluteString, type: format == "hls" ? "hls" : "video") }
                    guard candidate.host == "pornhub.com" || candidate.host?.hasSuffix(".pornhub.com") == true else { continue }
                    let details: Data
                    do { details = try await data(session: session, url: candidate, provider: provider, headers: cookieHeaders(credentials)) }
                    catch APIError.providerStatus(.pornhub, let status) where status == 404 || status == 410 { continue }
                    let list = rows(try JSONSerialization.jsonObject(with: details)).sorted { number($0["quality"]) > number($1["quality"]) }
                    if let media = list.compactMap({ mediaURL(text($0["videoUrl"]), provider: provider) }).first { return ResolvedMedia(mediaUrl: media.absoluteString, type: "video") }
                }
            }
            throw APIError.server("Pornhub has no available stream for this post. It may have been removed or be unavailable in your region.")
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
