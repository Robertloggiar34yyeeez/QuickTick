import Foundation
import XCTest
@testable import QuicktickNative

final class RecommendationExperienceRegressionTests: XCTestCase {
    @MainActor func testRetiredHavenSelectionMigratesToHanime() {
        let store = AppStore()
        store.selectedProvider = .hhaven
        XCTAssertEqual(store.selectedProvider, .hanime)
    }

    func testIPadImmersiveRecognizesShortVerticalFlicksWithoutDiagonalPaging() {
        let height: CGFloat = 1_080
        XCTAssertEqual(ImmersivePageSwipePolicy.direction(
            translation: CGSize(width: 9, height: -56),
            velocity: CGSize(width: 20, height: -160), viewportHeight: height), 1)
        XCTAssertEqual(ImmersivePageSwipePolicy.direction(
            translation: CGSize(width: 4, height: 26),
            velocity: CGSize(width: 25, height: 720), viewportHeight: height), -1)
        XCTAssertNil(ImmersivePageSwipePolicy.direction(
            translation: CGSize(width: 4, height: 26),
            velocity: CGSize(width: 25, height: 90), viewportHeight: height))
        XCTAssertNil(ImmersivePageSwipePolicy.direction(
            translation: CGSize(width: 95, height: 48),
            velocity: CGSize(width: 700, height: 330), viewportHeight: height))
        XCTAssertNil(ImmersivePageSwipePolicy.direction(
            translation: CGSize(width: 4, height: 8),
            velocity: CGSize(width: 0, height: 950), viewportHeight: height))
    }

    func testDockScrubReachesEveryFeedWithinShortThumbTravel() {
        let slots = [0, 1, 2, 3, 4] // Create stays in the layout, never a feed target.
        func target(_ current: Int, _ x: CGFloat, _ y: CGFloat = 0) -> Int? {
            TabSwipePolicy.scrubDestination(current: current,
                translation: CGSize(width: x, height: y), vertical: false,
                axisLength: 390, visibleIndices: slots, accelerated: true)
        }
        XCTAssertEqual(target(0, 32), 1)
        XCTAssertEqual(target(0, 65), 2)
        XCTAssertEqual(target(0, 118), 3)
        XCTAssertEqual(target(3, -32), 2)
        XCTAssertNil(target(0, -100)) // Beyond the Home end.
        XCTAssertNil(target(1, 10)) // Below the deliberate-drag threshold.
        XCTAssertNil(target(1, 90, 85)) // Media-like diagonal drag.
    }

    func testIPadSideRailAcceleratesAndHiddenCreateClosesItsGap() {
        let allTabs = [0, 1, 2, 3, 4]
        func side(_ current: Int, _ y: CGFloat) -> Int? {
            TabSwipePolicy.scrubDestination(current: current,
                translation: CGSize(width: 1, height: y), vertical: true,
                axisLength: 260, visibleIndices: allTabs, accelerated: true)
        }
        XCTAssertNil(side(1, 28))
        XCTAssertEqual(side(1, 65), 2)
        XCTAssertEqual(side(1, 95), 3)
        XCTAssertEqual(side(1, 220), 3)
        XCTAssertEqual(side(1, -55), 0)
        XCTAssertNil(side(3, 90))

        XCTAssertEqual(TabSwipePolicy.scrubDestination(current: 1,
            translation: CGSize(width: 28, height: 2), vertical: false,
            axisLength: 388, visibleIndices: [0, 1, 3, 4], accelerated: true), 2)
        let position = TabSwipePolicy.indicatorPosition(current: 0,
            translation: CGSize(width: 35, height: 0), vertical: false,
            axisLength: 390, visibleIndices: allTabs, accelerated: true)
        XCTAssertEqual(position, 131.75, accuracy: 0.01)
    }

