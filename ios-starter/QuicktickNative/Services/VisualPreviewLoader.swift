import Foundation
import ImageIO

/// One small still preview at a time, only on unconstrained, inexpensive networks.
actor VisualPreviewLoader {
    static let shared = VisualPreviewLoader()
    private let session: URLSession
    private var failures: [String: Date] = [:]
    private var loading = false
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.allowsExpensiveNetworkAccess = false; config.allowsConstrainedNetworkAccess = false
        config.networkServiceType = .background; config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config)
    }
    static func thumbnailURL(_ post: Post) -> URL? {
        // Never fall back to the original: that can be a huge image or a video.
        [post.thumbUrl, post.previewUrl].compactMap { NativeProviderAPI.mediaURL($0) }.first {
            !["mp4", "m3u8", "mov", "webm", "gif"].contains($0.pathExtension.lowercased())
        }
    }
    func image(_ post: Post) async -> DecodedMediaImage? {
        guard !loading, !Task.isCancelled, let url = Self.thumbnailURL(post), (failures[url.absoluteString] ?? .distantPast) < .now else { return nil }
        loading = true; defer { loading = false }
        do {
            var request = URLRequest(url: url); request.networkServiceType = .background
            let (stream, response) = try await session.bytes(for: request)
            stream.task.priority = URLSessionTask.lowPriority
            defer { stream.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.mimeType ?? "").hasPrefix("image/"), http.expectedContentLength <= 512 * 1024 else { throw URLError(.badServerResponse) }
            var data = Data(); data.reserveCapacity(64 * 1024)
            for try await byte in stream {
                guard !Task.isCancelled, data.count < 512 * 1024 else { throw CancellationError() }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 384, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
            return DecodedMediaImage(image: image, nativeSize: CGSize(width: image.width, height: image.height), comic: false)
        } catch {
            if !Task.isCancelled {
                failures = failures.filter { $0.value > .now }
                if failures.count < 128 { failures[url.absoluteString] = Date.now.addingTimeInterval(3600) }
            }
            return nil
        }
    }
}
