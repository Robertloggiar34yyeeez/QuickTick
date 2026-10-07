import Foundation
import CoreGraphics

struct VisiblePostSelector {
    static func select(frames: [String: CGRect], viewport: CGRect, current: String?, eligible: Set<String>? = nil) -> String? {
        guard viewport.height > 0 else { return nil }
        let candidates = frames.compactMap { key, rect -> (String, CGFloat)? in
            guard rect.height > 0, eligible?.contains(key) != false else { return nil }
            let visible = rect.intersection(viewport).height
            let fraction = visible / min(rect.height, viewport.height)
            return fraction >= 0.55 ? (key, abs(rect.midY - viewport.midY)) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        if let current, eligible?.contains(current) != false, let frame = frames[current], frame.intersection(viewport).height / min(frame.height, viewport.height) >= 0.65 { return current }
        return candidates.first?.0
    }
}

enum MediaSizing {
    static func size(native: CGSize?, aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 4 / 3
        let wide = available.width > 600
        let maxHeight = min(wide ? 620 : 560, max(1, available.height * 0.72))
        var width = min(available.width, wide ? 680 : available.width, maxHeight * ratio)
        if let native, native.width > 0 { width = min(width, native.width) }
        return CGSize(width: max(1, width), height: max(1, width / ratio))
    }
}
