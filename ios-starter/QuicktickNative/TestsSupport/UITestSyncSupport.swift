#if DEBUG
import Foundation

// Public deterministic test vector, used only by simulator UI tests.
enum UITestSyncSupport {
    static let syncID = "QT6-AAECAwQFBgcICQoLDA0ODw.ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    static var snapshot: QuicktickSyncSnapshot {
        var value = QuicktickSyncSnapshot.empty
        value.rule34 = .init(updatedAt: 100, credentials: .init(userId: "synced-test-user", apiKey: "synthetic-test-key", remember: false))
        value.pornhub = .init(updatedAt: 100, auth: .init(username: "synced-test-name", session: "synthetic-test-session"))
        return value
    }
}

final class UITestSyncProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            // UI testing only: all requests stay off the network.
            var result: [String: Any] = ["ok": true]
            if request.url?.path == "/api/sync" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let read = stream.read(&buffer, maxLength: buffer.count)
                        guard read > 0 else { break }
                        body.append(contentsOf: buffer.prefix(read))
                    }
                }
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                if json?["action"] as? String == "get" {
                    let encrypted = try QuicktickSyncCrypto.encrypt(UITestSyncSupport.snapshot, syncID: UITestSyncSupport.syncID)
                    let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(encrypted.envelope))
                    result = ["exists": true, "payload": payload, "updatedAt": 100]
                }
            } else { result = ["items": [], "hasMore": false] }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
