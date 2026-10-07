import XCTest
import AVFoundation
@testable import QuicktickNative

final class ImmersiveMediaTests: XCTestCase {
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
