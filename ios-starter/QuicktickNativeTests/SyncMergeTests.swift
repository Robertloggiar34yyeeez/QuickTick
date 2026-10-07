import XCTest
@testable import QuicktickNative

final class SyncMergeTests: XCTestCase {
    func testNewerUnlikeTombstoneWinsAndTieKeepsLocal() throws {
        let post = Post(key: "rule34:1", id: "1", provider: "Rule34")
        var local = QuicktickSyncSnapshot.empty
        local.favorites[post.key] = post
        local.favoriteMeta[post.key] = FavoriteMeta(liked: true, updatedAt: 10)
        var remote = QuicktickSyncSnapshot.empty
        remote.favoriteMeta[post.key] = FavoriteMeta(liked: false, updatedAt: 11)
        let merged = try local.merging(remote)
        XCTAssertNil(merged.favorites[post.key])
        XCTAssertEqual(merged.favoriteMeta[post.key]?.updatedAt, 11)
        remote.favoriteMeta[post.key]?.updatedAt = 10
        XCTAssertNotNil(try local.merging(remote).favorites[post.key])
    }
    func testStampedSectionsAndLegacyFavoriteMetadata() throws {
        var local = QuicktickSyncSnapshot.empty
        local.exclusions = .init(updatedAt: 100, tags: ["local"])
        var remote = QuicktickSyncSnapshot.empty
        remote.updatedAt = 200
        remote.favorites["rule34:1"] = Post(key: "rule34:1", id: "1", provider: "Rule34")
        remote.exclusions = .init(updatedAt: 99, tags: ["remote"])
        remote.preferences = .init(updatedAt: 200, value: TasteSetup(done: true))
        let merged = try local.merging(remote)
        XCTAssertEqual(merged.exclusions.tags, ["local"])
        XCTAssertTrue(merged.preferences.value.done)
        XCTAssertEqual(merged.favoriteMeta["rule34:1"]?.updatedAt, 200)
    }
    func testLegacyV1ProfileRestoresCredentialsWithoutOptionalSections() throws {
        let wire = Data(#"{"version":1,"updatedAt":400,"rule34":{"updatedAt":300,"credentials":{"userId":"synthetic-user","apiKey":"synthetic-key","remember":false}}}"#.utf8)
        let remote = try JSONDecoder().decode(QuicktickSyncSnapshot.self, from: wire)
        let merged = try QuicktickSyncSnapshot.empty.merging(remote)
        XCTAssertEqual(merged.rule34.credentials.userId, "synthetic-user")
        XCTAssertEqual(merged.rule34.credentials.apiKey, "synthetic-key")
        XCTAssertFalse(merged.rule34.credentials.remember)
        XCTAssertTrue(merged.favoriteMeta.isEmpty)
        XCTAssertEqual(merged.preferences.updatedAt, 0)
    }
    func testFutureWireSchemaFailsBeforeIdentityCanBeReplaced() {
        XCTAssertThrowsError(try JSONDecoder().decode(QuicktickSyncSnapshot.self, from: Data(#"{"version":2}"#.utf8)))
    }
    func testRejectsFutureSchema() {
        var remote = QuicktickSyncSnapshot.empty; remote.version = 2
        XCTAssertThrowsError(try QuicktickSyncSnapshot.empty.merging(remote))
    }
}
