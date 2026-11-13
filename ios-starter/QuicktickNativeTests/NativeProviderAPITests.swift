import XCTest
@testable import QuicktickNative

private final class NativeRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var hanimeCatalogBlocked = false
    private var hanimeSearchBlocked = false
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    func reset() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
    func blockHanimeCatalog(_ blocked: Bool) {
        lock.lock(); defer { lock.unlock() }; hanimeCatalogBlocked = blocked
    }
    func isHanimeCatalogBlocked() -> Bool {
        lock.lock(); defer { lock.unlock() }; return hanimeCatalogBlocked
    }
    func blockHanimeSearch(_ blocked: Bool) {
        lock.lock(); defer { lock.unlock() }; hanimeSearchBlocked = blocked
    }
    func isHanimeSearchBlocked() -> Bool {
        lock.lock(); defer { lock.unlock() }; return hanimeSearchBlocked
    }
}

private final class NativeProviderProtocol: URLProtocol, @unchecked Sendable {
    static let log = NativeRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    // URLSession commonly transfers POST data to httpBodyStream before
    // URLProtocol sees the request. The Hanime fixture must decode that stream,
    // otherwise every handshake looks like the default successful slug.
    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 128_000 { return nil }
        }
        return data
    }

    override func startLoading() {
        Self.log.append(request)
        let url = request.url!, host = url.host ?? ""
        // Foundation URL.path drops a trailing slash; the canonical-route
        // fallback fixture must distinguish /search from /search/.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let payload: String
        var responseHeaders: [String: String] = [:]
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
        else if host == "api.redgifs.com", path == "/v2/niches" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let number = query.first(where: { $0.name == "page" })?.value ?? "1"
            payload = number == "3"
                ? #"{"pages":3,"niches":[{"id":"no-cover","name":"No Cover","gifs":18}]}"#
                : (number == "2"
                    ? #"{"pages":2,"niches":[{"id":"gaming","name":"Gaming","gifs":54,"thumbnail":"https://media.redgifs.com/gaming.jpg"}]}"#
                    : #"{"pages":2,"niches":[{"id":"cosplay","name":"Cosplay","gifs":200,"thumbnail":"https://media.redgifs.com/niche.jpg"}]}"#)
        }
        else if host == "api.redgifs.com", path == "/v2/niches/no-cover/gifs" {
            payload = #"{"pages":1,"gifs":[]}"#
        }
        else if host == "api.redgifs.com", path == "/v2/niches/gaming/gifs" {
            payload = #"{"pages":1,"gifs":[{"id":"gamingclip","type":"g","tags":["gaming"],"urls":{"hd":"https://media.redgifs.com/gamingclip.mp4","poster":"https://media.redgifs.com/gamingclip.jpg"}}]}"#
        }
        else if host == "api.redgifs.com", path == "/v2/niches/cosplay/gifs" {
            payload = #"{"pages":2,"gifs":[{"id":"nicheclip","type":"g","title":"Cosplay clip title","tags":["cosplay"],"niches":["cosplay"],"urls":{"hd":"https://media.redgifs.com/nicheclip.mp4","poster":"https://media.redgifs.com/nicheclip.jpg"}},{"id":"wrongclip","type":"g","niches":["gaming"],"urls":{"hd":"https://media.redgifs.com/wrongclip.mp4","poster":"https://media.redgifs.com/wrongclip.jpg"}}]}"#
        }
        else if host == "api.redgifs.com", path == "/v2/niches/empty-top/gifs" {
            let order = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "order" })?.value
            payload = order == "top"
                ? #"{"pages":1,"gifs":[{"id":"still","type":"i","niches":["empty-top"],"urls":{"poster":"https://media.redgifs.com/still.jpg"}}]}"#
                : #"{"pages":1,"gifs":[{"id":"usable","type":"g","niches":["empty-top"],"urls":{"hd":"https://media.redgifs.com/usable.mp4","poster":"https://media.redgifs.com/usable.jpg"}}]}"#
        }
        else if host == "api.redgifs.com" { payload = #"{"pages":3,"gifs":[{"id":"clip","type":"g","width":1920,"height":1080,"tags":["engineering"],"urls":{"hd":"https://media.redgifs.com/clip.mp4","poster":"https://media.redgifs.com/clip.jpg"}}]}"# }
        else if host == "www.xvideos.com", path == "/" || path.hasPrefix("/best/") || path.hasPrefix("/new/") {
            let search = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "k" })?.value ?? ""
            if search == "empty" {
                payload = #"<html><div>No matches</div></html>"#
            } else {
                payload = #"""
                <html><div class="thumb-block">
                    <div class="thumb"><a href="/video.abc123/first-story">
                    <img data-src="https://img-cf.xvideos-cdn.com/videos/first.jpg"></a></div>
                    <p><a href="/video.abc123/first-story" title="First story">First story</a></p>
                </div><div class="thumb-block"><div class="thumb">
                    <a href="/video.def456/second-story"><img data-src="https://img-cf.xvideos-cdn.com/videos/second.jpg"></a>
                </div><p><a href="/video.def456/second-story" title="Second story">Second story</a></p></div></html>
                """#
            }
        }
        else if host == "www.xvideos.com", path.hasPrefix("/video.") {
            payload = #"""
            <html><script>
            html5player.setVideoUrlHigh('https://cdn77.xvideos-cdn.com/videos/full-hd.mp4?token=valid');
            html5player.setVideoUrlLow('https://cdn77.xvideos-cdn.com/videos/full-sd.mp4');
            html5player.setVideoHLS('https://cdn77.xvideos-cdn.com/videos/full-hls.m3u8');
            </script></html>
            """#
        }
        else if host == "www.erome.com", ["/explore", "/explore/new", "/search"].contains(path) {
            let search = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "q" })?.value
            payload = search == "summary-video"
                ? #"<html><div id="albums"><div class="album"><a class="album-title" href="/a/ABC123">City portrait</a><img class="album-thumbnail" src="https://s7.erome.com/123/ABC123/poster.jpg"><span class="album-videos">1</span></div></div></html>"#
                : search == "mixed-albums"
                ? #"<html><div id="albums"><div class="album"><a class="album-title" href="/a/IMGONLY">Photo set</a><img class="album-thumbnail" src="https://s7.erome.com/123/ABC123/poster.jpg"></div><a class="album-link" href="/a/ABC123">Video not in summaries</a></div></html>"#
                : #"<html><div id="albums"><a class="album-link" href="/a/ABC123">Album</a><a href="https://evil.invalid/a/FAKE" class="album-link">Do not read</a><a class="album-link" href="/a/ABC123">Duplicate</a></div></html>"#
        }
        else if host == "www.erome.com", path == "/a/ABC123" {
            payload = #"<html><head><title>City portrait - Erome</title><meta property="og:image" content="https://s7.erome.com/123/ABC123/poster.jpg"></head><body><video data-setup='{&quot;poster&quot;:&quot;https://s7.erome.com/123/ABC123/poster.jpg&quot;}'><source src="https://v12.erome.com/123/ABC123/clip_720p.mp4" type="video/mp4"></video><div class="img"><img data-src="https://s7.erome.com/123/ABC123/photo.jpg"></div><div class="img"><img data-src="https://evil.invalid/malicious.jpg"></div></body></html>"#
        }
        else if host == "www.erome.com", path == "/a/IMGONLY" {
            payload = #"<html><title>Photo set - Erome</title><div class="img"><img data-src="https://s7.erome.com/123/ABC123/photo.jpg"></div></html>"#
        }
        else if host == "auth.hanime.tv", path == "/api/v11/search_hvs" {
            if Self.log.isHanimeCatalogBlocked() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403,
                    httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = #"{"hits":[{"slug":"sample","name":"Fantasy at night","poster_url":"https://cdn.hanime.tv/thumb.jpg","hentai_tags":[{"text":"fantasy"},{"text":"dark skin"}],"views":42,"released_at_unix":1760000000}]}"#
        }
        else if host == "hanime.tv", path == "/" {
            payload = #"<html><a href="/videos/hentai/public-fantasy"><img data-src="https://cdn.hanime.tv/public.webp" alt="Public fantasy"></a><a href="https://evil.invalid/videos/hentai/fake"><img src="https://evil.invalid/fake.webp"></a></html>"#
        }
        else if host == "hanime.tv", path == "/videos/hentai/web-only" {
            payload = #"<html><head><meta content="https://hanime-cdn.com/images/covers/web-only.webp?size=large&amp;v=2" property="og:image"></head></html>"#
        }
        else if host == "auth.hanime.tv", path == "/api/v11/handshake" {
            let object = (Self.requestBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
            let token = object?["token"] as? String ?? ""
            let clear = try? HanimeHandshakeCodec.open(token)
            let input = clear.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let slug = input?["slug"] as? String ?? ""
            if slug == "missing-404" || slug == "legacy-working" {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404,
                    httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            let result: String
            if slug == "no-stream" {
                result = #"{"sources":[{"kind":"promotion","src":"/hls/ad/placeholder"}]}"#
            } else if slug == "alternate-stream" {
                result = #"{"sources":[{"kind":"normal","src":"/hls/broken","height":1080},{"kind":"normal","src":"/hls/alternate","height":720}]}"#
            } else if slug == "plain-json" {
                result = #"{"sources":[{"kind":"normal","src":"https://cdn.hanime.tv/hls/signed-opaque?token=abc","height":720}]}"#
            } else if slug == "download-file" {
                result = #"{"sources":[{"kind":"normal","src":"https://cdn.hanime.tv/videos/high-quality.m3u8","height":1080},{"kind":"normal","src":"https://cdn.hanime.tv/videos/download-full.mp4","height":720}]}"#
            } else {
                result = #"{"sources":[{"kind":"promotion","src":"/hls/ad/placeholder"},{"kind":"normal","src":"/hls/42/fixture-token","height":1080,"type":"application/vnd.apple.mpegurl"}]}"#
            }
            if slug == "plain-json" { payload = result }
            else {
                responseHeaders["x-token"] = try? HanimeHandshakeCodec.seal(Data(result.utf8))
                payload = #"{"ok":true}"#
            }
        }
        else if host == "hanime.tv", path == "/hls/broken" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403,
                httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        else if host == "hanime.tv", path == "/hls/alternate" {
            payload = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n"
        }
        else if host == "hanime.tv", path == "/hls/42/fixture-token" {
            payload = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n"
        }
        else if host == "hanime.tv", path == "/api/v8/video" {
            // Test both a removed endpoint and an empty legacy manifest.
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id" })?.value
            if id == "missing-404" || id == "web-only" {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404,
                    httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            if id == "legacy-working" {
                payload = #"{"videos_manifest":{"servers":[{"streams":[{"height":1080,"url":"https://cdn.hanime.tv/videos/legacy-full.m3u8"},{"height":720,"url":"https://cdn.hanime.tv/videos/legacy-small.m3u8"},{"height":9999,"url":"https://evil.invalid/unsafe.m3u8"}]}]}}"#
            } else {
                payload = #"{"hentai_video":{"poster_url":"https://cdn.hanime.tv/official-poster.webp","cover_url":"https://cdn.hanime.tv/official-cover.jpg"},"videos_manifest":{"servers":[{"streams":[]}]}}"#
            }
        }
        else if host == "api.rule34.xxx", path == "/autocomplete.php" { payload = #"[{"value":"engineering","label":"engineering (12)","count":12}]"# }
        else if host == "api.rule34.xxx" {
            let comments = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "s" && $0.value == "comment" } == true
            payload = comments ? #"<comments><comment id="7" creator="Fixture" body="A &amp; B" /></comments>"# : #"[{"id":1,"score":9,"tags":"engineering car","width":1920,"height":1080,"file_url":"https://media.rule34.xxx/clip.mp4","preview_url":"https://media.rule34.xxx/clip.jpg"}]"#
        } else if host == "www.eporner.com", path.contains("/embed/") { payload = #"<html><script>var hash='00112233445566778899aabbccddeeff';</script></html>"# }
        else if host == "www.eporner.com", path.contains("/xhr/video/") { payload = #"{"sources":{"mp4":{"360p":{"src":"https://cdn.eporner.com/small.mp4"},"1080p":{"src":"https://cdn.eporner.com/full.mp4"}}}}"# }
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
        else if host == "search.htv-services.com" {
            if Self.log.isHanimeCatalogBlocked() || Self.log.isHanimeSearchBlocked() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403,
                    httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            let body = Self.requestBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let secondPage = (body?["page"] as? Int) == 1
            payload = secondPage
                ? #"{"nbPages":3,"hits":"[{\"slug\":\"second-page\",\"name\":\"Another fantasy\",\"poster_url\":\"https://cdn.hanime.tv/second.webp\"}]"}"#
                : #"{"nbPages":3,"hits":"[{\"slug\":\"sample\",\"name\":\"Fantasy at night\",\"poster_url\":\"https://cdn.hanime.tv/thumb.jpg\",\"hentai_tags\":[{\"text\":\"fantasy\"},{\"text\":\"dark skin\"}],\"views\":42}]"}"#
        }
        else if host == "members.hanime.tv", path == "/rapi/v7/hentai_videos" {
            if Self.log.isHanimeCatalogBlocked() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403,
                    httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = #"{"hentai_videos":[{"slug":"member-sample","name":"Member catalog title","poster_url":"https://cdn.hanime.tv/member.webp"}]}"#
        }
        else if path == "/api/v8/video" { payload = #"{"videos_manifest":{"servers":[{"streams":[{"height":1080,"url":"https://cdn.hanime.tv/full.m3u8"}]}]}}"# }
        else if path == "/webmasters/categories" {
            payload = #"{"categories":[{"category":"Cosplay"},{"category":"Vintage"},{"category":"Anal"}]}"#
        }
        else if path == "/webmasters/search" || path == "/webmasters/search/" {
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let search = params
                .first(where: { $0.name == "search" })?.value
            let category = params.first(where: { $0.name == "category" })?.value
            if search == "unavailable-route" || search == "public-html" ||
               search == "browse-missing-first" || search == "browse-soft404" ||
               search == "browse-filter-404" ||
               (search == "api-host" && host != "api.pornhub.com") ||
               (path == "/webmasters/search" && search == "route-fixture") {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = category == "hentai" && search == nil
                ? #"{"videos":[{"video_id":"hentai-cover","categories":[{"category":"Hentai"}],"hd_thumb":"https://cdn.pornhub.com/verified-hentai.jpg"}]}"#
                : search == "filtered-terms"
                ? #"{"videos":[{"video_id":"allowed","title":"First","duration":"15:00","production":"homemade","categories":[{"category":"Cosplay"}]},{"video_id":"blocked","title":"Second","duration":"04:00","production":"professional","categories":[{"category":"Vintage"}]}]}"#
                : search == "html-response"
                ? "<html><head><title>404 Not Found</title></head><body>The requested URL was not found on this server.</body></html>"
                : #"{"videos":[{"video_id":"ph1","title":"Fixture","tags":[{"tag_name":"sample"}],"default_thumb":"https://cdn.pornhub.com/thumb.jpg","thumbs":[{"size":"small","src":"https://cdn.pornhub.com/thumb-small.jpg"}]}]}"#
        }
        else if host == "www.pornhub.com", path == "/video/search" {
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let search = params.first(where: { $0.name == "search" })?.value
            if search == "browse-filter-404", params.contains(where: { $0.name == "min_duration" }) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            if search == "browse-missing-first", params.contains(where: { $0.name == "page" }) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            payload = search == "browse-soft404" && params.contains(where: { $0.name == "page" })
                ? "<html><head><title>404 Not Found</title></head><body>The requested URL was not found on this server.</body></html>"
                : #"<html><ul><li class="videoblock videoBox" data-video-vkey="phpublic"><a href="/view_video.php?viewkey=phpublic" title="Public &amp; indexed"><img data-thumb_url="https://cdn.pornhub.com/public.jpg" src="https://cdn.pornhub.com/public-small.jpg" alt="Public video"></a></li></ul></html>"#
        }
        else if host == "www.pornhub.com", path == "/categories/cosplay" {
            payload = #"<html><ul><li class="videoblock videoBox" data-video-vkey="phcos"><a href="/view_video.php?viewkey=phcos" title="Costume category entry"><img data-thumb_url="https://cdn.pornhub.com/category-cosplay.jpg"></a></li></ul></html>"#
        }
        else if host == "www.pornhub.com", ["/categories/hentai", "/categories/vintage"].contains(path) {
            payload = "<html><title>404 Not Found</title><body>The requested URL was not found on this server.</body></html>"
        }
        else if path == "/view_video.php" {
            let unavailable = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "viewkey" && $0.value == "watch-missing" } == true
            if unavailable {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self); return
            }
            let fallback = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "viewkey" && $0.value == "fallback" } == true
            let opaque = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "viewkey" && $0.value == "opaque" } == true
            let multi = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "viewkey" && $0.value == "multi" } == true
            let downloadPriority = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "viewkey" && $0.value == "download-priority" } == true
            payload = fallback ? #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://www.pornhub.com/removed-definition"},{"format":"hls","quality":"720","videoUrl":"https://cdn.pornhub.com/valid.m3u8"}]};</script>"#
                : opaque ? #"<script>var player={"mediaDefinitions":[{"format":"hls","quality":"1080","videoUrl":"https://vid-cdn.phncdn.com/signed/abc123?expires=123&token=xyz"}]};</script>"#
                : multi ? #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://cdn.pornhub.com/first-1080.mp4"},{"format":"hls","quality":"720","videoUrl":"https://cdn.pornhub.com/second-720.m3u8"}]};</script>"#
                : downloadPriority ? #"<script>var player={"mediaDefinitions":[{"format":"hls","quality":"1080","videoUrl":"https://cdn.pornhub.com/priority-1080.m3u8"},{"format":"mp4","quality":"720","videoUrl":"https://cdn.pornhub.com/offline-720.mp4"}]};</script>"#
                : #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://cdn.pornhub.com/full.mp4"}]};</script>"#
        }
        else if path == "/embed/multi" {
            payload = #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://cdn.pornhub.com/first-1080.mp4"},{"format":"mp4","quality":"480","videoUrl":"https://cdn.pornhub.com/third-480.mp4"}]};</script>"#
        }
        else if path == "/embed/watch-missing" {
            payload = #"<script>var player={"mediaDefinitions":[{"format":"hls","quality":"720","videoUrl":"https://cdn.pornhub.com/embed-valid.m3u8"}]};</script>"#
        }
        else if path == "/removed-definition" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        else if path == "/api/sync" { payload = #"{"exists":false,"ok":true}"# }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: responseHeaders)!
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
    func testFreeEromeCatalogSearchMediaAndRetry() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        XCTAssertEqual(Provider.identify("www.erome.com"), .erome)
        XCTAssertEqual(Provider.identifyPage("https://www.erome.com/a/ABC123"), .erome)
        XCTAssertNil(Provider.identifyPage("https://www.erome.com.evil.invalid/a/ABC123"))
        let page = try await api.posts(provider: .erome,
            query: ParsedQuery(included: [], excluded: []), page: 1, sort: "recent")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(Set(page.items.map(\.type)), ["video", "image"])
        XCTAssertEqual(page.items[0].stableID, "erome:ABC123:clip_720p.mp4")
        XCTAssertEqual(page.items[0].cardPreviewURL, "https://s7.erome.com/123/ABC123/poster.jpg")
        XCTAssertEqual(page.items[0].caption, "City portrait")
        XCTAssertEqual(page.items[1].mediaUrl, "https://s7.erome.com/123/ABC123/photo.jpg")
        XCTAssertEqual(VisualDomain.classify(page.items[0]), .realLife)
        XCTAssertEqual(page.items[0].providerKey, .erome)
        let resolved = try await api.resolveMedia(Post(key: page.items[0].key,
            id: page.items[0].id, provider: "erome"))
        XCTAssertEqual(resolved.mediaUrl, page.items[0].mediaUrl)
        let routes = NativeProviderProtocol.log.snapshot().compactMap(\.url)
        XCTAssertTrue(routes.contains { $0.path == "/explore/new" })
        XCTAssertTrue(routes.allSatisfy { $0.host == "www.erome.com" },
                      "Public Erome integration never calls paid Apify or untrusted album hosts")

        NativeProviderProtocol.log.reset()
        let searched = try await api.posts(provider: .erome,
            query: ParsedQuery(included: ["city"], excluded: []), page: 2)
        XCTAssertEqual(searched.items.count, 2)
        let query = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first?.url)
        XCTAssertEqual(query.path, "/search")
        XCTAssertEqual(URLComponents(url: query, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value, "city")
    }

    func testEromeParserRejectsExternalHostsAndMalformedAlbumIDs() throws {
        let malicious = #"<div id="albums"><a class="album-link" href="//evil.invalid/a/SNEAK">bad</a><a class="album-link" href="/a/GOOD_22">valid</a><a class="album-link" href="/a/../evil">traversal</a></div>"#
        XCTAssertEqual(EromePublicCatalog.albumLinks(malicious).map(\.path), ["/a/GOOD_22"])
        let album = try XCTUnwrap(URL(string: "https://www.erome.com/a/GOOD_22"))
        let injected = #"<video><source src="https://video.evil.invalid/clip.mp4"></video><div class="img"><img data-src="https://s7.erome.com.evil.invalid/fake.jpg"></div>"#
        XCTAssertTrue(EromePublicCatalog.albumMedia(injected, albumURL: album).isEmpty)
    }

    func testEromeListingSummariesDoNotDownloadAllAlbums() throws {
        let html = #"<div id="albums"><div class="album"><a class="album-title" href="/a/ABC123">City portrait</a><img class="album-thumbnail" src="https://s7.erome.com/123/ABC123/poster.jpg"><span class="album-user">Creator</span><span class="album-videos">1</span></div></div>"#
        let summaries = EromePublicCatalog.albumSummaries(html)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.stableID, "erome:ABC123")
        XCTAssertEqual(summaries.first?.type, "video")
        XCTAssertEqual(summaries.first?.mediaUrl, "")
        XCTAssertTrue(summaries.first?.isUnresolvedEromePreview == true,
                      "Scrolling past an Erome album summary must not begin video resolution")
        XCTAssertEqual(summaries.first?.caption, "City portrait")
        XCTAssertEqual(summaries.first?.creator, "Creator")
    }

    func testEromeImmersiveHydratesPlayablesFromAlbumSummaries() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let query = ParsedQuery(included: ["summary-video"], excluded: [])
        let preview = try await api.posts(provider: .erome, query: query, page: 1)
        XCTAssertEqual(preview.items.map(\.id), ["ABC123:clip_720p.mp4", "ABC123:photo.jpg"])
        XCTAssertEqual(preview.items.first?.mediaUrl,
                       "https://v12.erome.com/123/ABC123/clip_720p.mp4")
        XCTAssertFalse(preview.items.first?.isUnresolvedEromePreview == true)
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter {
            $0.url?.path == "/a/ABC123"
        }.count, 1, "Home should hydrate real video once, not show album-only thumbnails")

        NativeProviderProtocol.log.reset()
        let playable = try await api.posts(provider: .erome, query: query, page: 1, immersive: true)
        XCTAssertEqual(playable.items.map(\.id), ["ABC123:clip_720p.mp4"])
        XCTAssertEqual(playable.items.first?.mediaUrl,
                       "https://v12.erome.com/123/ABC123/clip_720p.mp4")
        XCTAssertFalse(playable.items.first?.isUnresolvedEromePreview == true,
                       "Immersive playback must keep auto-playing fully resolved videos")
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/a/ABC123" },
                       "Returning to an album should reuse hydrated media from Home")
    }

    func testEromeAlbumMediaIsReusedAcrossImmersiveAndPlaybackResolution() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let query = ParsedQuery(included: ["summary-video"], excluded: [])
        let page = try await api.posts(provider: .erome, query: query, page: 1, immersive: true)
        let clip = try XCTUnwrap(page.items.first)
        let unresolved = Post(key: "erome:ABC123", id: "ABC123", provider: "Erome", type: "video")
        async let first = api.resolveMedia(unresolved)
        async let second = api.resolveMedia(unresolved)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.mediaUrl, clip.mediaUrl)
        XCTAssertEqual(two.mediaUrl, clip.mediaUrl)
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/a/ABC123" }.count, 1,
                       "Replaying an Erome album should not repeat its expensive HTML/WebKit load")
    }

    func testEromeImmersiveDoesNotLoseVideoLinksBesideImageSummaries() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let query = ParsedQuery(included: ["mixed-albums"], excluded: [])
        let page = try await api.posts(provider: .erome, query: query, page: 1, immersive: true)
        XCTAssertEqual(page.items.map(\.id), ["ABC123:clip_720p.mp4"])
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/a/IMGONLY" })
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/a/ABC123" })
    }

    func testRedgifsNichesUseRealPopularPreviewAndOpenVideoFeed() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let niches = try await api.redgifsNiches()
        XCTAssertEqual(niches.map(\.id), ["cosplay"])
        XCTAssertEqual(niches.first?.name, "Cosplay")
        XCTAssertEqual(niches.first?.imageURL, "https://media.redgifs.com/nicheclip.jpg",
                       "Niche icon should be the real poster from a popular post")
        let page = try await api.posts(provider: .redgifs,
            query: ParsedQuery(included: ["niche:cosplay"], excluded: []),
            page: 1, sort: "popular", immersive: true)
        XCTAssertEqual(page.items.map(\.id), ["nicheclip"])
        XCTAssertFalse(page.items.contains { $0.id == "wrongclip" },
                       "An explicitly different niche membership must not be relabeled as the selected niche")
        XCTAssertEqual(page.items.first?.mediaUrl, "https://media.redgifs.com/nicheclip.mp4")
        XCTAssertEqual(page.items.first?.caption, "Cosplay clip title")
        XCTAssertEqual(page.items.first?.category, "cosplay",
                       "A Like from a niche feed should retain the community context")
        let another = try await api.posts(provider: .redgifs,
            query: ParsedQuery(included: ["niche:gaming"], excluded: []),
            page: 1, sort: "popular", immersive: true)
        XCTAssertEqual(another.items.map(\.id), ["gamingclip"])
        XCTAssertNotEqual(another.items.first?.id, page.items.first?.id,
                          "Selecting a different niche must load its own clips")
        XCTAssertEqual(another.items.first?.mediaUrl, "https://media.redgifs.com/gamingclip.mp4")
        let routes = NativeProviderProtocol.log.snapshot()
        XCTAssertTrue(routes.contains { $0.url?.path == "/v2/niches" })
        XCTAssertTrue(routes.contains { $0.url?.path == "/v2/niches/cosplay/gifs" })
        XCTAssertTrue(routes.contains { $0.url?.path == "/v2/niches/gaming/gifs" })
        XCTAssertTrue(routes.filter { $0.url?.path.hasPrefix("/v2/niches/") == true }
            .allSatisfy { $0.value(forHTTPHeaderField: "Referer") == "https://www.redgifs.com/" })
    }

    func testRedgifsNicheTriesLatestWhenTopContainsNoPlayableVideo() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .redgifs,
            query: ParsedQuery(included: ["niche:empty-top"], excluded: []),
            page: 1, sort: "popular", immersive: true)
        XCTAssertEqual(page.items.map(\.id), ["usable"])
        XCTAssertEqual(page.items.first?.category, "empty-top")
        let orders = NativeProviderProtocol.log.snapshot().filter { $0.url?.path == "/v2/niches/empty-top/gifs" }
            .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "order" })?.value }
        XCTAssertEqual(orders, ["top", "latest"])
    }

    func testRedgifsShowAllNichesPaginatesAndUsesRealPopularPosters() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let first = try await api.redgifsNichesPage(page: 1, limit: 24)
        XCTAssertEqual(first.items.map(\.id), ["cosplay"])
        XCTAssertTrue(first.hasMore)
        let second = try await api.redgifsNichesPage(page: 2, limit: 24)
        XCTAssertEqual(second.items.map(\.id), ["gaming"])
        XCTAssertEqual(second.items.first?.imageURL, "https://media.redgifs.com/gamingclip.jpg")
        XCTAssertFalse(second.hasMore)
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { request in
            request.url?.path == "/v2/niches" &&
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "page" && $0.value == "2" }) == true
        })
    }

    func testRedgifsNicheWithoutArtworkIsStillAvailableToBrowse() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let page = try await api.redgifsNichesPage(page: 3, limit: 24)
        XCTAssertEqual(page.items.map(\.id), ["no-cover"])
        XCTAssertEqual(page.items.first?.imageURL, "")
        XCTAssertFalse(page.hasMore)
    }

    @MainActor func testRedgifsExplicitNicheSelectionReplacesFeedAndKeepsLikedClips() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .redgifs
        store.commitSearch(query: "niche:cosplay", sort: "popular")
        await store.refresh(immersive: true)
        let cosplay = try XCTUnwrap(store.posts.first)
        XCTAssertEqual(cosplay.id, "nicheclip")
        XCTAssertEqual(cosplay.category, "cosplay")
        store.toggleFavorite(cosplay)
        await store.refresh(immersive: true)
        XCTAssertEqual(store.posts.map(\.id), ["nicheclip"],
            "A direct niche filter should keep showing its clips after liking them")
        store.commitSearch(query: "niche:gaming", sort: "popular")
        await store.refresh(immersive: true)
        XCTAssertEqual(store.posts.map(\.id), ["gamingclip"],
            "Switching niche must replace the old feed with the requested niche")
        XCTAssertNil(store.lastError)
    }

    func testHanimePublicCatalogSearchesTagsBeforeAuthAPI() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .hanime,
            query: ParsedQuery(included: ["dark skin"], excluded: []), page: 1)
        XCTAssertEqual(page.items.map(\.stableID), ["hanime:sample"])
        XCTAssertEqual(page.items.first?.tags, ["fantasy", "dark skin"])
        let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first)
        XCTAssertEqual(request.url?.host, "search.htv-services.com")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.host == "auth.hanime.tv" })
        let filtered = try await api.posts(provider: .hanime,
            query: ParsedQuery(included: ["fantasy"], excluded: ["dark skin"]), page: 1)
        XCTAssertTrue(filtered.items.isEmpty)
    }

    func testHanimeCatalogReusesRecentResultsWithoutRepeatingNetworkRequest() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let query = ParsedQuery(included: ["fantasy"], excluded: [])
        let first = try await api.posts(provider: .hanime, query: query, page: 1)
        let second = try await api.posts(provider: .hanime, query: query, page: 1)
        XCTAssertEqual(first.items, second.items)
        XCTAssertEqual(first.hasMore, second.hasMore)
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().filter {
            $0.url?.host == "search.htv-services.com"
        }.count, 1, "Switching back to Hanime should reuse the existing catalog")
    }

    func testHanimeSearchUsesServerPaginationWithoutDoubleSkipping() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .hanime,
            query: ParsedQuery(included: [], excluded: []), page: 2)
        XCTAssertEqual(page.items.map(\.stableID), ["hanime:second-page"])
        XCTAssertEqual(page.hasMore, true)
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.host == "search.htv-services.com" && $0.httpMethod == "POST"
        })
    }

    func testHanimeMemberCatalogRecoversWhenPublicSearchFails() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        NativeProviderProtocol.log.blockHanimeSearch(true)
        defer { NativeProviderProtocol.log.blockHanimeSearch(false) }
        let page = try await api.posts(provider: .hanime,
            query: ParsedQuery(included: [], excluded: []), page: 1, immersive: true)
        XCTAssertEqual(page.items.map(\.stableID), ["hanime:member-sample"])
        XCTAssertEqual(page.items.first?.thumbUrl, "https://cdn.hanime.tv/member.webp")
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.host == "auth.hanime.tv" })
    }

    func testHanimeWebsiteFallbackShowsPublicTitlesWhenCatalogAPIIsBlocked() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        NativeProviderProtocol.log.blockHanimeCatalog(true)
        defer { NativeProviderProtocol.log.blockHanimeCatalog(false) }

        let page = try await api.posts(provider: .hanime,
            query: ParsedQuery(included: [], excluded: []), page: 1, immersive: true)
        XCTAssertEqual(page.items.map(\.stableID), ["hanime:public-fantasy"])
        XCTAssertEqual(page.items.first?.thumbUrl, "https://cdn.hanime.tv/public.webp")
        XCTAssertEqual(page.items.first?.caption, "Public fantasy")
        XCTAssertEqual(page.hasMore, false)
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { $0.url?.host == "hanime.tv" })
    }

    func testHanimePublicHTMLRejectsUnrelatedLinksAndPosters() throws {
        let html = #"<a href="/videos/hentai/first-video"><img src="https://cdn.hanime.tv/first.jpg" alt="First &amp; final"></a><a href="https://evil.invalid/videos/hentai/other"><img src="https://evil.invalid/other.jpg"></a><a href="/videos/hentai/first-video">Duplicate</a><a href="https://hanime.tv/videos/hentai/second-video"><img data-src="https://evil.invalid/fake.jpg" alt="Second video"></a>"#
        let posts = NativeProviderAPI.parseHanimeWebsiteCatalog(html)
        XCTAssertEqual(posts.map(\.id), ["first-video", "second-video"])
        XCTAssertEqual(posts.map(\.caption), ["First & final", "Second video"])
        XCTAssertEqual(posts.map(\.thumbUrl), ["https://cdn.hanime.tv/first.jpg", ""])
        XCTAssertThrowsError(try NativeProviderAPI.hanimeWebsitePage(
            "<html><h1>Site Unavailable</h1></html>",
            query: ParsedQuery(included: [], excluded: []), immersive: true))
        let official = NativeProviderAPI.parseHanimeWebsiteCatalog(
            #"<a href="/videos/hentai/doura-4"><img alt="Doura 4 HD cover image" src="https://hanime-cdn.com/images/covers/doura-4-cover_1794219216.webp"></a>"#)
        XCTAssertEqual(official.map(\.id), ["doura-4"])
        XCTAssertEqual(official.first?.thumbUrl,
                       "https://hanime-cdn.com/images/covers/doura-4-cover_1794219216.webp")
    }

    func testHanimeArtworkPrefersVerifiedFirstPartyNestedPosterFields() {
        let row: [String: Any] = [
            "poster_url": "",
            "cover": ["large": "https://cdn.hanime.tv/cover-original.webp"],
            "thumbnail": "https://unrelated.example.com/unverified.jpg"
        ]
        XCTAssertEqual(NativeProviderAPI.hanimePosterURL(row),
                       "https://cdn.hanime.tv/cover-original.webp")
        XCTAssertEqual(NativeProviderAPI.hanimePosterURL([
            "thumbnail": "https://unrelated.example.com/unverified.jpg"
        ]), "", "Topic artwork must never come from an unrelated image host")
        XCTAssertEqual(HanimeGeneratedAPI.mediaHeaders(for:
            URL(string: "https://img.hanime.tv/poster.webp")!)["Referer"], "https://hanime.tv/")
        XCTAssertEqual(NativeProviderAPI.hanimePosterURL([
            "data": ["hentai_video": ["poster_url": "https://cdn.hanime.tv/nested.webp"]]
        ]), "https://cdn.hanime.tv/nested.webp")
        XCTAssertEqual(NativeProviderAPI.hanimeWatchPosterURL(
            #"<meta content="https://evil.invalid/untrusted.jpg" property="og:image"><meta content="https://cdn.hanime.tv/real.jpg" property="og:image">"#),
            "https://cdn.hanime.tv/real.jpg")
        let officialCover = "https://hanime-cdn.com/images/covers/doura-4-cover_1794219216.webp"
        XCTAssertEqual(NativeProviderAPI.hanimePosterURL(["cover_url": officialCover]), officialCover)
        XCTAssertTrue(HanimeGeneratedAPI.permittedArtworkURL(URL(string: officialCover)!))
        XCTAssertEqual(HanimeGeneratedAPI.mediaHeaders(for: URL(string: officialCover)!)["Referer"],
                       "https://hanime.tv/")
        XCTAssertFalse(HanimeGeneratedAPI.permittedArtworkURL(
            URL(string: "https://hanime-cdn.com.evil.invalid/images/covers/doura.webp")!))
        XCTAssertFalse(HanimeGeneratedAPI.permittedArtworkURL(
            URL(string: "https://hanime-cdn.com/ads/overlay.webp")!))
        XCTAssertEqual(NativeProviderAPI.hanimeWatchPosterURL(
            #"<img src="https://evil.invalid/advert.jpg" alt="ad"><img alt="Doura 4 HD cover image" src="https://hanime-cdn.com/images/covers/doura-4.webp">"#),
            "https://hanime-cdn.com/images/covers/doura-4.webp")
    }

    func testHanimeMissingSearchCoverLoadsOnlyRequestedTitleArtwork() async throws {
        let (_, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let bare = try XCTUnwrap(NativeProviderAPI.hanimeCatalogPost([
            "slug": "sample", "name": "Only a title in search"
        ]))
        XCTAssertTrue(bare.thumbUrl.isEmpty)
        let artwork = await NativeProviderAPI.hanimeArtworkURL(session: session, slug: bare.id)
        XCTAssertEqual(artwork, "https://cdn.hanime.tv/official-poster.webp")
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().compactMap(\.url).map(\.path), ["/api/v8/video"])

        NativeProviderProtocol.log.reset()
        let websiteArtwork = await NativeProviderAPI.hanimeArtworkURL(session: session, slug: "web-only")
        XCTAssertEqual(websiteArtwork, "https://hanime-cdn.com/images/covers/web-only.webp?size=large&v=2")
        XCTAssertEqual(NativeProviderProtocol.log.snapshot().compactMap(\.url).map(\.path),
                       ["/api/v8/video", "/videos/hentai/web-only"])
        NativeProviderProtocol.log.reset()
        let unsafeArtwork = await NativeProviderAPI.hanimeArtworkURL(session: session, slug: "https://evil.invalid")
        XCTAssertEqual(unsafeArtwork, "")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().isEmpty)
    }

    func testHanimeMissingPublicStreamSuggestsSupportedPlaybackOptions() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "hanime:no-stream", id: "no-stream", provider: "Hanime", type: "video")
        do {
            _ = try await api.resolveMedia(post)
            XCTFail("Expected a clear error when the v11 handshake returns no normal streams")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Browse inside QuickTick"))
            XCTAssertTrue(error.localizedDescription.contains("Hanime API"))
        }
    }

    func testHanimeDownloadSelectsFullVideoWhenFirstPartyPlayerAlsoOffersHLS() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "hanime:download-file", id: "download-file", provider: "Hanime", type: "video")
        let playback = try await api.resolveMedia(post)
        XCTAssertEqual(playback.type, "hls")
        XCTAssertEqual(playback.mediaUrl, "https://cdn.hanime.tv/videos/high-quality.m3u8")
        let download = try await api.resolveMedia(post, forDownload: true)
        XCTAssertEqual(download.type, "video")
        XCTAssertEqual(download.mediaUrl, "https://cdn.hanime.tv/videos/download-full.mp4")
        let result = try DownloadSourcePolicy.validate(media: download, for: post)
        XCTAssertFalse(result.isHLS)
    }

    func testHanimeNativeHLSResolvesCurrentV11Handshake() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "hanime:sample", id: "sample", provider: "Hanime", type: "video")
        let resolved = try await api.resolveMedia(post)
        XCTAssertEqual(resolved.mediaUrl, "https://hanime.tv/hls/42/fixture-token")
        XCTAssertEqual(resolved.type, "hls")
        let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first {
            $0.url?.path == "/api/v11/handshake"
        })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-signature-version"), "web2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-signature")?.count, 64)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-csrf-token"), "null")
        XCTAssertEqual(HanimeGeneratedAPI.mediaHeaders(for: URL(string: resolved.mediaUrl)!)["Referer"],
                       "https://player.hanime.tv/")
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/api/v8/video" })
    }

    func testHanimeFallsBackToVerifiedLegacyStreamWhenHandshakeIsGone() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let post = Post(key: "hanime:legacy-working", id: "legacy-working", provider: "Hanime", type: "video")
        let result = try await api.resolveMedia(post)
        XCTAssertEqual(result.mediaUrl, "https://cdn.hanime.tv/videos/legacy-full.m3u8")
        XCTAssertEqual(result.type, "hls")
        let lower = try await api.resolveMedia(post, streamVariant: 1)
        XCTAssertEqual(lower.mediaUrl, "https://cdn.hanime.tv/videos/legacy-full.m3u8")
        let nextQuality = try await api.resolveMedia(post, streamVariant: 2)
        XCTAssertEqual(nextQuality.mediaUrl, "https://cdn.hanime.tv/videos/legacy-small.m3u8")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/api/v8/video" })
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.host == "evil.invalid" })
    }

    func testHanimeRetriesLowerQualityWithoutConsumingSignedPlaylist() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "hanime:alternate-stream", id: "alternate-stream", provider: "Hanime", type: "video")
        let initial = try await api.resolveMedia(post)
        XCTAssertEqual(initial.mediaUrl, "https://hanime.tv/hls/broken")
        let resolved = try await api.resolveMedia(post, streamVariant: 1)
        XCTAssertEqual(resolved.mediaUrl, "https://hanime.tv/hls/alternate")
        XCTAssertEqual(resolved.type, "hls")
        let requests = NativeProviderProtocol.log.snapshot().filter { $0.url?.host == "hanime.tv" && $0.url?.path.hasPrefix("/hls/") == true }
        XCTAssertTrue(requests.isEmpty, "The native player must receive signed HLS URLs before any extra GET request")
    }
    func testHanimeAcceptsAuthorizedPlainJSONStreamOnOfficialSignedCDN() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "hanime:plain-json", id: "plain-json", provider: "Hanime", type: "video")
        let resolved = try await api.resolveMedia(post)
        XCTAssertEqual(resolved.mediaUrl, "https://cdn.hanime.tv/hls/signed-opaque?token=abc")
        XCTAssertEqual(resolved.type, "hls")
        XCTAssertTrue(HanimeGeneratedAPI.permittedStreamURL(URL(string: resolved.mediaUrl)!))
    }

    func testHanimeHandshakeCodecAuthenticatesEnvelope() throws {
        let value = Data(#"{"slug":"sample","directive":"htv_player_handshake"}"#.utf8)
        let token = try HanimeHandshakeCodec.seal(value)
        XCTAssertEqual(try HanimeHandshakeCodec.open(token), value)
        XCTAssertThrowsError(try HanimeHandshakeCodec.open("not-a-real-token"))
    }

    func testHanimeNativePlaybackAcceptsFirstPartyCatalogStream() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let stream = NativeProviderAPI.hanimeCatalogStream([
            "stream_url": "https://cdn.hanime.tv/videos/sample.m3u8?token=fixture",
            "video_url": "https://untrusted.example.org/tracker.mp4"
        ])
        XCTAssertEqual(stream, "https://cdn.hanime.tv/videos/sample.m3u8?token=fixture")
        XCTAssertEqual(NativeProviderAPI.hanimeCatalogStream([
            "stream_url": "https://cdn.hanime.tv.evil.invalid/sample.m3u8"
        ]), "")
        let post = Post(key: "hanime:sample", id: "sample", provider: "Hanime",
                        mediaUrl: stream, type: "video")
        let resolved = try await api.resolveMedia(post)
        XCTAssertEqual(resolved.mediaUrl, stream)
        XCTAssertEqual(resolved.type, "hls")
        XCTAssertFalse(NativeProviderProtocol.log.snapshot().contains { $0.url?.path == "/api/v8/video" },
                       "Play native HLS immediately instead of hitting the removed v8 endpoint")
    }

    func testHanimeRemovedEndpointShowsAuthorizedPlaybackFallback() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "hanime:missing-404", id: "missing-404", provider: "Hanime", type: "video")
        do {
            _ = try await api.resolveMedia(post)
            XCTFail("Expected a useful fallback when Hanime's old endpoint returns 404")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Native playback"))
            XCTAssertTrue(error.localizedDescription.contains("Hanime API"))
            XCTAssertFalse(error.localizedDescription.contains("HTTP 404"))
        }
    }

    func testGeneratedProviderAPIsValidateURLsAndQueryExclusions() throws {
        XCTAssertNotNil(HanimeGeneratedAPI.validatedURL("https://api.example.com"))
        XCTAssertNil(HanimeGeneratedAPI.validatedURL("http://api.example.com"))
        XCTAssertNil(HanimeGeneratedAPI.validatedURL("https://name:secret@api.example.com"))
        XCTAssertTrue(HanimeGeneratedAPI.permittedStreamURL(URL(string: "https://hanime.tv/hls/valid.m3u8")!))
        XCTAssertTrue(HanimeGeneratedAPI.permittedStreamURL(URL(string: "https://cdn.hanime.tv/videos/valid.m3u8?token=1")!))
        XCTAssertFalse(HanimeGeneratedAPI.permittedStreamURL(URL(string: "https://cdn.hanime.tv.evil.invalid/valid.m3u8")!))
        XCTAssertFalse(HanimeGeneratedAPI.permittedStreamURL(URL(string: "https://cdn.hanime.tv/watch.html")!))
        let base = URL(string: "https://api.example.com")!
        let query = ParsedQuery(included: ["dark skin"], excluded: ["blocked_tag"])
        let hanime = try HanimeGeneratedAPI.listingURL(base: base, query: query, page: 2, sort: "recent")
        let erome = try EromeGeneratedAPI.listingURL(base: base, query: query, page: 3,
                                                     sort: "recent", immersive: true)
        XCTAssertEqual(URLComponents(url: hanime, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "q" })?.value, "dark skin")
        XCTAssertEqual(URLComponents(url: erome, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "exclude" })?.value, "blocked_tag")
    }

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
        XCTAssertTrue(Provider.allCases.contains(.hanime))
        XCTAssertFalse(Provider.allCases.contains(.hhaven), "Keep legacy Haven downloads without showing Haven in the picker")
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
        XCTAssertTrue(recentRequest.value(forHTTPHeaderField: "User-Agent")?.contains("QuickTick/1.0") == true)
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

    func testXVideosProviderIdentityAndSafeURLs() throws {
        XCTAssertEqual(Provider.identify("XVideos.com"), .xvideos)
        XCTAssertEqual(Provider.identifyPage("https://www.xvideos.com/video.abc123/example"), .xvideos)
        XCTAssertTrue(Provider.allCases.contains(.xvideos))
        XCTAssertNotNil(NativeProviderAPI.xvideosWatchURL("/video.abc123/example"))
        XCTAssertNil(NativeProviderAPI.xvideosWatchURL("https://evil.invalid/video.abc123/example"))
        XCTAssertNotNil(NativeProviderAPI.xvideosPlayerMediaURL("https://cdn77.xvideos-cdn.com/video.mp4"))
        XCTAssertNil(NativeProviderAPI.xvideosPlayerMediaURL("https://evil.invalid/preview.mp4"))
        XCTAssertNil(NativeProviderAPI.xvideosPlayerMediaURL("https://img-cf.xvideos-cdn.com/video.jpg"))
    }

    func testXVideosFeedSearchAndPlaybackUseFirstPartyPages() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .xvideos,
            query: QueryParser.parse("first story"), page: 1, sort: "popular")
        XCTAssertEqual(page.items.map(\.stableID), ["xvideos:abc123", "xvideos:def456"])
        XCTAssertEqual(page.items.first?.caption, "First story")
        XCTAssertEqual(page.items.first?.thumbUrl,
            "https://img-cf.xvideos-cdn.com/videos/first.jpg")
        XCTAssertEqual(page.items.first?.type, "video")
        let search = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first { $0.url?.host == "www.xvideos.com" })
        let params = URLComponents(url: try XCTUnwrap(search.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(params.first(where: { $0.name == "k" })?.value, "first story")
        let post = try XCTUnwrap(page.items.first)
        let first = try await api.resolveMedia(post)
        XCTAssertEqual(first.mediaUrl, "https://cdn77.xvideos-cdn.com/videos/full-hd.mp4?token=valid")
        XCTAssertEqual(first.type, "video")
        let next = try await api.resolveMedia(post, streamVariant: 1, forDownload: true)
        XCTAssertEqual(next.mediaUrl, "https://cdn77.xvideos-cdn.com/videos/full-sd.mp4")
        let hls = try await api.resolveMedia(post, streamVariant: 2)
        XCTAssertEqual(hls.type, "hls")
        XCTAssertTrue(try DownloadSourcePolicy.validate(media: hls, for: post).isHLS)
    }

    func testXVideosUnavailableSearchNeverInventsPosts() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        do {
            _ = try await api.posts(provider: .xvideos,
                query: QueryParser.parse("empty"), page: 1)
            XCTFail("A blank provider search should not manufacture unrelated video cards.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("XVideos"))
        }
    }

    func testPornhubHomeCategoryUsesActualCategoryParameter() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let page = try await api.posts(provider: .pornhub,
            query: QueryParser.parse("category:hentai"), page: 1)
        XCTAssertEqual(page.items.map(\.stableID), ["pornhub:hentai-cover"])
        XCTAssertEqual(page.items.first?.previewImageURLs, [
            "https://cdn.pornhub.com/verified-hentai.jpg"
        ], "A category chip must use artwork belonging to a verified member of that category")
        let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first {
            $0.url?.path == "/webmasters/search"
        })
        let params = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(params.first(where: { $0.name == "category" })?.value, "hentai")
        XCTAssertNil(params.first(where: { $0.name == "search" }),
            "A category-only chip must not be sent as an unrelated title search")
    }

    func testPornhubSearchOnlyAppliesSelectedProviderFilters() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        var filters = PornhubSearchFilters(order: .topRated, production: .homemade,
                                           minimumMinutes: 10, maximumMinutes: 20,
                                           includedCategory: "Cosplay", excludedCategories: ["Vintage"])
        let query = QueryParser.parse(filters.encodedQuery("filtered-terms"))
        let result = try await api.posts(provider: .pornhub, query: query, page: 2, sort: "popular")
        XCTAssertEqual(result.items.map(\.stableID), ["pornhub:allowed"])
        let request = try XCTUnwrap(NativeProviderProtocol.log.snapshot().first { $0.url?.path == "/webmasters/search" })
        let params = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { params.first { $0.name == key }?.value }
        XCTAssertEqual(value("ordering"), "rating")
        XCTAssertEqual(value("production"), "homemade")
        XCTAssertEqual(value("min_duration"), "10")
        XCTAssertEqual(value("max_duration"), "20")
        XCTAssertEqual(value("category"), "Cosplay")
        XCTAssertEqual(value("exclude_category[]"), "Vintage")
        XCTAssertEqual(value("search"), "filtered-terms")

        let categories = try await api.pornhubCategories()
        XCTAssertEqual(categories, ["Anal", "Cosplay", "Vintage"])
        let unrestricted = NativeProviderAPI.pornhubSearchParameters(query: QueryParser.parse("filtered-terms"), page: 1, sort: "recent")
        XCTAssertFalse(unrestricted.contains(where: { ["production", "min_duration", "max_duration", "category", "exclude_category[]"].contains($0.name) }))
        XCTAssertEqual(unrestricted.first { $0.name == "ordering" }?.value, "newest")
        XCTAssertEqual(NativeProviderAPI.pornhubDurationSeconds("1:05:30"), 3930)
        XCTAssertNil(NativeProviderAPI.pornhubDurationSeconds("unknown"))
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

    func testPornhubUnsupportedBrowseFilterRetriesCanonicalSearchRoute() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let options = PornhubSearchFilters(minimumMinutes: 10, maximumMinutes: 20)
        let query = QueryParser.parse(options.encodedQuery("browse-filter-404"))
        let result = try await api.posts(provider: .pornhub, query: query, page: 1)
        XCTAssertEqual(result.items.map(\.stableID), ["pornhub:phpublic"])
        let requests = NativeProviderProtocol.log.snapshot().filter {
            $0.url?.path == "/video/search"
        }
        XCTAssertTrue(requests.contains {
            $0.url?.query?.contains("min_duration") == true
        })
        XCTAssertTrue(requests.contains {
            $0.url?.query?.contains("search=browse-filter-404") == true &&
            $0.url?.query?.contains("min_duration") != true
        }, "An unsupported filter must not permanently break a valid search")
    }

    func testPornhubOfflineResolutionPrefersFullMP4OverHLS() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "pornhub:download-priority", id: "download-priority",
                        provider: "Pornhub", type: "video")
        let playback = try await api.resolveMedia(post)
        XCTAssertEqual(playback.type, "hls")
        XCTAssertEqual(playback.mediaUrl, "https://cdn.pornhub.com/priority-1080.m3u8")
        let offline = try await api.resolveMedia(post, forDownload: true)
        XCTAssertEqual(offline.type, "video")
        XCTAssertEqual(offline.mediaUrl, "https://cdn.pornhub.com/offline-720.mp4")
    }

    func testPornhubWatchPage404FallsBackToFirstPartyEmbedMedia() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let embedMarkup = #"<script>var player={"mediaDefinitions":[{"format":"hls","quality":"720","videoUrl":"https://cdn.pornhub.com/embed-valid.m3u8"}]};</script>"#
        XCTAssertEqual(NativeProviderAPI.pornhubPlayerDefinitions(embedMarkup).first?["videoUrl"] as? String,
                       "https://cdn.pornhub.com/embed-valid.m3u8")
        let post = Post(key: "pornhub:watch-missing", id: "watch-missing",
                        provider: Provider.pornhub.rawValue, type: "video")
        let media: ResolvedMedia
        do {
            media = try await api.resolveMedia(post)
        } catch {
            let routes = NativeProviderProtocol.log.snapshot().compactMap { $0.url?.absoluteString }
            XCTFail("Pornhub media fallback failed after requests: \(routes.joined(separator: ", ")); \(error)")
            throw error
        }
        XCTAssertEqual(media.mediaUrl, "https://cdn.pornhub.com/embed-valid.m3u8")
        XCTAssertEqual(media.type, "hls")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.path == "/embed/watch-missing"
        })
    }

    func testPornhubCategoryArtworkUsesFirstPartyPageOrVerifiedCategoryMetadata() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        NativeProviderProtocol.log.reset()
        let preview = try await api.pornhubCategoryPreview(token: "category:cosplay")
        XCTAssertEqual(preview, "https://cdn.pornhub.com/category-cosplay.jpg")
        XCTAssertTrue(NativeProviderProtocol.log.snapshot().contains {
            $0.url?.path == "/categories/cosplay"
        })
        let verified = try await api.pornhubCategoryPreview(token: "category:hentai")
        XCTAssertEqual(verified, "https://cdn.pornhub.com/verified-hentai.jpg",
                       "A category API result may supply a cover when its metadata confirms membership")
        let unavailable = try await api.pornhubCategoryPreview(token: "category:vintage")
        XCTAssertNil(unavailable, "An unavailable category must never borrow a generic video's poster")
        let invalid = try await api.pornhubCategoryPreview(token: "category:../wrong")
        XCTAssertNil(invalid)
        XCTAssertEqual(NativeProviderAPI.pornhubImageHeaders(for:
            URL(string: "https://thumbs.phncdn.com/cosplay.webp")!)["Referer"],
            "https://www.pornhub.com/")
    }

    @MainActor func testHanimeImmersiveKeepsVideosWithUnmatchedWDInterests() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .hanime
        store.tasteSetup.sources[Provider.hanime.rawValue] = TasteChoice(done: true,
            into: ["extremely_specific_wd_visual_tag"])
        await store.recommendations.load(RecommendationState())
        await store.refresh(immersive: true)
        XCTAssertEqual(store.posts.map(\.stableID), ["hanime:sample"])
        XCTAssertTrue(store.posts.allSatisfy(\.isImmersiveMedia))
        await store.refresh(immersive: true)
        XCTAssertFalse(store.posts.isEmpty,
            "Unmatched WD interests must not empty Hanime when another public catalog page is available")
        XCTAssertTrue(store.posts.allSatisfy { $0.providerKey == .hanime && $0.isImmersiveMedia })
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

    @MainActor func testMigratedHavenSelectionLoadsHanimePublicCatalog() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: api, localStorage: LocalStateStore(directory: directory))
        await store.bootstrap()
        store.selectedProvider = .hhaven
        XCTAssertEqual(store.selectedProvider, .hanime)
        store.tasteSetup.sources[Provider.hanime.rawValue] = TasteChoice(done: true, into: ["fantasy"])
        await store.recommendations.load(RecommendationState())
        await store.refresh()
        XCTAssertEqual(store.posts.map(\.stableID), ["hanime:sample"],
            "Migrating a saved Haven selection must use Hanime's available catalog")
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
        store.tasteSetup.sources[Provider.eporner.rawValue] = TasteChoice(
            done: true, into: ["engineering", "aerodynamics"])
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
    func testPornhubAcceptsExplicitSignedCDNStreamWithoutFileExtension() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "pornhub:opaque", id: "opaque", provider: "Pornhub",
                        pageUrl: "https://www.pornhub.com/view_video.php?viewkey=opaque", type: "video")
        let media = try await api.resolveMedia(post)
        XCTAssertEqual(media.mediaUrl, "https://vid-cdn.phncdn.com/signed/abc123?expires=123&token=xyz")
        XCTAssertEqual(media.type, "hls")
    }
    func testPornhubPlaybackRetryStepsDownQualityAndAvoidsDuplicateEmbedSources() async throws {
        let (api, session) = client(); defer { session.invalidateAndCancel() }
        let post = Post(key: "pornhub:multi", id: "multi", provider: "Pornhub",
                        pageUrl: "https://www.pornhub.com/view_video.php?viewkey=multi", type: "video")
        let highest = try await api.resolveMedia(post)
        let lower = try await api.resolveMedia(post, streamVariant: 1)
        let embed = try await api.resolveMedia(post, streamVariant: 2)
        XCTAssertEqual(highest.mediaUrl, "https://cdn.pornhub.com/first-1080.mp4")
        XCTAssertEqual(lower.mediaUrl, "https://cdn.pornhub.com/second-720.m3u8")
        XCTAssertEqual(embed.mediaUrl, "https://cdn.pornhub.com/third-480.mp4")
    }
    func testPornhubParsesFlashvarsEscapedMediaDefinitions() throws {
        let html = #"<script>window.flashvars={"mediaDefinitions":"[{\"format\":\"hls\",\"quality\":\"720\",\"videoUrl\":\"https:\/\/cdn.pornhub.com\/escaped.m3u8\"}]"};</script>"#
        let definitions = NativeProviderAPI.pornhubPlayerDefinitions(html)
        let stream = try XCTUnwrap(definitions.first)
        XCTAssertEqual(NativeProviderAPI.pornhubDeclaredMedia(stream)?.mediaUrl,
                       "https://cdn.pornhub.com/escaped.m3u8")
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
            XCTAssertEqual(page.items.count,
                           provider == .kemono || provider == .coomer ? 3 : (provider == .erome ? 2 : 1), provider.rawValue)
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
        // Hanime's public catalog no longer guarantees a playback stream.
        // Its missing-stream behavior is covered by a separate regression test.
        for (provider, expected) in [(Provider.eporner, "https://cdn.eporner.com/full.mp4"), (.pornhub, "https://cdn.pornhub.com/full.mp4")] {
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
