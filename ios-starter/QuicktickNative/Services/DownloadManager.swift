import Foundation
import AVFoundation
import Combine

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var storageError: String?
    var onCompleted: ((Post) -> Void)?
    private let resolver: MediaResolver
    nonisolated let root: URL
    private var tasks: [String: URLSessionTask] = [:]
    private var preparing = Set<String>()
    private var metadataFailed = false
    private lazy var directSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.quicktick.downloads.files")
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.quicktick.downloads.hls")
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    init(resolver: MediaResolver, directory: URL? = nil) {
        self.resolver = resolver
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quicktick/Downloads")
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                if let catalog = try? JSONDecoder().decode(DownloadCatalog.self, from: data) {
                    guard catalog.version == 1 else { throw APIError.server("Unsupported download catalog version") }
                    records = catalog.records
                } else { records = try JSONDecoder().decode([DownloadRecord].self, from: data) }
            }
        } catch { metadataFailed = true; storageError = "Download metadata could not be read. The original file is preserved." }
        Task { [weak self] in
            guard let self else { return }
            for record in records where record.state == .complete {
                if let path = record.localMediaPath { await measureSize(record.key, at: URL(fileURLWithPath: path)) }
            }
        }
    }
    func restoreTasks() async {
        let files = await directSession.allTasks
        let packages = await hlsSession.allTasks
        for task in files + packages { if let key = task.taskDescription { tasks[key] = task } }
        for var record in records where [.downloading, .queued, .paused].contains(record.state) && tasks[record.key] == nil {
            record.state = .failed; record.errorMessage = "Interrupted transfer. Retry to download again."; upsert(record)
        }
    }
    #if DEBUG
    func useUITestDownloads(_ posts: [Post]) {
        records = posts.map { post in
            var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: "Saved fixture", tags: post.tags, thumbnailRemoteURL: "", localMediaPath: URL(string: post.mediaUrl)?.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
            record.mediaType = post.type == "image" ? nil : post.type
            if let path = record.localMediaPath,
               let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber { record.fileSize = size.int64Value }
            return record
        }
    }
    #endif
    func download(_ post: Post, refreshSource: Bool = false) {
        guard !metadataFailed, tasks[post.stableID] == nil, !preparing.contains(post.stableID), records.first(where: { $0.key == post.stableID })?.state != .complete else { return }
        preparing.insert(post.stableID)
        // Publish the queued state *before* any resolver/network await. Home and
        // Immersive can animate the tap immediately, even on a slow provider.
        let pending: DownloadRecord = {
            var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id,
                title: post.tags.first ?? post.provider, tags: post.tags,
                thumbnailRemoteURL: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl,
                kind: .file, state: .queued, progress: 0, createdAt: .now)
            record.mediaType = post.type
            return record
        }()
        upsert(pending)
        Task {
            defer { preparing.remove(post.stableID) }
            do {
                let media = try await resolver.resolve(post, refresh: refreshSource)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let file = URL(string: media.mediaUrl), file.isFileURL {
                    let dir = root.appendingPathComponent(Self.safeName(post.stableID))
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let copy = dir.appendingPathComponent("media." + file.pathExtension)
                    if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
                    try FileManager.default.copyItem(at: file, to: copy)
                    var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: "Saved fixture", tags: post.tags, thumbnailRemoteURL: "", localMediaPath: copy.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
                    record.mediaType = post.type; upsert(record)
                    await measureSize(record.key, at: copy)
                    return
                }
                #endif
                guard let url = URL(string: media.mediaUrl), url.scheme == "https" else { throw URLError(.badURL) }
                if let host = url.host, let provider = post.providerKey { try await ProviderRequestGate.shared.wait(host: host, provider: provider) }
                let hls = media.type == "hls" || url.pathExtension.lowercased() == "m3u8"
                var record = pending
                record.kind = hls ? .hlsPackage : .file
                let task: URLSessionTask
                if hls {
                    guard let transfer = hlsSession.makeAssetDownloadTask(asset: AVURLAsset(url: url), assetTitle: record.title, assetArtworkData: nil, options: nil) else { throw APIError.server("This HLS stream cannot be stored offline.") }
                    task = transfer
                } else { task = directSession.downloadTask(with: url) }
                task.taskDescription = record.key
                record.remoteURL = url.absoluteString; record.state = .downloading
                record.mediaType = media.type
                tasks[record.key] = task; upsert(record); task.resume()
                await cacheThumbnail(record)
            } catch {
                var record = records.first { $0.key == post.stableID } ?? DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: post.tags.first ?? post.provider, tags: post.tags, thumbnailRemoteURL: post.thumbUrl, kind: .file, state: .failed, progress: 0, createdAt: .now)
                record.state = .failed; record.errorMessage = error.localizedDescription; upsert(record)
            }
        }
    }
    func pause(_ record: DownloadRecord) { tasks[record.key]?.suspend(); update(record.key) { $0.state = .paused } }
    func resume(_ record: DownloadRecord) { tasks[record.key]?.resume(); update(record.key) { $0.state = .downloading } }
    func cancel(_ record: DownloadRecord) { tasks.removeValue(forKey: record.key)?.cancel(); update(record.key) { $0.state = .cancelled } }
    func retry(_ record: DownloadRecord) {
        cancel(record)
        // A previous signed CDN URL may have expired. Recover the provider
        // stream on retry, retaining direct URLs for unknown/legacy sites.
        let identity = Post(key: record.key, id: record.postID, provider: record.provider)
        let retainedURL = identity.providerKey == nil ? (record.remoteURL ?? "") : ""
        download(Post(key: record.key, id: record.postID, provider: record.provider, tags: record.tags,
                      mediaUrl: retainedURL, thumbUrl: record.thumbnailRemoteURL,
                      type: record.mediaType ?? (record.kind == .hlsPackage ? "hls" : "video")),
                 refreshSource: identity.providerKey != nil)
    }
    func delete(_ record: DownloadRecord) {
        tasks.removeValue(forKey: record.key)?.cancel()
        do {
            if let path = record.localMediaPath, FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }
            let dir = root.appendingPathComponent(Self.safeName(record.key))
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            records.removeAll { $0.key == record.key }; save()
        } catch { update(record.key) { $0.errorMessage = error.localizedDescription } }
    }
    private func update(_ key: String, _ mutation: (inout DownloadRecord) -> Void) {
        guard var record = records.first(where: { $0.key == key }) else { return }
        mutation(&record); upsert(record)
    }
    private func upsert(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.key == record.key }) { records[index] = record } else { records.insert(record, at: 0) }
        save()
    }
    private func save() {
        do { try JSONEncoder().encode(DownloadCatalog(records: records)).write(to: root.appendingPathComponent("downloads.json"), options: .atomic) }
        catch { metadataFailed = true; storageError = error.localizedDescription }
    }
    nonisolated private static func safeName(_ value: String) -> String { value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) }
    private func finished(_ key: String, location: URL) {
        guard let record = records.first(where: { $0.key == key }), record.state != .cancelled else { try? FileManager.default.removeItem(at: location); return }
        update(key) { $0.localMediaPath = location.path; $0.progress = 1; $0.state = .complete; $0.errorMessage = nil }
        tasks.removeValue(forKey: key)
        onCompleted?(Post(key: record.key, id: record.postID, provider: record.provider, tags: record.tags))
        Task { await measureSize(key, at: location) }
    }
    private func measureSize(_ key: String, at url: URL) async {
        guard let size = await DownloadSizeReader.shared.bytes(at: url),
              records.contains(where: { $0.key == key && $0.state == .complete && $0.localMediaPath == url.path }) else { return }
        update(key) { $0.fileSize = size }
    }
    private func cacheThumbnail(_ record: DownloadRecord) async {
        guard let url = NativeProviderAPI.mediaURL(record.thumbnailRemoteURL), let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let dir = root.appendingPathComponent(Self.safeName(record.key))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("thumbnail.jpg")
            try data.write(to: file, options: .atomic)
            update(record.key) { $0.thumbnailLocalPath = file.path }
        } catch { update(record.key) { $0.errorMessage = "Thumbnail: \(error.localizedDescription)" } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 429, let host = response.url?.host {
            let deadline = NativeProviderAPI.retryDeadline(response)
            Task { @MainActor in
                await ProviderRequestGate.shared.block(host: host, until: deadline)
                guard let record = self.records.first(where: { $0.key == key }) else { return }
                self.tasks.removeValue(forKey: key)
                let provider = record.offlinePost?.providerKey ?? Provider(rawValue: record.provider.lowercased()) ?? .rule34
                self.update(key) { $0.state = .failed; $0.errorMessage = APIError.rateLimited(provider, deadline).localizedDescription }
            }
            return
        }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode), !(response.mimeType ?? "").contains("text"), !(response.mimeType ?? "").contains("json") else { throw APIError.invalidResponse }
            let dir = root.appendingPathComponent(Self.safeName(key))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = downloadTask.originalRequest?.url?.pathExtension ?? ""
            let file = dir.appendingPathComponent("media.\(ext.isEmpty ? "mp4" : ext)")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            // The temporary file disappears after this callback: move before dispatching to MainActor.
            try FileManager.default.moveItem(at: location, to: file)
            Task { @MainActor in self.finished(key, location: file) }
        } catch { let message = error.localizedDescription; Task { @MainActor in self.update(key) { $0.state = .failed; $0.errorMessage = message } } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in self.update(key) { $0.progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0; $0.fileSize = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil } }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = assetDownloadTask.taskDescription else { return }
        Task { @MainActor in self.finished(key, location: location) }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let key = assetDownloadTask.taskDescription else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = totalTimeRangesLoaded.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        Task { @MainActor in self.update(key) { $0.progress = expected.isFinite && expected > 0 ? min(1, loaded / expected) : 0 } }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error else { return }
        let message = error.localizedDescription
        let taskID = task.taskIdentifier
        Task { @MainActor in
            guard self.tasks[key]?.taskIdentifier == taskID else { return }
            self.tasks.removeValue(forKey: key)
            self.update(key) { if $0.state != .cancelled { $0.state = .failed; $0.errorMessage = message } }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in BackgroundDownloadEvents.complete(identifier) }
    }
}

actor DownloadSizeReader {
    static let shared = DownloadSizeReader()
    func bytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
        if values.isDirectory != true { return values.fileSize.map { Int64($0) } }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return nil }
        var size: Int64 = 0
        for case let file as URL in files {
            if let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), value.isRegularFile == true { size += Int64(value.fileSize ?? 0) }
        }
        return size
    }
}
