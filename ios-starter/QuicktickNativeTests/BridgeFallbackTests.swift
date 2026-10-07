import XCTest
@testable import QuicktickNative

private final class DisabledRecommendationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"available":false,"enabled":false}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BridgeFallbackTests: XCTestCase {
    func testUnavailableGorseLeavesLocalRankingFunctional() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DisabledRecommendationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let bridge = RecommendationBridge(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"), session: session))
        let posts = [Post(key: "rule34:1", id: "1", provider: "Rule34", tags: ["samus_aran"]), Post(key: "rule34:2", id: "2", provider: "Rule34", tags: ["unrelated"])]
        let scores = await bridge.rank(posts: posts, provider: .rule34, syncID: QuicktickSyncCrypto.generate(), positiveTerms: [], negativeTerms: [])
        XCTAssertNil(scores)
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await engine.recordSearch(provider: .rule34, query: "samus_aran")
        let ranked = await engine.rank(posts, taste: TasteChoice(), recent: [], collaborativeScores: scores ?? [:])
        XCTAssertEqual(ranked.first?.stableID, "rule34:1")
    }
    func testOlderRecommendationProfileMigratesWithoutLosingTerms() async throws {
        let state = try JSONDecoder().decode(RecommendationState.self, from: Data(#"{"version":2,"profiles":{"rule34":{"terms":{"samus_aran":14}}}}"#.utf8))
        let engine = RecommendationEngine(semantic: SemanticRecommender(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))); await engine.load(state)
        let saved = await engine.snapshot()
        XCTAssertEqual(saved.version, 3)
        XCTAssertEqual(saved.profiles["rule34"]?.terms["samus_aran"], 14)
    }
}
