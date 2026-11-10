import XCTest
@testable import QuicktickNative

final class PersistenceTests: XCTestCase {
    @MainActor func testExportOnlyUsesExistingLocalFiles() throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: local) }
        XCTAssertNil(DownloadExporter.localFileURL(local.absoluteString))
        XCTAssertNil(DownloadExporter.localFileURL("https://example.com/video.mp4"))
        try Data([0, 1, 2]).write(to: local)
        XCTAssertEqual(DownloadExporter.localFileURL(local.absoluteString), local)
    }

    func testLegacyHanimePosterIsNotAnOfflineVideo() throws {
        let poster = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: poster)
        defer { try? FileManager.default.removeItem(at: poster) }
        var record = DownloadRecord(key: "hanime:sample", provider: "Hanime", postID: "sample",
                                    title: "Sample", tags: [], thumbnailRemoteURL: "",
                                    localMediaPath: poster.path, kind: .file,
                                    state: .complete, progress: 1, createdAt: .now)
        record.mediaType = "video"
        XCTAssertNil(record.offlinePost)
        XCTAssertNil(record.exportURL)
    }

    @MainActor func testFavoritesNewestFirstUsesLikeTimeAcrossProviders() {
        let posts = [
            Post(key: "rule34:900", id: "900", provider: "Rule34"),
            Post(key: "kemono:1", id: "1", provider: "Kemono"),
            Post(key: "coomer:7", id: "7", provider: "Coomer"),
            Post(key: "hhaven:old", id: "old", provider: "hhaven")
        ]
        let collection = Dictionary(uniqueKeysWithValues: posts.map { ($0.stableID, $0) })
        let dates: [String: FavoriteMeta] = [
            "rule34:900": .init(liked: true, updatedAt: 100),
            "kemono:1": .init(liked: true, updatedAt: 300),
            "coomer:7": .init(liked: true, updatedAt: 200)
        ]
        let ordered = AppStore.sortFavoritesNewestFirst(collection, metadata: dates)
        XCTAssertEqual(ordered.map(\.stableID), ["kemono:1", "coomer:7", "rule34:900", "hhaven:old"])
    }
    func testCoreMLFastPathRequiresRealMemoryHeadroom() {
        let gib = UInt64(1_024 * 1_024 * 1_024)
        XCTAssertFalse(StudioCoreMLPerformance.useFastPath(physicalBytes: 4 * gib, availableBytes: 4 * gib))
        XCTAssertFalse(StudioCoreMLPerformance.useFastPath(physicalBytes: 8 * gib, availableBytes: 2 * gib))
        XCTAssertTrue(StudioCoreMLPerformance.useFastPath(physicalBytes: 16 * gib, availableBytes: 6 * gib))
    }
    @MainActor func testDownloadsRestoreNewestFirstAcrossProviders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldest = DownloadRecord(key: "rule34:1", provider: "Rule34", postID: "1", title: "oldest", tags: [], thumbnailRemoteURL: "", localMediaPath: "", kind: .file, state: .complete, progress: 1, createdAt: Date(timeIntervalSince1970: 100))
        let newest = DownloadRecord(key: "kemono:3", provider: "Kemono", postID: "3", title: "newest", tags: [], thumbnailRemoteURL: "", localMediaPath: "", kind: .file, state: .complete, progress: 1, createdAt: Date(timeIntervalSince1970: 300))
        let middle = DownloadRecord(key: "coomer:2", provider: "Coomer", postID: "2", title: "middle", tags: [], thumbnailRemoteURL: "", localMediaPath: "", kind: .file, state: .complete, progress: 1, createdAt: Date(timeIntervalSince1970: 200))
        try JSONEncoder().encode([oldest, newest, middle]).write(to: dir.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: dir)
        XCTAssertEqual(manager.records.map(\.key), [newest.key, middle.key, oldest.key])
    }

    func testDownloadShuffleKeepsItsDeckThroughProgressAndCatalogUpdates() {
        let records = (1...4).reversed().map { id in
            DownloadRecord(key: "rule34:\(id)", provider: "Rule34", postID: "\(id)",
                title: "Saved \(id)", tags: [], thumbnailRemoteURL: "",
                kind: .file, state: .complete, progress: 1,
                createdAt: Date(timeIntervalSince1970: Double(id)))
        }
        var order = DownloadShuffleOrder()
        XCTAssertEqual(order.ordered(records).map(\.key), records.map(\.key))

        order.shuffle(records: records)
        let shuffled = order.ordered(records).map(\.key)
        XCTAssertTrue(order.isShuffled)
        XCTAssertEqual(Set(shuffled), Set(records.map(\.key)))

        var progressUpdate = records
        progressUpdate[0].progress = 0.75
        XCTAssertEqual(order.ordered(progressUpdate).map(\.key), shuffled,
                       "Background download progress must never reshuffle saved posts")

        let addition = DownloadRecord(key: "erome:new", provider: "Erome", postID: "new",
            title: "New download", tags: [], thumbnailRemoteURL: "", kind: .file,
            state: .complete, progress: 1, createdAt: .now)
        let expanded = [addition] + records
        order.reconcile(records: expanded)
        XCTAssertEqual(order.ordered(expanded).map(\.key), shuffled + [addition.key],
                       "New downloads should join the end of an existing shuffled deck")

        let removed = expanded.filter { $0.key != shuffled[1] }
        order.reconcile(records: removed)
        XCTAssertEqual(order.ordered(removed).map(\.key),
                       (shuffled + [addition.key]).filter { $0 != shuffled[1] })

        order.restoreOriginalOrder()
        XCTAssertFalse(order.isShuffled)
        XCTAssertEqual(order.ordered(removed).map(\.key), removed.map(\.key))
    }

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

    @MainActor func testBatchDeleteKeepsUnselectedDownloadsAndPersistsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var fixtures: [DownloadRecord] = []
        for id in 1...3 {
            let media = root.appendingPathComponent("media-\(id).mp4")
            try Data([1, 2, 3]).write(to: media)
            fixtures.append(DownloadRecord(key: "rule34:\(id)", provider: "Rule34", postID: "\(id)",
                title: "File \(id)", tags: [], thumbnailRemoteURL: "", localMediaPath: media.path,
                kind: .file, state: .complete, progress: 1,
                createdAt: Date(timeIntervalSince1970: Double(id))))
        }
        try JSONEncoder().encode(fixtures).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: root)
        manager.delete(keys: ["rule34:1", "rule34:3"])
        for _ in 0..<50 where manager.records.count != 1 {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(manager.records.map(\.key), ["rule34:2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("media-2.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media-1.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media-3.mp4").path))
        XCTAssertEqual(DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: root).records.map(\.key), ["rule34:2"])
    }

    @MainActor func testLegacyDownloadPathsSurviveRepeatedAppContainerChanges() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("original/Downloads")
        let second = base.appendingPathComponent("updated/Downloads")
        let third = base.appendingPathComponent("updated-again/Downloads")
        let folder = first.appendingPathComponent("rule34_42")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = folder.appendingPathComponent("media.jpg")
        let thumbnail = folder.appendingPathComponent("thumbnail.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: media)
        try Data([0xFF, 0xD8]).write(to: thumbnail)
        var old = DownloadRecord(key: "rule34:42", provider: "Rule34", postID: "42", title: "Old image", tags: [], thumbnailRemoteURL: "", localMediaPath: media.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
        old.thumbnailLocalPath = thumbnail.path
        try JSONEncoder().encode([old]).write(to: first.appendingPathComponent("downloads.json"))

        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: first, to: second)
        let restored = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: second)
        XCTAssertEqual(restored.records.first?.localMediaPath, second.appendingPathComponent("rule34_42/media.jpg").path)
        XCTAssertEqual(restored.records.first?.thumbnailLocalPath, second.appendingPathComponent("rule34_42/thumbnail.jpg").path)
        XCTAssertNotNil(restored.records.first?.offlinePost)
        XCTAssertNotNil(restored.records.first?.exportURL)

        // Migration writes relative locations. A subsequent update works without
        // having to recognize the first installation's absolute sandbox path.
        let catalog = try JSONDecoder().decode(DownloadCatalog.self, from: Data(contentsOf: second.appendingPathComponent("downloads.json")))
        XCTAssertEqual(catalog.records.first?.localMediaPath, "quicktick-downloads:rule34_42/media.jpg")
        XCTAssertEqual(catalog.records.first?.thumbnailLocalPath, "quicktick-downloads:rule34_42/thumbnail.jpg")

        try FileManager.default.createDirectory(at: third.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: second, to: third)
        let restoredAgain = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: third)
        XCTAssertEqual(restoredAgain.records.first?.localMediaPath, third.appendingPathComponent("rule34_42/media.jpg").path)
        XCTAssertNotNil(restoredAgain.records.first?.offlinePost)
    }

    @MainActor func testMissingCompletedDownloadRemainsInCatalogForRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let missing = DownloadRecord(key: "rule34:missing", provider: "Rule34", postID: "missing", title: "Missing file", tags: [], thumbnailRemoteURL: "", localMediaPath: "/old/container/media.jpg", kind: .file, state: .complete, progress: 1, createdAt: .now)
        try JSONEncoder().encode([missing]).write(to: dir.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: dir)
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertNil(manager.records[0].offlinePost)
        XCTAssertEqual(manager.records[0].state, .complete)
    }

    @MainActor func testLegacyHanimeImageMisnamedMP4IsRecoverableNotCompleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("hanime_clip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let disguised = folder.appendingPathComponent("media.mp4")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2]).write(to: disguised)
        let record = DownloadRecord(key: "hanime:clip", provider: "Hanime", postID: "clip",
            title: "Old preview", tags: [], thumbnailRemoteURL: "", localMediaPath: disguised.path,
            kind: .file, state: .complete, progress: 1, createdAt: .now)
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("downloads.json"))

        let manager = DownloadManager(resolver: MediaResolver(api: QuicktickAPIClient()), directory: root)
        let recovered = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(recovered.state, .failed)
        XCTAssertNil(recovered.offlinePost)
        XCTAssertNil(recovered.exportURL)
        XCTAssertTrue(try XCTUnwrap(recovered.errorMessage).contains("full Hanime video"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disguised.path), "Keep the old preview until retry.")
    }

    func testSystemManagedHLSPathsRebaseWithoutMovingPackage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("container-two")
        let package = home.appendingPathComponent("Library/com.apple.assets/clip.movpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let formerID = UUID().uuidString
        let obsolete = "/var/mobile/Containers/Data/Application/\(formerID)/Library/com.apple.assets/clip.movpkg"
        let record = DownloadRecord(key: "video:42", provider: "Rule34", postID: "42", title: "HLS", tags: [], thumbnailRemoteURL: "", localMediaPath: obsolete, kind: .hlsPackage, state: .complete, progress: 1, createdAt: .now)
        let storage = DownloadPathStorage(root: home.appendingPathComponent("Library/Application Support/Quicktick/Downloads"), container: home)
        let recovered = storage.restore(record)
        XCTAssertEqual(recovered.localMediaPath, package.path)
        XCTAssertEqual(storage.persist(recovered).localMediaPath, "quicktick-container:Library/com.apple.assets/clip.movpkg")

        let nextHome = base.appendingPathComponent("container-three")
        try FileManager.default.moveItem(at: home, to: nextHome)
        let nextStorage = DownloadPathStorage(root: nextHome.appendingPathComponent("Library/Application Support/Quicktick/Downloads"), container: nextHome)
        XCTAssertEqual(nextStorage.restore(storage.persist(recovered)).localMediaPath,
                       nextHome.appendingPathComponent("Library/com.apple.assets/clip.movpkg").path)
    }
}
