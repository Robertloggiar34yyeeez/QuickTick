import Foundation
import CoreGraphics

struct VisiblePostSelector {
    static func immersive(frames: [String: CGRect], viewport: CGRect, current: String?, keys: Set<String>) -> String? {
        // Between full pages neither crosses the normal visibility threshold.
        // Keep ownership through that gap and transient empty layout preferences.
        select(frames: frames, viewport: viewport, current: current, eligible: keys)
            ?? current.flatMap { keys.contains($0) ? $0 : nil }
    }
    static func select(frames: [String: CGRect], viewport: CGRect, current: String?, eligible: Set<String>? = nil) -> String? {
        guard viewport.height > 0 else { return nil }
        let candidates = frames.compactMap { key, rect -> (String, CGFloat, CGFloat)? in
            guard rect.height > 0, eligible?.contains(key) != false else { return nil }
            let visible = rect.intersection(viewport).height
            let fraction = visible / min(rect.height, viewport.height)
            return fraction >= 0.55 ? (key, abs(rect.midY - viewport.midY), rect.minY) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        // Enter a feed at its first sufficiently visible playable card. Large
        // windows can expose several complete cards before playback starts.
        if current == nil {
            return candidates.min { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }?.0
        }
        // Retention prevents jitter, but must not pin a peripheral card after
        // rotation or scrolling exposes a substantially more centered card.
        if let current, eligible?.contains(current) != false, let frame = frames[current], frame.height > 0,
           frame.intersection(viewport).height / min(frame.height, viewport.height) >= 0.65,
           abs(frame.midY - viewport.midY) <= (candidates.first?.1 ?? .infinity) + viewport.height * 0.25 { return current }
        return candidates.first?.0
    }
}

enum PlaybackPosition {
    static func resume(_ seconds: Double?, duration: Double) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0, duration.isFinite,
              duration > 1, seconds < duration - 0.5 else { return nil }
        return seconds
    }
}

enum MediaSizing {
    // Full viewing canvas: deliberately separate from the bounded Home cards.
    static func immersive(aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
        let width = max(1, min(available.width, max(1, available.height) * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    static func size(native: CGSize?, aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 4 / 3
        let wide = available.width > 600
        let maxHeight = min(wide ? 620 : 560, max(1, available.height * 0.72))
        let width = max(1, min(available.width, 680))
        return CGSize(width: width, height: max(1, min(width / ratio, maxHeight)))
    }
}
