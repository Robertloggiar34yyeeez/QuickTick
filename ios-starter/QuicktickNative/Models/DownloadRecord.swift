import Foundation
import ImageIO

enum DownloadState: String, Codable, Sendable { case queued, downloading, paused, complete, failed, cancelled }
enum DownloadMediaKind: String, Codable, Sendable { case file, hlsPackage }

struct DownloadCatalog: Codable {
    var version = 1
    var records: [DownloadRecord]
}

struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let provider: String
    let postID: String
    var title: String
    var tags: [String]
    var thumbnailRemoteURL: String
    var thumbnailLocalPath: String?
    var localMediaPath: String?
    var kind: DownloadMediaKind
    var state: DownloadState
    var progress: Double
    var createdAt: Date
    var fileSize: Int64?
    var remoteURL: String?
    var errorMessage: String?
    var mediaType: String?
    /// Preserve original geometry through offline restoration.
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Retain the canonical provider post URL for signed-media retries.
    /// Older saved catalogs decode this optional field as nil.
    var pageURL: String?
    var formattedSize: String {
        guard let fileSize, fileSize >= 0 else { return "Size unavailable" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // Earlier Hanime builds could mark the poster as a completed video.
    // Treat those entries as needing restoration, never as offline playback.
    var isHanimePosterOnly: Bool {
        guard provider.lowercased() == "hanime", kind == .file,
              let path = localMediaPath else { return false }
        return ["jpg", "jpeg", "png", "webp", "avif", "heic"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    // An old download may contain a poster named as media, not full video.
    var isProviderVideoPoster: Bool {
        guard kind == .file, ["hanime", "pornhub"].contains(provider.lowercased()),
              let path = localMediaPath,
              provider.lowercased() == "hanime" || mediaType?.lowercased() == "video" else {
            return false
        }
        let location = URL(fileURLWithPath: path)
        if ["jpg", "jpeg", "png", "webp", "avif", "heic", "gif"]
            .contains(location.pathExtension.lowercased()) { return true }
        // Old versions wrote JPEGs under the filename media.mp4. A filename
        // cannot prove that video data was downloaded; inspect the signature.
        return DownloadResponseValidator.isPreviewImage(at: location)
    }

    // The share sheet exports the existing file/package without decoding or copying it.
    var exportURL: URL? {
        guard !isProviderVideoPoster, state == .complete, let path = localMediaPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var offlinePost: Post? {
        guard !isProviderVideoPoster, state == .complete, let path = localMediaPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        let media = URL(fileURLWithPath: path)
        let type: String
        if let mediaType, ["image", "video", "gif"].contains(mediaType.lowercased()) { type = mediaType.lowercased() }
        else if kind == .hlsPackage { type = "video" }
        else {
            switch media.pathExtension.lowercased() {
            case "jpg", "jpeg", "png", "webp", "heic", "avif", "bmp", "tiff": type = "image"
            case "gif": type = "gif"
            case "mp4", "mov", "m4v", "webm", "m3u8": type = "video"
            default: return nil
            }
        }
        let thumbnail = thumbnailLocalPath.map { URL(fileURLWithPath: $0).absoluteString } ?? ""
        var post = Post(key: key, id: postID, provider: provider, tags: tags, mediaUrl: media.absoluteString,
                        previewUrl: type == "image" ? media.absoluteString : thumbnail, thumbUrl: thumbnail, type: type)
        post.caption = title
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            post.width = Double(pixelWidth)
            post.height = Double(pixelHeight)
        } else if type == "image",
                  let source = CGImageSourceCreateWithURL(media as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? {
            post.width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
            post.height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        }
        return post
    }
}