    func testPhoneDockKeepsOriginalUnacceleratedTabDistances() {
        let slots = [0, 1, 2, 3, 4]
        func phone(_ dx: CGFloat) -> Int? {
            TabSwipePolicy.scrubDestination(current: 0,
                translation: CGSize(width: dx, height: 0), vertical: false,
                axisLength: 390, visibleIndices: slots)
        }
        XCTAssertEqual(phone(85), 1)
        XCTAssertEqual(phone(172), 2)
        XCTAssertEqual(phone(290), 3)
        XCTAssertNil(phone(14))
        let indicator = TabSwipePolicy.indicatorPosition(current: 0,
            translation: CGSize(width: 85, height: 0), vertical: false,
            axisLength: 390, visibleIndices: slots)
        XCTAssertEqual(indicator, 124, accuracy: 0.01)
    }

    @MainActor func testTypedArtistSelectionCanBeSavedFromTagsWithoutPrefix() {
        let store = AppStore()
        let post = Post(key: "rule34:typed-artist", id: "typed-artist", provider: "rule34",
                        tags: ["sample_artist", "chun_li", "sitting"], type: "image")
        store.preferArtist("sample_artist", from: post)
        XCTAssertTrue(store.tasteChoice(for: .rule34).artists.contains("sample_artist"))
    }

    @MainActor func testChangingProviderDropsStaleArchiveCreatorRoute() {
        let store = AppStore()
        store.commitSearch(query: "creator:fanbox:42", sort: "recommended")
        store.selectedProvider = .kemono
        XCTAssertEqual(store.queryText, "")
        XCTAssertEqual(store.selectedProvider, .kemono)
    }

    @MainActor func testSuggestedTopicSurvivesTabReturnAndCanBeCleared() {
        let store = AppStore()
        store.commitSuggestedTopic("space_opera", excluded: [])
        XCTAssertEqual(store.selectedTopicTerm, "space_opera")
        XCTAssertFalse(store.queryText.isEmpty)

        _ = store.beginFeedTabSelection(1)
        _ = store.beginFeedTabSelection(0)
        XCTAssertEqual(store.selectedTopicTerm, "space_opera")

        // The persistent Home filter chip uses the same reset path.
        store.commitSearch(query: "", sort: "recommended")
        XCTAssertNil(store.selectedTopicTerm)
        XCTAssertEqual(store.queryText, "")
        XCTAssertEqual(store.feedSort, "recommended")
    }
    func testPullRefreshRequiresTopOriginBeforeSwipe() {
        var gate = HomePullRefreshGate()
        gate.observe(startOffset: -420)
        XCTAssertFalse(gate.finish(translation: CGSize(width: 0, height: 520)))
        gate.observe(startOffset: 10)
        XCTAssertTrue(gate.finish(translation: CGSize(width: 0, height: 115)))
        gate.observe(startOffset: nil)
        XCTAssertFalse(gate.finish(translation: CGSize(width: 0, height: 130)))
    }

    func testImmersivePreparesTwoUpcomingClipsAndRetainsPrevious() {
        XCTAssertEqual(ImmersivePreloadPlan.retainedIndices(current: 2, count: 6), [1, 2, 3, 4])
        XCTAssertEqual(ImmersivePreloadPlan.forwardIndices(current: 2, count: 6), [3, 4])
        XCTAssertEqual(ImmersivePreloadPlan.forwardIndices(current: 5, count: 6), [])
    }

    func testBroadCandidatesAreInRankersFirstWindowEvenForHugeCreatorPosts() {
        let focused = (0..<410).map { index in
            Post(key: "kemono:f:\(index)", id: "f-\(index)", provider: "kemono",
                 tags: ["repeated_creator"])
        }
        let broad = (0..<12).map { index in
            Post(key: "kemono:b:\(index)", id: "b-\(index)", provider: "kemono",
                 tags: ["discovery_artist_\(index)"])
        }
        let mixed = CandidatePoolMix.interleave(focused, broad)
        XCTAssertEqual(mixed.count, 422)
        XCTAssertEqual(mixed[0].stableID, focused[0].stableID)
        XCTAssertEqual(mixed[1].stableID, broad[0].stableID)
        XCTAssertTrue(mixed.prefix(48).contains { $0.stableID == broad[11].stableID })
        XCTAssertEqual(Set(mixed.map(\.stableID)).count, mixed.count)
    }

