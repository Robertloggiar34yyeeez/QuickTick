import SwiftUI
import ImageIO
import UIKit

// Only one active GIF is decoded. Frames are sampled and downscaled to bound memory.
struct GIFFrames: @unchecked Sendable {
    let images: [UIImage]
    let duration: Double
    static func decode(_ data: Data) -> GIFFrames? {
        guard data.count <= 32 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var ends: [Double] = []; var duration = 0.0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += max(0.02, (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1)
            ends.append(duration)
        }
        let samples = min(60, max(count, Int(ceil(min(duration, 30) * 15))))
        var images: [UIImage] = []; var decoded: [Int: UIImage] = [:]; var index = 0
        for sample in 0..<samples {
            let time = Double(sample) / Double(samples) * duration
            while index < count - 1 && ends[index] <= time { index += 1 }
            if decoded[index] == nil {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 360, kCGImageSourceCreateThumbnailWithTransform: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
                decoded[index] = UIImage(cgImage: image)
            }
            if let image = decoded[index] { images.append(image) }
        }
        return GIFFrames(images: images, duration: duration)
    }
}

struct AnimatedGIFSurface: View {
    let url: URL
    var playing = true
    var naturalAspect = false
    @State private var frames: GIFFrames?
    @State private var failed = false
    var body: some View {
        Group {
            if let frames {
                if naturalAspect, let size = frames.images.first?.size {
                    GIFImageView(frames: frames, playing: playing).aspectRatio(size.width / max(1, size.height), contentMode: .fit)
                } else { GIFImageView(frames: frames, playing: playing) }
            }
            else if failed { Text("GIF could not be loaded").foregroundStyle(.white) }
            else { ProgressView().tint(.white) }
        }.task(id: url) {
            do {
                let data: Data
                if url.isFileURL { data = try Data(contentsOf: url) }
                else { (data, _) = try await URLSession.shared.data(from: url) }
                let decoded = await Task.detached(priority: .userInitiated) { GIFFrames.decode(data) }.value
                guard !Task.isCancelled else { return }
                frames = decoded; failed = decoded == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct GIFImageView: UIViewRepresentable {
    let frames: GIFFrames
    let playing: Bool
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(); view.contentMode = .scaleAspectFit; view.clipsToBounds = true
        view.animationImages = frames.images; view.animationDuration = frames.duration
        view.animationRepeatCount = 0; view.image = frames.images.first
        if playing { view.startAnimating() }
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        if playing && !view.isAnimating { view.startAnimating() }
        else if !playing && view.isAnimating { view.stopAnimating() }
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Void) { view.stopAnimating(); view.animationImages = nil }
}
