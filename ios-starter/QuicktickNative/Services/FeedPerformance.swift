import Foundation
import os

enum FeedPerformance {
    static func emit(_ stage: String, started: Date, count: Int) {
        #if DEBUG
        let ms = Date().timeIntervalSince(started) * 1000
        Logger(subsystem: "QuickTick", category: "FeedPerformance").debug("stage=\(stage, privacy: .public) ms=\(ms, privacy: .public) posts=\(count, privacy: .public)")
        #endif
    }
}
