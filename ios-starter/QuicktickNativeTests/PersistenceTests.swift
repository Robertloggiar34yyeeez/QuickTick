import XCTest
@testable import QuicktickNative

final class PersistenceTests: XCTestCase {
    func testLocalStateRoundTripAndUnknownVersionIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalStateStore(directory: dir)
        var state = LocalAppState(); state.resumePositions["rule34:1"] = 43
        state.snapshot.favoriteMeta["rule34:1"] = .init(liked: false, updatedAt: 12)
        try storage.save(state)
        XCTAssertEqual(try storage.load().resumePositions["rule34:1"], 43)
        state.version = 100; try storage.save(state)
        XCTAssertThrowsError(try storage.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.url.path))
    }

    @MainActor func testDownloadMetadataReloadAndDeleteOnlyOwnedMedia() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = dir.appendingPathComponent("test.mp4")
        let untouched = dir.appendingPathComponent("another.mp4")
        try Data([1,2,3]).write(to: media); try Data([4]).write(to: untouched)
        let record = DownloadRecord(key: "rule34:1", provider: "Rule34", postID: "1", title: "fixture", tags: [], thumbnailRemoteURL: "", localMediaPath: media.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
        try JSONEncoder().encode([record]).write(to: dir.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: dir)
        XCTAssertEqual(manager.records.count, 1)
        manager.delete(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
        XCTAssertTrue(DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: dir).records.isEmpty)
    }
}
