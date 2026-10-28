import XCTest
@testable import QuicktickNative

private final class NativeRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    func reset() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
}

private final class NativeProviderProtocol: URLProtocol, @unchecked Sendable {
    static let log = NativeRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.append(request)
        let url = request.url!, host = url.host ?? ""
        // Foundation URL.path drops a trailing slash; the canonical-route
        // fallback fixture must distinguish /search from /search/.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let payload: String
        if path == "/v2/auth/temporary" { payload = #"{"token":"synthetic-provider-token"}"# }
        else if ["coomer.st", "kemono.cr"].contains(host), path == "/api/v1/creators" {
            payload = #"[{"id":"42","service":"fanbox","name":"Fixture Artist","favorited":42},{"id":"51","service":"patreon","name":"Other Creator","favorited":8}]"#
        }
        else if ["coomer.st", "kemono.cr"].contains(host),
                path == "/api/v1/posts" || path == "/api/v1/fanbox/user/42/posts" {
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if host == "kemono.cr", parts.contains(where: { $0.name == "q" && $0.value == "private-403" }) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            if host == "kemono.cr", path == "/api/v1/posts",
               parts.contains(where: { $0.name == "o" && $0.value == "100" }) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = #"{"posts":[{"id":"p100","service":"fanbox","user":"42","title":"Cosplay fantasy portrait","artist":"Fixture Artist","published":"2026-09-01T10:00:00Z","file":{"name":"portrait.jpg","path":"/ab/cd.jpg"},"attachments":[{"name":"clip.mp4","path":"/ab/ef.mp4"},{"name":"sound.mp3","path":"/ab/sound.mp3"},{"name":"archive.zip","path":"/ab/ignored.zip"}]}]}"#
        }
        else if ["coomer.st", "kemono.cr"].contains(host), path.hasSuffix("/comments") {
            payload = #"[{"id":"1","author":"Visitor","content":"Amazing post","created_at":"2026-09-01"}]"#
        }
        else if host == "api.redgifs.com" { payload = #"{"pages":3,"gifs":[{"id":"clip","type":"g","width":1920,"height":1080,"tags":["engineering"],"urls":{"hd":"https://media.redgifs.com/clip.mp4","poster":"https://media.redgifs.com/clip.jpg"}}]}"# }
        else if host == "api.rule34.xxx", path == "/autocomplete.php" { payload = #"[{"value":"engineering","label":"engineering (12)","count":12}]"# }
        else if host == "api.rule34.xxx" {
            let comments = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "s" && $0.value == "comment" } == true
            payload = comments ? #"<comments><comment id="7" creator="Fixture" body="A &amp; B" /></comments>"# : #"[{"id":1,"score":9,"tags":"engineering car","width":1920,"height":1080,"file_url":"https://media.rule34.xxx/clip.mp4","preview_url":"https://media.rule34.xxx/clip.jpg"}]"#
        } else if path.contains("/embed/") { payload = #"<html><script>var hash='00112233445566778899aabbccddeeff';</script></html>"# }
        else if path.contains("/xhr/video/") { payload = #"{"sources":{"mp4":{"360p":{"src":"https://cdn.eporner.com/small.mp4"},"1080p":{"src":"https://cdn.eporner.com/full.mp4"}}}}"# }
        else if host == "www.eporner.com" {
            let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = Int(parameters.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
            let order = parameters.first(where: { $0.name == "order" })?.value
            let quality = parameters.first(where: { $0.name == "lq" })?.value
            let query = parameters.first(where: { $0.name == "query" })?.value
            payload = page > 3 || (query == "all" && order == "latest" && quality == "0")
                ? #"{"total_pages":3,"videos":[]}"#
                : #"{"total_pages":3,"videos":[{"id":"ep1","title":"Ground effect","keywords":"engineering,aerodynamics","views":10,"default_thumb":{"src":"https://cdn.eporner.com/thumb.jpg"}}]}"#
        }
        else if host == "api.hentaihaven.app", path == "/v1/warden" {
            payload = #"{"data":{"token":"fixture-warden-token"}}"#
        }
        else if host == "api.hentaihaven.app", path == "/v1/search" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "q" })?.value
            if q == "unavailable-response" {
                payload = "<html><head><title>Site Unavailable</title></head><body>Unable to access this site.</body></html>"
            } else if q == "embedded-429" {
                payload = #"{"data":"429 Too many requests"}"#
            } else if q == "embedded-502" || q == "fallback-web" {
                payload = #"{"data":"502 Upstream unavailable"}"#
            } else if q == "unmatched-interest" {
                payload = #"{"data":"No search results"}"#
            } else {
                payload = #"{"data":[{"post_id":12,"post_name":"maid-episode","post_title":"Maid episode","post_thumbnail":"https://cdn.hentaihaven.app/thumb.jpg"}]}"#
            }
        }
        else if host == "api.hentaihaven.app", path == "/v1/hentai/all" {
            payload = ["fallback-test-token", "category-only-test-token"].contains(request.value(forHTTPHeaderField: "warden") ?? "")
                ? #"{"data":{"hentais":[],"total_pages":0}}"#
                : #"{"data":{"hentais":[{"post_id":12,"post_name":"maid-episode","post_title":"Maid episode","post_thumbnail":"https://cdn.hentaihaven.app/thumb.jpg"}],"total_pages":3}}"#
        }
        else if host == "api.hentaihaven.app", path == "/v1/hentai/home" {
            payload = request.value(forHTTPHeaderField: "warden") == "category-only-test-token"
                ? #"{"data":{"trending_month":[],"last":[],"yuri":[{"post_id":19,"post_title":"Yuri romance","post_thumbnail":"https://cdn.hentaihaven.app/yuri.jpg"}]}}"#
                : #"{"data":{"trending_month":[{"post_id":12,"post_title":"Maid episode","post_thumbnail":"https://cdn.hentaihaven.app/thumb.jpg"}],"yuri":[{"post_id":19,"post_title":"Yuri romance","post_thumbnail":"https://cdn.hentaihaven.app/yuri.jpg"}]}}"#
        }
        else if host == "api.hentaihaven.app", path == "/v1/genre/17" {
            payload = #"{"data":{"hentais":[{"post_id":34,"post_title":"Maid academy","post_thumbnail":"https://cdn.hentaihaven.app/maid.jpg"}],"total_pages":2}}"#
        }
        else if host == "nhentai.net", path.hasPrefix("/api/galleries") || path.hasPrefix("/api/gallery/") {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        else if host == "nhentai.net", path == "/api/v2/galleries/popular" {
            payload = #"[{"id":456,"media_id":"321","english_title":"Space adventure","thumbnail":"galleries/321/cover.png","thumbnail_width":600,"thumbnail_height":900}]"#
        }
        else if host == "nhentai.net", path == "/api/v2/galleries" || path == "/api/v2/search" {
            payload = #"{"result":[{"id":456,"media_id":"321","english_title":"Space adventure","japanese_title":null,"thumbnail":"galleries/321/cover.png","thumbnail_width":600,"thumbnail_height":900,"num_pages":3,"tag_ids":[100,200]}],"num_pages":3,"per_page":25}"#
        }
        else if host == "nhentai.net", path == "/api/v2/galleries/456" {
            payload = #"{"id":456,"media_id":"321","title":{"english":"Space adventure","pretty":"Space adventure"},"pages":[{"number":1,"path":"galleries/321/1.jpg"},{"number":2,"path":"2.png"},{"number":3,"path":"3.webp"}]}"#
        }
        else if host == "api.hentaihaven.app", path == "/v1/hentai/12" {
            payload = #"{"data":{"post_id":12,"episodes":[{"chapter_id":34,"chapter_name":"Episode 1"}]}}"#
        }
        else if host == "api.hentaihaven.app", path == "/v1/hentai/12/episode/34" {
            payload = #"{"data":{"chapter_content":"https://cdn.hentaihaven.app/episode.m3u8"}}"#
        }
        else if host == "hentaihaven.xxx", path == "/" {
            payload = #"<html><a href="/watch/fallback-web/"><img src="https://img.hentaihaven.xxx/poster.jpg" alt="Fallback web fantasy"></a><a href="/watch/another-title/"><img src="https://img.hentaihaven.xxx/second.jpg" alt="Another title"></a></html>"#
        }
        else if host == "hentaihaven.xxx", path == "/series/yuri/" {
            payload = #"<html><a href="/watch/genre-entry/"><img src="https://coverlanyvd.org/cover.jpg" alt="Genre entry"></a></html>"#
        }
        else if host == "hentaihaven.xxx", path == "/watch/fallback-web/" {
            payload = #"<html><video controls><source src="https://media.hentaihaven.xxx/episode.m3u8" type="application/vnd.apple.mpegurl"></video></html>"#
        }
        else if host == "hentaihaven.xxx", path == "/watch/no-public-stream/" {
            payload = #"<html><div class="player">Player temporarily unavailable</div></html>"#
        }
        else if host == "search.htv-services.com" { payload = #"{"nbPages":3,"hits":"[{\"slug\":\"sample\",\"name\":\"Fixture\",\"poster_url\":\"https://cdn.hanime.tv/thumb.jpg\",\"hentai_tags\":[{\"text\":\"fantasy\"}]}]"}"# }
        else if path == "/api/v8/video" { payload = #"{"videos_manifest":{"servers":[{"streams":[{"height":1080,"url":"https://cdn.hanime.tv/full.m3u8"}]}]}}"# }
        else if path == "/webmasters/search" || path == "/webmasters/search/" {
            let search = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "search" })?.value
            if search == "unavailable-route" || search == "public-html" ||
               search == "browse-missing-first" || search == "browse-soft404" ||
               (search == "api-host" && host != "api.pornhub.com") ||
               (path == "/webmasters/search" && search == "route-fixture") {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = search == "html-response"
                ? "<html><head><title>404 Not Found</title></head><body>The requested URL was not found on this server.</body></html>"
                : #"{"videos":[{"video_id":"ph1","title":"Fixture","tags":[{"tag_name":"sample"}],"default_thumb":"https://cdn.pornhub.com/thumb.jpg","thumbs":[{"size":"small","src":"https://cdn.pornhub.com/thumb-small.jpg"}]}]}"#
        }
        else if host == "www.pornhub.com", path == "/video/search" {
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let search = params.first(where: { $0.name == "search" })?.value
            if search == "browse-missing-first", params.contains(where: { $0.name == "page" }) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = search == "browse-soft404" && params.contains(where: { $0.name == "page" })
                ? "<html><head><title>404 Not Found</title></head><body>The requested URL was not found on this server.</body></html>"
                : #"<html><ul><li class="videoblock videoBox" data-video-vkey="phpublic"><a href="/view_video.php?viewkey=phpublic" title="Public &amp; indexed"><img data-thumb_url="https://cdn.pornhub.com/public.jpg" src="https://cdn.pornhub.com/public-small.jpg" alt="Public video"></a></li></ul></html>"#
        }
        else if path == "/view_video.php" {
            let fallback = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "viewkey" && $0.value == "fallback" } == true
            payload = fallback ? #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://www.pornhub.com/removed-definition"},{"format":"hls","quality":"720","videoUrl":"https://cdn.pornhub.com/valid.m3u8"}]};</script>"# : #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://cdn.pornhub.com/full.mp4"}]};</script>"#
        }
        else if path == "/removed-definition" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        else if path == "/api/sync" { payload = #"{"exists":false,"ok":true}"# }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RateLimitProtocol: URLProtocol, @unchecked Sendable {
    static let log = NativeRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.append(request)
        let url = request.url!
        let count = Self.log.snapshot().filter { $0.url == url }.count
        let limit = url.path != "/recover" || count == 1
        let delay = url.path == "/long" ? "60" : url.path == "/cancel" ? "2" : "0"
        let response = HTTPURLResponse(url: url, statusCode: limit ? 429 : 200, httpVersion: nil, headerFields: ["Retry-After": delay])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NativeProviderAPITests: XCTestCase {
    func testArchiveDomainsNormalizeSafely() {
        XCTAssertEqual(Provider.identify("coomer.st"), .coomer)
        XCTAssertEqual(NativeProviderAPI.type("https://coomer.st/data/sound.mp3"), "audio")
        XCTAssertTrue(Post(key: "sound", id: "sound", provider: "coomer", type: "audio").isAudio)
        XCTAssertEqual(Provider.identify("kemono.cr"), .kemono)
        XCTAssertEqual(Provider.identifyPage("https://kemono.cr/fanbox/user/42/post/p100"), .kemono)
        XCTAssertNil(Provider.identifyPage("https://kemono.cr.evil.invalid/fanbox/user/42"))
        XCTAssertNil(NativeProviderAPI.archiveMediaURL(path: "https://evil.invalid/fake.jpg", provider: .kemono))
        XCTAssertEqual(NativeProviderAPI.archiveMediaURL(path: "/ab/cd.jpg", provider: .coomer)?.absoluteString,
                       "https://coomer.st/data/ab/cd.jpg")
        XCTAssertEqual(NativeProviderAPI.archiveMediaURL(path: "/ab/cd.jpg", provider: .kemono, thumbnail: true)?.absoluteString,
                       "https://img.kemono.cr/thumbnail/data/ab/cd.jpg")
        XCTAssertEqual(VisualDomain.classify(Post(key: "c", id: "1", provider: "coomer", type: "video")), .realLife)
        XCTAssertEqual(VisualDomain.classify(Post(key: "art-label", id: "2", provider: "coomer", tags: ["anime"], type: "image")), .realLife)
        XCTAssertNotNil(NativeProviderAPI.archiveMediaURL(path: "/ab/sound.mp3", provider: .coomer))
        XCTAssertTrue(VisualAppearanceEncoder.prefersMobileCLIP(domain: .realLife, provider: "coomer"))
    }

    func testArchiveProvidersSupportPagedSearchMediaAndComments() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        for provider in [Provider.coomer, .kemono] {
            NativeProviderProtocol.log.reset()
            let page = try await api.posts(provider: provider,
                query: ParsedQuery(included: ["cosplay"], excluded: []), page: 2)
            XCTAssertEqual(page.items.count, 3)
            XCTAssertEqual(Set(page.items.map(\.type)), ["image", "video", "audio"])
            XCTAssertEqual(page.items[0].providerKey, provider)
            XCTAssertEqual(page.items[0].mediaUrl,
                           "https://\(provider == .kemono ? "kemono.cr" : "coomer.st")/data/ab/cd.jpg")
            XCTAssertEqual(page.items[0].cardPreviewURL,
                           "https://img.\(provider == .kemono ? "kemono.cr" : "coomer.st")/thumbnail/data/ab/cd.jpg")
            let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot()
                .first(where: { $0.url?.path == "/api/v1/posts" }))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.contains("application/json") == true)
            let q = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(q.first(where: { $0.name == "q" })?.value, "cosplay")
            XCTAssertEqual(q.first(where: { $0.name == "o" })?.value, "50")
            let sound = try XCTUnwrap(page.items.first(where: { $0.isAudio }))
            XCTAssertTrue(sound.mediaUrl.hasSuffix("/ab/sound.mp3"))
            XCTAssertTrue(sound.cardPreviewURL.isEmpty)
            let resolved = try await api.resolveMedia(page.items[1])
            XCTAssertTrue(resolved.mediaUrl.hasSuffix("/ab/ef.mp4"))
            let comments = try await api.comments(page.items[0])
            XCTAssertEqual(comments.items.first?.body, "Amazing post")
            let filtered = NativeProviderAPI.page(page.items, hasMore: false,
                query: ParsedQuery(included: [], excluded: ["cosplay"]), immersive: false)
            XCTAssertTrue(filtered.items.isEmpty)
        }
    }

    func testArchiveArtistAutocompleteSelectsExactCreatorAndCachesTheIndex() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        for provider in [Provider.kemono, .coomer] {
            NativeProviderProtocol.log.reset()
            let matches = try await api.suggestions(provider: provider, query: "fixture")
            XCTAssertEqual(matches.first?.label, "Fixture Artist · fanbox")
            XCTAssertEqual(matches.first?.value, "creator:fanbox:42")
            _ = try await api.suggestions(provider: provider, query: "artist")
            let creatorRequests = NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/api/v1/creators" }
            XCTAssertEqual(creatorRequests.count, 1, "Creator index must not be downloaded on every keystroke")

            let results = try await api.posts(provider: provider,
                query: QueryParser.parse(try XCTUnwrap(matches.first?.value)), page: 2)
            XCTAssertEqual(results.items.count, 3)
            let route = try XCTUnwrap(NativeProviderProtocol.log.snapshot()
                .last(where: { $0.url?.path == "/api/v1/fanbox/user/42/posts" }))
            let query = URLComponents(url: try XCTUnwrap(route.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "o" })?.value, "50")
            XCTAssertNil(query.first(where: { $0.name == "q" }))
        }
        XCTAssertNil(NativeProviderAPI.archiveCreatorRoute("creator:fanbox:../evil"))
    }

