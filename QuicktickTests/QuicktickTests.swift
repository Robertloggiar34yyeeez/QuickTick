import XCTest
@testable import Quicktick

final class QuicktickTests: XCTestCase {
    func testDanbooruDecode() throws {
        let json = #"{"id":123,"tag_string":"blue_sky cloud","score":42,"rating":"g","image_width":800,"image_height":600,"file_ext":"jpg","file_url":"https://example.com/full.jpg","preview_file_url":"https://example.com/preview.jpg"}"#.data(using: .utf8)!
        let post = try JSONDecoder().decode(DanbooruPost.self, from: json).post
        XCTAssertEqual(post?.id, "danbooru:123")
        XCTAssertEqual(post?.tags, ["blue_sky", "cloud"])
        XCTAssertEqual(post?.kind, .image)
        XCTAssertEqual(post?.previewURL.lastPathComponent, "preview.jpg")
    }
    func testDanbooruQueryAndPagination() {
        var query = FeedQuery(tags: ["blue_sky"], sort: .recent)
        query.cursor = "123"
        let url = DanbooruProvider.url(for: query)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "page" })?.value, "b123")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "tags" })?.value, "blue_sky")
    }
    func testTagsAndExclusions() {
        XCTAssertEqual(TagRules.terms("Blue Sky,cloud"), ["blue", "sky", "cloud"])
        let post = Post(id: "a", source: .danbooru, sourceID: "a", kind: .image, previewURL: URL(string: "https://example.com/a")!, mediaURL: URL(string: "https://example.com/a")!, pageURL: URL(string: "https://example.com/a")!, tags: ["blue_sky", "cloud"], score: 0, rating: nil, width: 1, height: 1)
        XCTAssertFalse(TagRules.allowed(post, exclusions: ["blue sky", "other"]))
        XCTAssertTrue(TagRules.allowed(post, exclusions: ["other"]))
    }
    func testRecommendations() {
        let post = Post(id: "a", source: .danbooru, sourceID: "a", kind: .image, previewURL: URL(string: "https://example.com/a")!, mediaURL: URL(string: "https://example.com/a")!, pageURL: URL(string: "https://example.com/a")!, tags: ["cloud", "sun"], score: 0, rating: nil, width: 1, height: 1)
        var signals: [String: Double] = [:]
        RecommendationEngine.record(post, weight: 5, into: &signals)
        XCTAssertEqual(Set(RecommendationEngine.topTags(from: signals, excluded: ["sun"])), ["cloud"])
    }
}
