import Foundation
import ImageIO
import CoreGraphics

struct DecodedMediaImage: @unchecked Sendable {
    let image: CGImage
    let nativeSize: CGSize
    let comic: Bool
    var perceptualHash: UInt64? = nil
    var cost: Int { image.bytesPerRow * image.height }
}

/// One bounded decoded cache and URLCache-backed transport for every feed preview.
actor MediaImagePipeline {
    static let shared = MediaImagePipeline()
    private let session: URLSession
    private var images: [String: DecodedMediaImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    private var prefetchedGIF: (key: String, bytes: Data)?
    private var flights: [String: Task<Data, Error>] = [:]
    private var waiters: [String: Set<UUID>] = [:]
    private(set) var hits = 0
    private(set) var misses = 0
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.default
            config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config)
        }
    }
    func image(raw: String, pixels: Int, comicPreview: Bool = false) async throws -> DecodedMediaImage {
        guard !raw.isEmpty, let url = URL(string: raw)?.isFileURL == true ? URL(string: raw) : NativeProviderAPI.mediaURL(raw) else { throw URLError(.badURL) }
        let bucket = min(2048, max(256, ((pixels + 255) / 256) * 256))
        let key = "\(url.absoluteString):\(bucket):\(comicPreview)"
        if let cached = images[key] { hits += 1; touch(key); return cached }
        misses += 1
        let data = try await data(url: url)
        try Task.checkCancellation()
        if let cached = images[key] { hits += 1; touch(key); return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { throw URLError(.cannotDecodeContentData) }
        let comic = comicPreview && h > w * 4
        var cg: CGImage?
        if comic {
            // Bound the full-strip thumbnail before cropping; never decode the giant original for a card.
            let scale = min(1, min(Double(bucket) / w, min(8192 / h, sqrt(2_000_000 / (w * h)))))
            let edge = max(1, Int(max(w,h) * scale))
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                cg = thumbnail.cropping(to: CGRect(x:0,y:0,width:thumbnail.width,height:min(thumbnail.height,Int(Double(thumbnail.width) * 1.5))))
            }
        } else {
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: bucket, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let cg else { throw URLError(.cannotDecodeContentData) }
        let decoded = DecodedMediaImage(image: cg, nativeSize: CGSize(width: w, height: h), comic: comic,
            perceptualHash: VisualAnalysisService.fingerprint(cg))
        if images[key] == nil { images[key] = decoded; bytes += decoded.cost; touch(key) }
        while bytes > 32 * 1024 * 1024, let oldest = order.first { order.removeFirst(); if let old = images.removeValue(forKey: oldest) { bytes -= old.cost } }
        return decoded
    }
    func fullImage(url: URL) async throws -> DecodedMediaImage {
        let bytes = try await data(url: url)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let originalWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let originalHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              originalWidth.isFinite, originalHeight.isFinite,
              originalWidth > 0, originalHeight > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        // A gigantic original comic could otherwise allocate hundreds of MB
        // on the main viewing surface and kill the app, especially on iPad.
        // Decode at most 16 megapixels with a longest edge of 8192 points.
        let maxEdge = min(8192.0, sqrt(16_000_000.0 / (originalWidth * originalHeight))
            * max(originalWidth, originalHeight))
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxEdge)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
        guard let image else { throw URLError(.cannotDecodeContentData) }
        return DecodedMediaImage(image: image,
            nativeSize: CGSize(width: originalWidth, height: originalHeight),
            comic: originalHeight > originalWidth * 4)
    }
    /// Reuse a decoded card image immediately when a full-screen cover opens.
    /// This lookup never makes a request or decodes new pixels.
    func cachedPreview(raw: String) -> DecodedMediaImage? {
        guard let url = URL(string: raw)?.isFileURL == true ? URL(string: raw) : NativeProviderAPI.mediaURL(raw),
              let key = order.reversed().first(where: { $0.hasPrefix(url.absoluteString + ":") }) else { return nil }
        return images[key]
    }
    func data(url: URL) async throws -> Data {
        if let cached = prefetchedGIF, cached.key == url.absoluteString { return cached.bytes }
        if url.isFileURL { return try Data(contentsOf: url) }
        guard NativeProviderAPI.mediaURL(url.absoluteString) != nil else { throw URLError(.badURL) }
        let key = url.absoluteString
        let pending: Task<Data, Error>
        if let shared = flights[key] { pending = shared }
        else {
            let session = session
            pending = Task {
                var request = URLRequest(url: url); request.timeoutInterval = 20
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 32 * 1024 * 1024 else { throw URLError(.badServerResponse) }
                return data
            }
            flights[key] = pending
        }
        let waiter = UUID(); waiters[key, default: []].insert(waiter)
        return try await withTaskCancellationHandler {
            defer { finishWaiter(key, waiter: waiter, cancel: false) }
            let bytes = try await pending.value; try Task.checkCancellation(); return bytes
        } onCancel: { Task { await self.finishWaiter(key, waiter: waiter, cancel: true) } }
    }
    func prefetchGIF(url: URL) async {
        guard !Task.isCancelled, let data = try? await data(url: url), !Task.isCancelled, data.count <= 8 * 1024 * 1024 else { return }
        prefetchedGIF = (url.absoluteString, data)
    }
    private func finishWaiter(_ key: String, waiter: UUID, cancel: Bool) {
        guard waiters[key]?.remove(waiter) != nil else { return }
        if waiters[key]?.isEmpty == true {
            if cancel { flights[key]?.cancel() }
            flights.removeValue(forKey: key); waiters.removeValue(forKey: key)
        }
    }
    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    func clearDecoded() { images.removeAll(); order.removeAll(); bytes = 0; prefetchedGIF = nil }
    /// Analysis may reuse decoded previews only. It cannot trigger network traffic.
    func cachedAnalysisImage(raw: String) -> DecodedMediaImage? {
        guard let key = order.reversed().first(where: { $0.hasPrefix(raw + ":") }), let value = images[key] else { return nil }
        let scale = min(1, 384 / Double(max(value.image.width, value.image.height)))
        let w = max(1, Int(Double(value.image.width) * scale)), h = max(1, Int(Double(value.image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(value.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage() else { return nil }
        return DecodedMediaImage(image: image, nativeSize: value.nativeSize, comic: value.comic)
    }
    var decodedBytes: Int { bytes }
}
