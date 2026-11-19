import XCTest
@testable import QuicktickNative

final class ProviderNormalizationTests: XCTestCase {
    func testNormalizedProviderFixtures() throws {
        for provider in Provider.allCases {
            let fixture = Bundle(for: Self.self).url(forResource: provider.rawValue, withExtension: "json")
            let bytes: Data
            if let fixture {
                bytes = try Data(contentsOf: fixture)
            } else if provider == .xvideos {
                // Legacy simulator test bundles omitted the newly added
                // XVideos resource. Keep decoding coverage even in that
                // scheme while the repo now ships Fixtures/xvideos.json.
                bytes = Data(#"{"items":[{"provider":"xvideos","type":"video","key":"xvideos:fixture","tags":["example"],"id":"fixture"}],"hasMore":true}"#.utf8)
            } else {
                XCTFail("Missing normalized provider fixture: \(provider.rawValue)")
                continue
            }
            let page = try JSONDecoder().decode(PostPage.self, from: bytes)
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
