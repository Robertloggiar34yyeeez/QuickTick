import XCTest
@testable import QuicktickNative

final class APIConfigurationTests: XCTestCase {
    func testPackagedOriginIsUsedOnlyForOptionalSync() throws {
        let url = try XCTUnwrap(QuicktickAPIClient.configuredBaseURL())
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNotEqual(NativeProviderAPI.origin(.rule34).host, url.host)
        XCTAssertNotEqual(NativeProviderAPI.origin(.eporner).host, url.host)
        XCTAssertNotEqual(NativeProviderAPI.origin(.redgifs).host, url.host)
    }
}
