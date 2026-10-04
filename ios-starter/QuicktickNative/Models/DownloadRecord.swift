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
}
