import Foundation
import XCTest
@testable import QuicktickNative

final class RecommendationExperienceRegressionTests: XCTestCase {
    func testPullRefreshRequiresTopOriginBeforeSwipe() {
        var gate = HomePullRefreshGate()
        gate.observe(startOffset: -420)
        XCTAssertFalse(gate.finish(translation: CGSize(width: 0, height: 520)))
        gate.observe(startOffset: 10)
        XCTAssertTrue(gate.finish(translation: CGSize(width: 0, height: 115)))
        gate.observe(startOffset: nil)
        XCTAssertFalse(gate.finish(translation: CGSize(width: 0, height: 130)))
    }

    func testImmersivePreparesOneUpcomingClipAndRetainsPrevious() {
        XCTAssertEqual(ImmersivePreloadPlan.retainedIndices(current: 2, count: 6), [1, 2, 3])
        XCTAssertEqual(ImmersivePreloadPlan.forwardIndices(current: 2, count: 6), [3])
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
        var planner = RhythmTempoPlanner()
        planner.reset(baseBPM: 240)
        XCTAssertLessThanOrEqual(planner.currentBPM, RhythmTempoPlanner.maximumBPM)
        XCTAssertLessThanOrEqual(RhythmTempoPlanner.target(mode: .spam, baseBPM: 240, section: 3,
            intensity: 1, randomness: 1, randomUnit: 1), RhythmTempoPlanner.maximumBPM)
        let interval = RhythmTempoPlanner.interval(bpm: 240, division: .quad)
        XCTAssertGreaterThanOrEqual(interval, 1 / RhythmTempoPlanner.maximumTapsPerSecond)
    }

    func testVisualAversionIsNotOverriddenByTags() {
        XCTAssertTrue(RecommendationQualityModel.rejects(visual: -2.2))
        XCTAssertFalse(RecommendationQualityModel.rejects(visual: -0.4))
        XCTAssertFalse(RecommendationQualityModel.rejects(visual: nil))
    }
}
