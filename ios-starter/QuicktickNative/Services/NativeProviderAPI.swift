import Foundation

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

// Provider networking lives on the API actor, never on a scrolling view. No
// requests in this service use the optional QuickTick Sync origin.
enum NativeProviderAPI {
    static let userAgent = "QuickTickNative/0.9.5"
    static let quicktickHost = "quick-tick-webb.vercel.app"

    static func origin(_ provider: Provider) -> URL {
        switch provider {
        case .rule34: URL(string: "https://rule34.xxx")!
        case .redgifs: URL(string: "https://www.redgifs.com")!
        case .eporner: URL(string: "https://www.eporner.com")!
        case .pornhub: URL(string: "https://www.pornhub.com")!
        case .hanime: URL(string: "https://hanime.tv")!
        }
    }

    static func mediaURL(_ raw: String, provider: Provider? = nil) -> URL? {
        guard !raw.isEmpty, !raw.hasPrefix("/api/") else { return nil }
        let base = provider.map(origin)
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
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

    static func data(session: URLSession, url: URL, provider: Provider, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        guard url.scheme == "https", let host = url.host, host.lowercased() != quicktickHost else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
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
            guard data.count <= 8 * 1024 * 1024 else { throw APIError.server("Provider response is too large.") }
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
        case "mp4", "webm", "mov", "m3u8": "video"
        default: "image"
        }
    }
    static func page(_ rows: [Post], hasMore: Bool, query: ParsedQuery, immersive: Bool) -> PostPage {
        let banned = Set(query.excluded.map { $0.lowercased() })
        var seen = Set<String>()
        return PostPage(items: rows.filter {
            !$0.id.isEmpty && seen.insert($0.stableID).inserted && (!immersive || $0.isImmersiveMedia)
                && banned.isDisjoint(with: Set($0.tags.map { $0.lowercased() }))
        }, hasMore: hasMore)
    }

    static func rule34(session: URLSession, credentials: ProviderCredentials, query: ParsedQuery, page: Int, sort: String, immersive: Bool, id: String? = nil) async throws -> PostPage {
        guard !credentials.rule34User.isEmpty, !credentials.rule34Key.isEmpty else {
            throw APIError.server("Add your Rule34 user ID and API key in Settings. They are sent directly to Rule34.")
        }
        let limit = id == nil ? 40 : 1
        var tags = query.included + query.excluded.map { "-" + $0 }
        if immersive { tags.append("( video ~ animated_gif )") }
        if sort == "popular" { tags.append("sort:score") }
        let items = [URLQueryItem(name: "page", value: "dapi"), .init(name: "s", value: "post"), .init(name: "q", value: "index"),
                     .init(name: "pid", value: String(max(0, page - 1))), .init(name: "limit", value: String(limit)),
                     .init(name: "tags", value: tags.joined(separator: " ")), .init(name: "json", value: "1"),
                     .init(name: "user_id", value: credentials.rule34User), .init(name: "api_key", value: credentials.rule34Key)] + (id.map { [URLQueryItem(name: "id", value: $0)] } ?? [])
        let bytes = try await data(session: session, url: url("https://api.rule34.xxx/index.php", items), provider: .rule34)
        let raw: [[String: Any]]
        var total = 0
        if let json = try? JSONSerialization.jsonObject(with: bytes) {
            if let array = json as? [[String: Any]] { raw = array }
            else if let object = json as? [String: Any], object["post"] != nil {
                raw = rows(object["post"]); total = Int(number(object["count"]))
            } else { throw APIError.invalidResponse }
        } else {
            let xml = try ProviderXML.parse(bytes)
            raw = xml.posts.map { $0 as [String: Any] }; total = xml.total
        }
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

    static func hanime(session: URLSession, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        let body: [String: Any] = ["search_text": query.included.joined(separator: " "), "tags": [], "tags_mode": "AND", "brands": [], "blacklist": [],
                                   "order_by": sort == "recent" ? "released_at_unix" : "views", "ordering": "desc", "page": max(0, page - 1)]
        let result: [String: Any]
        do {
            result = try object(await data(session: session, url: url("https://search.htv-services.com/"), provider: .hanime, method: "POST", body: JSONSerialization.data(withJSONObject: body)))
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

    static func pornhub(session: URLSession, credentials: ProviderCredentials, query: ParsedQuery, page: Int, sort: String, immersive: Bool) async throws -> PostPage {
        // Public webmaster API; no third-party relay or challenge bypass.
        let parameters: [URLQueryItem] = [
            .init(name: "search", value: query.included.joined(separator: " ")), .init(name: "page", value: String(page)),
            .init(name: "ordering", value: sort == "recent" ? "newest" : sort == "popular" ? "mostviewed" : "featured"),
            .init(name: "thumbsize", value: "large_hd"), .init(name: "period", value: "monthly")]
        let bytes: Data
        do { bytes = try await data(session: session, url: url("https://www.pornhub.com/webmasters/search", parameters), provider: .pornhub, headers: cookieHeaders(credentials)) }
        catch APIError.providerStatus(.pornhub, 404) {
            // Same public API and host; some deployments require the canonical
            // trailing slash. Never rotate domains or retry access/rate limits.
            bytes = try await data(session: session, url: url("https://www.pornhub.com/webmasters/search/", parameters), provider: .pornhub, headers: cookieHeaders(credentials))
        }
        let result = try object(bytes)
        if result["videos"] == nil { throw APIError.server("Pornhub did not return a public feed. Check provider availability in your region.") }
        let raw = rows(result["videos"])
        let posts = raw.map { row -> Post in
            let id = text(row["video_id"] ?? row["id"])
            var post = Post(key: "pornhub:\(id)", id: id, provider: "Pornhub", score: number(row["views"]),
                            tags: strings(row["tags"]) + strings(row["categories"]), thumbUrl: text(row["default_thumb"] ?? row["thumb"]),
                            pageUrl: text(row["url"]), type: "video")
            post.caption = text(row["title"]); post.creator = text(row["username"]); return post
        }
        return self.page(posts, hasMore: raw.count >= 20, query: query, immersive: immersive)
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
    static func resolve(session: URLSession, credentials: ProviderCredentials, post: Post, redgifsToken: String?) async throws -> ResolvedMedia {
        guard let provider = post.providerKey else { throw APIError.invalidResponse }
        if let direct = mediaURL(post.mediaUrl, provider: provider) {
            return ResolvedMedia(mediaUrl: direct.absoluteString, type: direct.pathExtension.lowercased() == "m3u8" ? "hls" : post.type)
        }
        switch provider {
        case .rule34:
            let page = try await rule34(session: session, credentials: credentials, query: QueryParser.parse(""), page: 1, sort: "recent", immersive: false, id: post.id)
            guard let media = page.items.first?.mediaUrl else { throw APIError.invalidResponse }
            return ResolvedMedia(mediaUrl: media, type: page.items.first?.type ?? "video")
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
