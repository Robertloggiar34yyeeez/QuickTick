import Foundation

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
    /// Retain the canonical provider post URL for signed-media retries.
    /// Older saved catalogs decode this optional field as nil.
    var pageURL: String?
    /// Only set after a successful HLS task and explicit offline-cache validation.
    var offlineHLSVerified: Bool?
    var offlineHLSValidationVersion: Int?
    var hlsAssetBookmark: Data?
    var videoValidationVersion: Int?
    var mediaWidth: Double?
    var mediaHeight: Double?

    static let standaloneVideoValidationVersion = 3
    static let currentHLSValidationVersion = 1
    var needsStandaloneVideoValidation: Bool {
        Provider.identify(provider) == .hanime && kind == .file &&
            videoValidationVersion != Self.standaloneVideoValidationVersion
    }
    var needsHLSValidation: Bool {
        kind == .hlsPackage && (offlineHLSVerified != true ||
            (Provider.identify(provider) == .hanime && offlineHLSValidationVersion != Self.currentHLSValidationVersion))
    }
    var formattedSize: String {
        guard let fileSize, fileSize >= 0 else { return "Size unavailable" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // Earlier Hanime builds could mark the poster as a completed video.
    // Treat those entries as needing restoration, never as offline playback.
    var isHanimePosterOnly: Bool {
        guard Provider.identify(provider) == .hanime, kind == .file,
              let path = localMediaPath else { return false }
        return ["jpg", "jpeg", "png", "webp", "avif", "heic", "heif", "gif", "bmp", "tif", "tiff"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    // The share sheet exports the existing file/package without decoding or copying it.
    var exportURL: URL? {
        // An HLS package is not an ordinary MP4 file. Never offer it as
        // one in a share sheet, where it may be represented by artwork.
        if needsStandaloneVideoValidation || kind == .hlsPackage { return nil }
        guard !isHanimePosterOnly,
              state == .complete, let path = localMediaPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var offlinePost: Post? {
        guard !needsStandaloneVideoValidation, !isHanimePosterOnly, !needsHLSValidation,
              state == .complete, let path = localMediaPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        let media = URL(fileURLWithPath: path)
        let type: String
        if kind == .hlsPackage { type = "video" }
        else if let mediaType, ["image", "video", "gif"].contains(mediaType.lowercased()) { type = mediaType.lowercased() }
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
        post.width = mediaWidth
        post.height = mediaHeight
        return post
    }
}
