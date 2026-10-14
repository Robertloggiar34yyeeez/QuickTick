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
        let url = request.url!, host = url.host ?? "", path = url.path
        let payload: String
        if path == "/v2/auth/temporary" { payload = #"{"token":"synthetic-provider-token"}"# }
        else if host == "api.redgifs.com" { payload = #"{"pages":3,"gifs":[{"id":"clip","type":"g","width":1920,"height":1080,"tags":["engineering"],"urls":{"hd":"https://media.redgifs.com/clip.mp4","poster":"https://media.redgifs.com/clip.jpg"}}]}"# }
        else if host == "api.rule34.xxx", path == "/autocomplete.php" { payload = #"[{"value":"engineering","label":"engineering (12)","count":12}]"# }
        else if host == "api.rule34.xxx" {
            let comments = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "s" && $0.value == "comment" } == true
            payload = comments ? #"<comments><comment id="7" creator="Fixture" body="A &amp; B" /></comments>"# : #"[{"id":1,"score":9,"tags":"engineering car","width":1920,"height":1080,"file_url":"https://media.rule34.xxx/clip.mp4","preview_url":"https://media.rule34.xxx/clip.jpg"}]"#
        } else if path.contains("/embed/") { payload = #"<html><script>var hash='00112233445566778899aabbccddeeff';</script></html>"# }
        else if path.contains("/xhr/video/") { payload = #"{"sources":{"mp4":{"360p":{"src":"https://cdn.eporner.com/small.mp4"},"1080p":{"src":"https://cdn.eporner.com/full.mp4"}}}}"# }
        else if host == "www.eporner.com" { payload = #"{"total_pages":3,"videos":[{"id":"ep1","title":"Ground effect","keywords":"engineering,aerodynamics","views":10,"default_thumb":{"src":"https://cdn.eporner.com/thumb.jpg"}}]}"# }
        else if host == "search.htv-services.com" { payload = #"{"nbPages":3,"hits":"[{\"slug\":\"sample\",\"name\":\"Fixture\",\"poster_url\":\"https://cdn.hanime.tv/thumb.jpg\",\"hentai_tags\":[{\"text\":\"fantasy\"}]}]"}"# }
        else if path == "/api/v8/video" { payload = #"{"videos_manifest":{"servers":[{"streams":[{"height":1080,"url":"https://cdn.hanime.tv/full.m3u8"}]}]}}"# }
        else if path == "/webmasters/search" { payload = #"{"videos":[{"video_id":"ph1","title":"Fixture","tags":[{"tag_name":"sample"}],"default_thumb":"https://cdn.pornhub.com/thumb.jpg"}]}"# }
        else if path == "/view_video.php" { payload = #"<script>var player={"mediaDefinitions":[{"format":"mp4","quality":"1080","videoUrl":"https://cdn.pornhub.com/full.mp4"}]};</script>"# }
        else if path == "/api/sync" { payload = #"{"exists":false,"ok":true}"# }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NativeProviderAPITests: XCTestCase {
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
            XCTAssertEqual(page.items.count, 1, provider.rawValue)
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
