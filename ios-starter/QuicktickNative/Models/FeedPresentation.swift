import Foundation
import CoreGraphics

// Pure gesture classifier for Home and Immersive. Ignore layout jitter,
 // backwards paging, and deliberate viewing. A return to a previously
 // skipped post is always neutralization, never positive feedback.
enum QuickSkipDecision {
    static func dislikes(elapsed: TimeInterval, from: Int, to: Int) -> Bool {
        elapsed.isFinite && to > from && elapsed >= 0.08 && elapsed <= 1.25
    }
}

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
           frame.intersection(viewport).height / min(frame.height, viewport.height) >= 0.52,
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
    /// Natural Home geometry for images and videos, just like Downloads.
    /// Exceptionally long comic strips are preview-cropped in the feed.
    static func feedCard(aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio: CGFloat = aspect.isFinite && aspect > 0 ? aspect : CGFloat(4) / 3
        let fullWidth = max(1, min(available.width, 680))
        let shortViewport = available.height < 500
        let shortCap = max(1, available.height * 0.72)
        let width = ratio >= 1 && shortViewport
            ? min(fullWidth, shortCap * ratio) : fullWidth
        let naturalHeight = width / ratio
        let comicCap = min(available.width > 600 ? CGFloat(620) : CGFloat(560),
                            max(1, available.height * (shortViewport ? 0.60 : 0.72)))
        let height = ratio < 1.0 / 3.0 ? min(naturalHeight, comicCap) : naturalHeight
        return CGSize(width: width, height: max(1, height))
    }

    /// Offline media is rendered at its original ratio and available width,
    /// not the Home preview's bounded/cropped height. Long comics are
    /// clamped by the card caller and remain full size in the reader.
    static func offlineCard(aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : CGFloat(4) / 3
        let width = max(1, min(available.width, 680))
        return CGSize(width: width, height: max(1, width / ratio))
    }

    // Full viewing canvas: deliberately separate from the bounded Home cards.
    static func immersive(aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
        let width = max(1, min(available.width, max(1, available.height) * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    static func size(native: CGSize?, aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 4 / 3
        let wide = available.width > 600
        let maxHeight = min(wide ? 620 : 560,
                            max(1, available.height * (available.height < 500 ? 0.60 : 0.72)))
        // The source's native pixel count is not a point-size limit. An
        // 240px video thumbnail on iPad must not produce a 240pt card.
        let width = max(1, min(available.width, 680, maxHeight * ratio))
        return CGSize(width: width, height: width / ratio)
    }
}

// Count advancing media time, capped by elapsed wall time. Buffering, pauses,
// loading and discontinuous seeks never become positive engagement.
struct PlaybackExposure {
    static func completion(position: Double, watched: Double, duration: Double) -> Double {
        guard position.isFinite, watched.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(1, min(position, watched / duration)))
    }

    private var previousMedia: Double?
    private var previousWall: Double?
    private var wasPlaying = false
    mutating func sample(media: Double?, wall: Double, playing: Bool) -> Double {
        defer { previousMedia = media; previousWall = wall; wasPlaying = playing }
        guard playing || wasPlaying, let previousWall, wall > previousWall else { return 0 }
        let elapsed = min(2, wall - previousWall)
        guard let media, let previousMedia, media.isFinite, previousMedia.isFinite else { return 0 }
        let advance = media - previousMedia
        guard advance > 0, advance <= elapsed * 1.5 + 0.25 else { return 0 }
        return min(elapsed, advance)
    }
}
