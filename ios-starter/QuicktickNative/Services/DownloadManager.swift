import Foundation
import AVFoundation
import Combine

/// URLSession delegate callbacks can arrive dozens of times per second.
/// Coalesce on their background queue before scheduling MainActor work.
private final class DownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: TimeInterval] = [:]

    func shouldPublish(key: String, progress: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date.timeIntervalSinceReferenceDate
        // Completion is always immediate; intermediate progress is sampled
        // slowly enough that multiple active transfers cannot flood the feed.
        if progress < 0.999, let prior = last[key], now - prior < 0.80 { return false }
        last[key] = now
        return true
    }

    func clear(key: String) {
        lock.lock(); defer { lock.unlock() }
        last.removeValue(forKey: key)
    }
}

enum HanimeDownloadRetryPolicy {
    static func nextVariant(provider: String, attempts: Int) -> Int? {
        guard provider.lowercased() == Provider.hanime.rawValue, (0..<2).contains(attempts) else { return nil }
        return attempts + 1
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var storageError: String?
    // Search indexes/offline-post snapshots depend on catalog changes, not
    // the progress samples published while a transfer is active.
    let catalogDidChange = PassthroughSubject<Void, Never>()
    var onCompleted: ((Post) -> Void)?
    private let resolver: MediaResolver
    nonisolated let root: URL
    private var tasks: [String: URLSessionTask] = [:]
    private var preparing = Set<String>()
    private var preparationTasks: [String: Task<Void, Never>] = [:]
    private var preparationIDs: [String: UUID] = [:]
    private var refreshedPornhubTransfers = Set<String>()
    private var hanimeStreamRetries: [String: Int] = [:]
    nonisolated private let progressGate = DownloadProgressGate()
    private var metadataFailed = false
    // Native URLSession transfers already survive app suspension. Delegate
    // callbacks must not run on the UI thread for every downloaded chunk.
    private lazy var transferDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "QuickTick background download callbacks"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var directSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.quicktick.downloads.files")
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: transferDelegateQueue)
    }()
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.quicktick.downloads.hls")
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: transferDelegateQueue)
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
                let savedRecords: [DownloadRecord]
                if let catalog = try? JSONDecoder().decode(DownloadCatalog.self, from: data) {
                    guard catalog.version == 1 else { throw APIError.server("Unsupported download catalog version") }
                    savedRecords = catalog.records
                } else { savedRecords = try JSONDecoder().decode([DownloadRecord].self, from: data) }
                let paths = DownloadPathStorage(root: root)
                records = Self.newestFirst(savedRecords.map { paths.restore($0) })
                for index in records.indices where
                    [Provider.hanime.rawValue, Provider.pornhub.rawValue].contains(records[index].provider.lowercased()) &&
                    records[index].state == .complete && records[index].kind == .file &&
                    (records[index].isProviderVideoPoster ||
                     (records[index].mediaType?.lowercased() == "video" &&
                      records[index].localMediaPath.map {
                        DownloadResponseValidator.isPreviewImage(at: URL(fileURLWithPath: $0))
                      } == true)) {
                    // Older releases also stored image bytes *named media.mp4*.
                    // Check the file signature once while restoring metadata;
                    // don't read files repeatedly on the scrolling hot path.
                    // Preserve the preview for recovery, but never expose it
                    // as a completed offline movie.
                    records[index].state = .failed
                    records[index].progress = 0
                    records[index].errorMessage = "Only a preview was saved. Retry to fetch the complete provider video."
                }
                // Older builds serialized the app container's absolute UUID path.
                // iOS can change that UUID on an update even though the files survive.
                // Rewrite recovered entries as container-relative references now.
                if savedRecords != records || records.contains(where: { paths.persist($0) != $0 }) { save() }
            }
        } catch { metadataFailed = true; storageError = "Download metadata could not be read. The original file is preserved." }
        Task { [weak self] in
            guard let self else { return }
            for record in records where record.state == .complete && record.fileSize == nil {
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
        records = Self.newestFirst(posts.map { post in
            var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: "Saved fixture", tags: post.tags, thumbnailRemoteURL: "", localMediaPath: URL(string: post.mediaUrl)?.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
            record.mediaType = post.type == "image" ? nil : post.type
            record.pixelWidth = post.width.flatMap { $0.isFinite && $0 > 0 ? Int($0) : nil }
            record.pixelHeight = post.height.flatMap { $0.isFinite && $0 > 0 ? Int($0) : nil }
            if let path = record.localMediaPath,
               let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber { record.fileSize = size.int64Value }
            return record
        })
        catalogDidChange.send()
    }
    #endif
    func download(_ post: Post, refreshSource: Bool = false, streamVariant: Int = 0) {
        guard !metadataFailed, tasks[post.stableID] == nil, !preparing.contains(post.stableID), records.first(where: { $0.key == post.stableID })?.state != .complete else { return }
        if post.providerKey == .hanime && streamVariant == 0 { hanimeStreamRetries[post.stableID] = nil }
        if post.providerKey == .pornhub && streamVariant == 0 { refreshedPornhubTransfers.remove(post.stableID) }
        preparing.insert(post.stableID)
        let preparationID = UUID()
        preparationIDs[post.stableID] = preparationID
        // Publish the queued state *before* any resolver/network await. Home and
        // Immersive can animate the tap immediately, even on a slow provider.
        let pending: DownloadRecord = {
            var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id,
                title: post.displayTitle ?? post.tags.first ?? post.provider, tags: post.tags,
                thumbnailRemoteURL: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl,
                kind: .file, state: .queued, progress: 0, createdAt: .now)
            record.mediaType = post.type
            record.pageURL = post.pageUrl
            record.pixelWidth = post.width.flatMap { $0.isFinite && $0 > 0 ? Int($0) : nil }
            record.pixelHeight = post.height.flatMap { $0.isFinite && $0 > 0 ? Int($0) : nil }
            return record
        }()
        upsert(pending)
        let work = Task {
            defer {
                if preparationIDs[post.stableID] == preparationID {
                    preparationIDs.removeValue(forKey: post.stableID)
                    preparationTasks.removeValue(forKey: post.stableID)
                    preparing.remove(post.stableID)
                }
            }
            do {
                // Each Hanime transfer needs a newly issued signed playlist.
                // Catalog previews and an AVPlayer's cached URL are not valid
                // substitutes for a downloadable video package.
                let media = try await resolver.resolve(post,
                    // Signed playback URLs may expire before transfer starts.
                    refresh: refreshSource || post.providerKey == .hanime || post.providerKey == .pornhub,
                    streamVariant: (post.providerKey == .hanime || post.providerKey == .pornhub)
                        ? streamVariant : 0,
                    forDownload: true)
                try Task.checkCancellation()
                // A user can cancel while the provider issues a signed URL.
                // The URL must never start a background transfer afterward.
                guard preparationIDs[post.stableID] == preparationID,
                      records.first(where: { $0.key == post.stableID })?.state == .queued else { return }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let file = URL(string: media.mediaUrl), file.isFileURL {
                    let dir = root.appendingPathComponent(Self.safeName(post.stableID))
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let copy = dir.appendingPathComponent("media." + file.pathExtension)
                    if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
                    try FileManager.default.copyItem(at: file, to: copy)
                    var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: "Saved fixture", tags: post.tags, thumbnailRemoteURL: "", localMediaPath: copy.path, kind: .file, state: .complete, progress: 1, createdAt: .now)
                    record.mediaType = post.type
                    record.pixelWidth = pending.pixelWidth
                    record.pixelHeight = pending.pixelHeight
                    upsert(record)
                    await measureSize(record.key, at: copy)
                    return
                }
                #endif
                let source = try DownloadSourcePolicy.validate(media: media, for: post)
                let url = source.url
                if let host = url.host, let provider = post.providerKey { try await ProviderRequestGate.shared.wait(host: host, provider: provider) }
                try Task.checkCancellation()
                guard preparationIDs[post.stableID] == preparationID,
                      records.first(where: { $0.key == post.stableID })?.state == .queued else { return }
                let hls = source.isHLS
                var record = pending
                record.kind = hls ? .hlsPackage : .file
                let task: URLSessionTask
                if hls {
                    var mediaHeaders = HanimeGeneratedAPI.mediaHeaders(for: url)
                        .merging(EromeGeneratedAPI.mediaHeaders(for: url)) { _, new in new }
                    if post.providerKey == .pornhub {
                        mediaHeaders["Referer"] = "https://www.pornhub.com/"
                        mediaHeaders["User-Agent"] = NativeProviderAPI.userAgent
                    }
                    var assetOptions: [String: Any] = [:]
                    if !mediaHeaders.isEmpty { assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = mediaHeaders }
                    if post.providerKey == .hanime {
                        // Match native player first-party session semantics.
                        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter {
                            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                            return domain == "hanime.tv" || domain.hasSuffix(".hanime.tv")
                        }
                        if !cookies.isEmpty { assetOptions[AVURLAssetHTTPCookiesKey] = cookies }
                    }
                    let asset = AVURLAsset(url: url, options: assetOptions)
                    guard let transfer = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: record.title, assetArtworkData: nil, options: nil) else { throw APIError.server("This HLS stream cannot be stored offline.") }
                    task = transfer
                } else {
                    var request = URLRequest(url: url)
                    if post.providerKey == .hanime {
                        // MP4 variants use ordinary URLSession transfers, but
                        // retain the same first-party headers as HLS playback.
                        request.setValue(NativeProviderAPI.userAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue("video/mp4, video/*;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
                        for (header, value) in HanimeGeneratedAPI.mediaHeaders(for: url) {
                            request.setValue(value, forHTTPHeaderField: header)
                        }
                    }
                    if post.providerKey == .pornhub || post.providerKey == .erome {
                        // Some media CDNs check the public source-page origin.
                        // No account cookies or third-party proxy are used.
                        request.setValue(NativeProviderAPI.userAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue(post.providerKey == .erome ? "https://www.erome.com/" : "https://www.pornhub.com/", forHTTPHeaderField: "Referer")
                        request.setValue("video/*, application/octet-stream;q=0.9, */*;q=0.7", forHTTPHeaderField: "Accept")
                    }
                    task = directSession.downloadTask(with: request)
                }
                task.taskDescription = record.key
                record.remoteURL = url.absoluteString; record.state = .downloading
                record.mediaType = "video" == post.type.lowercased() && hls ? "video" : media.type
                tasks[record.key] = task; upsert(record); task.resume()
                await cacheThumbnail(record)
            } catch is CancellationError {
                // Cancel is a user decision, never a failed download.
            } catch {
                guard !Task.isCancelled, preparationIDs[post.stableID] == preparationID else { return }
                var record = records.first { $0.key == post.stableID } ?? DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: post.tags.first ?? post.provider, tags: post.tags, thumbnailRemoteURL: post.thumbUrl, kind: .file, state: .failed, progress: 0, createdAt: .now)
                guard record.state != .cancelled else { return }
                record.state = .failed; record.errorMessage = error.localizedDescription; upsert(record)
            }
        }
        preparationTasks[post.stableID] = work
    }
    func pause(_ record: DownloadRecord) { tasks[record.key]?.suspend(); update(record.key) { $0.state = .paused } }
    func resume(_ record: DownloadRecord) { tasks[record.key]?.resume(); update(record.key) { $0.state = .downloading } }
    func cancel(_ record: DownloadRecord) {
        preparationTasks.removeValue(forKey: record.key)?.cancel()
        preparationIDs.removeValue(forKey: record.key)
        preparing.remove(record.key)
        tasks.removeValue(forKey: record.key)?.cancel()
        progressGate.clear(key: record.key)
        update(record.key) { $0.state = .cancelled }
    }
    func retry(_ record: DownloadRecord, streamVariant: Int = 0) {
        cancel(record)
        if streamVariant == 0 { hanimeStreamRetries[record.key] = nil }
        // A previous signed CDN URL may have expired. Recover the provider
        // stream on retry, retaining direct URLs for unknown/legacy sites.
        let identity = Post(key: record.key, id: record.postID, provider: record.provider)
        let retainedURL = identity.providerKey == nil ? (record.remoteURL ?? "") : ""
        download(Post(key: record.key, id: record.postID, provider: record.provider, tags: record.tags,
                      mediaUrl: retainedURL, thumbUrl: record.thumbnailRemoteURL,
                      pageUrl: record.pageURL ?? "",
                      type: record.mediaType ?? (record.kind == .hlsPackage ? "hls" : "video")),
                 refreshSource: identity.providerKey != nil, streamVariant: streamVariant)
    }
    func delete(_ record: DownloadRecord) {
        tasks.removeValue(forKey: record.key)?.cancel()
        do {
            if let path = record.localMediaPath, FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }
            let dir = root.appendingPathComponent(Self.safeName(record.key))
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            records.removeAll { $0.key == record.key }; save()
            catalogDidChange.send()
        } catch { update(record.key) { $0.errorMessage = error.localizedDescription } }
    }
    /// Remove a selected batch off the main actor so deleting large HLS
    /// packages does not block the Downloads scroll view. Commit metadata once.
    func delete(keys: Set<String>) {
        guard !keys.isEmpty else { return }
        let targets = records.filter { keys.contains($0.key) }
        for record in targets {
            tasks.removeValue(forKey: record.key)?.cancel()
            progressGate.clear(key: record.key)
        }
        for index in records.indices where keys.contains(records[index].key) {
            records[index].state = .cancelled
        }
        let storageRoot = root
        Task {
            let failures = await Task.detached(priority: .utility) { () -> [String: String] in
                var failures: [String: String] = [:]
                for record in targets {
                    do {
                        if let path = record.localMediaPath, FileManager.default.fileExists(atPath: path) {
                            try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                        }
                        let name = record.key.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
                        let folder = storageRoot.appendingPathComponent(name, isDirectory: true)
                        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                    } catch { failures[record.key] = error.localizedDescription }
                }
                return failures
            }.value
            records.removeAll { keys.contains($0.key) && failures[$0.key] == nil }
            for (key, message) in failures {
                if let index = records.firstIndex(where: { $0.key == key }) {
                    records[index].state = .failed
                    records[index].errorMessage = "Could not delete: \(message)"
                }
            }
            save()
            catalogDidChange.send()
        }
    }
    private func update(_ key: String, _ mutation: (inout DownloadRecord) -> Void) {
        guard var record = records.first(where: { $0.key == key }) else { return }
        mutation(&record); upsert(record)
    }
    private func reportProgress(_ key: String, value: Double, expectedBytes: Int64? = nil) {
        guard let index = records.firstIndex(where: { $0.key == key }),
              records[index].state == .downloading else { return }
        // Only live in-memory UI state changes here. Encoding and atomically
        // rewriting downloads.json for every URLSession progress packet caused
        // scrolling stalls until a transfer completed.
        var record = records[index]
        record.progress = min(1, max(0, value))
        if let expectedBytes, expectedBytes > 0 { record.fileSize = expectedBytes }
        records[index] = record
    }
    private func upsert(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.key == record.key }) { records[index] = record } else { records.insert(record, at: 0) }
        records = Self.newestFirst(records)
        save()
        catalogDidChange.send()
    }
    /// Persist and display one chronological list across every provider.
    /// Progress callbacks must not reorder older transfers ahead of new ones.
    static func newestFirst(_ records: [DownloadRecord]) -> [DownloadRecord] {
        records.sorted {
            if $0.createdAt == $1.createdAt { return $0.key < $1.key }
            return $0.createdAt > $1.createdAt
        }
    }
    private func save() {
        do {
            let paths = DownloadPathStorage(root: root)
            try JSONEncoder().encode(DownloadCatalog(records: records.map { paths.persist($0) }))
                .write(to: root.appendingPathComponent("downloads.json"), options: .atomic)
        }
        catch { metadataFailed = true; storageError = error.localizedDescription }
    }
    nonisolated private static func safeName(_ value: String) -> String { value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) }
    private func finished(_ key: String, location: URL) async {
        guard let record = records.first(where: { $0.key == key }) else { return }
        // HLS may report both didFinishDownloadingTo and didCompleteWithError.
        // Never delete a successfully stored system-managed package on the
        // second callback or count the same completion twice.
        if record.state == .complete { return }
        if record.state == .cancelled {
            if record.kind == .file { try? FileManager.default.removeItem(at: location) }
            return
        }
        if record.kind == .file,
           [Provider.hanime.rawValue, Provider.pornhub.rawValue].contains(record.provider.lowercased()),
           record.mediaType?.lowercased() == "video" {
            // A completed download must be decodable video, not a thumbnail
            // or an HTML error document disguised as an MP4.
            let playable = (try? await AVURLAsset(url: location).load(.isPlayable)) ?? false
            guard playable else {
                failedTransfer(key, reason: "The provider did not save a playable full video. Retry with a fresh stream.")
                return
            }
        }
        if record.kind == .hlsPackage {
            var isDirectory: ObjCBool = false
            guard location.pathExtension.lowercased() == "movpkg",
                  FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.enumerator(at: location, includingPropertiesForKeys: nil)?
                    .nextObject() != nil else {
                failedTransfer(key, reason: "The stream did not produce an offline video package. Retry to download the video.")
                return
            }
            let offlineAsset = AVURLAsset(url: location)
            let playable = (try? await offlineAsset.load(.isPlayable)) ?? false
            guard playable else {
                failedTransfer(key, reason: "The HLS download contained no playable offline video. Retry to save the full stream.")
                return
            }
        }
        // Multiple URLSession delegate callbacks may race while an HLS
        // package is being verified; publish completion exactly once.
        guard let current = records.first(where: { $0.key == key }),
              current.state != .complete, current.state != .cancelled else { return }
        progressGate.clear(key: key)
        update(key) { $0.localMediaPath = location.path; $0.progress = 1; $0.state = .complete; $0.errorMessage = nil }
        tasks.removeValue(forKey: key)
        hanimeStreamRetries[key] = nil
        onCompleted?(Post(key: record.key, id: record.postID, provider: record.provider, tags: record.tags))
        Task { await measureSize(key, at: location) }
    }
    private func measureSize(_ key: String, at url: URL) async {
        guard let size = await DownloadSizeReader.shared.bytes(at: url),
              let record = records.first(where: { $0.key == key && $0.state == .complete && $0.localMediaPath == url.path }),
              record.fileSize != size else { return }
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
        } catch {
            // A missing poster must not be reported as a failed video
            // transfer; thumbnails are optional display-only metadata.
        }
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
            let response = downloadTask.response as? HTTPURLResponse
            let handle = try FileHandle(forReadingFrom: location)
            let header = handle.readData(ofLength: 256)
            try? handle.close()
            if let reason = DownloadResponseValidator.failure(response: response, header: header,
                                                              expectedVideo: key.hasPrefix("hanime:") || key.hasPrefix("pornhub:")) {
                Task { @MainActor in self.failedTransfer(key, reason: reason) }
                return
            }
            let dir = root.appendingPathComponent(Self.safeName(key))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = downloadTask.originalRequest?.url?.pathExtension ?? ""
            let file = dir.appendingPathComponent("media.\(ext.isEmpty ? "mp4" : ext)")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            // The temporary file disappears after this callback: move before dispatching to MainActor.
            try FileManager.default.moveItem(at: location, to: file)
            Task { @MainActor in await self.finished(key, location: file) }
        } catch { let message = error.localizedDescription; Task { @MainActor in self.update(key) { $0.state = .failed; $0.errorMessage = message } } }
    }
    private func failedTransfer(_ key: String, reason: String) {
        tasks.removeValue(forKey: key)
        guard let record = records.first(where: { $0.key == key }), record.state != .cancelled else { return }
        if let next = HanimeDownloadRetryPolicy.nextVariant(provider: record.provider,
                                                            attempts: hanimeStreamRetries[key] ?? 0) {
            hanimeStreamRetries[key] = next
            // A signed playlist can expire before the offline asset session
            // fetches its segments. Request a genuinely new stream/quality,
            // never retry the old poster or an expired HLS URL.
            retry(record, streamVariant: next)
        } else if record.provider.lowercased() == Provider.pornhub.rawValue,
           !refreshedPornhubTransfers.contains(key) {
            refreshedPornhubTransfers.insert(key)
            // Try the next distinct declared stream rather than replaying
            // the same expired CDN URL.
            retry(record, streamVariant: 1)
        } else {
            update(key) { $0.state = .failed; $0.errorMessage = reason }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let value = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        guard progressGate.shouldPublish(key: key, progress: value) else { return }
        Task { @MainActor in self.reportProgress(key,
            value: value,
            expectedBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil) }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let key = assetDownloadTask.taskDescription else { return }
        let taskID = assetDownloadTask.taskIdentifier
        // AVFoundation owns HLS .movpkg packages. Retain its destination as
        // soon as it is assigned, including across background relaunches.
        Task { @MainActor in
            guard self.tasks[key]?.taskIdentifier == taskID else { return }
            self.update(key) { $0.localMediaPath = location.path }
        }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = assetDownloadTask.taskDescription else { return }
        Task { @MainActor in await self.finished(key, location: location) }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let key = assetDownloadTask.taskDescription else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = totalTimeRangesLoaded.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let value = expected.isFinite && expected > 0 ? min(1, loaded / expected) : 0
        guard progressGate.shouldPublish(key: key, progress: value) else { return }
        Task { @MainActor in self.reportProgress(key,
            value: value) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let message = error?.localizedDescription
        let taskID = task.taskIdentifier
        let isHLS = task is AVAssetDownloadTask
        Task { @MainActor in
            guard self.tasks[key]?.taskIdentifier == taskID else { return }
            if let message {
                self.failedTransfer(key, reason: message)
            } else if isHLS, let record = self.records.first(where: { $0.key == key }) {
                // Newer HLS delegate implementations can finish by reporting a
                // successful URLSession task after willDownloadTo. Do not leave
                // a successful offline package stuck at "Downloading".
                if let path = record.localMediaPath,
                   FileManager.default.fileExists(atPath: path) {
                    await self.finished(key, location: URL(fileURLWithPath: path))
                } else {
                    self.failedTransfer(key, reason:
                        "HLS ended without an offline video package. Retry to fetch the stream.")
                }
            }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in BackgroundDownloadEvents.complete(identifier) }
    }
}

enum DownloadSourcePolicy {
    static func validate(media: ResolvedMedia, for post: Post) throws -> (url: URL, isHLS: Bool) {
        guard let url = URL(string: media.mediaUrl), url.scheme == "https" else {
            throw URLError(.badURL)
        }
        let fileType = url.pathExtension.lowercased()
        // An MP4 served from /hls/ is still a file, not an HLS playlist.
        // Routing those to AVAssetDownloadURLSession silently fails or
        // produces incomplete offline packages on some providers.
        let isVideoFile = ["mp4", "m4v", "mov"].contains(fileType)
        let isHLS = !isVideoFile && (fileType == "m3u8" ||
            url.path.hasPrefix("/hls/") || media.type == "hls")
        if post.providerKey == .hanime {
            // An image can be a useful poster, but it must never be marked as
            // the completed offline video. Hanime requires first-party media.
            guard HanimeGeneratedAPI.permittedStreamURL(url),
                  isHLS || ["mp4", "m4v"].contains(fileType) ||
                    (fileType.isEmpty && media.type.lowercased() == "video") else {
                throw APIError.server("Hanime returned a preview instead of a video stream. Retry to resolve the HLS source.")
            }
        }
        if post.providerKey == .pornhub && post.type.lowercased() == "video" {
            // Do not accept a poster disguised as a video download.
            guard !["jpg", "jpeg", "png", "webp", "avif", "gif"].contains(fileType),
                  ["video", "hls"].contains(media.type.lowercased()) else {
                throw APIError.server("Pornhub returned an image instead of a downloadable video stream.")
            }
        }
        return (url, isHLS)
    }
}

enum DownloadResponseValidator {
    static func isPreviewImage(header: Data) -> Bool {
        if header.starts(with: [0xFF, 0xD8, 0xFF]) ||
           header.starts(with: [0x89, 0x50, 0x4E, 0x47]) ||
           header.starts(with: Array("GIF8".utf8)) { return true }
        if header.count >= 12, header.prefix(4) == Data("RIFF".utf8),
           header.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return true }
        if header.count >= 12, header.dropFirst(4).prefix(4) == Data("ftyp".utf8) {
            let brand = String(decoding: header.dropFirst(8).prefix(4), as: UTF8.self).lowercased()
            return ["avif", "avis", "heic", "heix", "mif1"].contains(brand)
        }
        return false
    }

    static func isPreviewImage(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isPreviewImage(header: handle.readData(ofLength: 32))
    }

    static func failure(response: HTTPURLResponse?, header: Data, expectedVideo: Bool = false) -> String? {
        guard let response else { return "The download server returned no HTTP response." }
        guard (200..<300).contains(response.statusCode) else {
            return "The media server returned HTTP \(response.statusCode). The source may have expired or be unavailable in your region."
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if expectedVideo && (mime.hasPrefix("image/") || isPreviewImage(header: header)) {
            return "The media server returned only a preview image, not the Hanime video. Retry to resolve its stream."
        }
        let prefix = String(decoding: header, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime.contains("text/") || mime.contains("json") || mime.contains("html") ||
           prefix.hasPrefix("<html") || prefix.hasPrefix("<!doctype html") ||
           prefix.hasPrefix("{\"error\"") || prefix.hasPrefix("{\"message\"") {
            return "The server returned a webpage or error instead of a video file. Check provider access or retry."
        }
        return nil
    }
}

/// Persist references relative to the app's *current* container, not to its
/// replaceable /Containers/Data/Application/<UUID> absolute path. The in-memory
/// records always contain fully resolved file paths for playback and sharing.
struct DownloadPathStorage {
    private static let downloadsPrefix = "quicktick-downloads:"
    private static let containerPrefix = "quicktick-container:"

    let root: URL
    let container: URL

    // FileManager.homeDirectoryForCurrentUser is macOS-only. Documents is a
    // stable, sandbox-local directory on iOS; its parent is the data container.
    init(root: URL, container: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].deletingLastPathComponent()) {
        self.root = root.standardizedFileURL
        self.container = container.standardizedFileURL
    }

    func persist(_ record: DownloadRecord) -> DownloadRecord {
        var result = record
        result.localMediaPath = portable(record.localMediaPath)
        result.thumbnailLocalPath = portable(record.thumbnailLocalPath)
        return result
    }

    func restore(_ record: DownloadRecord) -> DownloadRecord {
        var result = record
        result.localMediaPath = resolve(record.localMediaPath, key: record.key, media: record.kind == .file)
        result.thumbnailLocalPath = resolve(record.thumbnailLocalPath, key: record.key, media: false, thumbnail: true)
        return result
    }

    private func portable(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return path }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        if let suffix = relativePath(canonical, inside: root.path) { return Self.downloadsPrefix + suffix }
        if let suffix = relativePath(canonical, inside: container.path) { return Self.containerPrefix + suffix }
        return path // Files outside this container must never be silently relocated.
    }

    private func resolve(_ path: String?, key: String, media: Bool, thumbnail: Bool = false) -> String? {
        guard let path else { return nil }
        if let relative = path.stripPrefix(Self.downloadsPrefix), let url = safeChild(relative, of: root) { return url.path }
        if let relative = path.stripPrefix(Self.containerPrefix), let url = safeChild(relative, of: container) { return url.path }
        if FileManager.default.fileExists(atPath: path) { return path }

        // Recover media and thumbnails from older catalogs that still point to
        // a *previous* app container UUID. Files stay under the same download key.
        let folder = root.appendingPathComponent(Self.safeName(key), isDirectory: true)
        if thumbnail {
            let candidate = folder.appendingPathComponent("thumbnail.jpg")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        } else if media {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            if filename.hasPrefix("media.") {
                let exact = folder.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: exact.path) { return exact.path }
            }
            // Older builds may have saved a different media extension.
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                let candidates = names.filter { $0.hasPrefix("media.") }.sorted()
                if candidates.count == 1 { return folder.appendingPathComponent(candidates[0]).path }
            }
        }

        // AVAssetDownloadTask controls the location of HLS .movpkg packages.
        // Apple prohibits moving them into our download folder, so recover
        // their former container-relative location without touching the asset.
        if let relative = Self.previousContainerRelativePath(path),
           let candidate = safeChild(relative, of: container),
           FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        return path // Keep the original reference if its file is genuinely absent.
    }

    private func relativePath(_ path: String, inside directory: String) -> String? {
        guard path.hasPrefix(directory + "/") else { return nil }
        return String(path.dropFirst(directory.count + 1))
    }

    private func safeChild(_ relative: String, of directory: URL) -> URL? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return directory.appendingPathComponent(relative)
    }

    private static func previousContainerRelativePath(_ path: String) -> String? {
        guard let range = path.range(of: "/Containers/Data/Application/") else { return nil }
        let suffix = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        guard suffix.count > 2, UUID(uuidString: String(suffix[0])) != nil else { return nil }
        let relative = suffix.dropFirst().joined(separator: "/")
        return relative.hasPrefix("Library/") || relative.hasPrefix("Documents/") ? relative : nil
    }

    private static func safeName(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
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
