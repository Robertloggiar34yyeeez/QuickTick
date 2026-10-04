import XCTest
@testable import QuicktickNative

final class KeychainTests: XCTestCase {
    func testSecureStoragePersistsAndDeletesWithRealSigningEntitlements() throws {
        let account = "quicktick-regression-test"
        defer { KeychainStore.delete(account: account) }
        try KeychainStore.set("synthetic-secure-value", account: account)
        XCTAssertEqual(KeychainStore.get(account: account), "synthetic-secure-value")
        KeychainStore.delete(account: account)
        XCTAssertNil(KeychainStore.get(account: account))
    }
}