    func testKemonoRecoverable404ReturnsBoundedLocallyFilteredPosts() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .kemono,
            query: QueryParser.parse("cosplay"), page: 3)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertFalse(page.hasMore ?? true, "A recovered page must not loop its broken cursor")
        let requested = NativeProviderProtocol.log.snapshot().compactMap(\.url)
        XCTAssertEqual(requested.count, 2)
        let fallback = try XCTUnwrap(URLComponents(url: requested[1], resolvingAgainstBaseURL: false))
        XCTAssertNil(fallback.queryItems?.first(where: { $0.name == "q" }))
        XCTAssertEqual(fallback.queryItems?.first(where: { $0.name == "o" })?.value, "0")
    }

    func testKemono403ExplainsSourceRestrictionWithoutRetryingAccessDenied() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        do {
            _ = try await api.posts(provider: .kemono,
                query: QueryParser.parse("private-403"), page: 1)
            XCTFail("HTTP 403 is an upstream restriction, not a search result")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("403"))
            XCTAssertTrue(error.localizedDescription.contains("Kemono"))
            XCTAssertTrue(error.localizedDescription.contains("site access"))
        }
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter { $0.url?.host == "kemono.cr" }.count, 1,
            "Do not hammer an endpoint after an access-denied response")
    }

    func testDownloadsRecoverCanonicalProviderFromAliasesKeysAndOriginalPages() {
        XCTAssertEqual(Post(key: "legacy:1", id: "1", provider: "RedGIFs.com").providerKey, .redgifs)
        XCTAssertEqual(Post(key: "pornhub:2", id: "2", provider: "Unknown site").providerKey, .pornhub)
        XCTAssertEqual(Post(key: "legacy:3", id: "3", provider: "Rule34.xxx").providerKey, .rule34)
        XCTAssertEqual(Post(key: "legacy:4", id: "4", provider: "Hanime.tv").providerKey, .hanime)
        XCTAssertEqual(Post(key: "hhaven:12", id: "12", provider: "Hentai Haven").providerKey, .hhaven)
        XCTAssertFalse(Provider.allCases.contains(.hanime), "Old Hanime downloads remain identifiable but its feed is removed")
        XCTAssertTrue(Provider.allCases.contains(.hhaven))
        var fromPage = Post(key: "legacy:5", id: "5", provider: "Imported")
        fromPage.pageUrl = "https://www.eporner.com/video-abc"
        XCTAssertEqual(fromPage.providerKey, .eporner)
        fromPage.pageUrl = "https://www.pornhub.com.evil.invalid/view_video.php"
        XCTAssertNil(fromPage.providerKey)
    }

    func testHavenCatalogAndPlaybackFollowDocumentedWardenEpisodeRoutes() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .hhaven,
                                       query: QueryParser.parse(""), page: 1)
        XCTAssertEqual(page.items.map(\.stableID), ["hhaven:12"])
        XCTAssertEqual(page.items.first?.caption, "Maid episode")
        XCTAssertEqual(page.items.first?.cardPreviewURL, "https://cdn.hentaihaven.app/thumb.jpg")
        let post = try XCTUnwrap(page.items.first)
        let stream = try await api.resolveMedia(post)
        XCTAssertEqual(stream.mediaUrl, "https://cdn.hentaihaven.app/episode.m3u8")
        XCTAssertEqual(stream.type, "hls")
        let requests = NativeProviderProtocol.log.snapshot()
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/warden" }.count, 1)
        XCTAssertTrue(requests.contains { $0.url?.path == "/v1/hentai/12/episode/34" &&
            $0.value(forHTTPHeaderField: "warden") == "fixture-warden-token" })
        XCTAssertFalse(requests.contains { $0.url?.host == "search.htv-services.com" })
        XCTAssertEqual(VisualDomain.classify(post), .anime)
    }

    func testHavenHTMLUnavailablePageIsNotMisreportedAsEmptyRecommendedFeed() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        do {
            _ = try await api.posts(provider: .hhaven,
                query: QueryParser.parse("unavailable-response"), page: 1)
            XCTFail("Unavailable HTML from the catalog API must not become a zero-result feed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Hentai Haven"))
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
    }

    func testHavenEmbeddedRateLimitAndUpstreamFailuresAreNotEmptyCatalogs() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        do {
            _ = try await api.posts(provider: .hhaven, query: QueryParser.parse("embedded-429"), page: 1)
            XCTFail("Embedded 429 must not silently become an empty page")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limiting requests"))
        }
        do {
            _ = try await api.posts(provider: .hhaven, query: QueryParser.parse("embedded-502"), page: 1)
            XCTFail("Embedded 502 must not silently become an empty page")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("upstream"))
        }
    }

    func testHomeCategoryChipsHaveValidProviderSpecificFilters() {
        let haven = ProviderSearchCategories.suggestions(provider: .hhaven)
        let pornhub = ProviderSearchCategories.suggestions(provider: .pornhub)
        XCTAssertTrue(haven.contains { $0.value == "category:section:yuri" && $0.label == "Yuri" })
        XCTAssertTrue(pornhub.contains { $0.value == "category:hentai" && $0.label == "Hentai" })
        XCTAssertEqual(ProviderSearchCategories.suggestions(provider: .hhaven, matching: "yur").map(\.label), ["Yuri"])
        XCTAssertEqual(ProviderSearchCategories.suggestions(provider: .pornhub, matching: "anim").map(\.label), ["Animation"])
        XCTAssertTrue(ProviderSearchCategories.valid("category:genre:17", provider: .hhaven))
        XCTAssertFalse(ProviderSearchCategories.valid("category:genre:../private", provider: .hhaven))
        XCTAssertFalse(ProviderSearchCategories.valid("category:../../private", provider: .pornhub))
        let selected = ProviderSearchCategories.split(QueryParser.parse("category:section:yuri \"maid academy\""), provider: .hhaven)
        XCTAssertEqual(selected.category, "category:section:yuri")
        XCTAssertEqual(selected.keywords, ["maid academy"])
    }

    func testHavenHomeCategoriesOpenSectionOrGenreCatalog() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let section = try await api.posts(provider: .hhaven,
            query: QueryParser.parse("category:section:yuri"), page: 1)
        XCTAssertEqual(section.items.map(\.stableID), ["hhaven:19"])
        XCTAssertEqual(section.items.first?.category, "yuri")
        let genre = try await api.posts(provider: .hhaven,
            query: QueryParser.parse("category:genre:17 maid"), page: 1)
        XCTAssertEqual(genre.items.map(\.stableID), ["hhaven:34"])
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.path == "/v1/genre/17" &&
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "p" && $0.value == "1" }) == true
        })
    }

    func testHavenFirstCatalogPageFallsBackToPopulatedHomeIndex() async throws {
        let (_, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let result = try await NativeProviderAPI.haven(session: session, token: "fallback-test-token",
            query: ParsedQuery(included: [], excluded: []), page: 1,
            sort: "recommended", immersive: false)
        XCTAssertEqual(result.items.map(\.stableID), ["hhaven:12", "hhaven:19"])
        let paths = NativeProviderProtocol.log.snapshot().compactMap { $0.url?.path }
        XCTAssertTrue(paths.contains("/v1/hentai/all"))
        XCTAssertTrue(paths.contains("/v1/hentai/home"))
    }

    func testHavenHomeFallbackUsesAvailableCategoriesWhenTrendingAndRecentAreEmpty() async throws {
        let (_, session) = client(); defer { session.invalidateAndCancel() }
        let result = try await NativeProviderAPI.haven(session: session, token: "category-only-test-token",
            query: ParsedQuery(included: [], excluded: []), page: 1,
            sort: "recommended", immersive: false)
        XCTAssertEqual(result.items.map(\.stableID), ["hhaven:19"])
    }

    func testHavenShortCacheReusesTheSameFirstPage() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let query = ParsedQuery(included: [], excluded: [])
        let first = try await api.posts(provider: .hhaven, query: query, page: 1, sort: "recommended")
        let repeated = try await api.posts(provider: .hhaven, query: query, page: 1, sort: "recommended")
        XCTAssertEqual(first.items.map(\.stableID), repeated.items.map(\.stableID))
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/v1/hentai/all" }.count, 1)
    }

    func testHavenPublicCatalogParsesWatchPagesAndRejectsUnrelatedLinks() async throws {
        let (_, session) = client(); defer { session.invalidateAndCancel() }
        let result = try await NativeProviderAPI.havenWebsiteCatalog(session: session,
            query: QueryParser.parse("fallback-web"), page: 1,
            sort: "recommended", immersive: false)
        XCTAssertEqual(result.items.map(\.stableID), ["hhaven:web:fallback-web"])
        XCTAssertEqual(result.items.first?.type, "video")
        XCTAssertEqual(result.items.first?.pageUrl, "https://hentaihaven.xxx/watch/fallback-web/")
        XCTAssertEqual(result.items.first?.thumbUrl, "https://img.hentaihaven.xxx/poster.jpg")
        XCTAssertEqual(result.hasMore, false)
    }

    func testHavenFallsBackToPublicWatchPagesWhenUpstreamReturnsEmbedded502() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let response = try await api.posts(provider: .hhaven,
            query: QueryParser.parse("fallback-web"), page: 1)
        XCTAssertEqual(response.items.map(\.stableID), ["hhaven:web:fallback-web"])
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { $0.url?.host == "hentaihaven.xxx" })
    }

    func testHavenWebsiteCatalogUsesRealCategoryPagesAndRejectsBlockedHTML() async throws {
        let (_, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let selection = QueryParser.parse("category:section:yuri")
        let page = try await NativeProviderAPI.havenWebsiteCatalog(session: session,
            query: selection, page: 1, sort: "recommended", immersive: false)
        XCTAssertEqual(page.items.map(\.stableID), ["hhaven:web:genre-entry"])
        XCTAssertEqual(page.items.first?.thumbUrl, "https://coverlanyvd.org/cover.jpg")
        XCTAssertEqual(page.items.first?.category, "category:section:yuri")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().last?.url?.absoluteString.contains("/series/yuri/") == true,
            "URL.path may normalize trailing slashes; the actual request must retain the category route")
        XCTAssertNil(NativeProviderAPI.havenWebsiteURL(sort: "recommended",
            query: QueryParser.parse("category:genre:17")))

        let unavailable = "<html><head><title>Site Unavailable</title></head><body>Unable to access this site.</body></html>"
        XCTAssertThrowsError(try NativeProviderAPI.havenWebsitePage(unavailable, query: QueryParser.parse("")))
        let mistaken = #"<a href="https://different.invalid/watch/not-our-site/">Wrong host</a>"#
        XCTAssertThrowsError(try NativeProviderAPI.havenWebsitePage(mistaken, query: QueryParser.parse("")))
    }
    func testHavenVerifiedTrendingPaginationAndRealCards() throws {
        let popular = ParsedQuery(included: [], excluded: [])
        XCTAssertEqual(NativeProviderAPI.havenWebsiteURL(sort: "popular", query: popular, page: 2)?.absoluteString,
                       "https://hentaihaven.xxx/browse/trending/page/2/")
        XCTAssertNil(NativeProviderAPI.havenWebsiteURL(sort: "recommended", query: popular, page: 2))
        XCTAssertNil(NativeProviderAPI.havenWebsiteURL(sort: "popular", query: popular, page: 51))
        let cards = (1...20).map { id in
            #"<a href="/watch/fixture-\#(id)/"><img src="https://img.hentaihaven.xxx/\#(id).jpg" alt="Fixture \#(id)"></a>"#
        }.joined()
        let first = try NativeProviderAPI.havenWebsitePage(cards, query: popular, page: 1, sort: "popular")
        XCTAssertEqual(first.items.count, 20)
        XCTAssertEqual(first.hasMore, true)
        let last = try NativeProviderAPI.havenWebsitePage(cards, query: popular, page: 50, sort: "popular")
        XCTAssertEqual(last.hasMore, false)
    }

    func testHavenCatalogPlaysDirectlyWithoutOpeningAnyWebsiteView() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let catalog = try await api.posts(provider: .hhaven,
            query: QueryParser.parse("fallback-web"), page: 1)
        let post = try XCTUnwrap(catalog.items.first)
        XCTAssertTrue(post.isImmersiveMedia)
        XCTAssertEqual(post.type, "video")
        let stream = try await api.resolveMedia(post)
        XCTAssertEqual(stream.mediaUrl, "https://media.hentaihaven.xxx/episode.m3u8")
        XCTAssertEqual(stream.type, "hls")
        let urls = NativeProviderProtocol.log.snapshot().compactMap(\.url)
        // URL.path can normalize a final slash; compare the transport URL,
        // which is what the fixture and real website use.
        XCTAssertTrue(urls.contains { $0.host == "hentaihaven.xxx" &&
            $0.absoluteString.hasPrefix("https://hentaihaven.xxx/watch/fallback-web") })
        XCTAssertFalse(urls.contains { $0.path == "/v1/hentai/fallback-web" })
        let missing = Post(key: "hhaven:web:no-public-stream", id: "no-public-stream", provider: "hhaven",
            pageUrl: "https://hentaihaven.xxx/watch/no-public-stream/", type: "video")
        do {
            _ = try await api.resolveMedia(missing)
            XCTFail("An HTML watch page must never be handed to AVPlayer as a media URL")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("playable in-app stream"))
        }
    }

    func testHavenEpisodeAcceptsMarkupAndNestedSourceWithoutTreatingHTMLAsAVAsset() {
        let markup = ["chapter_content": #"<video controls><source src="https://media.hentaihaven.xxx/episode.m3u8?token=valid" type="application/x-mpegURL"></video>"#]
        XCTAssertEqual(NativeProviderAPI.havenEpisodeMedia(markup)?.mediaUrl,
                       "https://media.hentaihaven.xxx/episode.m3u8?token=valid")
        XCTAssertEqual(NativeProviderAPI.havenEpisodeMedia(markup)?.type, "hls")
        let nested: [String: Any] = ["sources": [["url": "https://media.hentaihaven.xxx/episode.mp4"]]]
        XCTAssertEqual(NativeProviderAPI.havenEpisodeMedia(nested)?.mediaUrl,
                       "https://media.hentaihaven.xxx/episode.mp4")
        XCTAssertNil(NativeProviderAPI.havenEpisodeMedia(["chapter_content": "<html>Access denied</html>"]))
    }

    func testNHentaiGalleryBrowseSearchAndCompletePageManifest() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        XCTAssertEqual(Provider.identify("nhentai.net"), .nhentai)
        XCTAssertEqual(Provider.identifyPage("https://nhentai.net/g/456/"), .nhentai)
        XCTAssertEqual(VisualDomain.classify(Post(key: "nhentai:456", id: "456", provider: "nhentai", type: "manga")), .anime)
        XCTAssertTrue(AnimeVisualRecommendationPolicy.usesWDTagger(
            Post(key: "nhentai:456", id: "456", provider: "nhentai", type: "manga"), domain: .anime))
        let home = try await api.posts(provider: .nhentai,
            query: ParsedQuery(included: [], excluded: []), page: 1)
        XCTAssertEqual(home.items.map(\.stableID), ["nhentai:456"])
        XCTAssertEqual(home.items.first?.type, "manga")
        XCTAssertEqual(home.items.first?.mediaUrl, "https://t1.nhentai.net/galleries/321/cover.png")
        XCTAssertEqual(home.items.first?.caption, "Space adventure")
        XCTAssertEqual(home.hasMore, true)
        let recentRequest = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first {
            $0.url?.path == "/api/v2/galleries"
        })
        XCTAssertTrue(recentRequest.value(forHTTPHeaderField: "User-Agent")?.contains("QuickTick/0.9.9") == true)
        XCTAssertEqual(NativeProviderAPI.nhentaiImageURL(path: "2.png", mediaID: "321", thumbnail: false)?.absoluteString,
                       "https://i1.nhentai.net/galleries/321/2.png")
        XCTAssertNil(NativeProviderAPI.nhentaiImageURL(path: "https://example.invalid/page.jpg", mediaID: "321", thumbnail: false))
        let pages = try await api.mangaPages(bookID: "456")
        XCTAssertEqual(pages.map(\.absoluteString), [
            "https://i1.nhentai.net/galleries/321/1.jpg",
            "https://i1.nhentai.net/galleries/321/2.png",
            "https://i1.nhentai.net/galleries/321/3.webp"
        ])
        let searched = try await api.posts(provider: .nhentai,
            query: QueryParser.parse("cosplay"), page: 2)
        XCTAssertEqual(searched.items.count, 1)
        let popular = try await api.posts(provider: .nhentai,
            query: ParsedQuery(included: [], excluded: []), page: 1, sort: "popular")
        XCTAssertEqual(popular.items.map(\.stableID), ["nhentai:456"])
        XCTAssertEqual(popular.hasMore, false)
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/api/v2/galleries/popular" })
        let beforeRepeatedBrowse = NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/api/v2/galleries" }.count
        _ = try await api.posts(provider: .nhentai, query: ParsedQuery(included: [], excluded: []), page: 1)
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/api/v2/galleries" }.count, beforeRepeatedBrowse,
            "Short catalog cache should avoid spending a second anonymous rate-limit request")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.path == "/api/v2/search" &&
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "query" && $0.value == "cosplay" }) == true
        })
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.path.hasPrefix("/api/galleries") == true || $0.url?.path.hasPrefix("/api/gallery/") == true
        }, "The retired v1 API returns HTTP 403; every catalog and reader request must use v2")
        _ = try await api.posts(provider: .nhentai,
            query: QueryParser.parse("adventure -violence"), page: 1)
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.path == "/api/v2/search" &&
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "query" && $0.value == "adventure -violence" }) == true
        })
        let immersivePage = try await api.posts(provider: .nhentai,
            query: ParsedQuery(included: [], excluded: []), page: 1, immersive: true)
        XCTAssertTrue(immersivePage.items.isEmpty)
    }

    func testSuggestedThemesRespectProviderPreferencesAndRequireRealExamples() {
        let preferred = Post(key: "nhentai:456", id: "456", provider: "nhentai",
            tags: ["cosplay", "adventure"], thumbUrl: "https://t1.nhentai.net/galleries/321/cover.jpg",
            type: "manga")
        let unrelated = Post(key: "rule34:1", id: "1", provider: "rule34",
            tags: ["cosplay"], thumbUrl: "https://example.com/unrelated.jpg", type: "image")
        let suggestions = HomeThemeSuggestions.make(provider: .nhentai,
            learned: ["cosplay"], chosen: [], visual: ["adventure"],
            favorites: [preferred, unrelated], posts: [], excluded: ["adventure"])
        XCTAssertEqual(suggestions.map(\.term), ["cosplay"])
        XCTAssertEqual(suggestions.first?.imageURL, preferred.thumbUrl)
        XCTAssertTrue(HomeThemeSuggestions.make(provider: .redgifs,
            learned: ["cosplay"], chosen: [], visual: [],
            favorites: [preferred], posts: [unrelated], excluded: []).isEmpty)
    }

    func testSuggestedThemesRotateOnRefreshWithoutLosingTasteOrExamples() {
        let terms = ["cosplay", "adventure", "portrait", "flowers", "fantasy", "costume"]
        let examples = terms.enumerated().map { index, term in
            Post(key: "rule34:\(index)", id: String(index), provider: "rule34",
                 tags: [term], thumbUrl: "https://example.com/post-\(index).jpg", type: "image")
        }
        let baseline = HomeThemeSuggestions.make(provider: .rule34, learned: terms,
            chosen: [], visual: [], favorites: examples, posts: [], excluded: [], limit: 3, rotation: 0)
        let refreshed = HomeThemeSuggestions.make(provider: .rule34, learned: terms,
            chosen: [], visual: [], favorites: examples, posts: [], excluded: [], limit: 3, rotation: 1)
        XCTAssertEqual(baseline.count, 3)
        XCTAssertEqual(refreshed.count, 3)
        XCTAssertNotEqual(baseline.map(\.term), refreshed.map(\.term))
        XCTAssertTrue(refreshed.allSatisfy { !$0.imageURL.isEmpty && terms.contains($0.term) })
    }

    func testSuggestedThemeModeDiscoversObservedPopularFranchisesAndMixesTags() {
        let popular = Post(key: "rule34:pokemon", id: "1", provider: "rule34", score: 125,
            tags: ["pokemon", "portrait"], thumbUrl: "https://example.com/pokemon.jpg", type: "image")
        let niche = Post(key: "rule34:streetfighter", id: "2", provider: "rule34", score: 5,
            tags: ["street_fighter", "dynamic_pose"], thumbUrl: "https://example.com/sf.jpg", type: "image")
        let settings = (learned: ["portrait"], chosen: [String](), visual: ["dynamic_pose"])
        let series = HomeThemeSuggestions.make(provider: .rule34, learned: settings.learned,
            chosen: settings.chosen, visual: settings.visual, favorites: [], posts: [popular, niche],
            excluded: [], limit: 2, mode: .franchises)
        XCTAssertEqual(series.first?.term, "pokemon")
        XCTAssertEqual(Set(series.map(\.term)), ["pokemon", "street_fighter"])
        XCTAssertTrue(series.allSatisfy { $0.kind == "franchise" && !$0.imageURL.isEmpty })
        let mixed = HomeThemeSuggestions.make(provider: .rule34, learned: settings.learned,
            chosen: settings.chosen, visual: settings.visual, favorites: [popular], posts: [popular, niche],
            excluded: [], limit: 3, mode: .balanced)
        XCTAssertTrue(mixed.contains(where: { $0.kind == "franchise" }))
        XCTAssertTrue(mixed.contains(where: { $0.kind == "tag" }))
        let blocked = HomeThemeSuggestions.make(provider: .rule34, learned: settings.learned,
            chosen: settings.chosen, visual: settings.visual, favorites: [], posts: [popular, niche],
            excluded: ["pokemon"], limit: 2, mode: .franchises)
        XCTAssertFalse(blocked.contains(where: { $0.term == "pokemon" }))
    }

    func testFranchiseDiscoveryPrefersPublicPopularSeriesBeyondLikedFranchises() {
        let liked = Post(key: "rule34:old", id: "old", provider: "rule34", score: 900,
            tags: ["pokemon"], thumbUrl: "https://example.com/liked.jpg", type: "image")
        let popular = [
            Post(key: "rule34:pop", id: "pop", provider: "rule34", score: 300,
                 tags: ["pokemon"], thumbUrl: "https://example.com/pokemon.jpg", type: "image"),
            Post(key: "rule34:zelda", id: "zelda", provider: "rule34", score: 200,
                 tags: ["the_legend_of_zelda"], thumbUrl: "https://example.com/zelda.jpg", type: "image"),
            Post(key: "rule34:ff", id: "ff", provider: "rule34", score: 160,
                 tags: ["final_fantasy"], thumbUrl: "https://example.com/ff.jpg", type: "image")
        ]
        let result = HomeThemeSuggestions.make(provider: .rule34, learned: ["pokemon"],
            chosen: ["pokemon"], visual: [], favorites: [liked], posts: [liked],
            popular: popular, excluded: [], limit: 3, mode: .franchises)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map(\.term)), Set(["pokemon", "the_legend_of_zelda", "final_fantasy"]))
        XCTAssertNotEqual(result.first?.term, "pokemon", "A liked franchise must not monopolize discovery")
        XCTAssertTrue(result.allSatisfy { $0.imageURL.hasPrefix("https://example.com/") })
        let excluded = HomeThemeSuggestions.make(provider: .rule34, learned: [],
            chosen: [], visual: [], favorites: [liked], posts: [liked],
            popular: popular, excluded: ["pokemon"], limit: 3, mode: .franchises)
        XCTAssertFalse(excluded.contains(where: { $0.term == "pokemon" }))
    }

    func testPornhubHomeCategoryUsesActualCategoryParameter() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .pornhub,
            query: QueryParser.parse("category:hentai"), page: 1)
        XCTAssertEqual(page.items.map(\.stableID), ["pornhub:ph1"])
        XCTAssertEqual(page.items.first?.previewImageURLs, [
            "https://cdn.pornhub.com/thumb.jpg", "https://cdn.pornhub.com/thumb-small.jpg"
        ], "If the large poster is missing or blocked, Home must still try the provider's alternate thumbnail")
        let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first {
            $0.url?.path == "/webmasters/search"
        })
        let params = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(params.first(where: { $0.name == "category" })?.value, "hentai")
        XCTAssertNil(params.first(where: { $0.name == "search" }),
            "A category-only chip must not be sent as an unrelated title search")
    }

    func testPornhubWebmaster404UsesSameSitePublicCatalog() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let result = try await api.posts(provider: .pornhub,
            query: QueryParser.parse("public-html"), page: 1)
        XCTAssertEqual(result.items.map(\.stableID), ["pornhub:phpublic"])
        XCTAssertEqual(result.items.first?.caption, "Public & indexed")
        XCTAssertEqual(result.items.first?.previewUrl, "https://cdn.pornhub.com/public.jpg")
        XCTAssertEqual(result.items.first?.thumbUrl, "https://cdn.pornhub.com/public-small.jpg")
        XCTAssertEqual(result.items.first?.previewImageURLs, [
            "https://cdn.pornhub.com/public.jpg", "https://cdn.pornhub.com/public-small.jpg"
        ])
        let requests = NativeProviderProtocol.log.snapshot()
        XCTAssertTrue(requests.contains { $0.url?.path == "/webmasters/search" })
        XCTAssertTrue(requests.contains { $0.url?.path == "/video/search" })
        XCTAssertFalse(requests.contains { $0.url?.host?.contains("proxy") == true })
    }

    func testPornhubHTMLMissingPageAlsoFallsBackAndIsNeverTreatedAsJSON() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let result = try await api.posts(provider: .pornhub,
            query: QueryParser.parse("html-response"), page: 1)
        XCTAssertEqual(result.items.map(\.stableID), ["pornhub:phpublic"])
        let unavailable = Data("<html><title>Site Unavailable</title></html>".utf8)
        XCTAssertTrue(NativeProviderAPI.unavailableHTML(unavailable))
        XCTAssertFalse(NativeProviderAPI.unavailableHTML(Data(#"{"videos":[]}"#.utf8)))
    }

    func testPornhubMissingBrowseRouteRetriesUnparameterizedFirstPartyURL() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        for query in ["browse-missing-first", "browse-soft404"] {
            NativeProviderProtocol.log.reset()
            let result = try await api.posts(provider: .pornhub,
                query: QueryParser.parse(query), page: 1)
            XCTAssertEqual(result.items.map(\.stableID), ["pornhub:phpublic"])
            let listing = NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/video/search" }
            XCTAssertEqual(listing.count, 2, "Only the bad first-page URL and clean canonical search may be tried")
            XCTAssertTrue(listing[0].url?.query?.contains("page=1") == true)
            XCTAssertFalse(listing[1].url?.query?.contains("page=") == true)
            XCTAssertTrue(listing[1].value(forHTTPHeaderField: "Accept")?.contains("text/html") == true)
        }
    }

    func testPornhubMissingWebmasterRouteTriesFirstPartyAPIHost() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let result = try await api.posts(provider: .pornhub,
            query: QueryParser.parse("api-host"), page: 1)
        XCTAssertEqual(result.items.map(\.stableID), ["pornhub:ph1"])
        let requests = NativeProviderProtocol.log.snapshot()
        XCTAssertTrue(requests.contains { $0.url?.host == "api.pornhub.com" && $0.url?.path == "/webmasters/search" })
        XCTAssertFalse(requests.contains { $0.url?.path == "/video/search" },
            "A valid response from the provider's first-party API host should avoid scraping its browse HTML")
    }

    @MainActor func testHavenRecommendedKeepsSafeCatalogDiscoveryWhileWDTasteWarms() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .hhaven
        store.tasteSetup.sources[Provider.hhaven.rawValue] = TasteChoice(done: true, into: ["unmatched-interest"])
        await store.recommendations.load(RecommendationState())
        await store.refresh()
        XCTAssertEqual(store.posts.map(\.stableID), ["hhaven:12"],
            "A focused title miss must not erase an available public catalog page")
        XCTAssertNil(store.lastError)
    }

    func testUnknownSiteCanDownloadValidDirectMediaWithoutProviderRequest() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let video = Post(key: "legacy:1", id: "1", provider: "Unknown site",
                         mediaUrl: "https://files.example.invalid/clip.mp4", type: "video")
        XCTAssertNil(video.providerKey)
        let media = try await api.resolveMedia(video)
        XCTAssertEqual(media.mediaUrl, video.mediaUrl)
        XCTAssertEqual(media.type, "video")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().isEmpty)
        XCTAssertEqual(NativeProviderAPI.mediaURL("//files.example.invalid/clip.mp4")?.absoluteString,
                       "https://files.example.invalid/clip.mp4")
        let page = Post(key: "legacy:2", id: "2", provider: "Unknown site",
                        mediaUrl: "https://www.example.invalid/watch/clip", type: "video")
        do {
            _ = try await api.resolveMedia(page)
            XCTFail("A web page must not be saved as a video when its provider is unknown")
        } catch { XCTAssertTrue(error.localizedDescription.contains("recognized source")) }
    }

    func testKeywordSearchRoutesToEveryNonRule34Provider() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let phrase = "cosplay scene"
        let parsed = QueryParser.parse("\"cosplay scene\" -\"unwanted intro\"")
        for provider in [Provider.eporner, .redgifs, .hhaven, .pornhub] {
            NativeProviderProtocol.log.reset()
            _ = try await api.posts(provider: provider, query: parsed, page: 1)
            let requests = NativeProviderProtocol.log.snapshot()
            let search = requests.first { request in
                switch provider {
                case .eporner: request.url?.host == "www.eporner.com"
                case .redgifs: request.url?.host == "api.redgifs.com" && request.url?.path.contains("search") == true
                case .hhaven: request.url?.host == "api.hentaihaven.app" && request.url?.path == "/v1/search"
                case .pornhub: request.url?.host == "www.pornhub.com"
                default: false
                }
            }
            let actual = try XCTUnwrap(search, "No keyword search request for \(provider.rawValue)")
            let items = URLComponents(url: try XCTUnwrap(actual.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let parameter = provider == .eporner ? "query" : provider == .redgifs ? "search_text" : provider == .hhaven ? "q" : "search"
            XCTAssertEqual(items.first(where: { $0.name == parameter })?.value, phrase)
        }
    }
    func testKeywordProviderExclusionsMatchTitlesAndCreatorWithoutSubstringErrors() {
        var unwanted = Post(key: "eporner:1", id: "1", provider: "Eporner",
                            tags: ["other"], type: "video")
        unwanted.caption = "Evening portrait outdoors"
        var creatorHit = Post(key: "redgifs:2", id: "2", provider: "RedGIFs",
                              tags: ["scene"], type: "video")
        creatorHit.creator = "Blocked Studio"
        var allowed = Post(key: "hanime:3", id: "3", provider: "Hanime",
                           tags: ["battle", "fantasy"], type: "video")
        allowed.caption = "A battle in the city"
        let result = NativeProviderAPI.page([unwanted, creatorHit, allowed],
            hasMore: false, query: ParsedQuery(included: ["portrait"],
                excluded: ["outdoors", "blocked studio", "bat"]), immersive: false)
        XCTAssertEqual(result.items.map(\.stableID), [allowed.stableID])
        XCTAssertFalse(NativeProviderAPI.containsKeyword("bat", in: allowed),
            "A negative keyword must not match inside 'battle'")
    }

    func testKeywordSearchCanReuseOnlyMatchingVisiblePostsWhenProviderIndexIsEmpty() {
        var matching = Post(key: "eporner:1", id: "1", provider: "Eporner",
                            tags: ["red_hair", "cosplay"], type: "video")
        matching.caption = "Character cosplay"
        let wrong = Post(key: "eporner:2", id: "2", provider: "Eporner",
                         tags: ["blue_hair", "cosplay"], type: "video")
        let otherSource = Post(key: "redgifs:3", id: "3", provider: "RedGIFs",
                               tags: ["red_hair", "cosplay"], type: "video")
        let result = NativeProviderAPI.matchingCachedPosts([wrong, otherSource, matching],
            provider: .eporner,
            query: ParsedQuery(included: ["red hair"], excluded: ["blue hair"]),
            immersive: false)
        XCTAssertEqual(result.map(\.stableID), [matching.stableID])
    }

    func testEpornerEmptyHDOnlyCatalogRetriesWithInclusiveQuality() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let result = try await api.posts(provider: .eporner,
            query: ParsedQuery(included: [], excluded: []), page: 1, sort: "recent")
        XCTAssertEqual(result.items.map(\.stableID), ["eporner:ep1"])
        let requests = NativeProviderProtocol.log.snapshot()
            .filter { $0.url?.host == "www.eporner.com" && $0.url?.path.hasPrefix("/api/v2/video/search") == true }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "lq" })?.value }, ["0", "1"])
    }

    @MainActor func testEpornerRecommendedRecoversWhenCatalogRepeatsOfferedPosts() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .eporner
        await store.recommendations.load(RecommendationState())
        for _ in 0..<4 {
            await store.refresh()
            XCTAssertEqual(store.posts.map(\.stableID), ["eporner:ep1"],
                "Repeated public pages must not permanently blank Home when the available video was offered but never watched")
            XCTAssertNil(store.lastError)
        }
    }


    @MainActor func testUntouchedRecommendedFetchesTwoDifferentBroadPages() async throws {
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .eporner
        await store.recommendations.load(RecommendationState())
        NativeProviderProtocol.log.reset()
        await store.refresh()
        let requests = NativeProviderProtocol.log.snapshot()
            .filter { $0.url?.path.hasPrefix("/api/v2/video/search") == true }
        let pages = requests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value
        }
        XCTAssertGreaterThanOrEqual(pages.count, 2)
        XCTAssertGreaterThanOrEqual(Set(pages).count, 2,
            "An empty taste profile must never download identical broad pages twice")
    }

    @MainActor func testRecommendedUsesDifferentCandidateQueriesBeforeRanking() async throws {
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .eporner
        // Supply distinct intentional interests without updating on-disk user
        // preferences or depending on external network responses.
        await store.recommendations.record(.like,
            post: Post(key: "eporner:liked-a", id: "liked-a", provider: "Eporner",
                       tags: ["engineering", "aerodynamics"]))
        NativeProviderProtocol.log.reset()
        await store.refresh()
        let searches = NativeProviderProtocol.log.snapshot()
            .filter { $0.url?.path.hasPrefix("/api/v2/video/search") == true }
            .compactMap { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "query" })?.value
            }
        XCTAssertGreaterThanOrEqual(searches.count, 2,
            "Recommended must search at least two distinct interest/discovery pools")
        XCTAssertGreaterThan(Set(searches).count, 1,
            "Rearranging duplicate pages cannot improve candidate quality")
    }

    func testPornhubFeed404TriesCanonicalRouteOnce() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let page: PostPage
        do {
            page = try await api.posts(provider: .pornhub, query: QueryParser.parse("route-fixture"), page: 1)
        } catch {
            XCTFail("Expected fallback to the canonical public route; requests: \(NativeProviderProtocol.log.snapshot().compactMap(\.url)) error: \(error)")
            return
        }
        XCTAssertEqual(page.items.count, 1)
        let rawPaths = NativeProviderProtocol.log.snapshot().compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
        XCTAssertEqual(rawPaths, ["/webmasters/search", "/webmasters/search/"],
                       "Fallback request should retain its trailing slash")
    }
    func testPornhubEmptySearchIsOmittedAndUnavailableRouteExplained() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        _ = try await api.posts(provider: .pornhub,
            query: ParsedQuery(included: [], excluded: []), page: 1)
        let home = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first?.url)
        let terms = URLComponents(url: home, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(terms.contains(where: { $0.name == "search" }))

        NativeProviderProtocol.log.reset()
        let fallback = try await api.posts(provider: .pornhub,
            query: QueryParser.parse("unavailable-route"), page: 1)
        XCTAssertEqual(fallback.items.map(\.stableID), ["pornhub:phpublic"])
        let paths = NativeProviderProtocol.log.snapshot().compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/webmasters/search", "/webmasters/search", "/webmasters/search", "/video/search"],
            "All first-party webmaster routes may fail, in which case the same-site catalog is used")
        XCTAssertEqual(NativeProviderProtocol.log.snapshot()[2].url?.host, "api.pornhub.com")
    }
    func testPornhubUsesCanonicalPageAndSurvivesRemovedMP4Definition() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "ph:wrong-id", id: "wrong-id", provider: "Pornhub", pageUrl: "https://www.pornhub.com/view_video.php?viewkey=fallback", type: "video")
        let media = try await api.resolveMedia(post)
        XCTAssertEqual(media.mediaUrl, "https://cdn.pornhub.com/valid.m3u8")
        XCTAssertEqual(media.type, "hls")
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/view_video.php" }.count, 1)
    }
    func testRule34BatchIsSmallAndStillIncludesNextPageMetadata() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        for immersive in [false, true] {
            let page = try await api.posts(provider: .rule34, query: QueryParser.parse(""), page: 2, immersive: immersive)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.previewUrl, "https://media.rule34.xxx/clip.jpg")
        }
        for request in NativeProviderProtocol.log.snapshot() {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains { $0.name == "limit" && $0.value == "40" })
            XCTAssertTrue(query.contains { $0.name == "pid" && $0.value == "1" })
        }
    }
    func testRule34ExcessExclusionsStayLocalRatherThanBreakingTheProviderQuery() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let bans = ["filler1", "filler2", "filler3", "filler4", "filler5", "car"]
        let page = try await api.posts(provider: .rule34,
            query: ParsedQuery(included: [], excluded: bans), page: 1)
        XCTAssertTrue(page.items.isEmpty, "Locally excluded tags must still be enforced even when omitted from the API URL")
        let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first)
        let remote = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "tags" }?.value ?? ""
        XCTAssertEqual(remote.split(separator: " ").count, 5)
        XCTAssertFalse(remote.contains("-car"))
    }
    func testRule34DAPIEmptyAndRejectedResponsesAreNotGenericInvalidServerErrors() throws {
        XCTAssertTrue(try NativeProviderAPI.rule34Payload(Data("{}".utf8)).posts.isEmpty)
        XCTAssertTrue(try NativeProviderAPI.rule34Payload(Data(#"{"count":0}"#.utf8)).posts.isEmpty)
        let single = Data(#"{"count":1,"post":{"id":17}}"#.utf8)
        XCTAssertEqual(try NativeProviderAPI.rule34Payload(single).posts.count, 1)
        let rejected = Data(#"{"success":false,"message":"search down"}"#.utf8)
        XCTAssertThrowsError(try NativeProviderAPI.rule34Payload(rejected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("search down"))
        }
    }
    private func rateSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RateLimitProtocol.self]
        return URLSession(configuration: config)
    }
    func test429ShortCooldownRecoversAndRetriesAreBounded() async throws {
        let session = rateSession(); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://\(UUID().uuidString).invalid/recover")!
        _ = try await NativeProviderAPI.data(session: session, url: url, provider: .eporner)
        XCTAssertEqual(RateLimitProtocol.log.snapshot().filter { $0.url == url }.count, 2)
        let limited = URL(string: "https://\(UUID().uuidString).invalid/always")!
        do { _ = try await NativeProviderAPI.data(session: session, url: limited, provider: .eporner); XCTFail("Expected rate limit") }
        catch { XCTAssertNotNil((error as? APIError)?.retryAfter) }
        XCTAssertEqual(RateLimitProtocol.log.snapshot().filter { $0.url == limited }.count, 3)
    }
    func test429LongCooldownPreventsRepeatedNetworkRequests() async {
        let session = rateSession(); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://\(UUID().uuidString).invalid/long")!
        for _ in 0..<2 {
            do { _ = try await NativeProviderAPI.data(session: session, url: url, provider: .eporner); XCTFail("Expected cooldown") }
            catch { XCTAssertGreaterThan((error as? APIError)?.retryAfter?.timeIntervalSinceNow ?? 0, 55) }
        }
        XCTAssertEqual(RateLimitProtocol.log.snapshot().filter { $0.url == url }.count, 1)
    }
    func test429RetryWaitCancelsWithoutAnotherRequest() async {
        let session = rateSession(); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://\(UUID().uuidString).invalid/cancel")!
        let work = Task { try await NativeProviderAPI.data(session: session, url: url, provider: .eporner) }
        for _ in 0..<100 {
            if RateLimitProtocol.log.snapshot().contains(where: { $0.url == url }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(RateLimitProtocol.log.snapshot().filter { $0.url == url }.count, 1)
    }
    func testRetryAfterUnderstandsHTTPDateAndInvalidHeaderFallback() {
        let now = Date(timeIntervalSince1970: 0)
        let url = URL(string: "https://example.invalid")!
        let dated = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:01:00 GMT"])!
        XCTAssertEqual(NativeProviderAPI.retryDeadline(dated, now: now).timeIntervalSince(now), 60, accuracy: 0.1)
        let invalid = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "NaN"])!
        XCTAssertEqual(NativeProviderAPI.retryDeadline(invalid, now: now, attempt: 1).timeIntervalSince(now), 2)
    }
    @MainActor func testReselectingFeedRefreshesAndPreservesSearch() async {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let store = AppStore(api: api)
        store.selectedProvider = .eporner
        store.feedSort = "recent"; store.queryText = "old search"
        await store.selectFeedTab(0)
        let first = store.feedRevision
        XCTAssertEqual(store.feedSort, "recent"); XCTAssertEqual(store.queryText, "old search")
        await store.selectFeedTab(0)
        XCTAssertNotEqual(first, store.feedRevision)
        XCTAssertEqual(store.feedSort, "recent"); XCTAssertEqual(store.queryText, "old search")
        await store.selectFeedTab(1)
        XCTAssertEqual(store.activeTab, 1); XCTAssertTrue(store.feedMediaOnly)
        let immersiveRevision = store.feedRevision
        await store.selectFeedTab(1)
        XCTAssertNotEqual(immersiveRevision, store.feedRevision)
    }

    func testExplicitPreferencesPersonalizeColdStartWithoutML() async {
        let values = TasteChoice.normalized([" Engineering ", "engineering", "ground   effect", ""])
        XCTAssertEqual(values, ["engineering", "ground effect"])
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let taste = TasteChoice(done: true, into: values, notInto: ["baking"])
        let request = await engine.candidateRequest(context: "eporner|all|", provider: .eporner, taste: taste, excluded: [])
        XCTAssertTrue(request.focused); XCTAssertEqual(request.query.included.first, "engineering")
        let good = Post(key: "good", id: "good", provider: "Eporner", tags: ["engineering"])
        let bad = Post(key: "bad", id: "bad", provider: "Eporner", tags: ["baking"])
        let ranked = await engine.rank([bad, good], taste: taste, recent: [])
        XCTAssertEqual(ranked.map(\.stableID), ["good"])
    }

    func testDownloadSizeMeasuresActualFilesAndHLSPackages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("part-a"), b = folder.appendingPathComponent("part-b")
        try Data(repeating: 1, count: 4096).write(to: a)
        try Data(repeating: 2, count: 8192).write(to: b)
        let fileSize = await DownloadSizeReader.shared.bytes(at: a)
        let packageSize = await DownloadSizeReader.shared.bytes(at: folder)
        XCTAssertEqual(fileSize, 4096); XCTAssertEqual(packageSize, 12288)
        let missing = await DownloadSizeReader.shared.bytes(at: folder.appendingPathComponent("missing"))
        XCTAssertNil(missing)
    }

    private func client() -> (QuicktickAPIClient, URLSession) {
        NativeProviderProtocol.log.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NativeProviderProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = ProviderCredentials(rule34User: "synthetic-user", rule34Key: "synthetic-key", pornhubSession: QuicktickSyncCrypto.base64URL(Data("session=synthetic-cookie".utf8)))
        return (QuicktickAPIClient(baseURL: nil, session: session, credentials: credentials), session)
    }
    func testAllFiveFeedsWorkWithoutQuicktickOriginAndScopeCredentials() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        for provider in Provider.allCases {
            let page = try await api.posts(provider: provider, query: QueryParser.parse(""), page: 1)
            XCTAssertEqual(page.items.count, provider == .kemono || provider == .coomer ? 3 : 1, provider.rawValue)
            XCTAssertEqual(page.items.first?.providerKey, provider)
        }
        let requests = NativeProviderProtocol.log.snapshot()
        XCTAssertFalse(requests.contains { $0.url?.host == NativeProviderAPI.quicktickHost })
        for request in requests {
            let host = request.url?.host
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.contains { $0.name == "api_key" }, host == "api.rule34.xxx")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-r34-key"))
            if request.value(forHTTPHeaderField: "Cookie") != nil { XCTAssertEqual(host, "www.pornhub.com") }
            if request.value(forHTTPHeaderField: "Authorization") != nil { XCTAssertEqual(host, "api.redgifs.com") }
        }
    }
    func testDirectResolversPreferHighQualityAndCommentsDecodeXML() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        for (provider, expected) in [(Provider.eporner, "https://cdn.eporner.com/full.mp4"), (.hanime, "https://cdn.hanime.tv/full.m3u8"), (.pornhub, "https://cdn.pornhub.com/full.mp4")] {
            let post = Post(key: "fixture", id: "sample", provider: provider.displayName, type: "video")
            let media = try await api.resolveMedia(post); XCTAssertEqual(media.mediaUrl, expected)
        }
        let comments = try await api.comments(Post(key: "r34", id: "1", provider: "Rule34"))
        XCTAssertEqual(comments.items.first?.body, "A & B")
        let suggestions = try await api.suggestions(provider: .rule34, query: "engin")
        XCTAssertEqual(suggestions.first?.value, "engineering")
    }
    func testConcurrentRedgifsRequestsShareTemporaryAuthentication() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        async let first = api.posts(provider: .redgifs, query: QueryParser.parse(""), page: 1)
        async let second = api.posts(provider: .redgifs, query: QueryParser.parse(""), page: 2)
        _ = try await (first, second)
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/v2/auth/temporary" }.count, 1)
    }
    func testWebsiteSyncAndRecommendationUploadsAreBlockedByDefault() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        do { _ = try await api.sync(action: "get", recordID: "fixture", verifier: "fixture"); XCTFail("Sync must require opt-in") } catch {}
        do { _ = try await api.recommend(["action": "feedback"]); XCTFail("Remote feedback must stay disabled") } catch {}
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().isEmpty)
        XCTAssertNil(NativeProviderAPI.mediaURL("https://quick-tick-webb.vercel.app/api/redgifs-media?id=1"))
        XCTAssertNil(NativeProviderAPI.mediaURL("/api/redgifs-media?id=1", provider: .redgifs))
    }
    @MainActor func testLegacyInstallDefaultsToSyncOffAndEngagementDoesNotUpload() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalStateStore(directory: directory)
        try storage.save(LocalAppState())
        let store = AppStore(api: api, localStorage: storage)
        await store.bootstrap()
        XCTAssertFalse(store.cloudSyncEnabled)
        store.toggleFavorite(Post(key: "privacy", id: "privacy", provider: "Eporner"))
        await store.syncWhenActive()
        do { try await store.syncNow(); XCTFail("Explicit Sync now also requires opt-in") } catch {}
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.host == NativeProviderAPI.quicktickHost || $0.url?.path == "/api/sync" || $0.url?.path == "/api/recommend" })
        XCTAssertEqual(try storage.load().cloudSyncEnabled, false)
    }
    func testInterestAcquisitionExploresAndPersistsIndependentCursors() async {
        let engine = RecommendationEngine()
        await engine.record(.like, post: Post(key: "liked", id: "liked", provider: "Rule34", tags: ["engineering"]))
        var requests: [RecommendationEngine.CandidateRequest] = []
        for _ in 0..<4 {
            let request = await engine.candidateRequest(context: "rule34|all|", provider: .rule34, taste: TasteChoice(), excluded: ["blocked"])
            await engine.advanceCandidatePage(context: request.context, nextPage: request.page + 1)
            requests.append(request)
        }
        XCTAssertEqual(requests.map(\.focused), [true, true, true, false])
        XCTAssertEqual(requests.map(\.page), [1, 2, 3, 1])
        XCTAssertTrue(requests[0].query.included.contains("engineering"))
        XCTAssertEqual(requests[3].query.excluded, ["blocked"])
        let restored = RecommendationEngine(); await restored.load(await engine.snapshot())
        let next = await restored.candidateRequest(context: "rule34|all|", provider: .rule34, taste: TasteChoice(), excluded: [])
        XCTAssertEqual(next.page, 4)
    }
    func testRankDeduplicatesIDsWithoutDiscardingOtherCandidates() async {
        let engine = RecommendationEngine()
        let a = Post(key: "a", id: "a", provider: "Eporner", tags: ["engineering"])
        let b = Post(key: "b", id: "b", provider: "Eporner", tags: ["cooking"])
        let ranked = await engine.rank([a, a, b], taste: TasteChoice(), recent: [])
        XCTAssertEqual(Set(ranked.map(\.stableID)), ["a", "b"])
        XCTAssertEqual(ranked.count, 2)
    }
}
