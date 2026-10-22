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
    func testCompactSearchFiltersRoundTripAndStayProviderScoped() {
        let state = SearchFilters.split("long_hair -jacket sort:random rating:general score:>=25")
        XCTAssertEqual(state.tags, "long_hair -jacket")
        XCTAssertEqual(state.filters.order, .random); XCTAssertEqual(state.filters.minimumScore, 25)
        let query = state.filters.query(tags: state.tags + " long_hair", provider: .rule34)
        XCTAssertEqual(query, "sort:random long_hair -jacket rating:general score:>=25")
        XCTAssertEqual(state.filters.query(tags: state.tags, provider: .eporner), "long_hair -jacket")
        XCTAssertEqual(SearchFilters.split(query).filters, state.filters)
    }
    func testSignedCDNVariantsAssetHashesAndProviderIDAliasesAreDeduplicated() {
        let hash = "1234567890abcdef1234567890abcdef"
        let a = post("7", media: "https://one.test/\(hash).jpg?X-Amz-Signature=old")
        let mirror = post("8", provider: "eporner", media: "https://two.test/sample_\(hash).jpg?sig=new")
        let alias = post("0007", media: "https://other.test/unrelated.jpg")
        let unique = post("9", media: "https://one.test/different.jpg")
        let filter = FeedExclusions()
        XCTAssertEqual(filter.filter([a, mirror, alias, unique], favorites: [], recommended: true), [a, unique])
        let signed = post("a", media: "https://cdn.test/stream.mp4?asset=1&Policy=old&Key-Pair-Id=a")
        let resigned = post("b", media: "https://cdn.test/stream.mp4?asset=1&Policy=new&Key-Pair-Id=b")
        let different = post("c", media: "https://cdn.test/stream.mp4?asset=2&Policy=new")
        XCTAssertEqual(filter.filter([signed, resigned, different], favorites: [], recommended: false), [signed, different])
    }
    @MainActor func testCachedVisualDuplicatesAreRemovedOnlyFromTheUnseenTail() async {
        let store = AppStore()
        // Match a real refresh's revision setup before injecting fixture posts.
        store.feedSort = "recent"; store.feedSort = "recommended"
        let head = post("visible", media: "https://one.test/a.jpg")
        let duplicate = post("copy", media: "https://two.test/b.jpg")
        let unique = post("unique", media: "https://two.test/c.jpg")
        store.posts = [head, duplicate, unique]; store.inlinePlaybackID = head.stableID
        store.protectVisibleHomePosts([head.stableID])
        store.notePreviewFingerprint(head, hash: 0x12345678)
        store.notePreviewFingerprint(duplicate, hash: 0x12345679)
        store.notePreviewFingerprint(unique, hash: 0xfefefefefefefefe)
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(store.posts, [head, unique])
        store.selectedProvider = .eporner
    }
    @MainActor func testProviderSwitchStripsRule34FiltersBeforeRequestAndMemoryPressureStopsManualScan() {
        let store = AppStore()
        store.queryText = "long_hair -jacket sort:random rating:general score:>=25"
        store.selectedProvider = .eporner
        XCTAssertEqual(store.queryText, "long_hair -jacket")
        store.startManualVisualRefresh(); store.handleMemoryPressure()
        XCTAssertFalse(store.isManualVisualScanRunning)
    }
    @MainActor func testManualVisualRefreshProgressReusesLikeLedgerAndCanBeCancelled() async {
        let store = AppStore(), suffix = UUID().uuidString
        let a = post("manual-a-" + suffix, tags: ["long_hair"])
        let b = post("manual-b-" + suffix, tags: ["qipao"])
        store.favorites = [a.stableID: a, b.stableID: b]
        store.startManualVisualRefresh()
        for _ in 0..<1000 where store.isManualVisualScanRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isManualVisualScanRunning)
        XCTAssertEqual(store.manualVisualProgress?.completed, 2)
        XCTAssertEqual(store.manualVisualProgress?.fraction, 1)
        let first = await store.visual.snapshot()
        store.startManualVisualRefresh()
        for _ in 0..<1000 where store.isManualVisualScanRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isManualVisualScanRunning)
        XCTAssertEqual(store.manualVisualProgress?.completed, 2)
        let second = await store.visual.snapshot()
        XCTAssertEqual(first.liked, second.liked)
        store.startManualVisualRefresh(); store.cancelManualVisualRefresh()
        XCTAssertFalse(store.isManualVisualScanRunning)
        XCTAssertEqual(store.manualVisualProgress?.completed, 0)
        store.selectedProvider = .eporner
    }
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
        XCTAssertEqual(VisualDomain.classify(post("a")), .uncertain)
        for provider in ["pornhub", "eporner", "redgifs"] {
            XCTAssertEqual(VisualDomain.classify(post("b", provider: provider)), .uncertain)
            XCTAssertEqual(VisualDomain.classify(post("b", provider: provider, tags: ["anime"])), .anime)
        }
        XCTAssertEqual(VisualDomain.classify(post("c", tags: ["photo"])), .realLife)
        XCTAssertEqual(VisualDomain.classify(post("d", provider: "hanime")), .uncertain)
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
    func testExistingTagEngineKeepsLikedSubjectAfterPresentationDislike() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let liked = post("good", tags: ["chun_li", "qipao", "watercolor"])
        let bad = post("bad", tags: ["chun_li", "jacket", "sketch"])
        await engine.record(.like, post: liked)
        await engine.record(.less, post: bad)
        let state = await engine.snapshot()
        XCTAssertGreaterThan(state.profiles["rule34"]?.terms["chun_li"] ?? 0, 0)
        let suppressed = await engine.isHardDisliked(liked, taste: TasteChoice())
        XCTAssertFalse(suppressed)
        XCTAssertTrue(state.profiles["rule34"]?.recentSeen.contains(bad.stableID) == true)
    }
    func testHistoricalFavoritesPersistIdempotentlyAndNeverMixProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analyzer = VisualAnalysisService(directory: directory)
        let anime = post("a", tags: ["2d", "chun_li", "qipao"])
        let real = post("b", provider: "eporner", tags: ["photo", "jacket", "performer:explicit_metadata"])
        for _ in 0..<3 {
            await analyzer.analyzeFavorite(anime, useVision: false)
            await analyzer.analyzeFavorite(real, useVision: false)
        }
        let saved = await analyzer.snapshot()
        XCTAssertEqual(saved.liked.count, 2)
        XCTAssertNotNil(saved.profiles["rule34|anime"]?.attributes["clothing:qipao"])
        XCTAssertNil(saved.profiles["rule34|anime"]?.attributes["clothing:jacket"])
        XCTAssertNil(saved.profiles["eporner|realLife"]?.subjects["chun_li"])
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
    @MainActor func testRecommendationTasteAffectsInitialAndPaginatedPosts() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FastFeedProtocol.self]
        let credentials = ProviderCredentials(rule34User: "fixture-user", rule34Key: "fixture-key")
        let store = AppStore(api: QuicktickAPIClient(session: URLSession(configuration: config), credentials: credentials))
        let liked = Post(key: "rule34:liked", id: "liked", provider: "rule34", tags: ["sitting"])
        await store.recommendations.record(.like, post: liked)
        await store.refresh()
        XCTAssertEqual(store.posts.map(\.id), ["2", "1"])
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["2", "1", "4", "3"])
        store.selectedProvider = .eporner
    }

    func testExplicitBlockedVariantsAreFilteredBeforeRanking() {
        let furry = post("f", tags: ["furry_female"])
        let anthro = post("a", tags: ["anthro_wolf"])
        let unrelated = post("u", tags: ["chun-li_(street_fighter)", "2d"])
        let query = ParsedQuery(included: [], excluded: ["furry"])
        let filtered = NativeProviderAPI.page([furry, anthro, unrelated],
            hasMore: false, query: query, immersive: false)
        XCTAssertEqual(filtered.items, [unrelated])
        XCTAssertTrue(RecommendationTagRules.rejects(unrelated, exclusions: ["chun_li"]))
        XCTAssertFalse(RecommendationTagRules.rejects(unrelated, exclusions: ["3d"]))
    }
    func testDislikedVisualResemblanceIsContextualToLikedCharacter() {
        var profile = VisualProfile()
        let liked = VisualFeatures(domain: .anime, attributes: ["style:2d": 1],
            subjects: ["chun_li"], embedding: [1, 0, 0])
        let disliked = VisualFeatures(domain: .anime, attributes: ["style:3d": 1],
            subjects: ["chun_li"], embedding: [0, 1, 0])
        for _ in 0..<4 { profile.record(.like, features: liked) }
        let before = profile.subjects["chun_li"]?.affinity
        profile.record(.less, features: disliked)
        XCTAssertEqual(before, profile.subjects["chun_li"]?.affinity)
        XCTAssertNotNil(profile.negativeContextClusters["subject:chun_li"])
        let another3D = VisualFeatures(domain: .anime, attributes: ["style:3d": 1],
            subjects: ["chun_li"], embedding: [0, 0.99, 0.01])
        XCTAssertGreaterThan(profile.score(liked), profile.score(another3D))
    }

    @MainActor func testFeedPublishesProviderOrderWithoutAIAndPaginationAdvances() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FastFeedProtocol.self]
        let credentials = ProviderCredentials(rule34User: "fixture-user", rule34Key: "fixture-key")
        let store = AppStore(api: QuicktickAPIClient(session: URLSession(configuration: config), credentials: credentials))
        let start = Date()
        await store.refresh()
        print("QUICKTICK_METRIC fixture_first_posts_ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(store.posts.map(\.id), ["1", "2", "3", "4"],
                       "A recommended refresh must blend two unique candidate pages")
        XCTAssertFalse(store.isLoading)
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["1", "2", "3", "4", "5", "6", "7", "8"],
                       "Pagination should advance beyond both initial candidate pages")
        store.recordImpression(store.posts[0]); store.recordImpression(store.posts[1])
        store.favorites[store.posts[2].stableID] = store.posts[2]
        await store.refresh()
        XCTAssertFalse(store.posts.contains { ["1", "2", "3"].contains($0.id) })
        store.selectedProvider = .eporner // Cancel the delayed intelligence task.
    }
}
