import XCTest
@testable import QuicktickNative

final class RecommendationTests: XCTestCase {
    func testInstalledIPAMigratesV3CacheIntoV4WithoutDeletingTheOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var older = RecommendationState()
        older.version = 3
        var profile = RecommendationProfile()
        profile.terms = ["looking_at_viewer": 8, "leaning_over": -11]
        older.profiles["rule34"] = profile
        older.candidatePages = ["rule34|old": 17]
        try JSONEncoder().encode(older).write(to: root.appendingPathComponent("recommendations-v3.json"))

        let persistence = RecommendationPersistence(directory: root)
        let loaded = await persistence.load()
        let recovered = try XCTUnwrap(loaded)
        let wasLegacy = await persistence.loadedLegacyFile
        XCTAssertTrue(wasLegacy)
        let upgraded = recovered.upgradedForCurrentRanking()
        let saved = await persistence.save(upgraded)
        XCTAssertTrue(saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("recommendations-v3.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("recommendations-v4.json").path))
        XCTAssertTrue(upgraded.candidatePages.isEmpty)
        XCTAssertEqual(upgraded.profiles["rule34"], profile)
        let persisted = await persistence.load()
        let reloaded = try XCTUnwrap(persisted)
        let stillLegacy = await persistence.loadedLegacyFile
        XCTAssertFalse(stillLegacy)
        XCTAssertEqual(reloaded.version, RecommendationState.currentVersion)
        XCTAssertEqual(reloaded.profiles["rule34"], profile)
    }

    func testUpgradeRescansCandidateAcquisitionButPreservesExplicitNegativeEvidence() {
        var state = RecommendationState()
        state.version = 3
        state.candidatePages = ["rule34|round": 9]
        state.novelty.offered = ["rule34:unseen"]
        var profile = RecommendationProfile()
        profile.terms = ["looking_away": -7, "leaning_over": 11]
        profile.recentSeen = ["rule34:watched"]
        state.profiles["rule34"] = profile
        state.feedbackLedger = ["deliberate-feedback"]
        let migrated = state.upgradedForCurrentRanking()
        XCTAssertEqual(migrated.version, RecommendationState.currentVersion)
        XCTAssertTrue(migrated.candidatePages.isEmpty)
        XCTAssertTrue(migrated.novelty.offered.isEmpty)
        XCTAssertEqual(migrated.profiles["rule34"], profile)
        XCTAssertEqual(migrated.feedbackLedger, state.feedbackLedger)
        XCTAssertEqual(migrated.upgradedForCurrentRanking(), migrated)
        XCTAssertEqual(migrated.rebuildingCandidates().profiles, migrated.profiles)
    }

    func testActionTagsHaveMeaningAndRejectOpposingPoseOrGaze() async {
        XCTAssertEqual(ActionSemantics.facet("leaning over"), "pose:leaning_forward")
        XCTAssertEqual(ActionSemantics.facet("bent_over"), "pose:leaning_forward")
        XCTAssertEqual(ActionSemantics.facet("looking at viewer"), "gaze:at_viewer")
        XCTAssertEqual(ActionSemantics.facet("looking_away"), "gaze:away")
        XCTAssertNotEqual(ActionSemantics.facet("looking_up"), ActionSemantics.facet("looking_down"))
        let favored = Post(key: "rule34:l", id: "l", provider: "rule34",
            tags: ["2d", "chun_li", "leaning_over", "looking_at_viewer"])
        let compatible = Post(key: "rule34:yes", id: "yes", provider: "rule34",
            tags: ["2d", "chun_li", "leaning_forward", "eye_contact"])
        let conflicting = Post(key: "rule34:no", id: "no", provider: "rule34",
            tags: ["2d", "chun_li", "leaning_back", "looking_away"])
        let dimensions = VisualFeatures.metadata(favored)!.attributes
        XCTAssertNotNil(dimensions["pose:leaning_forward"])
        XCTAssertNotNil(dimensions["gaze:at_viewer"])
        XCTAssertTrue(RecommendationTagRules.rejects(compatible, exclusions: ["looking at viewer"]))
        XCTAssertTrue(RecommendationTagRules.rejects(compatible, exclusions: ["leaning over"]))
        XCTAssertFalse(RecommendationTagRules.rejects(conflicting, exclusions: ["looking at viewer"]))
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        await engine.configureFavorites([favored, favored])
        let first = await engine.score(compatible, taste: TasteChoice(), recent: [])
        let second = await engine.score(conflicting, taste: TasteChoice(), recent: [])
        XCTAssertGreaterThan(first, second)
    }

    func testDecisiveFavoriteMediumDoesNotLeakUnrelatedRenderStyles() async {
        let liked = (0..<6).map { index in
            Post(key: "rule34:a\(index)", id: "a\(index)", provider: "rule34",
                 tags: ["2d", "chun_li", "looking_at_viewer"])
        }
        let photo = Post(key: "rule34:p", id: "p", provider: "rule34",
            tags: ["photography", "real_person", "chun_li"])
        let sketch = Post(key: "rule34:s", id: "s", provider: "rule34",
            tags: ["2d", "chun_li", "looking_at_viewer"])
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        await engine.configureFavorites(liked)
        let rejectsPhoto = await engine.isHardDisliked(photo, taste: TasteChoice())
        let acceptsSketch = await engine.isHardDisliked(sketch, taste: TasteChoice())
        let explicitPhoto = await engine.isHardDisliked(photo, taste: TasteChoice(done: true, into: ["photography"]))
        XCTAssertTrue(rejectsPhoto)
        XCTAssertFalse(acceptsSketch)
        XCTAssertFalse(explicitPhoto)
    }

    func testImagePromptUsesActionsAndTaxonomyCreditedArtists() {
        let posts = [
            Post(key: "rule34:one", id: "one", provider: "rule34",
                tags: ["2d", "chun_li", "favorite_artist", "looking_at_viewer", "leaning_over", "beach"]),
            Post(key: "rule34:two", id: "two", provider: "rule34",
                tags: ["2d", "chun_li", "favorite_artist", "looking_at_camera", "beach"])
        ]
        let seed = StudioPromptSeed.build(favorites: posts,
            taxonomy: VisualTagTaxonomy(version: "test", artists: ["favorite_artist"], characters: ["chun_li"]))
        XCTAssertEqual(seed.characters.first, "chun_li")
        XCTAssertEqual(seed.artists.first, "favorite_artist")
        XCTAssertTrue(seed.attributes.contains("at_viewer"))
        XCTAssertEqual(seed.scenes.first, "beach")
        XCTAssertTrue(seed.prompt.contains("art by favorite artist"))
        XCTAssertTrue(seed.prompt.contains("looking at viewer"))
    }
    func testSimpleOnboardingSeparatesFictionalCharactersFromBroadKeywords() {
        let characters = StarterTastePick.characters
        let keywords = StarterTastePick.keywords
        XCTAssertFalse(characters.isEmpty)
        XCTAssertFalse(keywords.isEmpty)
        XCTAssertEqual(Set(characters.map(\.id)).count, characters.count)
        XCTAssertEqual(Set(keywords.map(\.id)).count, keywords.count)
        let chunLi = characters.first { $0.id == "chun_li" }
        XCTAssertEqual(chunLi?.query, "chun_li")
        XCTAssertTrue(chunLi?.tags.contains("street_fighter") == true,
                      "A selected character also seeds related franchise discovery")
        let rouge = characters.first { $0.id == "rouge" }
        XCTAssertEqual(rouge?.tags.first, "rouge_the_bat")
        XCTAssertFalse(rouge?.tags.contains("bat") == true,
                      "A fictional character must not add bare animal keywords")
        XCTAssertTrue(keywords.allSatisfy { $0.tags.count == 1 && $0.tags[0] == $0.query },
                      "Keyword providers should not silently insert fictional identities")
    }

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
    func testNoveltyExcludesPreviouslyOfferedPostsAndSignedURIAliasesAfterReload() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let original = Post(key: "rule34:10", id: "10", provider: "rule34",
            mediaUrl: "https://cdn.example.invalid/abc123.mp4?token=one", type: "video")
        let alias = Post(key: "rule34:other", id: "other", provider: "rule34",
            mediaUrl: "https://cdn.example.invalid/abc123.mp4?token=two", type: "video")
        let novel = Post(key: "rule34:11", id: "11", provider: "rule34", type: "video")
        await engine.recordOffered([original])
        let remaining = await engine.unseenRecommendations([original, alias, novel])
        XCTAssertEqual(remaining.map(\.stableID), [novel.stableID])
        let state = await engine.snapshot()
        let restored = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        await restored.load(state)
        let after = await restored.unseenRecommendations([original, alias, novel])
        XCTAssertEqual(after.map(\.stableID), [novel.stableID])
    }

