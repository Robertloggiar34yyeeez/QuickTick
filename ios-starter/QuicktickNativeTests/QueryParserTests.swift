import XCTest
@testable import QuicktickNative

final class QueryParserTests: XCTestCase {
    func testPositiveAndNegativeTerms() {
        XCTAssertEqual(QueryParser.parse("tag1 tag2 -excluded"), ParsedQuery(included: ["tag1","tag2"], excluded: ["excluded"]))
    }
}
