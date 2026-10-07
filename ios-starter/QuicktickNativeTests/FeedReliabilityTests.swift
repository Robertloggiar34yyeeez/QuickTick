import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import QuicktickNative

private final class FeedModeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let sort = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sort" }?.value ?? "recommended"
        let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
        let post = Post(key: "\(sort):\(page)", id: String(page), provider: "Eporner", tags: [page == 1 ? "filtered" : "keep"], type: "video")
        let data = try! JSONEncoder().encode(PostPage(items: [post], hasMore: page == 1))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        DispatchQueue.global().asyncAfter(deadline: .now() + (sort == "recommended" ? 0.15 : 0)) { [self] in
            client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self,didLoad: data);client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
final class FeedReliabilityTests: XCTestCase {
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
        XCTAssertTrue(store.posts.isEmpty); XCTAssertTrue(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.stableID), ["recent:2"])
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
        XCTAssertEqual(store.posts.map(\.stableID),["recent:1"])
        store.feedSort = "recommended";await store.refresh()
        XCTAssertEqual(store.posts.map(\.stableID),["recommended:1"])
    }
    func testVisibleCardUsesCoverageAndHysteresis() {
        let viewport = CGRect(x: 0,y: 0,width: 390,height: 700)
        let frames = ["first":CGRect(x: 0,y: -260,width: 390,height: 300),"next":CGRect(x: 0,y: 100,width: 390,height: 400)]
        XCTAssertEqual(VisiblePostSelector.select(frames: frames,viewport: viewport,current: "first"),"next")
        XCTAssertNil(VisiblePostSelector.select(frames: ["gone":CGRect(x: 0,y: 800,width: 390,height: 100)],viewport: viewport,current: nil))
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
    func testSizingMatrixForPhoneTabletAndSplitWindows() {
        for available in [CGSize(width: 358,height: 750),CGSize(width: 810,height: 1080),CGSize(width: 1180,height: 720),CGSize(width: 480,height: 1024)] {
            for native in [CGSize(width: 240,height: 426),CGSize(width: 1920,height: 1080),CGSize(width: 3000,height: 5000),CGSize(width: 320,height: 320)] {
                let output = MediaSizing.size(native: native,aspect: native.width/native.height,available: available)
                XCTAssertLessThanOrEqual(output.width, min(native.width,available.width,680))
                XCTAssertLessThanOrEqual(output.height,min(620,available.height*0.72)+1)
                XCTAssertEqual(output.width/output.height,native.width/native.height,accuracy: 0.001)
            }
        }
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
        XCTAssertEqual(result.mediaUrl,"https://example.invalid/sample.mp4")
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
        _ = try await semantic.embed(interest);let hits = await semantic.cacheHits;XCTAssertGreaterThanOrEqual(hits,2)
        let restored = SemanticRecommender(directory:folder,enabled:false)
        let persisted = try await restored.embed(interest);XCTAssertEqual(persisted,a)
        let restoredHits = await restored.cacheHits;XCTAssertEqual(restoredHits,1)
        let load = await semantic.modelLoadMs;let warm = await semantic.embeddingMs
        print("QUICKTICK_METRIC bge_load_ms=\(load) embedding_ms=\(warm)")
    }
}
