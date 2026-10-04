import XCTest
@testable import QuicktickNative

final class RecommendationTests: XCTestCase {
    func testExplicitNotIntoIsHardFilter() async {
        let engine = RecommendationEngine()
        let post = Post(key: "r:1", id: "1", provider: "rule34", tags: ["blocked_theme"], mediaUrl: "https://example.invalid/a.mp4", type: "video")
        let ranked = await engine.rank([post], taste: TasteChoice(done: true, into: [], notInto: ["blocked_theme"]), recent: [])
        XCTAssertTrue(ranked.isEmpty)
    }

    func testRecurringPositiveCommonDenominatorWins() async {
        let engine = RecommendationEngine()
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
        let engine = RecommendationEngine()
        let disliked = Post(key: "r:1", id: "1", provider: "rule34", tags: ["scat", "blue_hair", "outdoors", "solo"], mediaUrl: "https://example.invalid/1.mp4", type: "video")
        let innocent = Post(key: "r:2", id: "2", provider: "rule34", tags: ["blue_hair", "outdoors", "smile"], mediaUrl: "https://example.invalid/2.mp4", type: "video")

        await engine.record(.less, post: disliked)
        let ranked = await engine.rank([innocent], taste: TasteChoice(), recent: [])
        XCTAssertEqual(ranked.count, 1)
    }

    func testRecurringNegativeCommonDenominatorBecomesHardFilter() async {
        let engine = RecommendationEngine()
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
        let engine = RecommendationEngine()
        let blocked = Post(key: "r:1", id: "1", provider: "rule34", tags: ["blocked_theme"], mediaUrl: "https://example.invalid/1.mp4", type: "video")
        let scores = [await engine.gorseItemID(blocked): 1.0]
        let ranked = await engine.rank([blocked], taste: TasteChoice(done: true, into: [], notInto: ["blocked_theme"]), recent: [], collaborativeScores: scores)
        XCTAssertTrue(ranked.isEmpty)
    }
}
