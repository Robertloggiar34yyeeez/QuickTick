import XCTest
import AVFoundation
@testable import QuicktickNative

final class ImmersiveMediaTests: XCTestCase {
    func testPagingGapKeepsCurrentPlayerButDeletedPostDoesNot() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let halfway = ["first": CGRect(x: 0, y: -400, width: 400, height: 800), "next": CGRect(x: 0, y: 400, width: 400, height: 800)]
        XCTAssertEqual(VisiblePostSelector.immersive(frames: halfway, viewport: viewport, current: "first", keys: ["first", "next"]), "first")
        XCTAssertEqual(VisiblePostSelector.immersive(frames: [:], viewport: viewport, current: "first", keys: ["first", "next"]), "first")
        XCTAssertNil(VisiblePostSelector.immersive(frames: [:], viewport: viewport, current: "first", keys: ["next"]))
        XCTAssertEqual(VisiblePostSelector.immersive(frames: ["next": viewport], viewport: viewport, current: "first", keys: ["first", "next"]), "next")
        XCTAssertNil(VisiblePostSelector.select(frames: halfway, viewport: viewport, current: "first"))
    }
    func testResumeRejectsEndOrInvalidDurationBeforeSeeking() {
        XCTAssertEqual(PlaybackPosition.resume(5, duration: 20), 5)
        for position in [Double.nan, .infinity, -1, 0, 19.9, 20, 50] {
            XCTAssertNil(PlaybackPosition.resume(position, duration: 20))
        }
        XCTAssertNil(PlaybackPosition.resume(5, duration: .nan))
        XCTAssertNil(PlaybackPosition.resume(5, duration: .infinity))
        XCTAssertNil(PlaybackPosition.resume(5, duration: 0))
    }
    @MainActor func testLateInlineSelectionCannotPauseImmersivePlayback() {
        let store = AppStore()
        let url = URL(fileURLWithPath: "/tmp/clip.mp4")
        _ = store.players.activate(key: "clip", url: url, muted: true, owner: "immersive")
        store.inlinePlaybackID = "late-home-layout"
        XCTAssertEqual(store.players.activeKey, "clip")
        XCTAssertEqual(store.players.activeOwner, "immersive")
        store.players.releaseAll()
    }
    @MainActor func testRealFixtureAdvancesAfterFirstActivationAndReverseSwipe() async throws {
        let posts = try await UITestMediaFactory.shared.posts(sort: "recommended")
        let url = try XCTUnwrap(URL(string: posts[0].mediaUrl))
        let pool = PlayerPool()
        defer { pool.releaseAll() }
        for key in ["first", "next", "first"] {
            let player = pool.activate(key: key, url: url, muted: true, owner: "immersive")
            let start = player.currentTime().seconds
            for _ in 0..<200 {
                if player.currentTime().seconds > start + 0.2 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(player.currentItem?.status, .readyToPlay)
            XCTAssertGreaterThan(player.currentTime().seconds, start + 0.2, "Playback must advance on \(key)")
        }
    }
    func testImmersiveLandscapeUsesCanvasInsteadOfHomeNativeSizeCap() {
        let available = CGSize(width: 1280, height: 900)
        let output = MediaSizing.immersive(aspect: 16 / 9, available: available)
        XCTAssertEqual(output.width, 1280)
        XCTAssertEqual(output.height, 720)
        XCTAssertEqual(MediaSizing.size(native: CGSize(width: 320, height: 180), aspect: 16 / 9, available: available).width, 680)
    }
    func testImmersiveAspectFitAcrossRotationAndSplitWindows() {
        for available in [CGSize(width: 1280, height: 900), CGSize(width: 900, height: 1280), CGSize(width: 600, height: 800)] {
            for ratio: CGFloat in [9 / 16, 16 / 9, 1, 4 / 3] {
                let output = MediaSizing.immersive(aspect: ratio, available: available)
                XCTAssertLessThanOrEqual(output.width, available.width)
                XCTAssertLessThanOrEqual(output.height, available.height + 0.001)
                XCTAssertEqual(output.width / output.height, ratio, accuracy: 0.001)
                XCTAssertTrue(abs(output.width - available.width) < 0.001 || abs(output.height - available.height) < 0.001)
            }
        }
    }
    @MainActor func testActivatingNextClipRetainsPreparedWindowAndPausesPrevious() {
        let pool = PlayerPool()
        let url = URL(fileURLWithPath: "/tmp/clip.mp4")
        let current = pool.activate(key: "current", url: url, muted: false, owner: "immersive")
        pool.prewarm(key: "next", url: url)
        let next = pool.player(for: "next", url: url)
        pool.prewarm(key: "later", url: url)
        let later = pool.player(for: "later", url: url)
        XCTAssertTrue(pool.activate(key: "next", url: url, muted: true, owner: "immersive") === next)
        XCTAssertEqual(current.rate, 0)
        XCTAssertTrue(next.isMuted)
        XCTAssertEqual(pool.activeKey, "next")
        XCTAssertTrue(pool.player(for: "later", url: url) === later)
        XCTAssertEqual(pool.count, 3)
        pool.releaseAll()
    }
    func testImmersiveNeverIncludesStillOrUnknownMedia() {
        let posts = ["video", "gif", "image", "", "VIDEO", "GIF"].enumerated().map { Post(key: "test:\($0.offset)", id: String($0.offset), provider: "Rule34", type: $0.element) }
        XCTAssertEqual(posts.filter(\.isImmersiveMedia).map(\.type), ["video", "gif", "VIDEO", "GIF"])
    }
    @MainActor func testPlayerPoolReusesPreparedClipAndBoundsMemory() {
        let pool = PlayerPool()
        let url = URL(fileURLWithPath: "/tmp/clip.mp4")
        let first = pool.player(for: "first", url: url)
        XCTAssertTrue(first.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(first.currentItem?.preferredForwardBufferDuration, 3)
        XCTAssertTrue(pool.player(for: "first", url: url) === first)
        for index in 0..<pool.capacity { _ = pool.player(for: "clip\(index)", url: url) }
        XCTAssertFalse(pool.player(for: "first", url: url) === first)
        pool.releaseAll()
    }
}
