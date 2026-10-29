import Foundation
import XCTest
@testable import QuicktickNative

final class IRLVideoFrameSamplerTests: XCTestCase {
    func testEligibilityDoesNotMistakeAnimeOrGenericVideoForIRL() {
        let unknown = Post(key: "1", id: "1", provider: "redgifs", tags: ["solo"], type: "video")
        let anime = Post(key: "2", id: "2", provider: "redgifs", tags: ["2d"], type: "video")
        XCTAssertEqual(VisualDomain.classify(unknown), .realLife)
        XCTAssertTrue(IRLVideoFrameSamplingPlan.eligible(unknown, domain: .uncertain))
        XCTAssertFalse(IRLVideoFrameSamplingPlan.eligible(anime, domain: .anime))
        XCTAssertFalse(IRLVideoFrameSamplingPlan.eligible(
            Post(key: "3", id: "3", provider: "redgifs", type: "image"), domain: .uncertain))
    }

    func testFrameTimesRemainBoundedAndOrdered() {
        XCTAssertTrue(IRLVideoFrameSamplingPlan.times(duration: 2).isEmpty)
        let ticks = IRLVideoFrameSamplingPlan.times(duration: 30)
        XCTAssertEqual(ticks.count, 3)
        XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { pair in pair.0 < pair.1 })
        XCTAssertLessThan(IRLVideoFrameSamplingPlan.times(duration: 800).last ?? 999, 90)
    }

    func testEmbeddingFusionAndSceneConsensus() throws {
        let fused = IRLVideoFrameSamplingPlan.centroid([[1, 0, 0], [0, 1, 0]])
        XCTAssertEqual(fused[0], fused[1], accuracy: 0.00001)
        XCTAssertEqual(sqrt(fused.reduce(Float(0)) { $0 + $1 * $1 }), 1, accuracy: 0.00001)
        let accepted = IRLVideoFrameSamplingPlan.consensus([
            ["setting:indoor": 0.9, "setting:street": 0.9],
            ["setting:indoor": 0.8],
            ["setting:indoor": 0.7, "setting:other": 0.9]
        ])
        XCTAssertNotNil(accepted["setting:indoor"])
        XCTAssertNil(accepted["setting:street"])
        let feature = VisualFeatures(domain: .realLife, embedding: fused, sampledVideoFrames: 2)
        XCTAssertEqual(try JSONDecoder().decode(VisualFeatures.self,
            from: JSONEncoder().encode(feature)), feature)
    }
}