    func testInstantSkipIsNegativeAndScrollBackNeutralizesWithoutPositiveTraining() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let skipped = Post(key: "r:skip", id: "skip", provider: "rule34", tags: ["portrait", "jacket", "night"])
        let similar = Post(key: "r:similar", id: "similar", provider: "rule34", tags: ["portrait", "jacket", "night"])
        let before = await engine.score(similar, taste: TasteChoice(), recent: [])
        await engine.recordReversibleSkip(skipped)
        let disliked = await engine.score(similar, taste: TasteChoice(), recent: [])
        XCTAssertLessThan(disliked, before)
        let wasSkipped = await engine.hasReversibleSkip(skipped.stableID)
        XCTAssertTrue(wasSkipped)
        let neutralized = await engine.neutralizeReversibleSkip(skipped.stableID)
        XCTAssertTrue(neutralized)
        let neutral = await engine.score(similar, taste: TasteChoice(), recent: [])
        XCTAssertEqual(neutral, before, accuracy: 0.0001)
        let state = await engine.snapshot()
        XCTAssertEqual(state.profiles["rule34"]?.stats.likes ?? 0, 0)
        XCTAssertEqual(state.profiles["rule34"]?.stats.less ?? 0, 0)
    }

    func testRepeatedFastSkipsMoreStronglyDownrankASharedPresentation() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let similar = Post(key: "r:match", id: "match", provider: "rule34", tags: ["portrait", "jacket"])
        let one = Post(key: "r:one", id: "one", provider: "rule34", tags: ["portrait", "jacket"])
        let two = Post(key: "r:two", id: "two", provider: "rule34", tags: ["portrait", "jacket"])
        await engine.recordReversibleSkip(one)
        let oneScore = await engine.score(similar, taste: TasteChoice(), recent: [])
        await engine.recordReversibleSkip(two)
        let twoScore = await engine.score(similar, taste: TasteChoice(), recent: [])
        XCTAssertLessThan(twoScore, oneScore)
    }

    @MainActor func testCandidateRoundCountersAreKeptWhenSavingAppState() async {
        let store = AppStore()
        _ = await store.recommendations.candidateRequest(context: "rule34|clips", provider: .rule34,
            taste: TasteChoice(done: true, into: ["portrait"]), excluded: [])
        let before = await store.recommendations.snapshot()
        let saved = await store.recommendationState()
        XCTAssertEqual(saved.candidatePages["rule34|clips|round"], before.candidatePages["rule34|clips|round"])
    }

    func testInstantSkipClassifierRejectsReverseSwipeAndLongDwell() {
        XCTAssertTrue(QuickSkipDecision.dislikes(elapsed: 0.35, from: 0, to: 1))
        XCTAssertTrue(QuickSkipDecision.dislikes(elapsed: 1.1, from: 1, to: 3))
        XCTAssertFalse(QuickSkipDecision.dislikes(elapsed: 0.05, from: 0, to: 1))
        XCTAssertFalse(QuickSkipDecision.dislikes(elapsed: 2.0, from: 0, to: 1))
        XCTAssertFalse(QuickSkipDecision.dislikes(elapsed: 0.2, from: 3, to: 2))
        XCTAssertFalse(QuickSkipDecision.dislikes(elapsed: 0.2, from: 1, to: 1))
    }

    func testStrongRepeatedNegativeThemeIsFilteredButSingleDislikeIsNot() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let one = Post(key: "r:1", id: "1", provider: "rule34", tags: ["unwanted_theme", "red_hair"])
        let two = Post(key: "r:2", id: "2", provider: "rule34", tags: ["unwanted_theme", "blue_hair"])
        let candidate = Post(key: "r:3", id: "3", provider: "rule34", tags: ["unwanted_theme", "outside"])
        await engine.record(.less, post: one)
        let initiallyAllowed = await engine.isHardDisliked(candidate, taste: TasteChoice())
        XCTAssertFalse(initiallyAllowed)
        for _ in 0..<3 {
            await engine.record(.less, post: one)
            await engine.record(.less, post: two)
        }
        let nowRejected = await engine.isHardDisliked(candidate, taste: TasteChoice())
        XCTAssertTrue(nowRejected)
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
    func testRecommendedStrictModeFiltersUnrelatedDiscoveryWithoutBlockingRelatedMatches() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let unrelated = Post(key: "rule34:random", id: "random", provider: "rule34", tags: ["landscape", "jacket"])
        let wanted = Post(key: "rule34:wanted", id: "wanted", provider: "rule34", tags: ["chun_li", "qipao"])
        let blocked = Post(key: "rule34:blocked", id: "blocked", provider: "rule34", tags: ["chun_li", "furry_female"])
        let taste = TasteChoice(done: true, into: ["chun_li"], notInto: ["furry"])
        let served = await engine.rankFast([unrelated, blocked, wanted], taste: taste, recent: [], strict: true)
        XCTAssertEqual(served.map(\.stableID), [wanted.stableID])
        let broad = await engine.rankFast([unrelated, wanted], taste: taste, recent: [])
        XCTAssertEqual(broad.count, 2)
        let empty = await engine.rankFast([unrelated], taste: taste, recent: [], strict: true)
        XCTAssertTrue(empty.isEmpty, "Never fill explicit interests with unrelated posts")
    }

    func testStrongFavoriteCanRescueRelatedContentWithoutExactSelectedTag() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let favorites = (0..<3).map {
            Post(key: "rule34:fav-\($0)", id: "fav-\($0)", provider: "rule34",
                 tags: ["chun_li", "qipao"])
        }
        await engine.configureFavorites(favorites)
        let related = Post(key: "rule34:related", id: "related", provider: "rule34", tags: ["qipao"])
        let taste = TasteChoice(done: true, into: ["chun_li"], notInto: [])
        let result = await engine.rankFast([related], taste: taste, recent: [], strict: true)
        XCTAssertEqual(result.map(\.stableID), [related.stableID])
    }

    func testLegacyCharacterPlusFranchiseDoesNotCauseUnrelatedFranchiseRecommendations() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let wanted = Post(key: "rule34:character", id: "character", provider: "rule34",
                          tags: ["chun_li", "street_fighter"])
        let unrelated = Post(key: "rule34:franchise", id: "franchise", provider: "rule34",
                             tags: ["street_fighter", "juri_han"])
        let taste = TasteChoice(done: true, into: ["chun_li", "street_fighter"], notInto: [])
        let ranked = await engine.rankFast([unrelated, wanted], taste: taste,
                                           recent: [], strict: true)
        XCTAssertEqual(ranked.map(\.stableID), [wanted.stableID])
    }

    func testLearnedFavoritesRequireRepeatedSupportBeforeStrictGating() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let unrelated = Post(key: "rule34:landscape", id: "landscape", provider: "rule34",
                             tags: ["landscape"])
        let related = Post(key: "rule34:qipao", id: "qipao", provider: "rule34", tags: ["qipao"])
        await engine.configureFavorites([Post(key: "rule34:single", id: "single",
                                            provider: "rule34", tags: ["qipao"])])
        let early = await engine.rankFast([unrelated, related], taste: TasteChoice(),
                                         recent: [], strict: true)
        XCTAssertEqual(early.count, 2, "One favorite is not enough to hard-filter a cold-start feed")
        let favorites = (0..<3).map { index in
            Post(key: "rule34:favorite-\(index)", id: "favorite-\(index)",
                 provider: "rule34", tags: ["qipao"])
        }
        await engine.configureFavorites(favorites)
        let later = await engine.rankFast([unrelated, related], taste: TasteChoice(),
                                         recent: [], strict: true)
        XCTAssertEqual(later.map(\.stableID), [related.stableID])
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
        XCTAssertTrue(requests[2].focused, "The first three acquisition attempts are interest-focused")
        XCTAssertFalse(requests[3].focused, "Every fourth request explores broadly")
        XCTAssertTrue(requests.allSatisfy { $0.query.excluded.contains("blocked") })
        let after = await engine.snapshot()
        XCTAssertEqual(after.profiles, before.profiles)
    }
    func testBoundedLookAheadKeepsAllUniqueAllowedPostsAndPreferencesFirst() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        var posts: [Post] = []
        for index in 0..<240 {
            let tag: String = index == 239 ? "engineering" : (index == 238 ? "blocked" : "topic_\(index % 30)")
            posts.append(Post(key: "rule34:\(index)", id: String(index), provider: "rule34", tags: [tag]))
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

    func testSearchControlsDoNotBecomeTasteInterests() async {
        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        await engine.recordSearch(provider: .rule34, query: "sort:score:desc engineering -blocked rating:explicit score:>=50")
        let state = await engine.snapshot()
        XCTAssertEqual(state.profiles["rule34"]?.recentQueries.last, "engineering -blocked")
        XCTAssertGreaterThan(state.profiles["rule34"]?.terms["engineering"] ?? 0, 0)
        for term in ["sort", "score", "desc", "rating", "explicit"] { XCTAssertNil(state.profiles["rule34"]?.terms[term]) }
    }
}
