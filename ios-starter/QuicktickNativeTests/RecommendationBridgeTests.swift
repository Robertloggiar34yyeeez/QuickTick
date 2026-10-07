import XCTest
@testable import QuicktickNative

final class RecommendationBridgeTests: XCTestCase {
    func testGorseIdentityIsStableAndDoesNotContainSyncSecret() async throws {
        let syncID = QuicktickSyncCrypto.generate()
        let bridge = RecommendationBridge(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid")!))
        let first = try await bridge.userID(syncID: syncID)
        let second = try await bridge.userID(syncID: syncID)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("qtg_"))
        XCTAssertFalse(syncID.contains(first))
        XCTAssertFalse(first.contains("QT6-"))
    }
}
