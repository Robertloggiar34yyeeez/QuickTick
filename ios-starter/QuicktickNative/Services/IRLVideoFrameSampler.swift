import Foundation
import AVFoundation
import CoreGraphics

/// Bounded sampling and fusion for IRL videos. Called only by the deferred
/// visual taste analyzer, never during scrolling or the immersive player.
enum IRLVideoFrameSamplingPlan {
    static func eligible(_ post: Post, domain: VisualDomain) -> Bool {
        post.type.lowercased() == "video" &&
            VisualAppearanceEncoder.prefersMobileCLIP(domain: domain, provider: post.provider)
    }

    static func times(duration: Double) -> [Double] {
        guard duration.isFinite, duration >= 3 else { return [] }
        let window = min(duration, 90)
        return [0.16, 0.49, 0.82].map { window * $0 }
    }

    static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty,
              vectors.allSatisfy({ $0.count == first.count }) else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            for index in vector.indices { sum[index] += vector[index] }
        }
        let length = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
        guard length.isFinite, length > 0 else { return [] }
        return sum.map { $0 / length }
    }

    static func consensus(_ observations: [[String: Double]]) -> [String: Double] {
        guard observations.count >= 2 else { return [:] }
        var counts: [String: Int] = [:]
        var totals: [String: Double] = [:]
        for frame in observations {
            for (key, value) in frame where value.isFinite && value >= 0.5 {
                counts[key, default: 0] += 1
                totals[key, default: 0] += value
            }
        }
        let needed = max(2, (observations.count + 1) / 2)
        var result: [String: Double] = [:]
        for (key, total) in totals {
            let found = counts[key] ?? 0
            if found >= needed { result[key] = min(0.95, total / Double(found)) }
        }
        return result
    }

    static func duplicate(_ first: UInt64?, _ second: UInt64?) -> Bool {
        guard let first, let second else { return false }
        return (first ^ second).nonzeroBitCount <= 6
    }
}

actor IRLVideoFrameSampler {
    static let shared = IRLVideoFrameSampler()

    func frames(for post: Post, resolver: MediaResolver?) async -> [DecodedMediaImage] {
        guard !Task.isCancelled,
              IRLVideoFrameSamplingPlan.eligible(post, domain: VisualDomain.classify(post) ?? .uncertain)
        else { return [] }
        let raw = URL(string: post.mediaUrl)
        let media: URL?
        if let raw, valid(raw) { media = raw }
        else if let resolver { media = try? await resolver.resolve(post).mediaUrlURL }
        else { media = nil }
        guard !Task.isCancelled, let media, valid(media) else { return [] }
        let headers = EromeGeneratedAPI.mediaHeaders(for: media)
        let asset = headers.isEmpty ? AVURLAsset(url: media)
            : AVURLAsset(url: media, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        guard let duration = try? await asset.load(.duration) else { return [] }
        let times = IRLVideoFrameSamplingPlan.times(duration: duration.seconds)
        guard !times.isEmpty, !Task.isCancelled else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        // Nearest keyframes reduce remote decoding and bandwidth usage.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)
        var results: [DecodedMediaImage] = []
        var fingerprints: [UInt64?] = []
        for second in times {
            guard !Task.isCancelled else { break }
            guard let result = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
            else { continue }
            let image = result.image
            let fingerprint = VisualAnalysisService.fingerprint(image)
            if fingerprints.contains(where: { IRLVideoFrameSamplingPlan.duplicate($0, fingerprint) }) { continue }
            results.append(DecodedMediaImage(image: image,
                nativeSize: CGSize(width: image.width, height: image.height), comic: false,
                perceptualHash: fingerprint))
            fingerprints.append(fingerprint)
        }
        generator.cancelAllCGImageGeneration()
        return results
    }

    private func valid(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return false }
        // Do not fetch HTML, HLS manifests or unsupported streaming formats.
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
}
