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

    var offlinePost: Post? {
        guard state == .complete, let path = localMediaPath, FileManager.default.fileExists(atPath: path) else { return nil }
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
        return post
    }
}