    func testComfortTempoCapsEvenSpamAndQuad() {
        XCTAssertEqual(RhythmTempoPlanner.maximumTapsPerSecond, 3.0)
        XCTAssertEqual(RhythmTempoPlanner.maximumBPM, 112)
        var planner = RhythmTempoPlanner()
        planner.reset(baseBPM: 240)
        XCTAssertLessThanOrEqual(planner.currentBPM, RhythmTempoPlanner.maximumBPM)
        XCTAssertLessThanOrEqual(RhythmTempoPlanner.target(mode: .spam, baseBPM: 240, section: 3,
            intensity: 1, randomness: 1, randomUnit: 1), RhythmTempoPlanner.maximumBPM)
        let interval = RhythmTempoPlanner.interval(bpm: 240, division: .quad)
        XCTAssertGreaterThanOrEqual(interval, 1 / RhythmTempoPlanner.maximumTapsPerSecond)
    }

    func testEveryFastRhythmHasARealSlowerRecoveryAfterItsPeak() {
        for (mode, peakSection, recoverySection) in [
            (RhythmPattern.fast, 1, 2), (.spam, 1, 2), (.chaos, 1, 2),
            (.progressive, 3, 4), (.adaptive, 3, 4)
        ] {
            let peak = RhythmTempoPlanner.target(mode: mode, baseBPM: 100,
                section: peakSection, intensity: 0.75, randomness: 0, randomUnit: 0.5)
            let recovery = RhythmTempoPlanner.target(mode: mode, baseBPM: 100,
                section: recoverySection, intensity: 0.75, randomness: 0, randomUnit: 0.5)
            XCTAssertTrue(RhythmTempoPlanner.isRecoverySection(mode: mode, section: recoverySection))
            XCTAssertLessThan(recovery, peak * 0.85,
                "\(mode.title) must provide a genuine slow section after its fast burst")
        }
        var phrases = RhythmPhraseSequencer()
        phrases.reset(mode: .adaptive, mixed: true)
        _ = phrases.tick(mixed: true, quarterBeats: 1)
        phrases.beginRecovery(quarterBeats: 16)
        XCTAssertEqual(phrases.current, .regular)
        for _ in 0..<10 { XCTAssertFalse(phrases.tick(mixed: true, quarterBeats: 4)) }
        XCTAssertEqual(phrases.current, .regular)
    }

    func testVisualAversionIsNotOverriddenByTags() {
        XCTAssertTrue(RecommendationQualityModel.rejects(visual: -2.2))
        XCTAssertFalse(RecommendationQualityModel.rejects(visual: -0.4))
        XCTAssertFalse(RecommendationQualityModel.rejects(visual: nil))
    }

    func testTasteWrappedCountsExplicitCharacterArtistDynamicsAndPoseWithExamples() {
        let tags = ["anime", "chun_li", "street_fighter", "artist:example_artist",
                    "femdom", "sitting"]
        let favorites = (1...3).map { index in
            Post(key: "rule34:wrapped:\(index)", id: "wrapped-\(index)", provider: "Rule34",
                 tags: tags, previewUrl: "https://example.invalid/preview-\(index).jpg", type: "image")
        }
        let sections = TasteWrappedSummary.make(from: favorites)
        func find(_ section: String, _ label: String) -> TasteWrappedMoment? {
            sections.first(where: { $0.id == section })?.moments
                .first(where: { $0.label == label })
        }
        XCTAssertEqual(find("character", "Chun Li")?.appearances, 3)
        XCTAssertEqual(find("franchise", "Street Fighter")?.appearances, 3)
        XCTAssertEqual(find("artist", "Example Artist")?.appearances, 3)
        XCTAssertEqual(find("power", "Female Dominant")?.appearances, 3)
        XCTAssertEqual(find("action", "Sitting")?.appearances, 3)
        XCTAssertNotNil(find("character", "Chun Li")?.sample.cardPreviewURL)
    }

