import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import QuicktickNative

private final class FeedModeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let order = query.first { $0.name == "order" }?.value ?? "top-monthly"
        let sort = order == "latest" ? "recent" : "recommended"
        let page = Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1
        let json: [String: Any] = ["videos": [["id": "\(sort):\(page)", "title": "Fixture", "keywords": page == 1 ? "filtered" : "keep"]], "total_pages": 2]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        DispatchQueue.global().asyncAfter(deadline: .now() + (sort == "recommended" ? 0.15 : 0)) { [self] in
            client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self,didLoad: data);client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
private final class CandidatePageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = (Int(query.first { $0.name == "pid" }?.value ?? "0") ?? 0) + 1
        let mode = query.first { $0.name == "tags" }?.value?.contains("video") == true ? "video" : "feed"
        let video = mode != "video" || page >= 3
        let json: [[String: Any]] = [["id": "\(mode):\(page)", "tags": "engineering", "file_url": "https://cdn.example.invalid/fixture-\(page).\(video ? "mp4" : "jpg")"]]
        // A full raw page signals more pages even when local clip filtering removes it.
        let data = try! JSONSerialization.data(withJSONObject: Array(repeating: json[0], count: mode == "video" ? 100 : 80))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class FeedReliabilityTests: XCTestCase {
    func testFeedPreviewRestoresBeforeNetworkAndKeepsProviderScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedPreviewPersistence(directory: directory)
        let cold = await cache.load(provider: .rule34, query: "", sort: "recommended", mediaOnly: false)
        XCTAssertTrue(cold.isEmpty)
        let post = Post(key: "eporner:preview", id: "preview", provider: "eporner",
                        tags: ["cosplay"], thumbUrl: "https://example.com/p.jpg", type: "video")
        await cache.save([post], provider: .eporner, query: "", sort: "recommended", mediaOnly: false)
        let restoredProvider = await cache.recentProvider()
        XCTAssertEqual(restoredProvider, .eporner)
        let restored = await cache.load(provider: .eporner, query: "", sort: "recommended", mediaOnly: false)
        XCTAssertEqual(restored.map(\.stableID), [post.stableID])
        let otherProvider = await cache.load(provider: .rule34, query: "", sort: "recommended", mediaOnly: false)
        let otherSearch = await cache.load(provider: .eporner, query: "cosplay", sort: "recommended", mediaOnly: false)
        XCTAssertTrue(otherProvider.isEmpty)
        XCTAssertTrue(otherSearch.isEmpty)
        await cache.save([], provider: .eporner, query: "", sort: "recommended", mediaOnly: false)
        await cache.save([post], provider: .rule34, query: "zelda", sort: "popular", mediaOnly: false)
        await cache.save([post], provider: .rule34, query: "", sort: "recommended", mediaOnly: true)
        let afterEmptySave = await cache.load(provider: .eporner, query: "", sort: "recommended", mediaOnly: false)
        XCTAssertEqual(afterEmptySave.count, 1,
                       "Empty responses or temporary browsing modes must not erase the last usable Home feed")
        let rule34Post = Post(key: "rule34:another", id: "another", provider: "Rule34",
                              tags: ["engineering"], type: "image")
        await cache.save([rule34Post], provider: .rule34, query: "", sort: "recommended", mediaOnly: false)
        let restoredEporner = await cache.load(provider: .eporner, query: "", sort: "recommended", mediaOnly: false)
        let restoredRule34 = await cache.load(provider: .rule34, query: "", sort: "recommended", mediaOnly: false)
        XCTAssertEqual(restoredEporner.map(\.stableID), [post.stableID],
                       "Switching providers must not discard a working catalog during an outage")
        XCTAssertEqual(restoredRule34.map(\.stableID), [rule34Post.stableID])
    }
    func testSavedMediaSearchMatchesTitlesTagsAndProvidersWithoutNetwork() {
        var liked = Post(key: "rule34:star", id: "star", provider: "Rule34",
                         tags: ["space_opera", "blue_hair"], type: "image")
        liked.caption = "Cosmic Adventure"
        liked.creator = "Sample Artist"
        XCTAssertTrue(CollectionSearch.matches(liked, query: "SPACE opera"))
        XCTAssertTrue(CollectionSearch.matches(liked, query: "rule34 artist"))
        XCTAssertFalse(CollectionSearch.matches(liked, query: "football"))
        XCTAssertTrue(CollectionSearch.matches(liked, query: ""))

        let download = DownloadRecord(key: "eporner:clip", provider: "Eporner", postID: "clip",
            title: "Cosplay Session", tags: ["science_fiction", "blonde"],
            thumbnailRemoteURL: "", kind: .file, state: .complete, progress: 1, createdAt: .now)
        XCTAssertTrue(CollectionSearch.matches(download, query: "Eporner science fiction"))
        XCTAssertTrue(CollectionSearch.matches(download, query: "session"))
        XCTAssertFalse(CollectionSearch.matches(download, query: "cooking"))
        XCTAssertEqual(CollectionSearch.filter([liked], query: "SPACE opera").map(\.stableID), [liked.stableID])
        XCTAssertTrue(CollectionSearch.filter([liked], query: "football").isEmpty)
        XCTAssertEqual(CollectionSearch.matchingDownloadKeys([download], query: "Eporner science fiction"), [download.key])
        XCTAssertTrue(CollectionSearch.matchingDownloadKeys([download], query: "cooking").isEmpty)
    }

    func testDownloadsLargestFirstSortUsesMeasuredBytesAndKeepsUnknownLast() {
        let samples: [(String, Int64?)] = [
            ("small", 256), ("unknown", nil), ("large", 1_048_576),
            ("same-size", 256), ("zero", 0)
        ]
        let records = samples.map { sample -> DownloadRecord in
            let (key, size) = sample
            var record = DownloadRecord(
                key: "rule34:" + key, provider: "Rule34", postID: key,
                title: key, tags: [], thumbnailRemoteURL: "", kind: .file,
                state: .complete, progress: 1, createdAt: .now
            )
            record.fileSize = size
            return record
        }
        XCTAssertEqual(DownloadSizeOrder.largestFirst(records).map(\.postID),
                       ["large", "small", "same-size", "zero", "unknown"])
    }

    func testCollectionProviderFilterNormalizesRestoredSourceNames() {
        XCTAssertEqual(CollectionProviderOrder.key("Erome"), "erome")
        XCTAssertEqual(CollectionProviderOrder.key("www.erome.com"), "erome")
        XCTAssertEqual(CollectionProviderOrder.key("hentaihaven.xxx"), "hhaven")
        XCTAssertEqual(CollectionProviderOrder.name("hhaven"), "Hentai Haven")
        XCTAssertEqual(CollectionProviderOrder.available(["erome", "Rule34", "Erome", "hanime.tv"]),
                       ["erome", "hanime", "rule34"])
    }

    func testDownloadResponseRejectsPornhubHTMLAndPreservesBinaryMedia() {
        let url = URL(string: "https://cdn.pornhub.com/video.mp4")!
        let htmlResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/html"])!
        XCTAssertNotNil(DownloadResponseValidator.failure(response: htmlResponse,
                        header: Data("<html>Unavailable</html>".utf8)))
        let disguisedResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/octet-stream"])!
        XCTAssertNotNil(DownloadResponseValidator.failure(response: disguisedResponse,
                        header: Data("<!DOCTYPE html><html></html>".utf8)))
        XCTAssertNil(DownloadResponseValidator.failure(response: disguisedResponse,
                     header: Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])))
        let forbidden = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [:])!
        XCTAssertTrue(DownloadResponseValidator.failure(response: forbidden, header: Data())?.contains("403") == true)
    }
    func testHanimeDownloadsRequireVideoNotPoster() throws {
        let post = Post(key: "hanime:sample-video", id: "sample-video", provider: "Hanime", type: "video")
        XCTAssertThrowsError(try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://cdn.hanime.tv/poster.jpg", type: "image"),
            for: post))
        let hls = try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://hanime.tv/hls/sample-video/playlist.m3u8", type: "hls"),
            for: post)
        XCTAssertTrue(hls.isHLS)
        let mp4 = try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://cdn.hanime.tv/sample-video.mp4", type: "hls"),
            for: post)
        XCTAssertFalse(mp4.isHLS, "MP4 must be stored as a video file, not an HLS playlist package.")
        let mp4UnderHLSPath = try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://cdn.hanime.tv/hls/full-video.mp4", type: "hls"),
            for: post)
        XCTAssertFalse(mp4UnderHLSPath.isHLS, "An MP4 within /hls/ remains a direct video transfer.")
        let signed = try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://cdn.hanime.tv/video?token=signed", type: "video"),
            for: post)
        XCTAssertFalse(signed.isHLS, "Signed first-party MP4 streams may have opaque URLs.")
        XCTAssertThrowsError(try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://example.com/sample-video.mp4", type: "video"),
            for: post))
    }

    func testPornhubDownloadsRejectPostersButAcceptDeclaredVideo() throws {
        let post = Post(key: "pornhub:123", id: "123", provider: "Pornhub", type: "video")
        XCTAssertThrowsError(try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://cdn.example.test/poster.jpg", type: "video"),
            for: post))
        let stream = try DownloadSourcePolicy.validate(
            media: ResolvedMedia(mediaUrl: "https://cdn.example.test/video.m3u8", type: "hls"),
            for: post)
        XCTAssertTrue(stream.isHLS)
    }

    func testWrappedMotionRotatesSavedVideosBetweenChapters() {
        let posts = (0..<16).map { index in
            Post(key: "redgifs:" + String(index), id: String(index), provider: "RedGIFs",
                 type: index < 10 ? "video" : "image")
        }
        let first = WrappedMotionSelection.select(posts, chapter: 0)
        let later = WrappedMotionSelection.select(posts, chapter: 1)
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(Set(first.map(\.stableID)).count, 6)
        XCTAssertNotEqual(first.map(\.stableID), later.map(\.stableID))
        XCTAssertGreaterThanOrEqual(later.filter { $0.type == "video" }.count, 2)
    }

    func testOfflineImagePreservesSavedPortraitAndLandscapeRatios() {
        let screen = CGSize(width: 390, height: 844)
        let portrait = MediaSizing.offlineCard(aspect: 9.0 / 16.0, available: screen)
        let landscape = MediaSizing.offlineCard(aspect: 16.0 / 9.0, available: screen)
        XCTAssertEqual(portrait.width, 390, accuracy: 0.1)
        XCTAssertEqual(portrait.height, 390 * 16.0 / 9.0, accuracy: 0.1)
        XCTAssertEqual(landscape.width, 390, accuracy: 0.1)
        XCTAssertEqual(landscape.height, 390 * 9.0 / 16.0, accuracy: 0.1)
    }

    func testOfflineRecordKeepsOriginalDimensions() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var record = DownloadRecord(key: "rule34:portrait", provider: "Rule34",
            postID: "portrait", title: "Saved portrait", tags: [],
            thumbnailRemoteURL: "", localMediaPath: file.path,
            kind: .file, state: .complete, progress: 1, createdAt: .now)
        record.mediaType = "image"
        record.pixelWidth = 900
        record.pixelHeight = 1600
        XCTAssertEqual(record.offlinePost?.width, 900)
        XCTAssertEqual(record.offlinePost?.height, 1600)
    }

    @MainActor func testProviderSwitchKeepsNicheSearchOutOfBooruTags() {
        let store = AppStore()
        store.selectedProvider = .redgifs
        store.commitSearch(query: "niche:favorite-community", sort: "popular")
        store.selectedProvider = .rule34
        XCTAssertFalse(store.queryText.contains("niche:"))
        store.commitSearch(query: "favorite_character", sort: "recommended")
        store.selectedProvider = .redgifs
        XCTAssertEqual(store.queryText, "niche:favorite-community")
        store.selectedProvider = .rule34
        XCTAssertEqual(store.queryText, "favorite_character")
    }

    func testHanimeOfflineStreamRetriesAreBoundedAndProviderSpecific() {
        XCTAssertEqual(HanimeDownloadRetryPolicy.nextVariant(provider: "Hanime", attempts: 0), 1)
        XCTAssertEqual(HanimeDownloadRetryPolicy.nextVariant(provider: "hanime", attempts: 1), 2)
        XCTAssertNil(HanimeDownloadRetryPolicy.nextVariant(provider: "Hanime", attempts: 2))
        XCTAssertNil(HanimeDownloadRetryPolicy.nextVariant(provider: "Pornhub", attempts: 0))
        XCTAssertNil(HanimeDownloadRetryPolicy.nextVariant(provider: "Hanime", attempts: -1))
    }

    func testLegacyHanimePreviewNeverCountsAsOfflineVideo() {
        let record = DownloadRecord(key: "hanime:sample-video", provider: "Hanime",
            postID: "sample-video", title: "Preview", tags: [],
            thumbnailRemoteURL: "", localMediaPath: "/tmp/quicktick-legacy-cover.jpg",
            kind: .file, state: .complete, progress: 1, createdAt: .now)
        XCTAssertTrue(record.isHanimePosterOnly)
        XCTAssertNil(record.offlinePost)
        XCTAssertNil(record.exportURL)
    }

    func testHanimeVideoResponseRejectsImageBytes() {
        let url = URL(string: "https://cdn.hanime.tv/sample-video.mp4")!
        let image = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/jpeg"])!
        XCTAssertNotNil(DownloadResponseValidator.failure(
            response: image, header: Data([0xFF, 0xD8, 0xFF]), expectedVideo: true))
        let opaque = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/octet-stream"])!
        XCTAssertNotNil(DownloadResponseValidator.failure(
            response: opaque, header: Data([0xFF, 0xD8, 0xFF]), expectedVideo: true))
        XCTAssertNil(DownloadResponseValidator.failure(
            response: opaque, header: Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70]),
            expectedVideo: true))
        XCTAssertTrue(DownloadResponseValidator.isPreviewImage(header:
            Data("RIFF0000WEBPVP8 ".utf8)))
        XCTAssertTrue(DownloadResponseValidator.isPreviewImage(header:
            Data([0, 0, 0, 28] + Array("ftypavif".utf8))))
        XCTAssertFalse(DownloadResponseValidator.isPreviewImage(header:
            Data([0, 0, 0, 28] + Array("ftypisom".utf8))))
    }

    @MainActor func testRecommendedContinuesPastPageRemovedByNegativePreferences() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedModeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = AppStore(api: QuicktickAPIClient(baseURL: nil, session: session))
        store.selectedProvider = .eporner; store.activeTab = 1
        store.tasteSetup.sources[Provider.eporner.rawValue] = TasteChoice(done: true, into: [], notInto: ["filtered"])
        await store.refresh(immersive: true)
        XCTAssertEqual(store.posts.map(\.stableID), ["eporner:recommended:2"])
        XCTAssertTrue(store.posts.allSatisfy(\.isImmersiveMedia))
        XCTAssertFalse(store.posts.contains { $0.tags.contains("filtered") })
    }
    @MainActor private func candidateStore() -> (AppStore, URLSession) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CandidatePageProtocol.self]
        let session = URLSession(configuration: config)
        return (AppStore(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"), session: session, credentials: ProviderCredentials(rule34User: "test-user", rule34Key: "synthetic-test-key"))), session)
    }
    @MainActor func testRecommendedRefreshAdvancesAndRestoresCandidateCursor() async {
        let (store, session) = candidateStore(); defer { session.invalidateAndCancel() }
        await store.refresh()
        XCTAssertEqual(Set(store.posts.map(\.stableID)), Set(["rule34:feed:1", "rule34:feed:2"]))
        await store.refresh()
        XCTAssertEqual(Set(store.posts.map(\.stableID)), Set(["rule34:feed:3", "rule34:feed:4"]))
        let saved = await store.recommendations.snapshot()
        let (restored, anotherSession) = candidateStore(); defer { anotherSession.invalidateAndCancel() }
        await restored.recommendations.load(saved)
        await restored.refresh()
        XCTAssertEqual(Set(restored.posts.map(\.stableID)), Set(["rule34:feed:5", "rule34:feed:6"]),
                       "Both candidate cursors should persist beyond an app restart")
    }
    @MainActor func testConsumedCandidatePageIsSkippedInsteadOfReinserted() async {
        let (store, session) = candidateStore(); defer { session.invalidateAndCancel() }
        await store.recommendations.record(.impression, post: Post(key: "rule34:feed:1", id: "1", provider: "Rule34"))
        await store.refresh(); XCTAssertEqual(store.posts.map(\.stableID), ["rule34:feed:2"])
    }
    @MainActor func testImmersiveRequestsVideoCandidatesAndSkipsSparsePages() async {
        let (store, session) = candidateStore(); defer { session.invalidateAndCancel() }
        store.activeTab = 1
        await store.refresh(immersive: true)
        XCTAssertTrue(store.feedMediaOnly)
        XCTAssertEqual(Set(store.posts.map(\.stableID)), Set(["rule34:video:3", "rule34:video:4"]))
        await store.loadMore(immersive: true)
        XCTAssertEqual(Set(store.posts.map(\.stableID)), Set([
            "rule34:video:3", "rule34:video:4", "rule34:video:5", "rule34:video:6"
        ]))
        store.activeTab = 0; await store.refresh()
        XCTAssertFalse(store.feedMediaOnly)
        XCTAssertEqual(Set(store.posts.map(\.stableID)), Set(["rule34:feed:1", "rule34:feed:2"]))
    }
    @MainActor func testExplicitSearchKeepsFirstPageSemantics() async {
        let (store, session) = candidateStore(); defer { session.invalidateAndCancel() }
        store.queryText = "engineering"
        await store.refresh(); await store.refresh()
        XCTAssertEqual(store.posts.map(\.stableID), ["rule34:feed:1"])
    }
    func testLegacyRecommendationStateAndDownloadedImageType() throws {
        let legacy = try JSONDecoder().decode(RecommendationState.self, from: Data("{\"version\":3,\"profiles\":{}}".utf8))
        XCTAssertTrue(legacy.candidatePages.isEmpty)
        let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1, 2, 3]).write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        var record = DownloadRecord(key: "saved", provider: "Rule34", postID: "1", title: "Saved image", tags: [], thumbnailRemoteURL: "", localMediaPath: image.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
        XCTAssertEqual(record.offlinePost?.type, "image")
        XCTAssertEqual(record.offlinePost?.cardPreviewURL, image.absoluteString)
        let remote = Post(key: "image", id: "1", provider: "Rule34", mediaUrl: "https://cdn.example.invalid/original.jpg", previewUrl: "https://cdn.example.invalid/tiny.jpg", type: "image")
        XCTAssertEqual(remote.cardPreviewURL, remote.previewUrl,
                       "Use the smaller CDN preview first while full-screen retains the original")
        record.state = .failed; XCTAssertNil(record.offlinePost)
    }
    @MainActor func testRecommendationAdaptationWaitsForVisibleHomeAnchor() async {
        let store = AppStore(); store.selectedProvider = .eporner
        let first = Post(key: "first", id: "1", provider: "Eporner", tags: ["baking"], type: "video")
        let next = Post(key: "next", id: "2", provider: "Eporner", tags: ["racecar"], type: "video")
        let liked = Post(key: "liked", id: "3", provider: "Eporner", tags: ["racecar"])
        await store.recommendations.record(.like, post: liked)
        store.posts = [first, next]
        XCTAssertNil(store.inlinePlaybackID)
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(store.posts.map(\.stableID), ["first", "next"])
        let visibleComic = Post(key: "comic", id: "4", provider: "Eporner", tags: ["baking"], type: "image")
        store.posts = [first, visibleComic, next]
        store.inlinePlaybackID = first.stableID
        store.protectVisibleHomePosts([first.stableID, visibleComic.stableID])
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(store.posts.map(\.stableID), ["first", "comic", "next"], "Ranking must not replace a visible comic with another video")
    }
    @MainActor func testLazyPaginationDoesNotFetchBeforeInitialRefresh() async {
        let store = AppStore()
        await store.loadMore()
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isLoading)
    }
    @MainActor func testPaginationContinuesAfterFullyFilteredInitialPage() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedModeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = AppStore(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"), session: session))
        store.selectedProvider = .eporner; store.feedSort = "recent"; store.exclusions = ["filtered"]
        await store.refresh()
        // Refresh now skips the fully excluded page immediately instead of
        // relying on a footer appearance to request the first useful page.
        XCTAssertEqual(store.posts.map(\.stableID), ["eporner:recent:2"]); XCTAssertFalse(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.stableID), ["eporner:recent:2"])
        XCTAssertFalse(store.hasMore)
    }
    @MainActor func testModeChangeInvalidatesPlaybackAndObsoleteRecommendationResult() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedModeProtocol.self]
        let session = URLSession(configuration: config);defer { session.invalidateAndCancel() }
        let store = AppStore(api: QuicktickAPIClient(baseURL: URL(string: "https://example.invalid"),session: session));store.selectedProvider = .eporner
        let old = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(25))
        store.inlinePlaybackID = "recommended:1";store.feedSort = "recent"
        XCTAssertTrue(store.posts.isEmpty);XCTAssertNil(store.inlinePlaybackID)
        await store.refresh();await old.value
        XCTAssertEqual(store.posts.map(\.stableID),["eporner:recent:1"])
        store.feedSort = "recommended";await store.refresh()
        XCTAssertEqual(Set(store.posts.map(\.stableID)), Set(["eporner:recommended:1", "eporner:recommended:2"]),
                       "Recommended mode combines two independent candidate pools")
    }
    func testVisibleCardUsesCoverageAndHysteresis() {
        let viewport = CGRect(x: 0,y: 0,width: 390,height: 700)
        let frames = ["first":CGRect(x: 0,y: -260,width: 390,height: 300),"next":CGRect(x: 0,y: 100,width: 390,height: 400)]
        XCTAssertEqual(VisiblePostSelector.select(frames: frames,viewport: viewport,current: "first"),"next")
        XCTAssertNil(VisiblePostSelector.select(frames: ["gone":CGRect(x: 0,y: 800,width: 390,height: 100)],viewport: viewport,current: nil))
        let pages = ["first": CGRect(x: 0, y: -700, width: 390, height: 700), "next": CGRect(x: 0, y: 0, width: 390, height: 700)]
        XCTAssertEqual(VisiblePostSelector.select(frames: pages, viewport: viewport, current: "first"), "next", "A stale scroll restoration target must not keep the outgoing page active")
    }
    func testAutomaticPaginationNeedsANewUpwardUserGesture() {
        XCTAssertFalse(HomePaginationPolicy.shouldLoad(upwardDragSequence: 0, consumedSequence: 0,
                                                        loading: false, hasMore: true))
        XCTAssertTrue(HomePaginationPolicy.shouldLoad(upwardDragSequence: 1, consumedSequence: 0,
                                                       loading: false, hasMore: true))
        XCTAssertFalse(HomePaginationPolicy.shouldLoad(upwardDragSequence: 1, consumedSequence: 1,
                                                        loading: false, hasMore: true),
                       "A preview re-layout must not request a second page")
        XCTAssertFalse(HomePaginationPolicy.shouldLoad(upwardDragSequence: 2, consumedSequence: 1,
                                                        loading: true, hasMore: true))
        XCTAssertFalse(HomePaginationPolicy.shouldLoad(upwardDragSequence: 2, consumedSequence: 1,
                                                        loading: false, hasMore: false))
    }
    func testImmersiveFitsOriginalAspectOnPhoneWithoutZooming() {
        let viewport = CGSize(width: 390, height: 820)
        let landscape = MediaSizing.immersive(aspect: 16 / 9, available: viewport)
        XCTAssertEqual(landscape.width, 390, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 390 * 9 / 16, accuracy: 0.001)
        let square = MediaSizing.immersive(aspect: 1, available: viewport)
        XCTAssertEqual(square.width, square.height, accuracy: 0.001)
        XCTAssertEqual(square.width, 390, accuracy: 0.001)
        let portrait = MediaSizing.immersive(aspect: 9 / 16, available: viewport)
        XCTAssertEqual(portrait.width / portrait.height, 9.0 / 16, accuracy: 0.001)
        XCTAssertLessThanOrEqual(portrait.width, viewport.width)
        XCTAssertLessThanOrEqual(portrait.height, viewport.height)
    }
    func testPlaybackUsesMediaBoundsWhenMetadataIsBelowLandscapeViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 874, height: 254)
        let visibleMedia = CGRect(x: 277, y: 164, width: 320, height: 80)
        let cardWithActions = CGRect(x: 277, y: 164, width: 320, height: 220)
        XCTAssertNil(VisiblePostSelector.select(frames: ["video": cardWithActions], viewport: viewport, current: nil))
        XCTAssertEqual(VisiblePostSelector.select(frames: ["video": visibleMedia], viewport: viewport, current: nil), "video")
        XCTAssertEqual(VisiblePostSelector.select(frames: ["video": visibleMedia], viewport: viewport, current: "video"), "video")
    }
    func testCenteredImageDoesNotSuppressVisibleVideoOnTablet() {
        let viewport = CGRect(x: 0, y: 0, width: 1024, height: 1200)
        let frames = ["video": CGRect(x: 352, y: 220, width: 320, height: 280), "image": CGRect(x: 352, y: 520, width: 320, height: 480)]
        XCTAssertEqual(VisiblePostSelector.select(frames: frames, viewport: viewport, current: nil, eligible: ["video"]), "video")
        XCTAssertNil(VisiblePostSelector.select(frames: frames, viewport: viewport, current: "image", eligible: []))
    }
    func testRotationReleasesPeripheralAnchorAndInitialTabletPlaybackStartsAtFirstCard() {
        let portrait = CGRect(x: 0, y: 0, width: 402, height: 700)
        let frames = ["first": CGRect(x: 41, y: 220, width: 320, height: 280), "next": CGRect(x: 41, y: 506, width: 320, height: 280)]
        XCTAssertEqual(VisiblePostSelector.select(frames: frames, viewport: portrait, current: "next"), "first")
        let nearby = ["first": CGRect(x: 41, y: 100, width: 320, height: 280), "next": CGRect(x: 41, y: 386, width: 320, height: 280)]
        XCTAssertEqual(VisiblePostSelector.select(frames: nearby, viewport: portrait, current: "next"), "next")
        let tablet = CGRect(x: 0, y: 0, width: 1024, height: 1200)
        let bothVisible = ["first": CGRect(x: 352, y: 220, width: 320, height: 280), "next": CGRect(x: 352, y: 506, width: 320, height: 280)]
        XCTAssertEqual(VisiblePostSelector.select(frames: bothVisible, viewport: tablet, current: nil), "first")
        XCTAssertEqual(VisiblePostSelector.select(frames: bothVisible, viewport: tablet, current: "first"), "first")
    }
    @MainActor func testRapidForegroundReturnResumesSameOwnerWithoutAViewTaskAndHonorsPause() throws {
        let store = AppStore(); let url = try XCTUnwrap(Bundle.main.url(forResource: "UITestClip", withExtension: "mp4"))
        store.inlinePlaybackID = "visible"
        let player = store.players.activate(key: "visible", url: url, muted: false, owner: "home")
        store.isForeground = false; XCTAssertNil(store.players.activeKey)
        store.isForeground = true
        XCTAssertEqual(store.players.activeKey, "visible")
        XCTAssertEqual(store.players.activeOwner, "home")
        XCTAssertTrue(store.players.player(for: "visible", url: url) === player)
        store.pausedPlaybackID = "visible"
        store.isForeground = false; store.isForeground = true
        XCTAssertNil(store.players.activeKey)
        _ = store.players.activate(key: "visible", url: url, muted: false)
        store.isForeground = false; store.activeTab = 1; store.isForeground = true
        XCTAssertNil(store.players.activeKey)
    }
    @MainActor func testPlayerPoolChangesURLForSameIdentityAndPausesOnTabAndBackground() {
        let store = AppStore();let pool = store.players
        let a = URL(fileURLWithPath: "/tmp/a.mp4"), b = URL(fileURLWithPath: "/tmp/b.mp4")
        let first = pool.activate(key: "one",url: a,muted: false)
        XCTAssertFalse(pool.player(for: "one",url: b) === first)
        _ = pool.activate(key: "two",url: b,muted: true);XCTAssertEqual(first.rate,0)
        store.activeTab = 1;XCTAssertNil(pool.activeKey)
        let immersive = pool.activate(key: "same",url: a,muted: false,owner: "immersive")
        pool.pause("same",owner: "home")
        XCTAssertEqual(pool.activeKey,"same");XCTAssertTrue(pool.player(for:"same",url:a) === immersive)
        _ = pool.activate(key: "three",url: a,muted: false);store.isForeground = false;XCTAssertNil(pool.activeKey)
        XCTAssertLessThanOrEqual(pool.count,3)
    }
    func testHomeFeedCardIsFullBleedOnPhoneAndCappedOnTablet() {
        let phone = CGSize(width: 390, height: 800)
        let video = MediaSizing.feedCard(aspect: 16.0 / 9.0, available: phone)
        XCTAssertEqual(video.width, 390)
        XCTAssertEqual(video.width / video.height, 16.0 / 9.0, accuracy: 0.001)
        let tall = MediaSizing.feedCard(aspect: 0.125, available: phone)
        XCTAssertEqual(tall.width, 390)
        XCTAssertLessThanOrEqual(tall.height, 560)
        let tablet = MediaSizing.feedCard(aspect: 16.0 / 9.0,
                                          available: CGSize(width: 1024, height: 1200))
        XCTAssertEqual(tablet.width, 680)
        let landscape = MediaSizing.feedCard(aspect: 16.0 / 9.0,
                                             available: CGSize(width: 874, height: 322))
        XCTAssertLessThanOrEqual(landscape.height, 322 * 0.72)
        XCTAssertEqual(landscape.width / landscape.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertLessThan(landscape.width, 680, "Short landscape screens must not clip wide video")
    }

    func testHomeFiltersExplicitKeywordBansFromCaptionsAndCreators() {
        var caption = Post(key: "eporner:1", id: "1", provider: "Eporner", tags: ["misc"])
        caption.caption = "Outdoor portrait"
        var creator = Post(key: "redgifs:2", id: "2", provider: "RedGIFs", tags: ["misc"])
        creator.creator = "Blocked Studio"
        let battle = Post(key: "hanime:3", id: "3", provider: "Hanime", tags: ["battle"])
        XCTAssertTrue(RecommendationTagRules.rejects(caption, exclusions: ["portrait"]))
        XCTAssertTrue(RecommendationTagRules.rejects(creator, exclusions: ["blocked studio"]))
        XCTAssertFalse(RecommendationTagRules.rejects(battle, exclusions: ["bat"]))
    }

    func testFurryAliasDatabaseBlocksBooruSpeciesButNotWildlifePhotos() {
        for alias in ["carnivore", "canid", "canidae", "felid", "anthropomorphic_wolf", "scalie", "feral_fox"] {
            let illustration = Post(key: "rule34:\(alias)", id: alias, provider: "rule34",
                                    tags: [alias], type: "image")
            XCTAssertTrue(RecommendationTagRules.rejects(illustration, exclusions: ["furry"]),
                          "Expected furry umbrella exclusion for \(alias)")
        }
        let wildlife = Post(key: "redgifs:wildlife", id: "wildlife", provider: "redgifs",
                            tags: ["canid", "wildlife", "photo"], type: "video")
        XCTAssertFalse(RecommendationTagRules.rejects(wildlife, exclusions: ["furry"]))
        let unrelated = Post(key: "rule34:other", id: "other", provider: "rule34",
                             tags: ["portrait", "landscape"], type: "image")
        XCTAssertFalse(RecommendationTagRules.rejects(unrelated, exclusions: ["furry"]))
    }

    func testSizingMatrixForPhoneTabletAndSplitWindows() {
        for available in [CGSize(width: 358,height: 750),CGSize(width: 810,height: 1080),CGSize(width: 1180,height: 720),CGSize(width: 480,height: 1024)] {
            for native in [CGSize(width: 240,height: 426),CGSize(width: 1920,height: 1080),CGSize(width: 3000,height: 5000),CGSize(width: 320,height: 320)] {
                let output = MediaSizing.size(native: native,aspect: native.width/native.height,available: available)
                XCTAssertLessThanOrEqual(output.width, min(available.width,680))
                XCTAssertLessThanOrEqual(output.height,min(620,available.height*0.72)+1)
                XCTAssertEqual(output.width/output.height,native.width/native.height,accuracy: 0.001)
            }
        }
    }
    func testLowResolutionThumbnailsDoNotShrinkVideoCards() {
        let smallSourceVideo = MediaSizing.size(native: CGSize(width: 240,height: 135),
                                                 aspect: 16 / 9,
                                                 available: CGSize(width: 1024,height: 800))
        XCTAssertEqual(smallSourceVideo.width, 680)
        let landscape = MediaSizing.size(native: CGSize(width: 320,height: 180),
                                         aspect: 16 / 9,
                                         available: CGSize(width: 874,height: 322))
        XCTAssertLessThanOrEqual(landscape.height, 322 * 0.60 + 0.01)
    }
    func testImageCacheDownsamplesAndAvoidsRepeatedDecode() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(data:nil,width: 2000,height:1000,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);CGImageDestinationFinalize(destination)
        let pipeline = MediaImagePipeline();let coldStart = Date()
        let first = try await pipeline.image(raw: url.absoluteString,pixels:512)
        let cold = Date().timeIntervalSince(coldStart);let warmStart = Date()
        let second = try await pipeline.image(raw:url.absoluteString,pixels:512)
        let warm = Date().timeIntervalSince(warmStart)
        XCTAssertTrue(first.image === second.image);XCTAssertLessThanOrEqual(first.image.width,512)
        let hits = await pipeline.hits;XCTAssertEqual(hits,1)
        print("QUICKTICK_METRIC image cold_ms=\(cold*1000) warm_ms=\(warm*1000)")
    }
    func testCardPreviewsKeepFallbackThumbnailsWithoutFetchingVideosAsImages() {
        let video = Post(key: "pornhub:fixture", id: "fixture", provider: "Pornhub",
            mediaUrl: "https://media.example.invalid/video.mp4", previewUrl: "https://img.example.invalid/large.jpg",
            thumbUrl: "https://img.example.invalid/small.jpg", type: "video")
        XCTAssertEqual(video.previewImageURLs, [
            "https://img.example.invalid/large.jpg", "https://img.example.invalid/small.jpg"
        ])
        let noPoster = Post(key: "pornhub:empty", id: "empty", provider: "Pornhub",
            mediaUrl: "https://media.example.invalid/video.mp4", type: "video")
        XCTAssertTrue(noPoster.previewImageURLs.isEmpty,
            "The UI must display its designed fallback instead of decoding a movie as a poster")
        let image = Post(key: "rule34:fixture", id: "fixture", provider: "Rule34",
            mediaUrl: "https://media.example.invalid/original.jpg", previewUrl: "https://media.example.invalid/thumb.jpg",
            thumbUrl: "https://media.example.invalid/thumb.jpg", type: "image")
        XCTAssertEqual(image.previewImageURLs, [
            "https://media.example.invalid/thumb.jpg", "https://media.example.invalid/original.jpg"
        ])
    }
    func testLargeComicPreviewIsBoundedAndKeepsNativeMetadata() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:url) }
        let context = CGContext(data:nil,width:600,height:12000,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);CGImageDestinationFinalize(destination)
        let image = try await MediaImagePipeline().image(raw:url.absoluteString,pixels:512,comicPreview:true)
        XCTAssertTrue(image.comic);XCTAssertEqual(image.nativeSize,CGSize(width:600,height:12000))
        XCTAssertLessThanOrEqual(image.image.width,512);XCTAssertLessThan(image.cost,2_000_000)
        XCTAssertEqual(Double(image.image.width)/Double(image.image.height),2.0/3,accuracy:0.01)
    }
    func testSizingPreservesExtremeAspectAndShortWindow() {
        let wide = MediaSizing.size(native:CGSize(width:4000,height:200),aspect:20,available:CGSize(width:900,height:400))
        XCTAssertEqual(wide.width/wide.height,20,accuracy:0.001)
        let short = MediaSizing.size(native:nil,aspect:1,available:CGSize(width:900,height:100))
        XCTAssertLessThanOrEqual(short.height,72)
    }
    func testDirectProviderMediaURLIsAbsolute() async throws {
        let resolver = MediaResolver(api:QuicktickAPIClient(baseURL:URL(string:"https://example.invalid")))
        let result = try await resolver.resolve(Post(key:"rule34:1",id:"1",provider:"Rule34",mediaUrl:"/sample.mp4",type:"video"))
        XCTAssertEqual(result.mediaUrl,"https://rule34.xxx/sample.mp4")
    }
    func testWordPieceMasksPunctuationAndSubwords() {
        let tokenizer = WordPieceTokenizer(vocabulary:["[PAD]":0,"[CLS]":101,"[SEP]":102,"[UNK]":100,"race":1,"##car":2,",":3,"aero":4])
        let encoded = tokenizer.encode("Racecar, Áero",length:8)
        XCTAssertEqual(encoded.ids,[101,1,2,3,4,102,0,0]);XCTAssertEqual(encoded.mask,[1,1,1,1,1,1,0,0])
    }
    func testUnavailableSemanticModelRetainsLocalKeywordFeed() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let engine = RecommendationEngine(semantic:SemanticRecommender(directory:folder,enabled:false))
        let liked = Post(key:"liked",id:"1",provider:"rule34",tags:["engineering"])
        let related = Post(key:"related",id:"2",provider:"rule34",tags:["engineering"])
        let other = Post(key:"other",id:"3",provider:"rule34",tags:["baking"])
        await engine.record(.like,post:liked)
        let result = await engine.rank([other,related],taste:TasteChoice(),recent:[])
        XCTAssertEqual(result.first?.stableID,"related");XCTAssertEqual(result.count,2)
    }
    func testActualBGEMicroRecognizesNonMatchingKeywordsAndCaches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let semantic = SemanticRecommender(directory:folder)
        let interest = Post(key:"interest",id:"1",provider:"Eporner",tags:["F1 aerodynamics","McLaren engineering","race car suspension"])
        let related = Post(key:"related",id:"2",provider:"Eporner",tags:["ground effect downforce in racing cars"])
        let unrelated = Post(key:"unrelated",id:"3",provider:"Eporner",tags:["baking chocolate cake"])
        let a = try await semantic.embed(interest), b = try await semantic.embed(related), c = try await semantic.embed(unrelated)
        XCTAssertEqual(a.count,384);XCTAssertGreaterThan(SemanticRecommender.cosine(a,b),SemanticRecommender.cosine(a,c)+0.1)
        await semantic.record(.like,post:interest)
        let scores = await semantic.scores([related,unrelated]);XCTAssertGreaterThan(scores["related"]!.recent,scores["unrelated"]!.recent)
        let taste = TasteChoice(done: true, into: interest.tags, notInto: ["baking chocolate cake"])
        await semantic.preparePreferences(taste)
        let before = await semantic.cacheMisses
        let explicit = await semantic.scores([related, unrelated], taste: taste)
        XCTAssertGreaterThan(explicit["related"]!.preference, explicit["unrelated"]!.preference)
        XCTAssertGreaterThan(explicit["unrelated"]!.avoidance, explicit["related"]!.avoidance)
        let after = await semantic.cacheMisses; XCTAssertEqual(before, after)
        _ = try await semantic.embed(interest);let hits = await semantic.cacheHits;XCTAssertGreaterThanOrEqual(hits,2)
        let restored = SemanticRecommender(directory:folder,enabled:false)
        let persisted = try await restored.embed(interest);XCTAssertEqual(persisted,a)
        let restoredHits = await restored.cacheHits;XCTAssertEqual(restoredHits,1)
        let load = await semantic.modelLoadMs;let warm = await semantic.embeddingMs
        print("QUICKTICK_METRIC bge_load_ms=\(load) embedding_ms=\(warm)")
    }

    @MainActor func testImmersiveRanksOnlyUnseenTailAndKeepsViewedPrefix() async {
        let store = AppStore(); store.selectedProvider = .eporner; store.activeTab = 1
        let first = Post(key: "viewed", id: "1", provider: "Eporner", tags: ["baking"], type: "video")
        let current = Post(key: "current", id: "2", provider: "Eporner", tags: ["baking"], type: "video")
        let weak = Post(key: "weak", id: "3", provider: "Eporner", tags: ["baking"], type: "video")
        let strong = Post(key: "strong", id: "4", provider: "Eporner", tags: ["engineering"], type: "video")
        await store.recommendations.record(.like, post: strong)
        store.posts = [first, current, weak, strong]
        store.protectImmersivePost(current.stableID)
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(Array(store.posts.prefix(2)), [first, current])
        XCTAssertEqual(store.posts[2].stableID, strong.stableID)
        store.protectImmersivePost(first.stableID)
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(Array(store.posts.prefix(2)), [first, current])
    }
    @MainActor func testOrdinaryImmersiveFeedKeepsNextClipDuringBackgroundRanking() async {
        let store = AppStore(); store.selectedProvider = .eporner; store.activeTab = 1
        // Two independent posts may resolve to one CDN video URL. A normal
        // (non-personalized) feed must not lose the only next page mid-swipe.
        let first = Post(key: "clip-a", id: "1", provider: "Eporner", tags: ["portrait"],
                         mediaUrl: "https://cdn.example.invalid/shared.mp4", type: "video")
        let next = Post(key: "clip-b", id: "2", provider: "Eporner", tags: ["portrait"],
                        mediaUrl: first.mediaUrl, type: "video")
        store.posts = [first, next]
        store.protectImmersivePost(first.stableID)
        await store.adaptRecommendationTail(token: store.feedRevision)
        XCTAssertEqual(store.posts.map(\.stableID), [first.stableID, next.stableID])
    }
    @MainActor func testSearchCommitRetainsFeedUntilNewResponse() {
        let store = AppStore()
        let current = Post(key: "current", id: "1", provider: "Eporner", type: "video")
        store.posts = [current]
        store.commitSearch(query: "engineering -blocked", sort: "recent")
        XCTAssertEqual(store.posts, [current])
        XCTAssertEqual(store.queryText, "engineering -blocked")
        XCTAssertEqual(store.feedSort, "recent")
    }

    @MainActor func testTabSwitchRestoresIndependentQueriesAndFeeds() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedModeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = AppStore(api: QuicktickAPIClient(baseURL: nil, session: session)); store.selectedProvider = .eporner
        let home = Post(key: "home-saved", id: "1", provider: "Eporner", type: "image")
        let clip = Post(key: "clip-saved", id: "2", provider: "Eporner", type: "video")
        store.commitSearch(query: "home_tag", sort: "recent"); await store.refresh(); store.posts = [home]
        await store.selectFeedTab(1)
        store.commitSearch(query: "video_tag -blocked", sort: "popular"); await store.refresh(immersive: true); store.posts = [clip]
        await store.selectFeedTab(0)
        XCTAssertEqual(store.queryText, "home_tag"); XCTAssertEqual(store.feedSort, "recent"); XCTAssertEqual(store.posts, [home])
        await store.selectFeedTab(1)
        XCTAssertEqual(store.queryText, "video_tag -blocked"); XCTAssertEqual(store.feedSort, "popular"); XCTAssertEqual(store.posts, [clip])
        store.handleMemoryPressure()
    }
}
