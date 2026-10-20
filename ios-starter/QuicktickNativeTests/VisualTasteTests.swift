import XCTest
import CoreGraphics
@testable import QuicktickNative

final class VisualTasteTests: XCTestCase {
    private func image(red: CGFloat, green: CGFloat, blue: CGFloat) -> DecodedMediaImage {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        return DecodedMediaImage(image: context.makeImage()!, nativeSize: CGSize(width: 128, height: 128), comic: false)
    }
    func testPixelAttributesGeneralizeAcrossUnknownSubjects() {
        let red = VisualAppearanceEncoder.attributes(image(red: 1, green: 0, blue: 0).image)
        let blue = VisualAppearanceEncoder.attributes(image(red: 0, green: 0, blue: 1).image)
        XCTAssertNotNil(red["color:red"]); XCTAssertNotNil(blue["color:blue"])
        var profile = VisualProfile()
        profile.record(.like, features: VisualFeatures(domain: .anime, attributes: red, subjects: ["first_character"]))
        let unseenRed = VisualFeatures(domain: .anime, attributes: red, subjects: ["unseen_character"])
        let unseenBlue = VisualFeatures(domain: .anime, attributes: blue, subjects: ["unseen_character"])
        XCTAssertGreaterThan(profile.score(unseenRed), profile.score(unseenBlue))
    }
    func testIndependentVisualPositiveNegativeAndExposureClusters() throws {
        var profile = VisualProfile()
        let liked = VisualFeatures(domain: .realLife, embedding: [1, 0, 0])
        let disliked = VisualFeatures(domain: .realLife, embedding: [0, 1, 0])
        profile.record(.like, features: liked); profile.record(.less, features: disliked)
        profile.record(.impression, features: liked)
        XCTAssertEqual(profile.clusters.count, 1); XCTAssertEqual(profile.negativeClusters.count, 1)
        XCTAssertEqual(profile.exposureClusters.count, 1)
        XCTAssertGreaterThan(profile.score(liked), profile.score(disliked))
        let restored = try JSONDecoder().decode(VisualProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
        let legacy = try JSONDecoder().decode(VisualProfile.self, from: Data("{\"clusters\":[[1,0]]}".utf8))
        XCTAssertTrue(legacy.negativeClusters.isEmpty); XCTAssertEqual(legacy.clusters.count, 1)
    }
    func testKnownLikedIdentityDoesNotCreateWholeImageNegativeCluster() {
        var profile = VisualProfile()
        let liked = VisualFeatures(domain: .anime, attributes: ["clothing:qipao": 1], subjects: ["chun_li"], embedding: [1, 0])
        let disliked = VisualFeatures(domain: .anime, attributes: ["clothing:jacket": 1], subjects: ["chun_li"], embedding: [0.95, 0.05])
        profile.record(.like, features: liked); profile.record(.less, features: disliked)
        XCTAssertTrue(profile.negativeClusters.isEmpty)
        XCTAssertGreaterThan(profile.score(liked), profile.score(disliked))
    }
    func testBuiltInVisionProducesBoundedNormalizedEmbedding() async throws {
        let start = Date()
        let encoded = try await VisualAppearanceEncoder.embedding(image(red: 0.7, green: 0.2, blue: 0.1))
        XCTAssertFalse(encoded.vector.isEmpty); XCTAssertLessThanOrEqual(encoded.vector.count, 2048)
        let norm = sqrt(encoded.vector.reduce(Float(0)) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1, accuracy: 0.001)
        print("QUICKTICK_METRIC vision_fixture_ms=\(Date().timeIntervalSince(start) * 1000) dimensions=\(encoded.vector.count)")
    }
    func testPreviewSelectionNeverDownloadsOriginalsOrVideo() {
        var post = Post(key: "video", id: "1", provider: "redgifs", mediaUrl: "https://cdn.test/full.mp4", previewUrl: "https://cdn.test/animated.gif", type: "video")
        XCTAssertNil(VisualPreviewLoader.thumbnailURL(post))
        post.thumbUrl = "https://cdn.test/small.jpg"
        XCTAssertEqual(VisualPreviewLoader.thumbnailURL(post)?.lastPathComponent, "small.jpg")
    }
    @MainActor func testScrollingPreventsTailRankingAndPreservesOrder() async {
        let store = AppStore()
        let a = Post(key: "a", id: "1", provider: "rule34", tags: ["other"])
        let b = Post(key: "b", id: "2", provider: "rule34", tags: ["favorite"])
        store.posts = [a, b]; store.protectVisibleHomePosts([a.stableID])
        await store.recommendations.record(.like, post: b)
        store.noteFeedMotion()
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(store.posts, [a, b])
        store.selectedProvider = .eporner
    }
}