    func testTasteWrappedIncludesIRLAndArchiveProvidersWithoutInferringIdentities() {
        var video = Post(key: "pornhub:sample", id: "sample", provider: "Pornhub",
                         tags: ["webcam", "dancing"], previewUrl: "https://example.invalid/irl.jpg",
                         type: "video")
        video.creator = "Sample Creator"
        video.category = "Studio"
        let archive = Post(key: "coomer:sample", id: "sample", provider: "Coomer",
                           tags: ["photography"], previewUrl: "https://example.invalid/archive.jpg",
                           type: "image")
        let sections = TasteWrappedSummary.make(from: [video, archive])
        let sources = sections.first(where: { $0.id == "source" })?.moments.map(\.label) ?? []
        XCTAssertTrue(sources.contains("Pornhub"))
        XCTAssertTrue(sources.contains("Coomer"))
        XCTAssertEqual(sections.first(where: { $0.id == "creator" })?.moments.first?.label,
                       "Sample Creator")
        XCTAssertNotNil(sections.first(where: { $0.id == "theme" }))
        XCTAssertNil(sections.first(where: { $0.id == "character" }),
                     "A real-life person must not be guessed to be an anime character")
    }

    func testWrappedSpotlightsUseOnlyRealLikedPostsAndHonestCounts() {
        var recent = Post(key: "hanime:recent", id: "recent", provider: "Hanime",
                          tags: ["fantasy"], thumbUrl: "https://cdn.hanime.tv/recent.webp", type: "video")
        recent.caption = "A real saved video"
        let previous = Post(key: "hanime:previous", id: "previous", provider: "Hanime",
                            tags: ["fantasy"], thumbUrl: "https://cdn.hanime.tv/previous.webp", type: "video")
        let photo = Post(key: "rule34:image", id: "image", provider: "Rule34",
                         tags: ["city"], previewUrl: "https://example.invalid/photo.jpg", type: "image")
        let favorites = [recent, previous, photo]
        let summary = TasteWrappedSummary.make(from: favorites)
        let spotlights = TasteWrappedSpotlights.make(from: favorites, sections: summary)
        XCTAssertEqual(spotlights.count, 3)
        XCTAssertEqual(spotlights.first?.headline, "You love Hanime.")
        XCTAssertTrue(spotlights.first?.detail.contains("2 of your liked posts") == true)
        XCTAssertTrue(spotlights.allSatisfy { favorites.contains($0.post) })
        XCTAssertEqual(Set(spotlights.map(\.id)).count, spotlights.count,
                       "Wrapped must never show the same post twice as a distinct favorite")
        XCTAssertTrue(TasteWrappedSpotlights.make(from: [], sections: []).isEmpty)
    }

    func testWrappedActivityUsesOnlyRecordedProviderEvents() {
        var state = RecommendationState()
        var hanime = RecommendationProfile()
        hanime.stats.watchSeconds = 3_675
        hanime.stats.replays = 2
        hanime.stats.completions = 1
        hanime.stats.downloads = 4
        state.profiles["hanime"] = hanime
        var redgifs = RecommendationProfile()
        redgifs.stats.watchSeconds = 125
        redgifs.stats.replays = 3
        redgifs.stats.completions = 2
        redgifs.stats.downloads = 1
        state.profiles["redgifs"] = redgifs
        // Scoped interests are subdivisions of these sources; counting them
        // again would double-report the user's playback history.
        state.scopedProfiles["hanime:fantasy"] = hanime

        let activity = TasteWrappedActivity.make(from: state)
        XCTAssertEqual(activity.watchSeconds, 3_800)
        XCTAssertEqual(activity.watchTime, "1 hr 3 min")
        XCTAssertEqual(activity.replays, 5)
        XCTAssertEqual(activity.completed, 3)
        XCTAssertEqual(activity.downloads, 5)
    }

