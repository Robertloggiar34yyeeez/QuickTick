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

    func testImmersivePreparesTwoClipsAndRetainsPrevious() {
        XCTAssertEqual(ImmersivePreloadPlan.retainedIndices(current: 2, count: 6), [1, 2, 3, 4])
        XCTAssertEqual(ImmersivePreloadPlan.forwardIndices(current: 2, count: 6), [3, 4])
        XCTAssertEqual(ImmersivePreloadPlan.forwardIndices(current: 5, count: 6), [])
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
