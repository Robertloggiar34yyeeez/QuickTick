import Foundation
import XCTest
@testable import QuicktickNative

final class RecommendationExperienceRegressionTests: XCTestCase {
    @MainActor func testRemovedHanimeSelectionMigratesToHaven() {
        let store = AppStore()
        store.selectedProvider = .hanime
        XCTAssertEqual(store.selectedProvider, .hhaven)
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

    func testDockSwipeChangesOneTabWithoutTriggeringMediaGestures() {
        XCTAssertEqual(TabSwipePolicy.destination(current: 0,
            translation: CGSize(width: 90, height: 5), vertical: false), 1)
        XCTAssertEqual(TabSwipePolicy.destination(current: 2,
            translation: CGSize(width: -110, height: 2), vertical: false), 1)
        XCTAssertNil(TabSwipePolicy.destination(current: 0,
            translation: CGSize(width: -100, height: 1), vertical: false))
        XCTAssertNil(TabSwipePolicy.destination(current: 1,
            translation: CGSize(width: 90, height: 85), vertical: false))
        XCTAssertNil(TabSwipePolicy.destination(current: 1,
            translation: CGSize(width: 25, height: 4), vertical: false))
        XCTAssertEqual(TabSwipePolicy.destination(current: 1,
            translation: CGSize(width: 1, height: 95), vertical: true), 2)
        XCTAssertEqual(TabSwipePolicy.destination(current: 1,
            translation: CGSize(width: 1, height: -95), vertical: true), 0)
        XCTAssertNil(TabSwipePolicy.destination(current: 3,
            translation: CGSize(width: 1, height: 95), vertical: true))
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
}
