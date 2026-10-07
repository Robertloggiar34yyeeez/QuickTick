import XCTest
@testable import QuicktickNative

final class ProviderNormalizationTests: XCTestCase {
    func testNormalizedProviderFixtures() throws {
        for provider in Provider.allCases {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: provider.rawValue, withExtension: "json"))
            let page = try JSONDecoder().decode(PostPage.self, from: Data(contentsOf: url))
            XCTAssertEqual(page.items.first?.providerKey, provider)
            XCTAssertEqual(page.items.first?.stableID, "\(provider.rawValue):fixture")
            XCTAssertEqual(page.hasMore, true)
        }
    }
    func testMissingOptionalPostFieldsHaveDefaults() throws {
        let post = try JSONDecoder().decode(Post.self, from: Data(#"{"id":"1","provider":"Rule34"}"#.utf8))
        XCTAssertEqual(post.stableID, "rule34:1")
        XCTAssertEqual(post.tags, [])
        XCTAssertEqual(post.mediaUrl, "")
    }
}
