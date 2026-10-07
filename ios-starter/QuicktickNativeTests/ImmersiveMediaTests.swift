import XCTest
import AVFoundation
@testable import QuicktickNative

final class ImmersiveMediaTests: XCTestCase {
    func testImmersiveLandscapeUsesCanvasInsteadOfHomeNativeSizeCap() {
        let available = CGSize(width: 1280, height: 900)
        let output = MediaSizing.immersive(aspect: 16 / 9, available: available)
        XCTAssertEqual(output.width, 1280)
        XCTAssertEqual(output.height, 720)
        XCTAssertEqual(MediaSizing.size(native: CGSize(width: 320, height: 180), aspect: 16 / 9, available: available).width, 320)
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
        XCTAssertFalse(first.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(first.currentItem?.preferredForwardBufferDuration, 3)
        XCTAssertTrue(pool.player(for: "first", url: url) === first)
        for index in 0..<pool.capacity { _ = pool.player(for: "clip\(index)", url: url) }
        XCTAssertFalse(pool.player(for: "first", url: url) === first)
        pool.releaseAll()
    }
}
