import XCTest
@testable import QuicktickNative

final class RecommendationTests: XCTestCase {
    func testDrainedInterestFallsBackToAdvancingBroadCursorWithoutResettingProfile() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        var state = RecommendationState(); var profile = RecommendationProfile(); profile.terms = ["engineering": 20]
        state.profiles["rule34"] = profile; await engine.load(state)
        let taste = TasteChoice(done: true, into: ["engineering"], notInto: ["blocked"])
        let focused = await engine.candidateRequest(context: "recovery", provider: .rule34, taste: taste, excluded: [])
        await engine.markCandidateDrained(context: focused.context)
        let broad = await engine.candidateRequest(context: "recovery", provider: .rule34, taste: taste, excluded: [], forceBroad: true)
        XCTAssertFalse(broad.focused); XCTAssertTrue(broad.query.included.isEmpty); XCTAssertEqual(broad.query.excluded, ["blocked"])
        await engine.advanceCandidatePage(context: broad.context, nextPage: 7)
        let continued = await engine.candidateRequest(context: "recovery", provider: .rule34, taste: taste, excluded: [])
        XCTAssertFalse(continued.focused); XCTAssertEqual(continued.page, 7)
        let saved = await engine.snapshot(); XCTAssertEqual(saved.profiles["rule34"], profile)
    }
    @MainActor func testImportCannotRaceInitialProfileRestoration() async {
        let store = AppStore()
        store.exclusions = ["existing"]
        let transfer = RecommendationTransfer(preferences: TasteSetup(), exclusions: ["incoming"], state: RecommendationState(), semanticProfiles: [:])
        await store.importRecommendationProfile(transfer)
        XCTAssertEqual(store.exclusions, ["existing"])
        XCTAssertNotNil(store.profileTransferError)
        XCTAssertFalse(store.cloudSyncEnabled)
    }
    func testPositiveAndNegativeTagsGuideRatherThanReplaceLearnedProfile() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        var state = RecommendationState(); var profile = RecommendationProfile()
        profile.terms = ["engineering": 20, "blocked": 15]; profile.recentSeen = ["old-post"]
        state.profiles["rule34"] = profile; await engine.load(state)
        let before = await engine.snapshot()
        let taste = TasteChoice(done: true, into: (0..<12).map { "new_topic_\($0)" }, notInto: ["blocked"])
        var requests: [RecommendationEngine.CandidateRequest] = []
        for _ in 0..<4 { requests.append(await engine.candidateRequest(context: "rule34|test", provider: .rule34, taste: taste, excluded: [])) }
        XCTAssertTrue(requests[0].query.included.first?.hasPrefix("new_topic_") == true)
        XCTAssertEqual(requests[1].query.included, ["engineering"])
        XCTAssertEqual(requests[2].query.included, ["engineering"])
        XCTAssertFalse(requests[3].focused)
        XCTAssertTrue(requests.allSatisfy { $0.query.excluded.contains("blocked") })
        let after = await engine.snapshot()
        XCTAssertEqual(after.profiles, before.profiles)
    }
    func testBoundedLookAheadKeepsAllUniqueAllowedPostsAndPreferencesFirst() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let posts = (0..<240).map { index in
            Post(key: "rule34:\(index)", id: String(index), provider: "rule34", tags: [index == 239 ? "engineering" : (index == 238 ? "blocked" : "topic_\(index % 30)")])
        }
        let start = Date()
        let ranked = await engine.rank(posts + [posts[0]], taste: TasteChoice(done: true, into: ["engineering"], notInto: ["blocked"]), recent: [])
        print("QUICKTICK_METRIC bounded_rank_240_ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(ranked.first?.stableID, posts[239].stableID)
        XCTAssertEqual(ranked.count, 239)
        XCTAssertEqual(Set(ranked.map(\.stableID)).count, ranked.count)
        XCTAssertFalse(ranked.contains { $0.tags.contains("blocked") })
    }

    func testRecommendationTransferRoundTripPreservesInterestsWithoutHistoryOrCredentials() async throws {
        var state = RecommendationState(); var profile = RecommendationProfile()
        profile.terms = ["engineering": 14]; profile.recentSeen = ["private-post-id"]; profile.recentQueries = ["private-query"]
        state.profiles["rule34"] = profile; state.candidatePages["private-query"] = 12
        var semantic = SemanticInterest(); semantic.recent = Array(repeating: 0.1, count: 384)
        let preferences = TasteSetup(sources: ["rule34": TasteChoice(done: true, into: ["engineering"], notInto: ["blocked"])])
        let transfer = RecommendationTransfer(preferences: preferences, exclusions: ["excluded"], state: state, semanticProfiles: ["rule34": semantic])
        let data = try JSONEncoder().encode(transfer)
        let json = String(decoding: data, as: UTF8.self)
        for secret in ["private-post-id", "private-query", "apiKey", "session", "syncID", "candidatePages", "mediaUrl"] { XCTAssertFalse(json.contains(secret), secret) }
        let decoded = try RecommendationTransferReader.decode(data)
        XCTAssertEqual(decoded.preferences, preferences)
        XCTAssertEqual(decoded.exclusions, ["excluded"])
        XCTAssertEqual(decoded.profiles["rule34"]?.terms["engineering"], 14)
        XCTAssertEqual(decoded.semanticProfiles["rule34"]?.recent, semantic.recent)
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        var imported = RecommendationState(); imported.profiles = decoded.profiles; await engine.load(imported)
        let interests = await engine.positiveTerms(provider: .rule34, taste: TasteChoice())
        XCTAssertTrue(interests.contains("engineering"))
    }

    func testMalformedOrFutureProfileCannotBeImported() throws {
        var value = RecommendationTransfer(preferences: TasteSetup(), exclusions: [], state: RecommendationState(), semanticProfiles: [:])
        value.version = 999
        XCTAssertThrowsError(try RecommendationTransferReader.decode(JSONEncoder().encode(value)))
        value.version = 1
        var invalid = SemanticInterest(); invalid.recent = [0.1, 0.2]
        value.semanticProfiles = ["rule34": invalid]
        XCTAssertThrowsError(try value.validated())
        XCTAssertThrowsError(try RecommendationTransferReader.decode(Data(repeating: 32, count: 2 * 1024 * 1024 + 1)))
        value.semanticProfiles = [:]; value.profiles = ["unknown-provider": RecommendationProfile()]
        XCTAssertThrowsError(try value.validated())
    }
    func testExplicitNotIntoIsHardFilter() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let post = Post(key: "r:1", id: "1", provider: "rule34", tags: ["blocked_theme"], mediaUrl: "https://example.invalid/a.mp4", type: "video")
        let ranked = await engine.rank([post], taste: TasteChoice(done: true, into: [], notInto: ["blocked_theme"]), recent: [])
        XCTAssertTrue(ranked.isEmpty)
    }

    func testRecurringPositiveCommonDenominatorWins() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let samusA = Post(key: "r:1", id: "1", provider: "rule34", tags: ["samus_aran", "zero_suit", "blonde_hair"], mediaUrl: "https://example.invalid/1.mp4", type: "video")
        let samusB = Post(key: "r:2", id: "2", provider: "rule34", tags: ["samus_aran", "metroid", "cosplay"], mediaUrl: "https://example.invalid/2.mp4", type: "video")
        let unrelated = Post(key: "r:3", id: "3", provider: "rule34", tags: ["zelda", "princess"], mediaUrl: "https://example.invalid/3.mp4", type: "video")

        await engine.record(.like, post: samusA)
        await engine.record(.download, post: samusB)
        await engine.recordSearch(provider: .rule34, query: "samus_aran")

        let ranked = await engine.rank([unrelated, samusB], taste: TasteChoice(), recent: [])
        XCTAssertEqual(ranked.first?.stableID, samusB.stableID)
    }

    func testOneLessDoesNotHardBlacklistEveryCoTag() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let disliked = Post(key: "r:1", id: "1", provider: "rule34", tags: ["scat", "blue_hair", "outdoors", "solo"], mediaUrl: "https://example.invalid/1.mp4", type: "video")
        let innocent = Post(key: "r:2", id: "2", provider: "rule34", tags: ["blue_hair", "outdoors", "smile"], mediaUrl: "https://example.invalid/2.mp4", type: "video")

        await engine.record(.less, post: disliked)
        let ranked = await engine.rank([innocent], taste: TasteChoice(), recent: [])
        XCTAssertEqual(ranked.count, 1)
    }

    func testRecurringNegativeCommonDenominatorBecomesHardFilter() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let a = Post(key: "r:1", id: "1", provider: "rule34", tags: ["scat", "blue_hair", "outdoors"], mediaUrl: "https://example.invalid/1.mp4", type: "video")
        let b = Post(key: "r:2", id: "2", provider: "rule34", tags: ["scat", "red_hair", "indoors"], mediaUrl: "https://example.invalid/2.mp4", type: "video")
        let c = Post(key: "r:3", id: "3", provider: "rule34", tags: ["scat", "cosplay"], mediaUrl: "https://example.invalid/3.mp4", type: "video")

        for _ in 0..<3 {
            await engine.record(.less, post: a)
            await engine.record(.less, post: b)
        }
        let ranked = await engine.rank([c], taste: TasteChoice(), recent: [])
        XCTAssertTrue(ranked.isEmpty)
    }

    func testCollaborativeHintCannotOverrideHardNotInto() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let blocked = Post(key: "r:1", id: "1", provider: "rule34", tags: ["blocked_theme"], mediaUrl: "https://example.invalid/1.mp4", type: "video")
        let scores = [await engine.gorseItemID(blocked): 1.0]
        let ranked = await engine.rank([blocked], taste: TasteChoice(done: true, into: [], notInto: ["blocked_theme"]), recent: [], collaborativeScores: scores)
        XCTAssertTrue(ranked.isEmpty)
    }
}
