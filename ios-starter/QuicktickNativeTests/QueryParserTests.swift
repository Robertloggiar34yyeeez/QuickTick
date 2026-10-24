import XCTest
import AVFoundation
@testable import QuicktickNative

final class QueryParserTests: XCTestCase {
    func testPositiveAndNegativeTerms() {
        XCTAssertEqual(QueryParser.parse("tag1 tag2 -excluded"), ParsedQuery(included: ["tag1","tag2"], excluded: ["excluded"]))
    }
    func testQuotedKeywordPhrasesAndMultiwordExclusions() {
        XCTAssertEqual(QueryParser.parse("\"cosplay scene\" -\"unwanted intro\" fantasy"),
                       ParsedQuery(included: ["cosplay scene", "fantasy"], excluded: ["unwanted intro"]))
        XCTAssertEqual(QueryParser.parse("\"unfinished phrase"), ParsedQuery(included: ["unfinished phrase"], excluded: []))
    }
    func testFormattingPostSearchTagsPreservesMultiwordPhrases() {
        let terms = ParsedQuery(included: ["chun_li", "red hair"], excluded: ["long hair", "watermark"])
        XCTAssertEqual(QueryParser.parse(QueryParser.formatted(terms)), terms)
        XCTAssertEqual(QueryParser.formatted(terms), "chun_li \"red hair\" -\"long hair\" -watermark")
    }
    func testVideoIntroPolicyOnlySkipsLongPornhubVideos() {
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: 60, enabled: true, provider: "pornhub"), 10)
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: 60, enabled: true, provider: "PornHub"), 10)
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: 60, enabled: true, provider: "rule34"), 0)
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: 60, enabled: true, provider: "redgifs"), 0)
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: 12, enabled: true, provider: "pornhub"), 0)
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: 60, enabled: false, provider: "pornhub"), 0)
        XCTAssertEqual(VideoIntroPolicy.startTime(duration: .nan, enabled: true, provider: "pornhub"), 0)
    }

    func testPornhubIntroMustHaveBufferedFramesAfterTenSeconds() {
        let range = CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 600),
                                duration: CMTime(seconds: 1.5, preferredTimescale: 600))
        let introOnly = CMTimeRange(start: .zero, duration: CMTime(seconds: 9, preferredTimescale: 600))
        XCTAssertTrue(VideoIntroPolicy.bufferedFrom(10, ranges: [range]))
        XCTAssertFalse(VideoIntroPolicy.bufferedFrom(10, ranges: [introOnly]))
        XCTAssertFalse(VideoIntroPolicy.bufferedFrom(10, ranges: []))
    }

    func testAutoplayDefaultsOnAndCanBeDisabledPersistently() {
        let name = "QuicktickVideoAutoplayTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { XCTFail("Missing isolated defaults"); return }
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(VideoPlaybackPreferences.autoplayEnabled(defaults))
        defaults.set(false, forKey: VideoPlaybackPreferences.autoplayKey)
        XCTAssertFalse(VideoPlaybackPreferences.autoplayEnabled(defaults))
        XCTAssertFalse(VideoPlaybackPreferences.shouldResume(owner: "home", defaults: defaults))
        XCTAssertFalse(VideoPlaybackPreferences.shouldResume(owner: "favorites", defaults: defaults))
        XCTAssertTrue(VideoPlaybackPreferences.shouldResume(owner: "immersive", defaults: defaults))
        XCTAssertTrue(VideoPlaybackPreferences.shouldResume(owner: "home-immersive", defaults: defaults))
        XCTAssertTrue(VideoPlaybackPreferences.shouldResume(owner: "offline-immersive", defaults: defaults))
        defaults.set(true, forKey: VideoPlaybackPreferences.autoplayKey)
        XCTAssertTrue(VideoPlaybackPreferences.autoplayEnabled(defaults))
        XCTAssertTrue(VideoPlaybackPreferences.shouldResume(owner: "home", defaults: defaults))
    }

    func testStudioPromptMetadataIsPersistedBesideImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gallery = root.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        let image = gallery.appendingPathComponent("sample.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        let metadata = StudioGenerationMetadata(prompt: "one character, nighttime city",
                                                negativePrompt: "blurry", steps: 8,
                                                guidance: 2, seed: 42, aspect: "square", longestEdge: 512)
        let studio = LocalImageStudio(directory: root)
        try await studio.saveGenerationMetadata(metadata, for: image)
        let persisted = await studio.generationMetadata(for: [image])
        XCTAssertEqual(persisted["sample.png"]?.prompt, metadata.prompt)
        XCTAssertEqual(persisted["sample.png"]?.seed, 42)
        XCTAssertEqual(persisted["sample.png"]?.steps, 8)
    }

    func testTagIdentityAndIndependentExclusion() {
        var tags = SearchTag.parse("Chun_Li ARTIST -chun_li artist")
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(Set(tags.map(\.id)).count, 2)
        let before = tags.map(\.id)
        let index = tags.firstIndex { $0.id == "artist" }!
        tags[index].excluded.toggle()
        XCTAssertEqual(tags.map(\.id), before)
        XCTAssertTrue(tags.first { $0.id == "chun_li" }!.excluded)
        XCTAssertTrue(tags[index].excluded)
        tags.removeAll { $0.id == "artist" }
        XCTAssertEqual(tags.map(\.id), ["chun_li"])
    }
    func testFiltersOnlyEmitSupportedRule34Syntax() {
        let filters = SearchFilters(order: .score, rating: "explicit", minimumScore: 50)
        let query = filters.query(tags: "long_hair -jacket", provider: .rule34)
        XCTAssertTrue(query.contains("sort:score:desc")); XCTAssertTrue(query.contains("score:>=50"))
        XCTAssertEqual(filters.query(tags: "long_hair -jacket", provider: .redgifs), "long_hair -jacket")
        XCTAssertEqual(SearchFilters.split(query).filters, filters)
    }
    func testWatchTimeExcludesLoadingPausesAndSeeks() {
        var exposure = PlaybackExposure()
        XCTAssertEqual(exposure.sample(media: 0, wall: 0, playing: false), 0)
        XCTAssertEqual(exposure.sample(media: 0, wall: 10, playing: false), 0)
        XCTAssertEqual(exposure.sample(media: 0.5, wall: 11, playing: true), 0.5)
        XCTAssertEqual(exposure.sample(media: 0.5, wall: 12, playing: false), 0)
        XCTAssertEqual(exposure.sample(media: 0.5, wall: 15, playing: false), 0)
        XCTAssertEqual(exposure.sample(media: 30, wall: 16, playing: true), 0)
        XCTAssertEqual(exposure.sample(media: 30.75, wall: 17, playing: true), 0.75)
        XCTAssertEqual(exposure.sample(media: 0, wall: 18, playing: true), 0)
    }

    func testSeekingToEndDoesNotImplyCompletedWatch() {
        XCTAssertEqual(PlaybackExposure.completion(position: 0.95, watched: 0.5, duration: 20), 0.025)
        XCTAssertEqual(PlaybackExposure.completion(position: 1, watched: 19, duration: 20), 0.95)
        XCTAssertEqual(PlaybackExposure.completion(position: 1, watched: 0, duration: 20), 0)
        XCTAssertEqual(PlaybackExposure.completion(position: 1, watched: 20, duration: .nan), 0)
    }
}