    func testInterfaceSwitchUsesExistingPersistentKeyWithoutTouchingPersonalData() {
        let defaults = UserDefaults.standard
        let key = "quicktick-modern-ui-v1"
        let original = defaults.object(forKey: key)
        let favoriteFixture = "quicktick-test-interface-preserves-liked-ids"
        let previousFixture = defaults.object(forKey: favoriteFixture)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let previousFixture { defaults.set(previousFixture, forKey: favoriteFixture) }
            else { defaults.removeObject(forKey: favoriteFixture) }
        }
        defaults.set(["hanime:favorite", "rule34:favorite"], forKey: favoriteFixture)
        defaults.set(true, forKey: key)
        XCTAssertTrue(AppTheme.premium)
        defaults.set(false, forKey: key)
        XCTAssertFalse(AppTheme.premium)
        XCTAssertEqual(defaults.stringArray(forKey: favoriteFixture), ["hanime:favorite", "rule34:favorite"])
    }

    func testOptionalBirthdayOnlyMatchesTheCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let birth = calendar.date(from: DateComponents(year: 2001, month: 12, day: 24))!
        let matching = calendar.date(from: DateComponents(year: 2026, month: 12, day: 24))!
        let ordinary = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        XCTAssertTrue(BirthdayProfile.isBirthday(birth.timeIntervalSince1970, on: matching, calendar: calendar))
        XCTAssertFalse(BirthdayProfile.isBirthday(birth.timeIntervalSince1970, on: ordinary, calendar: calendar))
        XCTAssertFalse(BirthdayProfile.isBirthday(0, on: matching, calendar: calendar))
    }

    func testCrimsonAndFiveSeasonalAccentsAreSelectable() {
        for palette in [
            AppTheme.AccentPalette.crimson, .easter, .summer, .halloween, .christmas, .snow
        ] {
            XCTAssertTrue(AppTheme.AccentPalette.allCases.contains(palette))
            XCTAssertFalse(palette.name.isEmpty)
            XCTAssertGreaterThanOrEqual(palette.gradientColors.count, 2)
        }
    }

    func testSeasonalThemesFollowDatesAndLeaveOtherMonthsForManualPalette() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func theme(_ year: Int, _ month: Int, _ day: Int) -> AppTheme.AccentPalette? {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
            return SeasonalThemeSchedule.palette(for: date, calendar: calendar)
        }
        XCTAssertEqual(theme(2026, 4, 5), .easter)
        XCTAssertEqual(theme(2026, 7, 14), .summer)
        XCTAssertEqual(theme(2026, 10, 28), .halloween)
        XCTAssertEqual(theme(2026, 12, 13), .christmas)
        XCTAssertEqual(theme(2027, 1, 12), .snow)
        XCTAssertNil(theme(2026, 5, 20))
        XCTAssertNil(theme(2026, 9, 20))
        XCTAssertNil(theme(2026, 11, 20))
    }

    @MainActor func testTopicChoiceSurvivesPopularSortButManualSearchClearsIt() {
        let store = AppStore()
        store.commitSuggestedTopic("chun_li", excluded: [])
        XCTAssertEqual(store.selectedTopicTerm, "chun_li")
        XCTAssertTrue(QueryParser.parse(store.queryText).included.contains("chun_li"))
        store.commitSearch(query: store.queryText, sort: "popular")
        XCTAssertEqual(store.selectedTopicTerm, "chun_li",
                       "Popular keeps the selected topic while using unpersonalized source order")
        store.commitSearch(query: store.queryText, sort: "recommended")
        XCTAssertEqual(store.selectedTopicTerm, "chun_li",
                       "Returning to Recommended restores taste ranking within the topic")
        store.commitSearch(query: "different_topic", sort: "recommended")
        XCTAssertNil(store.selectedTopicTerm)
    }
}
