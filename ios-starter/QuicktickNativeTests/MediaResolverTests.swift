import XCTest
@testable import QuicktickNative

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class MediaProtocol: URLProtocol, @unchecked Sendable {
    static let counter = RequestCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.increment()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"mediaUrl":"https://example.invalid/video.mp4","type":"video"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MediaResolverTests: XCTestCase {
    func testConcurrentPrewarmAndPlaybackShareOneMediaRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let resolver = MediaResolver(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"), session: session))
        let post = Post(key: "eporner:1", id: "1", provider: "Eporner", type: "video")
        let before = MediaProtocol.counter.value
        async let warm = resolver.resolve(post)
        async let active = resolver.resolve(post)
        let (first, second) = try await (warm, active)
        let cached = try await resolver.resolve(post)
        XCTAssertEqual(first.mediaUrl, second.mediaUrl)
        XCTAssertEqual(cached.mediaUrl, first.mediaUrl)
        XCTAssertEqual(MediaProtocol.counter.value - before, 1)
    }
}
