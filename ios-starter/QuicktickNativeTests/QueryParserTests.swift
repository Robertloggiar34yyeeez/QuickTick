import XCTest
@testable import QuicktickNative

final class QueryParserTests: XCTestCase {
    func testPositiveAndNegativeTerms() {
        XCTAssertEqual(QueryParser.parse("tag1 tag2 -excluded"), ParsedQuery(included: ["tag1","tag2"], excluded: ["excluded"]))
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
