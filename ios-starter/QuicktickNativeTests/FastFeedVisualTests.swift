import XCTest
@testable import QuicktickNative

private final class FastFeedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let page = Int(components?.queryItems?.first(where: { $0.name == "pid" })?.value ?? "0") ?? 0
        let id = page * 2 + 1
        let payload = "[{\"id\":\(id),\"tags\":\"standing\",\"file_url\":\"https://cdn.example.test/\(id).jpg\"},{\"id\":\(id+1),\"tags\":\"sitting\",\"file_url\":\"https://cdn.example.test/\(id+1).jpg\"}]"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        let envelope = "{\"count\":400,\"post\":" + payload + "}"
        client?.urlProtocol(self, didLoad: Data(envelope.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FastFeedVisualTests: XCTestCase {
    private func post(_ id: String, provider: String = "rule34", tags: [String] = [], media: String = "") -> Post {
        Post(key: provider + ":" + id, id: id, provider: provider, tags: tags, mediaUrl: media, type: "image")
    }
    func testCrossProviderIdentityURLsAndPerceptualDuplicates() {
        let liked = post("1", media: "https://cdn.test/shared.jpg?token=old")
        let mirror = post("different", provider: "eporner", media: "https://cdn.test/shared.jpg?token=new")
        let other = post("1", provider: "redgifs", media: "https://other.test/different.jpg")
        var exclusions = FeedExclusions()
        XCTAssertEqual(exclusions.filter([mirror, other], favorites: [liked], recommended: true), [other])
        exclusions.setFingerprints([liked.stableID: 0x12345678, other.stableID: 0x12345679])
        XCTAssertTrue(exclusions.filter([other], favorites: [liked], recommended: true).isEmpty)
        XCTAssertFalse(FeedExclusions.nearDuplicate(0, UInt64.max))
    }
    func testImageAndVideoImpressionsExcludeRecentAcrossProviderIDs() {
        let image = post("image", media: "https://cdn.test/still.jpg")
        var video = post("video", media: "https://cdn.test/movie.mp4"); video.type = "video"
        var exclusions = FeedExclusions(); exclusions.viewed(image); exclusions.viewed(video)
        let mirror = post("mirror", provider: "redgifs", media: video.mediaUrl)
        XCTAssertTrue(exclusions.filter([image, video, mirror], favorites: [], recommended: true).isEmpty)
        XCTAssertEqual(exclusions.filter([image], favorites: [], recommended: false), [image])
        for i in 0..<3000 { exclusions.viewed(post(String(i))) }
        XCTAssertLessThanOrEqual(exclusions.recent.count, 2048)
    }
    func testConservativeDomainClassificationAndExplicitIdentity() {
        XCTAssertEqual(VisualDomain.classify(post("a")), .anime)
        for provider in ["pornhub", "eporner", "redgifs"] {
            XCTAssertEqual(VisualDomain.classify(post("b", provider: provider)), .realLife)
            XCTAssertNil(VisualDomain.classify(post("b", provider: provider, tags: ["anime"])))
        }
        XCTAssertNil(VisualDomain.classify(post("c", tags: ["photo"])))
        XCTAssertNil(VisualDomain.classify(post("d", provider: "hanime")))
        XCTAssertTrue(VisualFeatures.metadata(post("e", provider: "redgifs", tags: ["blonde_hair"]))!.subjects.isEmpty)
    }
    func testDislikedChunLiPresentationPreservesIdentityAndContext() {
        let liked = VisualFeatures.metadata(post("liked", tags: ["chun_li", "qipao", "watercolor"]))!
        let disliked = VisualFeatures.metadata(post("bad", tags: ["chun_li", "jacket", "sketch"]))!
        var profile = VisualProfile()
        for _ in 0..<6 { profile.record(.like, features: liked) }
        let identityBefore = profile.subjects["chun_li"]!.affinity
        profile.record(.less, features: disliked)
        XCTAssertEqual(profile.subjects["chun_li"]!.affinity, identityBefore)
        XCTAssertGreaterThan(profile.score(liked), profile.score(disliked))
        XCTAssertLessThan(profile.interactions["chun_li|clothing:jacket"]!.affinity, 0)
        XCTAssertGreaterThan(profile.interactions["chun_li|clothing:qipao"]!.affinity, 0)
        var another = liked; another.subjects = ["unseen_character"]
        XCTAssertGreaterThan(profile.score(another), 0)
    }
    func testImpressionBaselineReducesCommonAttributeConfidence() {
        let features = VisualFeatures(domain: .realLife, attributes: ["setting:outdoors": 1])
        var common = VisualProfile(), selective = VisualProfile()
        for _ in 0..<50 { common.record(.impression, features: features) }
        common.record(.like, features: features); selective.record(.like, features: features)
        XCTAssertLessThan(common.score(features), selective.score(features))
    }
    func testHistoricalFavoritesPersistIdempotentlyAndNeverMixProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analyzer = VisualAnalysisService(directory: directory)
        let anime = post("a", tags: ["chun_li", "qipao"])
        let real = post("b", provider: "eporner", tags: ["jacket", "performer:explicit_metadata"])
        for _ in 0..<3 {
            await analyzer.analyzeFavorite(anime, useVision: false)
            await analyzer.analyzeFavorite(real, useVision: false)
        }
        let saved = await analyzer.snapshot()
        XCTAssertEqual(saved.liked.count, 2)
        XCTAssertNotNil(saved.profiles["anime"]?.attributes["clothing:qipao"])
        XCTAssertNil(saved.profiles["anime"]?.attributes["clothing:jacket"])
        XCTAssertNil(saved.profiles["realLife"]?.subjects["chun_li"])
        let restored = await VisualAnalysisService(directory: directory).snapshot()
        XCTAssertEqual(saved.profiles, restored.profiles)
        XCTAssertEqual(saved.features, restored.features)
    }
    func testResourceGatesAndInstantMissingModelFallback() async {
        XCTAssertFalse(VisualAnalysisService.resourcesAllowAnalysis(lowPower: false, thermal: 0, playback: true, loading: false))
        XCTAssertFalse(VisualAnalysisService.resourcesAllowAnalysis(lowPower: true, thermal: 0, playback: false, loading: false))
        XCTAssertFalse(VisualAnalysisService.resourcesAllowAnalysis(lowPower: false, thermal: 3, playback: false, loading: false))
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let candidate = post("fallback", tags: ["standing"])
        let ranked = await engine.rank([candidate], taste: TasteChoice(), recent: [])
        XCTAssertEqual(ranked, [candidate])
    }
    @MainActor func testActualStoreTransitionPreservesUpcomingPreparation() {
        let store = AppStore()
        let url = URL(fileURLWithPath: "/tmp/not-loaded.mp4")
        store.inlinePlaybackID = "first"
        _ = store.players.activate(key: "first", url: url, muted: false)
        store.players.prewarm(key: "next", url: url)
        let next = store.players.player(for: "next", url: url)
        store.inlinePlaybackID = "next"
        XCTAssertTrue(store.players.isPreparing("next"))
        XCTAssertTrue(store.players.player(for: "next", url: url) === next)
        store.activeTab = 2
        XCTAssertFalse(store.players.isPreparing("next"))
        store.players.releaseAll()
    }
    @MainActor func testFeedPublishesProviderOrderWithoutAIAndPaginationAdvances() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FastFeedProtocol.self]
        let credentials = ProviderCredentials(rule34User: "fixture-user", rule34Key: "fixture-key")
        let store = AppStore(api: QuicktickAPIClient(session: URLSession(configuration: config), credentials: credentials))
        let start = Date()
        await store.refresh()
        print("QUICKTICK_METRIC fixture_first_posts_ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(store.posts.map(\.id), ["1", "2"])
        XCTAssertFalse(store.isLoading)
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["1", "2", "3", "4"])
        store.recordImpression(store.posts[0]); store.recordImpression(store.posts[1])
        store.favorites[store.posts[2].stableID] = store.posts[2]
        await store.refresh()
        XCTAssertFalse(store.posts.contains { ["1", "2", "3"].contains($0.id) })
        store.selectedProvider = .eporner // Cancel the delayed intelligence task.
    }
}
