import XCTest
@testable import QuicktickNative

private final class SyncResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "x-test-mode")
        let data = Data((mode == "missing-payload" ? #"{"exists":true,"updatedAt":100}"# : #"{"ok":false}"#).utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SyncServiceTests: XCTestCase {
    private func session(_ mode: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncResponseProtocol.self]
        config.httpAdditionalHeaders = ["x-test-mode":mode]
        return URLSession(configuration: config)
    }
    func testExistingProfileWithoutPayloadCannotBeTreatedAsEmpty() async {
        let session = session("missing-payload"); defer { session.invalidateAndCancel() }
        let service = QuicktickSyncService(api: QuicktickAPIClient(baseURL: URL(string:"https://example.invalid"),session:session))
        do { _ = try await service.pull(syncID: QuicktickSyncCrypto.generate()); XCTFail("Must reject corrupt cloud profile before a subsequent upload") }
        catch { XCTAssertTrue(error is QuicktickSyncCryptoError) }
    }
    func testUnacknowledgedSaveIsNotReportedAsSuccess() async {
        let session = session("save-failed"); defer { session.invalidateAndCancel() }
        let service = QuicktickSyncService(api: QuicktickAPIClient(baseURL: URL(string:"https://example.invalid"),session:session))
        do { try await service.push(syncID: QuicktickSyncCrypto.generate(), snapshot: .empty); XCTFail("Server refused the save") }
        catch { XCTAssertTrue(error is APIError) }
    }
}
