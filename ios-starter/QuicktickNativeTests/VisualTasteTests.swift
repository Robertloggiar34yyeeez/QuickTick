import XCTest
import CoreGraphics
@testable import QuicktickNative

final class VisualTasteTests: XCTestCase {
    func testStudioFavoritePromptKeepsOneCharacterOneSceneAndOnePose() {
        let seed = StudioPromptSeed(
            characters: ["chun_li", "samus_aran"], artists: ["favorite_artist"],
            attributes: ["blonde_hair", "black_hair", "leaning_forward", "sitting", "at_viewer", "away"],
            scenes: ["indoors", "outdoors"])
        let prompt = seed.prompt
        XCTAssertTrue(prompt.contains("chun li"))
        XCTAssertTrue(prompt.contains("leaning forward"))
        XCTAssertTrue(prompt.contains("looking at viewer"))
        XCTAssertTrue(prompt.contains("indoors"))
        XCTAssertFalse(prompt.contains("samus"))
        XCTAssertFalse(prompt.contains("blonde"))
        XCTAssertFalse(prompt.contains("black hair"))
        XCTAssertFalse(prompt.contains("outdoors"))
        XCTAssertFalse(prompt.contains("sitting"))
        XCTAssertFalse(prompt.contains("looking away"))
    }

    func testStudioAnimaResolutionsAreNativeAndAligned() {
        for ratio in StudioAspectRatio.allCases {
            let size = ratio.nativePixelDimensions(longestEdge: 896)
            XCTAssertEqual(max(size.width, size.height), 896)
            XCTAssertEqual(size.width % 16, 0)
            XCTAssertEqual(size.height % 16, 0)
            XCTAssertGreaterThanOrEqual(min(size.width, size.height), 256)
        }
    }

    func testArtistsCharactersAndAttributesLearnIndependently() throws {
        let taxonomy = VisualTagTaxonomy(version: "fixture", artists: ["credited_artist"], characters: ["new_character"])
        var post = Post(key: "art", id: "1", provider: "rule34", mediaUrl: "", type: "image")
        post.tags = ["credited_artist", "new_character", "long_hair"]
        let features = try XCTUnwrap(VisualFeatures.metadata(post, taxonomy: taxonomy))
        XCTAssertEqual(features.artists, ["credited_artist"])
        XCTAssertEqual(features.subjects, ["new_character"])
        var profile = VisualProfile()
        profile.record(.like, features: features)
        profile.record(.less, features: VisualFeatures(domain: .anime, attributes: ["clothing:jacket": 1],
            subjects: ["new_character"], artists: ["credited_artist"]))
        XCTAssertEqual(profile.subjects["new_character"]?.negative, 0)
        XCTAssertEqual(profile.artists["credited_artist"]?.negative, 0)
        XCTAssertNotNil(profile.interactions["artist:credited_artist|appearance:long_hair"])
        XCTAssertGreaterThan(profile.score(VisualFeatures(domain: .anime, attributes: ["appearance:long_hair": 1], subjects: ["unseen"])),
            profile.score(VisualFeatures(domain: .anime, attributes: ["clothing:jacket": 1], subjects: ["unseen"])))
        let restored = try JSONDecoder().decode(VisualProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
        let realPost = Post(key: "real", id: "2", provider: "redgifs", tags: post.tags, mediaUrl: "", type: "image")
        let real = try XCTUnwrap(VisualFeatures.metadata(realPost, taxonomy: taxonomy))
        XCTAssertTrue(real.subjects.isEmpty); XCTAssertTrue((real.artists ?? []).isEmpty)
    }
    func testBundledArtistTaxonomyAndLegacyProfileMigration() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "visual-tag-taxonomy", withExtension: "json"))
        let taxonomy = try JSONDecoder().decode(VisualTagTaxonomy.self, from: Data(contentsOf: url))
        XCTAssertTrue(taxonomy.artists.contains("palcomix")); XCTAssertTrue(taxonomy.characters.contains("chun-li"))
        XCTAssertFalse(taxonomy.artists.contains("unknown_artist"))
        let old = try JSONDecoder().decode(VisualProfile.self, from: Data("{}".utf8))
        XCTAssertTrue(old.artists.isEmpty)
    }
    func testHistoricalFavoriteGainsArtistWithoutPixelsOrDuplicateLikes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        let post = Post(key: "history", id: "1", provider: "rule34", tags: ["2d", "palcomix", "chun-li", "long_hair"], type: "image")
        await service.record(.like, post: post)
        await service.analyzeFavorite(post, useVision: false)
        await service.analyzeFavorite(post, useVision: false)
        let state = await service.snapshot()
        XCTAssertEqual(state.profiles["rule34|anime"]?.artists["palcomix"]?.positive, 0.5)
        XCTAssertEqual(state.profiles["rule34|anime"]?.subjects["chun_li"]?.positive, 0.7)
        XCTAssertNil(state.profiles["redgifs|realLife"])
        let restored = await VisualAnalysisService(directory: directory).snapshot()
        XCTAssertEqual(restored.profiles, state.profiles)
    }
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
    func testWDV3SeparatesCharactersAttributesAndRatings() {
        let labels = [WDAnimeTagger.Label(name: "chun-li_(street_fighter)", category: 4),
            WDAnimeTagger.Label(name: "long_hair", category: 0), WDAnimeTagger.Label(name: "qipao", category: 0),
            WDAnimeTagger.Label(name: "rating", category: 9), WDAnimeTagger.Label(name: "uncertain_character", category: 4)]
        let result = WDAnimeTagger.signals(labels: labels, probabilities: [0.96, 0.9, 0.85, 0.99, 0.4])
        XCTAssertEqual(result.subjects, ["chun_li"])
        XCTAssertNotNil(result.attributes["appearance:long_hair"]); XCTAssertNotNil(result.attributes["clothing:qipao"])
        XCTAssertFalse(result.attributes.keys.contains { $0.contains("rating") })
    }
    func testWDV3ActionLabelsUnifyWithProviderPoseAndGaze() {
        let labels = [WDAnimeTagger.Label(name: "looking_at_viewer", category: 0),
            WDAnimeTagger.Label(name: "bent_over", category: 0),
            WDAnimeTagger.Label(name: "looking_away", category: 0)]
        let result = WDAnimeTagger.signals(labels: labels, probabilities: [0.88, 0.83, 0.22])
        XCTAssertNotNil(result.attributes["gaze:at_viewer"])
        XCTAssertNotNil(result.attributes["pose:leaning_forward"])
        XCTAssertNil(result.attributes["gaze:away"])
    }
    func testBundledWDV3RunsOnlyForAnimeAndReleasesModel() async throws {
        let tagger = WDAnimeTagger(), sample = image(red: 0.7, green: 0.4, blue: 0.2)
        let real = await tagger.analyze(sample, domain: .realLife)
        XCTAssertNil(real)
        let before = await tagger.loadCount; XCTAssertEqual(before, 0)
        let anime = await tagger.analyze(sample, domain: .anime)
        XCTAssertNotNil(anime, "Pinned WD Tagger v3 must be bundled and runnable")
        let loads = await tagger.loadCount; XCTAssertEqual(loads, 1)
        let retained = await tagger.retainsModel; XCTAssertFalse(retained)
        let ms = await tagger.inferenceMs
        print("QUICKTICK_METRIC wd_v3_fixture_inference_ms=\(ms)")
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
