import XCTest
@testable import QuicktickNative

private final class SyncUploadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var uploads: [String: [SyncEnvelope]] = [:]
    func append(_ envelope: SyncEnvelope, recordID: String) {
        lock.lock(); defer { lock.unlock() }
        uploads[recordID, default: []].append(envelope)
    }
    func values(for recordID: String) -> [SyncEnvelope] {
        lock.lock(); defer { lock.unlock() }; return uploads[recordID] ?? []
    }
}

private final class SyncResponseProtocol: URLProtocol, @unchecked Sendable {
    static let capture = SyncUploadCapture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "x-test-mode")
        let data: Data
        if mode == "save-credentials" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if json?["action"] as? String == "put", let recordID = json?["id"] as? String, let payload = json?["payload"],
               let raw = try? JSONSerialization.data(withJSONObject: payload), let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: raw) {
                Self.capture.append(envelope, recordID: recordID)
                data = Data(#"{"ok":true}"#.utf8)
            } else { data = Data(#"{"exists":false}"#.utf8) }
        } else {
            data = Data((mode == "missing-payload" ? #"{"exists":true,"updatedAt":100}"# : #"{"ok":false}"#).utf8)
        }
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
    @MainActor func testSavingAccessSettingsAutomaticallyUploadsEncryptedCredentials() async throws {
        let session = session("save-credentials"); defer { session.invalidateAndCancel() }
        let accounts = ["quicktick-sync-id", "rule34-user", "rule34-key", "pornhub-session", "pornhub-username"]
        let original = accounts.map { KeychainStore.get(account: $0) }
        defer {
            for (index, account) in accounts.enumerated() {
                if let value = original[index] { try? KeychainStore.set(value, account: account) }
                else { KeychainStore.delete(account: account) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"), session: session), localStorage: LocalStateStore(directory: directory))
        let syncID = QuicktickSyncCrypto.generate()
        let recordID = try QuicktickSyncCrypto.parse(syncID).recordID
        try await store.connectSyncID(syncID)
        XCTAssertEqual(SyncResponseProtocol.capture.values(for: recordID).count, 1)
        await store.saveCredentials(user: "synthetic-user", key: "synthetic-key", session: "synthetic-session", remember: false, username: "synthetic-name")
        for _ in 0..<40 {
            if SyncResponseProtocol.capture.values(for: recordID).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let uploads = SyncResponseProtocol.capture.values(for: recordID)
        XCTAssertEqual(uploads.count, 2, "Saving access must schedule a cloud upload without requiring Sync now")
        let envelope = try XCTUnwrap(uploads.last)
        let remote = try QuicktickSyncCrypto.decrypt(QuicktickSyncSnapshot.self, envelope: envelope, syncID: syncID)
        XCTAssertEqual(remote.rule34.credentials.userId, "synthetic-user")
        XCTAssertEqual(remote.rule34.credentials.apiKey, "synthetic-key")
        XCTAssertFalse(remote.rule34.credentials.remember)
        XCTAssertEqual(remote.pornhub.auth.username, "synthetic-name")
        XCTAssertEqual(remote.pornhub.auth.session, "synthetic-session")
        let disk = try LocalStateStore(directory: directory).load()
        XCTAssertTrue(disk.snapshot.rule34.credentials.apiKey.isEmpty)
        XCTAssertTrue(disk.snapshot.pornhub.auth.session.isEmpty)
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
