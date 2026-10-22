import XCTest
import CoreGraphics
import ImageIO
@testable import QuicktickNative

final class IntelligentRecommendationTests: XCTestCase {
    func testIncrementalScanSkipsCurrentPostsAcrossRestartAndCombinesStats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var old = post("old", ["photo", "qipao"], provider: "redgifs")
        old.mediaUrl = url.absoluteString; old.thumbUrl = url.absoluteString
        _ = try await MediaImagePipeline.shared.image(raw: url.absoluteString, pixels: 128)
        let visual = VisualAnalysisService(directory: directory.appendingPathComponent("state"))
        await visual.analyzeFavorite(old, useVision: true)
        let first = await visual.snapshot()
        XCTAssertNotNil(first.analysisVersions?[old.stableID])
        let new = post("new", ["photo", "jacket"], provider: "redgifs")
        await visual.record(.like, post: new, queueAnalysis: false)
        let queue = await visual.historicalQueue([old, new]); XCTAssertEqual(queue, [new])
        await visual.analyzeFavorite(old, useVision: true)
        let runs = await visual.inferenceRuns; XCTAssertEqual(runs, 1)
        let combined = await visual.snapshot()
        XCTAssertEqual(combined.profiles["redgifs|realLife"]?.attributes["clothing:qipao"], first.profiles["redgifs|realLife"]?.attributes["clothing:qipao"])
        XCTAssertGreaterThan(combined.profiles["redgifs|realLife"]?.attributes["clothing:jacket"]?.positive ?? 0, 0)
        let restored = VisualAnalysisService(directory: directory.appendingPathComponent("state"))
        let afterRestart = await restored.historicalQueue([old, new]); XCTAssertEqual(afterRestart, [new])
        var changed = old; changed.tags.append("portrait")
        let invalidated = await restored.historicalQueue([changed]); XCTAssertEqual(invalidated, [changed])
    }
    func testCachedVisualAvoidanceDominatesNeutralMetadataWithoutLoadingModels() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let unwanted = post("unwanted", ["portrait", "jacket"])
        let desired = post("desired", ["portrait", "jacket"])
        let noScores = await engine.rankFast([unwanted, desired], taste: TasteChoice(), recent: [])
        XCTAssertEqual(noScores.count, 2)
        let appearance = [unwanted.stableID: -4.0, desired.stableID: 3.5]
        let ranked = await engine.rankFast([unwanted, desired], taste: TasteChoice(),
            recent: [], visualScores: appearance)
        XCTAssertEqual(ranked.first?.stableID, desired.stableID)
        XCTAssertLessThan(RecommendationQualityModel.combined(metadata: 0, visual: -4), 0)
        XCTAssertGreaterThan(RecommendationQualityModel.combined(metadata: 0, visual: 4), 0)
        XCTAssertEqual(RecommendationQualityModel.combined(metadata: 3, visual: nil), 3)
    }

    func testHistoricalFavoritesRemainAWeakSignalRatherThanOvertakingDiversity() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let favorites = (0..<100).map { post("saved-\($0)", ["chun_li", "qipao", "art"]) }
        let matching = post("candidate", ["chun_li", "qipao", "art"])
        let distinct = post("different", ["raven", "landscape", "sketch"])
        await engine.configureFavorites(favorites)
        let matchScore = await engine.score(matching, taste: TasteChoice(), recent: [])
        let distinctScore = await engine.score(distinct, taste: TasteChoice(), recent: [])
        let delta = matchScore - distinctScore
        XCTAssertGreaterThan(delta, 0)
        XCTAssertLessThanOrEqual(delta, 3.1, "The entire liked history must not force a large saturated boost")
    }

    func testGlobalDislikeAppliesInAnotherVisualContext() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let disliked = post("reject", ["2d", "jacket"])
        await engine.record(.less, post: disliked)
        let otherContext = post("other-context", ["3d", "jacket"])
        let neutral = post("safe-context", ["3d", "landscape"])
        let negative = await engine.score(otherContext, taste: TasteChoice(), recent: [])
        let neutralScore = await engine.score(neutral, taste: TasteChoice(), recent: [])
        XCTAssertLessThan(negative, neutralScore)
    }

    func testReconciledLikeStillEnqueuesPixelAnalysis() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        let liked = post("queue-like", ["2d", "chun_li"])
        await service.reconcileFavorites([liked])
        let beforePending = await service.pendingCount()
        XCTAssertEqual(beforePending, 0)
        await service.record(.like, post: liked)
        let pending = await service.pendingCount()
        XCTAssertGreaterThan(pending, 0, "The async like must still request visual analysis after metadata reconciliation")
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.profiles["rule34|anime"]?.subjects["chun_li"]?.positive ?? 0, 0.7, accuracy: 0.001)
    }

    func testFastRankingDiversifiesNearbyEqualScoreThemes() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let candidates = [
            post("a1", ["chun_li", "qipao"]),
            post("a2", ["chun_li", "qipao"]),
            post("a3", ["chun_li", "qipao"]),
            post("b1", ["raven", "landscape"]),
            post("b2", ["raven", "landscape"])
        ]
        await engine.configureFavorites([post("liked", ["art", "misc"])])
        let ranked = await engine.rankFast(candidates, taste: TasteChoice(), recent: [])
        XCTAssertEqual(ranked.count, candidates.count)
        XCTAssertEqual(ranked.first?.stableID, candidates.first?.stableID)
        XCTAssertEqual(ranked.dropFirst().first?.stableID, candidates[3].stableID)
    }

    func testReconcileRemovesUnlikedVisualEvidenceWithoutResettingOtherLikes() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        let a = post("visual-a", ["2d", "chun_li", "qipao"])
        let b = post("visual-b", ["2d", "raven", "jacket"])
        await service.reconcileFavorites([a, b])
        let before = await service.snapshot()
        XCTAssertEqual(before.liked.count, 2)
        await service.reconcileFavorites([b])
        let after = await service.snapshot()
        XCTAssertEqual(after.liked, Set([b.stableID]))
        XCTAssertEqual(after.profiles["rule34|anime"]?.subjects["chun_li"]?.positive ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(after.profiles["rule34|anime"]?.attributes["clothing:jacket"]?.positive ?? 0, 0)
        await service.reconcileFavorites([b])
        let stable = await service.snapshot()
        XCTAssertEqual(stable.profiles, after.profiles)
    }

    func testAllCurrentFavoritesContributeWithoutReplayingLikeEvents() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let saved = (0..<32).map { post("saved-\($0)", ["chun_li", "qipao", "artist:example"]) }
        let matching = post("candidate", ["chun_li", "qipao", "artist:example"])
        let unrelated = post("unrelated", ["jacket", "landscape", "artist:other"])
        await engine.configureFavorites(saved)
        let favScore = await engine.score(matching, taste: TasteChoice(), recent: [])
        let otherScore = await engine.score(unrelated, taste: TasteChoice(), recent: [])
        XCTAssertGreaterThan(favScore, otherScore)
        let request = await engine.candidateRequest(context: "complete-likes", provider: .rule34,
            taste: TasteChoice(), excluded: [])
        XCTAssertTrue(request.focused)
        XCTAssertFalse(request.query.included.isEmpty)
        // Reconfiguration does not create synthetic feedback or mutate history.
        let after = await engine.snapshot()
        XCTAssertEqual(after.profiles.values.reduce(0) { $0 + $1.stats.likes }, 0)
        await engine.configureFavorites([])
        let cleared = await engine.score(matching, taste: TasteChoice(), recent: [])
        XCTAssertLessThan(cleared, favScore)
    }

    func testFavoriteMetadataBatchIsIdempotentAndRestorable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        let saved = (0..<12).map { post("batch-\($0)", ["2d", "chun_li", "qipao"]) }
        await service.reconcileFavorites(saved)
        let first = await service.snapshot()
        XCTAssertEqual(first.liked.count, saved.count)
        await service.reconcileFavorites(saved)
        let again = await service.snapshot()
        XCTAssertEqual(first.profiles, again.profiles)
        let restored = await VisualAnalysisService(directory: directory).snapshot()
        XCTAssertEqual(restored.liked.count, saved.count)
    }

    func testExpiringSignaturesDoNotInvalidateContentButAssetParametersDo() {
        let original = FeedExclusions.canonicalMediaURL("https://cdn.test/image.jpg?asset=1&token=old")
        XCTAssertEqual(original, FeedExclusions.canonicalMediaURL("https://cdn.test/image.jpg?token=new&asset=1"))
        XCTAssertNotEqual(original, FeedExclusions.canonicalMediaURL("https://cdn.test/image.jpg?asset=2&token=new"))
    }
    private func post(_ id: String, _ tags: [String], provider: String = "rule34") -> Post {
        Post(key: provider + ":" + id, id: id, provider: provider, tags: tags, type: "image")
    }
    func testReviewedFranchiseMappingsAliasesCrossoversAndAmbiguity() {
        let sf = TasteConcepts.resolve(["Chun-Li", "fortnite"])
        XCTAssertEqual(sf.characters, ["chun_li"])
        XCTAssertEqual(Set(sf.franchises), ["street_fighter", "fortnite"])
        XCTAssertEqual(sf.evidence["franchise:street_fighter"]?.origin, "reviewed_mapping")
        XCTAssertEqual(TasteConcepts.resolve(["shelly", "brawlstars"]).characters, ["shelly_brawl_stars"])
        XCTAssertEqual(TasteConcepts.resolve(["colette_(brawl_stars)"]).franchises, ["brawl_stars"])
        XCTAssertEqual(TasteConcepts.resolve(["fishstick_(fortnite)"]).franchises, ["fortnite"])
        XCTAssertTrue(TasteConcepts.resolve(["shelly", "raven", "unknown"]).characters.isEmpty)
        XCTAssertEqual(TasteConcepts.resolve(["franchise:unknown_series"]).franchises, ["unknown_series"])
    }
    func testContentBasedMediaClassificationAcrossProviders() {
        for provider in Provider.allCases {
            XCTAssertEqual(VisualDomain.classify(post("a", ["2d"], provider: provider.rawValue)), .anime)
            XCTAssertEqual(VisualDomain.classify(post("b", ["3dcg", "anime"], provider: provider.rawValue)), .threeD)
            XCTAssertEqual(VisualDomain.classify(post("c", ["photo"], provider: provider.rawValue)), .realLife)
            XCTAssertEqual(VisualDomain.classify(post("d", ["photo", "3d"], provider: provider.rawValue)), .mixed)
            XCTAssertEqual(VisualDomain.classify(post("e", ["animated", "realistic"], provider: provider.rawValue)), .uncertain)
        }
    }
    func testSpecificArtistMediumAndPresentationOutweighBroadSimilarity() throws {
        let liked = try XCTUnwrap(VisualFeatures.metadata(post("a", ["3d", "artist:one", "chun_li", "qipao"])))
        let unrelated = try XCTUnwrap(VisualFeatures.metadata(post("b", ["3d", "artist:other", "chun_li", "jacket"])))
        var profile = ContextTasteProfile()
        for _ in 0..<6 { profile.record(.like, features: liked) }
        let artistBefore = profile.dimensions["artist:one"]
        profile.record(.less, features: unrelated)
        XCTAssertEqual(profile.dimensions["artist:one"], artistBefore)
        XCTAssertGreaterThan(profile.score(liked), profile.score(unrelated))
        XCTAssertTrue(profile.discoveryQueries().contains { $0.contains("one") && $0.contains("3d") })
        var unseen = liked; unseen.subjects = ["new_character"]; unseen.franchises = []
        XCTAssertGreaterThan(profile.score(unseen), profile.score(unrelated))
        let decoded = try JSONDecoder().decode(ContextTasteProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }
    func testDislikePresentationPreservesLikedCharacterAndFranchise() throws {
        let liked = try XCTUnwrap(VisualFeatures.metadata(post("a", ["2d", "chun_li", "qipao", "watercolor"])))
        let bad = try XCTUnwrap(VisualFeatures.metadata(post("b", ["2d", "chun_li", "jacket", "sketch"])))
        var profile = ContextTasteProfile()
        for _ in 0..<4 { profile.record(.like, features: liked) }
        let identity = profile.dimensions["character:chun_li"], franchise = profile.dimensions["franchise:street_fighter"]
        profile.record(.less, features: bad)
        XCTAssertEqual(profile.dimensions["character:chun_li"], identity)
        XCTAssertEqual(profile.dimensions["franchise:street_fighter"], franchise)
        XCTAssertLessThan(profile.relationships["character:chun_li|clothing:jacket"]?.affinity ?? 0, 0)
        XCTAssertGreaterThan(profile.score(liked), profile.score(bad))
    }
    func testActiveFeedbackDeduplicationPersistenceAndMediumIsolation() async throws {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let liked = post("like", ["2d", "chun_li", "qipao"])
        await engine.record(.like, post: liked, eventID: "stable-event")
        let before = await engine.snapshot()
        await engine.record(.like, post: liked, eventID: "stable-event")
        let after = await engine.snapshot()
        XCTAssertEqual(before.contextualProfiles, after.contextualProfiles)
        XCTAssertNotNil(after.contextualProfiles["rule34|anime"])
        XCTAssertNil(after.contextualProfiles["rule34|threeD"])
        XCTAssertNil(after.contextualProfiles["redgifs|anime"])
        let restored = try JSONDecoder().decode(RecommendationState.self, from: JSONEncoder().encode(after))
        let second = RecommendationEngine(semantic: SemanticRecommender(enabled: false)); await second.load(restored)
        await second.record(.like, post: liked, eventID: "stable-event")
        let replayed = await second.snapshot()
        XCTAssertEqual(after.contextualProfiles, replayed.contextualProfiles)
        await second.record(.less, post: post("bad", ["3d", "chun_li", "jacket"]))
        let preserved = await second.snapshot()
        XCTAssertEqual(preserved.contextualProfiles["rule34|anime"], after.contextualProfiles["rule34|anime"])
    }
    func testDurableOutboxAndBoundedPriorityQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let visual = VisualAnalysisService(directory: directory)
        for i in 0..<80 { _ = await visual.enqueue(post("\(i)", ["2d"]), priority: 1) }
        let feedback = FeedbackEnvelope(id: "durable", post: post("negative", ["3d", "jacket"]), event: .less)
        await visual.stage(feedback, queueAnalysis: true); await visual.stage(feedback, queueAnalysis: true)
        let saved = await visual.snapshot()
        XCTAssertEqual(saved.pending?.count, 64)
        XCTAssertTrue(saved.pending?.contains { $0.post.id == "negative" && $0.priority == 5 } == true)
        XCTAssertEqual(saved.outbox?.count, 1)
        let recovered = VisualAnalysisService(directory: directory)
        let pending = await recovered.pendingFeedback(); XCTAssertEqual(pending.map(\.id), ["durable"])
        await recovered.acknowledge("durable")
        let acknowledged = await recovered.snapshot(); XCTAssertTrue(acknowledged.outbox?.isEmpty == true)
    }
    func testExplicitAliasFamiliesHaveZeroLeakageAndInferredNegativesRemainSoft() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let taste = TasteChoice(done: true, into: [], notInto: ["anthropomorphic"])
        let rejected = ["furry", "furry_male", "furry_female", "anthro", "anthro_female"].enumerated().map { post("\($0.offset)", [$0.element]) }
        let allowed = post("ok", ["anthropology", "furrowed_brow"])
        let ranked = await engine.rankFast(rejected + [allowed], taste: taste, recent: [])
        XCTAssertEqual(ranked, [allowed])
        await engine.record(.less, post: allowed)
        let hard = await engine.isHardDisliked(allowed, taste: TasteChoice()); XCTAssertFalse(hard)
        let request = await engine.candidateRequest(context: "aliases", provider: .rule34, taste: taste, excluded: [])
        XCTAssertTrue(request.query.excluded.contains("furry")); XCTAssertTrue(request.query.excluded.contains("anthro"))
    }
    func testChunLi3DMatchesTrustedArtistsInsteadOfAny3DRender() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        var one = post("liked-3d-a", ["3d", "chun_li", "artist:trusted_one"])
        one.creator = "shared_aggregator"
        var two = post("liked-3d-b", ["3d", "chun_li", "artist:trusted_two"])
        two.creator = "shared_aggregator"
        await engine.configureFavorites([one, two, post("2d", ["2d", "chun_li", "qipao"])])
        var favoriteArtist = post("good", ["3d", "chun_li", "artist:trusted_two"])
        favoriteArtist.creator = "shared_aggregator"
        var unlikedArtist = post("bad", ["3d", "chun_li", "artist:untrusted"])
        unlikedArtist.creator = "shared_aggregator"
        let unknown = post("unknown", ["3d", "chun_li"])
        let otherArtistExcluded = await engine.isHardDisliked(unlikedArtist, taste: TasteChoice())
        XCTAssertTrue(otherArtistExcluded, "A known unliked 3D artist should not be served")
        let override = TasteChoice(done: true, into: ["untrusted"], notInto: [])
        let explicitlyAllowed = await engine.isHardDisliked(unlikedArtist, taste: override)
        XCTAssertFalse(explicitlyAllowed, "User-selected artists override inferred restrictions")
        let good = await engine.score(favoriteArtist, taste: TasteChoice(), recent: [])
        let bad = await engine.score(unlikedArtist, taste: TasteChoice(), recent: [])
        let unknownScore = await engine.score(unknown, taste: TasteChoice(), recent: [])
        XCTAssertGreaterThan(good, bad + 30,
            "A popular character or shared uploader must not override an untrusted 3D artist")
        XCTAssertGreaterThan(good, unknownScore)
        let ranked = await engine.rankFast([unlikedArtist, unknown, favoriteArtist],
            taste: TasteChoice(), recent: [])
        XCTAssertEqual(ranked.first?.stableID, favoriteArtist.stableID)
    }

    func testRougeTheBatLikesNeverPromoteLiteralWildlife() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let liked = post("rouge-like", ["2d", "rouge_the_bat", "sonic_the_hedgehog", "anthro"])
        await engine.configureFavorites([liked])
        let wildBat = post("wild-bat", ["photo", "bat", "wildlife"])
        let wildFox = post("wild-fox", ["photo", "fox", "wildlife"])
        let rouge = post("rouge-art", ["2d", "rouge_the_bat", "anthro"])
        let otherFiction = post("fictional", ["2d", "character:fox_hero", "anthro"])
        let wildBatBlocked = await engine.isHardDisliked(wildBat, taste: TasteChoice())
        let wildFoxBlocked = await engine.isHardDisliked(wildFox, taste: TasteChoice())
        let rougeBlocked = await engine.isHardDisliked(rouge, taste: TasteChoice())
        let fictionBlocked = await engine.isHardDisliked(otherFiction, taste: TasteChoice())
        XCTAssertTrue(wildBatBlocked)
        XCTAssertTrue(wildFoxBlocked)
        XCTAssertFalse(rougeBlocked)
        XCTAssertFalse(fictionBlocked)
        let feed = await engine.rankFast([wildBat, wildFox, rouge, otherFiction],
            taste: TasteChoice(), recent: [])
        XCTAssertEqual(Set(feed.map(\.stableID)), Set([rouge.stableID, otherFiction.stableID]))
        let allowedAnimal = TasteChoice(done: true, into: ["bat"], notInto: [])
        let explicitBlocked = await engine.isHardDisliked(wildBat, taste: allowedAnimal)
        XCTAssertFalse(explicitBlocked,
            "An explicit animal preference must override automatic fictional disambiguation")
    }

    func testSonicCharacterAliasDoesNotMapBareAnimalOrAmbiguousName() {
        XCTAssertTrue(TasteConcepts.resolve(["rouge_the_bat"]).characters.contains("rouge_the_bat"))
        XCTAssertTrue(TasteConcepts.resolve(["sonic_the_hedgehog", "rouge"]).characters.contains("rouge_the_bat"))
        XCTAssertTrue(TasteConcepts.resolve(["bat"]).characters.isEmpty)
        XCTAssertTrue(TasteConcepts.resolve(["rouge"]).characters.isEmpty)
    }

    func testMetadataFixtureRelevanceAgainstLegacyScorer() async {
        let legacy = RecommendationEngine(semantic: SemanticRecommender(enabled: false), contextualRanking: false)
        let current = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        for i in 0..<8 {
            let favorite = post("favorite\(i)", ["2d", "chun_li", "artist:one", "qipao", "watercolor"])
            await legacy.record(.like, post: favorite); await current.record(.like, post: favorite)
        }
        let candidates = (0..<20).map { post("candidate\($0)", $0 < 10 ? ["3d", "chun_li", "artist:other", "animation"] : ["2d", "chun_li", "artist:one", "qipao", "watercolor"]) }
        let start = Date()
        let old = await legacy.rankFast(candidates, taste: TasteChoice(), recent: [])
        let baselineMs = Date().timeIntervalSince(start) * 1000
        let newStart = Date()
        let new = await current.rankFast(candidates, taste: TasteChoice(), recent: [])
        let currentMs = Date().timeIntervalSince(newStart) * 1000
        func precision(_ posts: [Post]) -> Double { Double(posts.prefix(5).filter { $0.tags.contains("artist:one") && $0.tags.contains("2d") }.count) / 5 }
        print("QUICKTICK_METRIC metadata_fixture_baseline_p5=\(precision(old)) current_p5=\(precision(new)) baseline_rank_ms=\(baselineMs) current_rank_ms=\(currentMs)")
        XCTAssertGreaterThanOrEqual(precision(new), precision(old)); XCTAssertEqual(precision(new), 1)
    }
}
