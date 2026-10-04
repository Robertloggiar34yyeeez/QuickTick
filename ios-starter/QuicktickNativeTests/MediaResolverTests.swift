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

private final class PaginationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
        // Page two is all duplicates; page three adds a new batch. Each response
        // also contains a repeated ID, as several provider APIs can do.
        let offset = page <= 2 ? 0 : 10
        let posts = (1...10).map { Post(key: "eporner:\($0 + offset)", id: "\($0 + offset)", provider: "Eporner", type: "video") }
        let data = try! JSONEncoder().encode(PostPage(items: posts + [posts[0]], hasMore: page < 3))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FeedPaginationTests: XCTestCase {
    @MainActor func testTenPostsContinuePastDuplicatePageWithoutRepeats() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PaginationProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = AppStore(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"), session: session))
        store.selectedProvider = .eporner
        await store.refresh()
        XCTAssertEqual(store.posts.count, 10)
        XCTAssertTrue(store.hasMore)
        await store.loadMore(immersive: true)
        XCTAssertEqual(store.posts.count, 20)
        XCTAssertEqual(Set(store.posts.map(\.stableID)).count, 20)
        XCTAssertFalse(store.hasMore)
    }
    func testNormalFeedUsesOriginalImageAndLargerPreview() {
        let image = Post(key: "1", id: "1", provider: "Rule34", mediaUrl: "https://example.invalid/full.jpg", previewUrl: "https://example.invalid/sample.jpg", thumbUrl: "https://example.invalid/tiny.jpg", type: "image")
        XCTAssertEqual(image.cardPreviewURL, image.mediaUrl)
        var video = image; video.type = "video"
        XCTAssertEqual(video.cardPreviewURL, video.previewUrl)
        video.previewUrl = "https://example.invalid/preview.mp4"
        XCTAssertEqual(video.cardPreviewURL, video.thumbUrl)
    }
}
