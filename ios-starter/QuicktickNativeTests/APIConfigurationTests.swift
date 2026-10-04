import XCTest
@testable import QuicktickNative

final class APIConfigurationTests: XCTestCase {
    func testPackagedAppContainsExistingVercelOrigin() throws {
        let url = try XCTUnwrap(QuicktickAPIClient.configuredBaseURL())
        XCTAssertEqual(url.absoluteString, "https://quick-tick-webb.vercel.app")
        XCTAssertEqual(url.scheme, "https")
    }
}

