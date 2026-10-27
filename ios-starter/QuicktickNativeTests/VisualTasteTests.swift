import XCTest
import CoreGraphics
@testable import QuicktickNative

final class VisualTasteTests: XCTestCase {
    func testGalaxyPaletteIsSelectableAndHasDistinctNebulaGradient() {
        XCTAssertTrue(AppTheme.AccentPalette.allCases.contains(.galaxy))
        XCTAssertEqual(AppTheme.AccentPalette(rawValue: "galaxy"), .galaxy)
        XCTAssertEqual(AppTheme.AccentPalette.galaxy.gradientColors.count, 3)
        XCTAssertEqual(AppTheme.AccentPalette.violet.gradientColors.count, 2)
    }

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
        XCTAssertEqual(StudioCanvasSize.allCases.map(\.label), ["Small", "Medium", "Large"])
        XCTAssertEqual(StudioCanvasSize.allCases.map(\.longestEdge), [512, 768, 1024])
        XCTAssertEqual(StudioCanvasSize.closest(to: 896), .medium)
        for ratio in StudioAspectRatio.allCases {
            let size = ratio.nativePixelDimensions(longestEdge: 896)
            XCTAssertEqual(max(size.width, size.height), 896)
            XCTAssertEqual(size.width % 64, 0)
            XCTAssertEqual(size.height % 64, 0)
            XCTAssertGreaterThanOrEqual(min(size.width, size.height), 256)
        }
        XCTAssertEqual(StudioAspectRatio.story.nativePixelDimensions(longestEdge: 512).width, 320)
        XCTAssertEqual(StudioAspectRatio.tall.nativePixelDimensions(longestEdge: 1024).width, 512)
        XCTAssertEqual(StudioAspectRatio.tall.nativePixelDimensions(longestEdge: 1024).height, 1024)
        let portrait = StudioAspectRatio.story.nativePixelDimensions(longestEdge: StudioCanvasSize.medium.longestEdge)
        XCTAssertEqual(portrait.width, 448)
        XCTAssertEqual(portrait.height, 768)
    }

    func testStyleLoRATriggerWordsDoNotDuplicatePromptTags() {
        let result = StudioLoRATriggers.applying(["watercolor, painterly", "watercolor", "Painterly"],
            to: "portrait of a character, painterly background")
        XCTAssertEqual(result, "watercolor, portrait of a character, painterly background")
        XCTAssertEqual(StudioLoRATriggers.applying([], to: "portrait"), "portrait")
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
    func testCreditedArchiveArtistBecomesIdentityButPhotoUploaderDoesNot() throws {
        var kemono = Post(key: "kemono:42", id: "42", provider: "kemono", tags: ["sitting", "indoors"], type: "image")
        kemono.creator = "Studio Artist"
        XCTAssertEqual(ArtistAttribution.credited(in: kemono), ["studio_artist"])
        let anime = try XCTUnwrap(VisualFeatures.metadata(kemono))
        XCTAssertEqual(anime.artists, ["studio_artist"])

        var comic = Post(key: "nhentai:17", id: "17", provider: "nhentai", tags: ["manga", "kneeling"], type: "image")
        comic.creator = "Studio Artist"
        XCTAssertEqual(VisualFeatures.metadata(comic)?.artists, ["studio_artist"])

        var real = Post(key: "coomer:55", id: "55", provider: "coomer", tags: ["photo"], type: "image")
        real.creator = "Studio Artist"
        XCTAssertEqual(ArtistAttribution.credited(in: real), ["studio_artist"])
        XCTAssertTrue(VisualFeatures.metadata(real)?.artists?.isEmpty ?? true)
    }

    func testArtistPreferencesDecodeFromLegacyChoiceAndRoundTrip() throws {
        let old = try JSONDecoder().decode(TasteChoice.self, from: Data(#"{"done":true,"into":["pose"]}"#.utf8))
        XCTAssertTrue(old.artists.isEmpty)
        let chosen = TasteChoice(done: true, into: ["pose"], artists: ["artist_one"])
        XCTAssertEqual(try JSONDecoder().decode(TasteChoice.self, from: JSONEncoder().encode(chosen)).artists, ["artist_one"])
    }
    func testBundledArtistTaxonomyAndLegacyProfileMigration() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "visual-tag-taxonomy", withExtension: "json"))
        let taxonomy = try JSONDecoder().decode(VisualTagTaxonomy.self, from: Data(contentsOf: url))
        XCTAssertFalse(taxonomy.artists.isEmpty); XCTAssertFalse(taxonomy.characters.isEmpty)
        XCTAssertFalse(taxonomy.artists.contains("unknown_artist"))
        let old = try JSONDecoder().decode(VisualProfile.self, from: Data("{}".utf8))
        XCTAssertTrue(old.artists.isEmpty)
    }
    func testHistoricalFavoriteGainsArtistWithoutPixelsOrDuplicateLikes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        let post = Post(key: "history", id: "1", provider: "rule34", tags: ["2d", "artist:sample_artist", "character:sample_character", "long_hair"], type: "image")
        await service.record(.like, post: post)
        await service.analyzeFavorite(post, useVision: false)
        await service.analyzeFavorite(post, useVision: false)
        let state = await service.snapshot()
        XCTAssertEqual(state.profiles["rule34|anime"]?.artists["sample_artist"]?.positive, 0.5)
        XCTAssertEqual(state.profiles["rule34|anime"]?.subjects["sample_character"]?.positive, 0.7)
        XCTAssertNil(state.profiles["redgifs|realLife"])
        let restored = await VisualAnalysisService(directory: directory).snapshot()
        XCTAssertEqual(restored.profiles, state.profiles)
    }
    func testVisualContextAffectsFastFeedRankingAndCandidatesBeyond128() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        for number in 0..<4 {
            let liked = Post(key: "rule34:visual-like-\(number)", id: "like-\(number)", provider: "rule34",
                             tags: ["2d", "chun_li", "qipao", "looking_at_viewer"], type: "image")
            await service.record(.like, post: liked, queueAnalysis: false)
        }
        let wrongPresentation = Post(key: "rule34:visual-other", id: "other", provider: "rule34",
                                     tags: ["2d", "chun_li", "jacket", "looking_away"], type: "image")
        let preferred = Post(key: "rule34:visual-preferred", id: "preferred", provider: "rule34",
                             tags: ["2d", "chun_li", "qipao", "looking_at_viewer"], type: "image")
        let fillers = (0..<180).map { index in
            Post(key: "rule34:visual-filler-\(index)", id: "filler-\(index)", provider: "rule34",
                 tags: ["2d", "other_tag"], type: "image")
        }
        let scores = await service.scores(fillers + [wrongPresentation, preferred])
        XCTAssertNotNil(scores[preferred.stableID], "The full ranking window must receive cached visual scores")
        XCTAssertGreaterThan(scores[preferred.stableID] ?? 0, scores[wrongPresentation.stableID] ?? 0)

        let engine = RecommendationEngine(semantic: SemanticRecommender(enabled: false))
        let ranked = await engine.rankFast([wrongPresentation, preferred], taste: TasteChoice(),
                                           recent: [], visualScores: scores)
        XCTAssertEqual(ranked.first?.stableID, preferred.stableID)
    }
    func testHavenCatalogAndSavedVideosUseDeferredAnimeWDTagger() {
        let haven = Post(key: "hhaven:12", id: "12", provider: "hhaven", tags: ["hentai"],
                         thumbUrl: "https://cdn.hentaihaven.app/thumb.jpg", type: "video")
        let legacy = Post(key: "hhaven:13", id: "13", provider: "hhaven",
                          thumbUrl: haven.thumbUrl, type: "video")
        for post in [haven, legacy] {
            XCTAssertEqual(VisualDomain.classify(post), .anime)
            XCTAssertTrue(AnimeVisualRecommendationPolicy.usesWDTagger(post, domain: .anime))
            XCTAssertTrue(AnimeVisualRecommendationPolicy.fetchesIdlePreview(post, domain: .anime,
                favorite: false, disliked: false, lightweight: false))
            XCTAssertFalse(AnimeVisualRecommendationPolicy.fetchesIdlePreview(post, domain: .anime,
                favorite: false, disliked: false, lightweight: true))
            XCTAssertEqual(VisualPreviewLoader.thumbnailURL(post)?.absoluteString, haven.thumbUrl)
        }
        let real = Post(key: "coomer:1", id: "1", provider: "coomer", type: "video")
        XCTAssertFalse(AnimeVisualRecommendationPolicy.usesWDTagger(real, domain: .realLife))
        XCTAssertFalse(AnimeVisualRecommendationPolicy.fetchesIdlePreview(real, domain: .realLife,
            favorite: false, disliked: false, lightweight: false))
        let audio = Post(key: "hhaven:audio", id: "audio", provider: "hhaven", type: "audio")
        XCTAssertFalse(AnimeVisualRecommendationPolicy.usesWDTagger(audio, domain: .anime))
    }
    func testHavenWDVisualSignalsImproveRankingBeyondAnimeTitleTags() async {
        let labels = [WDAnimeTagger.Label(name: "long_hair", category: 0),
                      WDAnimeTagger.Label(name: "blue_eyes", category: 0),
                      WDAnimeTagger.Label(name: "character_one", category: 4)]
        let signals = WDAnimeTagger.signals(labels: labels, probabilities: [0.95, 0.9, 0.96])
        var liked = VisualFeatures(domain: .anime, subjects: ["title_character"])
        AnimeVisualRecommendationPolicy.mergeWD(signals, into: &liked)
        XCTAssertEqual(liked.subjects, ["character_one", "title_character"])
        XCTAssertNotNil(liked.attributes["appearance:long_hair"])
        XCTAssertEqual(liked.conceptEvidence?["character:character_one"]?.origin, "wd-v3-high-confidence")
        var profile = VisualProfile()
        profile.record(.like, features: liked)
        var matched = VisualFeatures(domain: .anime)
        AnimeVisualRecommendationPolicy.mergeWD(signals, into: &matched)
        let unmatched = VisualFeatures(domain: .anime, attributes: ["appearance:short_hair": 0.9])
        XCTAssertGreaterThan(profile.score(matched), profile.score(unmatched))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VisualAnalysisService(directory: directory)
        let post = Post(key: "hhaven:liked", id: "liked", provider: "hhaven",
                        tags: ["hentai", "long_hair"], type: "video")
        await service.record(.like, post: post, queueAnalysis: false)
        let candidate = Post(key: "hhaven:candidate", id: "candidate", provider: "hhaven",
                             tags: ["hentai", "long_hair"], type: "video")
        let scores = await service.scores([candidate])
        XCTAssertGreaterThan(scores[candidate.stableID] ?? 0, 0,
            "Haven visual profiles must score future Haven candidates independently of Rule34")
    }
    func testVisualDiscoveryAlternatesWithBroadExplorationAndRespectsExclusions() {
        let queries = [["sample_character_one", "2d"], ["sample_artist", "2d"], ["sample_character_two", "2d"]]
        XCTAssertNil(VisualDiscoveryPolicy.query(round: 1, queries: queries, excluded: []))
        XCTAssertEqual(VisualDiscoveryPolicy.query(round: 2, queries: queries, excluded: []), queries[0])
        XCTAssertNil(VisualDiscoveryPolicy.query(round: 3, queries: queries, excluded: []))
        XCTAssertEqual(VisualDiscoveryPolicy.query(round: 7, queries: queries, excluded: []), queries[1])
        XCTAssertEqual(VisualDiscoveryPolicy.query(round: 12, queries: queries,
                                                   excluded: ["sample_character_one", "sample_artist"]), queries[2])
        XCTAssertNil(VisualDiscoveryPolicy.query(round: 12, queries: queries, excluded: ["2d"]))
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
    func testMobileCLIPOnlyTargetsExplicitPhotosOrUnknownRealLifeVideoProviders() {
        XCTAssertTrue(VisualAppearanceEncoder.prefersMobileCLIP(domain: .realLife, provider: "rule34"))
        for provider in ["pornhub", "ePorner", "redgifs"] {
            XCTAssertTrue(VisualAppearanceEncoder.prefersMobileCLIP(domain: .uncertain, provider: provider))
            XCTAssertFalse(VisualAppearanceEncoder.prefersMobileCLIP(domain: .anime, provider: provider))
            XCTAssertFalse(VisualAppearanceEncoder.prefersMobileCLIP(domain: .threeD, provider: provider))
        }
        XCTAssertFalse(VisualAppearanceEncoder.prefersMobileCLIP(domain: .uncertain, provider: "rule34"))
        let unknownVideo = Post(key: "unknown", id: "1", provider: "redgifs", tags: ["solo"], type: "video")
        XCTAssertEqual(VisualDomain.classify(unknownVideo), .realLife)
        let taggedAnime = Post(key: "anime", id: "2", provider: "redgifs", tags: ["2d", "anime"], type: "video")
        XCTAssertEqual(VisualDomain.classify(taggedAnime), .anime)
    }
    func testMobileCLIPMigrationNeverComparesOrBlendsVisionVectors() throws {
        let vision = VisualFeatures(domain: .realLife, attributes: ["setting:portrait": 1], embedding: [1, 0, 0], version: "vision-featureprint-r2-v2")
        let mobile = VisualFeatures(domain: .realLife, attributes: ["setting:portrait": 1], embedding: [0, 1, 0], version: MobileCLIPRealLifeEncoder.version)
        var profile = VisualProfile()
        profile.record(.like, features: vision)
        profile.record(.less, features: VisualFeatures(domain: .realLife, embedding: [0, 0, 1]))
        XCTAssertEqual(profile.embeddingSpace, "vision-featureprint")
        XCTAssertEqual(profile.clusters, [[1, 0, 0]])
        XCTAssertEqual(profile.negativeClusters.count, 1)
        profile.record(.like, features: mobile)
        XCTAssertEqual(profile.embeddingSpace, "mobileclip-s0-image")
        XCTAssertEqual(profile.clusters, [[0, 1, 0]])
        XCTAssertTrue(profile.negativeClusters.isEmpty)
        XCTAssertEqual(profile.attributes["setting:portrait"]?.positive, 2)
        XCTAssertGreaterThan(profile.score(mobile), profile.score(vision))
        profile.record(.like, features: vision)
        XCTAssertEqual(profile.clusters, [[0, 1, 0]])
        let restored = try JSONDecoder().decode(VisualProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
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
    func testWDV3SexualActionInferenceRequiresHighConfidence() {
        let labels = [WDAnimeTagger.Label(name: "fellatio", category: 0),
            WDAnimeTagger.Label(name: "oral_sex", category: 0),
            WDAnimeTagger.Label(name: "kissing", category: 0),
            WDAnimeTagger.Label(name: "oral_sex", category: 9)]
        let result = WDAnimeTagger.signals(labels: labels, probabilities: [0.7, 0.92, 0.9, 0.99])
        XCTAssertEqual(result.attributes["act:oral"] ?? -1, Double(Float(0.92)) * 0.8, accuracy: 0.0001)
        XCTAssertNotNil(result.attributes["act:kissing"])
        XCTAssertFalse(result.subjects.contains("oral_sex"))
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
