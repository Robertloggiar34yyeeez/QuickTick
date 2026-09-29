import Foundation

struct DanbooruProvider: MediaProvider {
    let id: SourceID = .danbooru
    let supportedSorts: [FeedSort] = FeedSort.allCases
    var client = HTTPClient()

    static func url(for query: FeedQuery, login: String? = nil, apiKey: String? = nil) -> URL {
        var components = URLComponents(string: "https://danbooru.donmai.us/posts.json")!
        var terms = query.tags.prefix(query.sort == .recent ? 2 : 1).map(TagRules.normalized)
        switch query.sort {
        case .score: terms.append("order:score")
        case .popular: if !terms.contains("order:rank") { terms.append("order:rank") }
        case .recommended, .recent: break
        }
        var items = [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "tags", value: terms.joined(separator: " "))]
        if let cursor = query.cursor { items.append(URLQueryItem(name: "page", value: "b\(cursor)")) }
        if let login, let apiKey, !login.isEmpty, !apiKey.isEmpty {
            items += [URLQueryItem(name: "login", value: login), URLQueryItem(name: "api_key", value: apiKey)]
        }
        components.queryItems = items
        return components.url!
    }

    func fetch(_ query: FeedQuery) async throws -> Page {
        let url = Self.url(for: query, login: Keychain.get("danbooru.login"), apiKey: Keychain.get("danbooru.key"))
        let data = try await client.get(url)
        let raw: [DanbooruPost]
        do { raw = try JSONDecoder().decode([DanbooruPost].self, from: data) }
        catch { throw NetworkError.badData }
        let posts = raw.compactMap(\.post)
            .filter { TagRules.allowed($0, exclusions: query.exclusions) }
            .filter { post in query.tags.allSatisfy { post.tags.contains(TagRules.normalized($0)) } }
            .filter { !query.animatedOnly || $0.kind != .image }
        return Page(posts: posts, nextCursor: raw.count == 30 ? raw.last.map { String($0.id) } : nil)
    }

    func suggestions(for prefix: String) async throws -> [String] {
        var parts = URLComponents(string: "https://danbooru.donmai.us/tags.json")!
        parts.queryItems = [URLQueryItem(name: "search[name_matches]", value: prefix + "*"), URLQueryItem(name: "limit", value: "12")]
        let data = try await client.get(parts.url!)
        return (try? JSONDecoder().decode([DanbooruTag].self, from: data).map(\.name)) ?? []
    }

    func testConnection() async throws {
        var query = FeedQuery(); query.sort = .recent
        _ = try await fetch(query)
    }
}

private struct DanbooruTag: Decodable { let name: String }

struct DanbooruPost: Decodable {
    let id: Int
    let tagString: String
    let score: Int
    let rating: String?
    let imageWidth: Int
    let imageHeight: Int
    let fileExt: String?
    let fileURL: URL?
    let largeFileURL: URL?
    let previewFileURL: URL?
    enum CodingKeys: String, CodingKey {
        case id, score, rating
        case tagString = "tag_string", imageWidth = "image_width", imageHeight = "image_height"
        case fileExt = "file_ext", fileURL = "file_url", largeFileURL = "large_file_url", previewFileURL = "preview_file_url"
    }
    var post: Post? {
        guard let media = fileURL ?? largeFileURL ?? previewFileURL, let preview = previewFileURL ?? largeFileURL ?? fileURL else { return nil }
        let kind: MediaKind = ["mp4", "webm"].contains(fileExt ?? "") ? .video : fileExt == "gif" ? .animation : .image
        return Post(id: "danbooru:\(id)", source: .danbooru, sourceID: String(id), kind: kind, previewURL: preview, mediaURL: media, pageURL: URL(string: "https://danbooru.donmai.us/posts/\(id)")!, tags: tagString.split(separator: " ").map(String.init), score: score, rating: rating, width: imageWidth, height: imageHeight)
    }
}

actor RedGIFsToken {
    private var token: String?
    private var acquired: Date = .distantPast
    func value(client: HTTPClient) async throws -> String {
        if let token, Date().timeIntervalSince(acquired) < 1800 { return token }
        let data = try await client.get(URL(string: "https://api.redgifs.com/v2/auth/temporary")!)
        struct Response: Decodable { let token: String }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else { throw NetworkError.badData }
        token = result.token; acquired = Date()
        return result.token
    }
}

struct RedGIFsProvider: MediaProvider {
    let id: SourceID = .redgifs
    let supportedSorts: [FeedSort] = [.recommended, .popular, .recent]
    var client = HTTPClient()
    let tokens = RedGIFsToken()

    func fetch(_ query: FeedQuery) async throws -> Page {
        let token = try await tokens.value(client: client)
        var parts = URLComponents(string: "https://api.redgifs.com/v2/gifs/search")!
        let page = Int(query.cursor ?? "1") ?? 1
        let order = query.sort == .recent ? "latest" : "top7"
        parts.queryItems = [URLQueryItem(name: "type", value: "g"), URLQueryItem(name: "order", value: order), URLQueryItem(name: "count", value: "30"), URLQueryItem(name: "page", value: String(page))]
        if !query.tags.isEmpty { parts.queryItems?.append(URLQueryItem(name: "tags", value: query.tags.joined(separator: ","))) }
        let data = try await client.get(parts.url!, headers: ["Authorization": "Bearer \(token)"])
        guard let result = try? JSONDecoder().decode(RedGIFsResult.self, from: data) else { throw NetworkError.badData }
        let posts = result.gifs.compactMap(\.post).filter { TagRules.allowed($0, exclusions: query.exclusions) }
        return Page(posts: posts, nextCursor: result.gifs.count == 30 ? String(page + 1) : nil)
    }
    func suggestions(for prefix: String) async throws -> [String] {
        let token = try await tokens.value(client: client)
        var parts = URLComponents(string: "https://api.redgifs.com/v2/search/suggest")!
        parts.queryItems = [URLQueryItem(name: "query", value: prefix)]
        let data = try await client.get(parts.url!, headers: ["Authorization": "Bearer \(token)"])
        struct Suggestion: Decodable { let text: String }
        return (try? JSONDecoder().decode([Suggestion].self, from: data).map(\.text)) ?? []
    }
    func testConnection() async throws { _ = try await tokens.value(client: client) }
}

private struct RedGIFsResult: Decodable { let gifs: [RedGIF] }
private struct RedGIF: Decodable {
    let id: String
    let tags: [String]?
    let likes: Int?
    let width: Int?
    let height: Int?
    let urls: URLs
    struct URLs: Decodable { let sd: URL?; let hd: URL?; let poster: URL?; let thumbnail: URL? }
    var post: Post? {
        guard let media = urls.hd ?? urls.sd, let preview = urls.poster ?? urls.thumbnail else { return nil }
        return Post(id: "redgifs:\(id)", source: .redgifs, sourceID: id, kind: .video, previewURL: preview, mediaURL: media, pageURL: URL(string: "https://www.redgifs.com/watch/\(id)")!, tags: tags ?? [], score: likes ?? 0, rating: nil, width: width ?? 0, height: height ?? 0)
    }
}
