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

/// The delegate queue is serial, but MainActor tasks are not a FIFO queue.
/// Capture the HLS destination before crossing into the actor.
private final class HLSDownloadLocations: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [Int: URL] = [:]

    func store(_ location: URL, taskID: Int) {
        lock.lock(); defer { lock.unlock() }
        locations[taskID] = location
    }

    func take(taskID: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return locations.removeValue(forKey: taskID)
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
    private var verifying = Set<String>()
    private var refreshedPornhubTransfers = Set<String>()
    private var hanimeVariantAttempts: [String: Int] = [:]
    nonisolated private let progressGate = DownloadProgressGate()
    nonisolated private let hlsLocations = HLSDownloadLocations()
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
                for index in records.indices where records[index].state == .complete &&
                    (records[index].isHanimePosterOnly || Self.isInvalidLegacyVideo(records[index])) {
                    // Older versions saved the cover as the video. Preserve
                    // that file, but make the record retryable so the user can
                    // replace it with a real HLS/MP4 download.
                    records[index].state = .failed
                    records[index].progress = 0
                    records[index].errorMessage = "Only the old preview was saved. Retry to download the full Hanime video."
                }
                // Older builds serialized the app container's absolute UUID path.
                // iOS can change that UUID on an update even though the files survive.
                // Rewrite recovered entries as container-relative references now.
                if savedRecords != records || records.contains(where: { paths.persist($0) != $0 }) { save() }
            }
        } catch { metadataFailed = true; storageError = "Download metadata could not be read. The original file is preserved." }
        Task { [weak self] in
            guard let self else { return }
            for record in records where record.state == .complete {
                if record.kind == .hlsPackage && record.offlineHLSVerified != true {
                    await revalidateLegacyHLS(record)
                }
                if record.fileSize == nil, let path = record.localMediaPath {
                    await measureSize(record.key, at: URL(fileURLWithPath: path))
                }
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
            if let path = record.localMediaPath,
               let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber { record.fileSize = size.int64Value }
            return record
        })
        catalogDidChange.send()
    }
    #endif
    func download(_ post: Post, refreshSource: Bool = false, hanimeVariant: Int = 0) {
        guard !metadataFailed, tasks[post.stableID] == nil, !preparing.contains(post.stableID), records.first(where: { $0.key == post.stableID })?.state != .complete else { return }
        preparing.insert(post.stableID)
        // Publish the queued state *before* any resolver/network await. Home and
        // Immersive can animate the tap immediately, even on a slow provider.
        let pending: DownloadRecord = {
            var record = DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id,
                title: post.displayTitle ?? post.tags.first ?? post.provider, tags: post.tags,
                thumbnailRemoteURL: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl,
                kind: .file, state: .queued, progress: 0, createdAt: .now)
            record.mediaType = post.type
            record.pageURL = post.pageUrl
            return record
        }()
        upsert(pending)
        Task {
            defer { preparing.remove(post.stableID) }
            do {
                // Each Hanime transfer needs a newly issued signed playlist.
                // Catalog previews and an AVPlayer's cached URL are not valid
                // substitutes for a downloadable video package.
                let media = try await resolver.resolve(post,
                    refresh: refreshSource || post.providerKey == .hanime,
                    hanimeVariant: hanimeVariant)
                guard records.first(where: { $0.key == post.stableID })?.state == .queued else { return }
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
                let source = try DownloadSourcePolicy.validate(media: media, for: post)
                let url = source.url
                if let host = url.host, let provider = post.providerKey { try await ProviderRequestGate.shared.wait(host: host, provider: provider) }
                guard records.first(where: { $0.key == post.stableID })?.state == .queued else { return }
                let hls = source.isHLS
                var record = pending
                record.kind = hls ? .hlsPackage : .file
                let task: URLSessionTask
                if hls {
                    let mediaHeaders = HanimeGeneratedAPI.mediaHeaders(for: url)
                        .merging(EromeGeneratedAPI.mediaHeaders(for: url)) { _, new in new }
                    let asset = mediaHeaders.isEmpty ? AVURLAsset(url: url)
                        : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": mediaHeaders])
                    let configuration = AVAssetDownloadConfiguration(asset: asset, title: record.title)
                    // Persist the actual preferred video/audio selection rather
                    // than letting the player choose a new remote rendition.
                    let selection = try await asset.load(.preferredMediaSelection)
                    configuration.primaryContentConfiguration.mediaSelections = [selection]
                    guard records.first(where: { $0.key == post.stableID })?.state == .queued else { return }
                    let transfer = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
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
                record.mediaType = hls || post.providerKey == .hanime ? "video" : media.type
                tasks[record.key] = task; upsert(record); task.resume()
                // Artwork is independent of the transfer. Do not keep the
                // preparation lock held while the thumbnail request runs.
                Task { await cacheThumbnail(record) }
            } catch {
                guard records.first(where: { $0.key == post.stableID })?.state == .queued else { return }
                var record = records.first { $0.key == post.stableID } ?? DownloadRecord(key: post.stableID, provider: post.provider, postID: post.id, title: post.tags.first ?? post.provider, tags: post.tags, thumbnailRemoteURL: post.thumbUrl, kind: .file, state: .failed, progress: 0, createdAt: .now)
                record.state = .failed; record.errorMessage = error.localizedDescription; upsert(record)
            }
        }
    }
    func pause(_ record: DownloadRecord) { tasks[record.key]?.suspend(); update(record.key) { $0.state = .paused } }
    func resume(_ record: DownloadRecord) { tasks[record.key]?.resume(); update(record.key) { $0.state = .downloading } }
    func cancel(_ record: DownloadRecord) {
        tasks.removeValue(forKey: record.key)?.cancel()
        progressGate.clear(key: record.key)
        update(record.key) { $0.state = .cancelled }
    }
    func retry(_ record: DownloadRecord) {
        cancel(record)
        hanimeVariantAttempts.removeValue(forKey: record.key)
        // A previous signed CDN URL may have expired. Recover the provider
        // stream on retry, retaining direct URLs for unknown/legacy sites.
        let identity = Post(key: record.key, id: record.postID, provider: record.provider)
        let retainedURL = identity.providerKey == nil ? (record.remoteURL ?? "") : ""
        download(Post(key: record.key, id: record.postID, provider: record.provider, tags: record.tags,
                      mediaUrl: retainedURL, thumbUrl: record.thumbnailRemoteURL,
                      pageUrl: record.pageURL ?? "",
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
    private func revalidateLegacyHLS(_ record: DownloadRecord) async {
        guard let path = record.localMediaPath else {
            update(record.key) { $0.state = .failed; $0.progress = 0; $0.errorMessage = "Saved video package is missing." }
            return
        }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let verified = OfflineHLSReadiness.isVerified(playable: playable, duration: duration,
                                                       cacheReady: asset.assetCache?.isPlayableOffline)
        guard records.contains(where: { $0.key == record.key && $0.createdAt == record.createdAt && $0.state == .complete }) else { return }
        update(record.key) {
            $0.offlineHLSVerified = verified
            if !verified {
                $0.state = .failed; $0.progress = 0
                $0.errorMessage = "The old package is not verified for offline playback. Retry the download."
            }
        }
    }

    private static func isInvalidLegacyVideo(_ record: DownloadRecord) -> Bool {
        guard Provider.identify(record.provider) == .hanime, record.kind == .file,
              let path = record.localMediaPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return DownloadResponseValidator.invalidVideoPayload(handle.readData(ofLength: 256))
    }

    private func finished(_ key: String, location: URL) async {
        guard let record = records.first(where: { $0.key == key }),
              verifying.insert(key).inserted else { return }
        defer { verifying.remove(key) }
        // HLS may report both didFinishDownloadingTo and didCompleteWithError.
        // Never delete a successfully stored system-managed package on the
        // second callback or count the same completion twice.
        if record.state == .complete { return }
        if record.state == .cancelled {
            if record.kind == .file { try? FileManager.default.removeItem(at: location) }
            return
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
            let duration = (try? await offlineAsset.load(.duration))?.seconds ?? 0
            let cacheReady = offlineAsset.assetCache?.isPlayableOffline
            let audioReady: Bool
            if let group = try? await offlineAsset.loadMediaSelectionGroup(for: .audible) {
                audioReady = group.options.isEmpty || !(offlineAsset.assetCache?.mediaSelectionOptions(in: group).isEmpty ?? true)
            } else { audioReady = true }
            guard audioReady, OfflineHLSReadiness.isVerified(playable: playable, duration: duration, cacheReady: cacheReady),
                  let size = await DownloadSizeReader.shared.bytes(at: location), size > 0 else {
                let cacheStatus = cacheReady.map { $0 ? "ready" : "not ready" } ?? "unavailable"
                failedTransfer(key, reason: "Offline HLS verification failed (cache: \(cacheStatus), cached audio: \(audioReady ? "ready" : "missing")). The video was not saved.")
                return
            }
        } else if Provider.identify(record.provider) == .hanime {
            // A successful HTTP transfer is not proof of a video. AVFoundation
            // must find an actual playable video track and a positive duration.
            let asset = AVURLAsset(url: location)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
                try? FileManager.default.removeItem(at: location)
                failedTransfer(key, reason: "The saved file is not a playable video. Retry the download.")
                return
            }
        }
        // Multiple URLSession delegate callbacks may race while an HLS
        // package is being verified; publish completion exactly once.
        guard let current = records.first(where: { $0.key == key }),
              current.createdAt == record.createdAt,
              current.state == .downloading || current.state == .paused else { return }
        progressGate.clear(key: key)
        hanimeVariantAttempts.removeValue(forKey: key)
        update(key) {
            $0.localMediaPath = location.path
            $0.progress = 1
            $0.state = .complete
            $0.errorMessage = nil
            if $0.kind == .hlsPackage { $0.offlineHLSVerified = true }
        }
        tasks.removeValue(forKey: key)
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
        guard records.first(where: { $0.key == record.key })?.createdAt == record.createdAt else { return }
        let dir = root.appendingPathComponent(Self.safeName(record.key))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("thumbnail.jpg")
            try data.write(to: file, options: .atomic)
            update(record.key) { $0.thumbnailLocalPath = file.path }
        } catch { /* Missing artwork must not change the video transfer status. */ }
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
                                                              expectedVideo: key.hasPrefix("hanime:")) {
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
    /// Try a fresh authorized Hanime handshake at a lower stream quality.
    /// This starts another actual AVAssetDownloadTask, never a thumbnail transfer.
    private func retryHanimeStream(_ key: String, reason: String) -> Bool {
        guard let record = records.first(where: { $0.key == key }),
              record.provider.lowercased() == Provider.hanime.rawValue,
              record.state != .cancelled, record.state != .complete,
              !preparing.contains(key) else { return false }
        let nextVariant = (hanimeVariantAttempts[key] ?? 0) + 1
        guard nextVariant <= 2 else {
            hanimeVariantAttempts.removeValue(forKey: key)
            return false
        }
        hanimeVariantAttempts[key] = nextVariant
        tasks.removeValue(forKey: key)
        update(key) {
            $0.state = .queued
            $0.progress = 0
            $0.localMediaPath = nil
            $0.errorMessage = "Retrying Hanime stream quality \(nextVariant + 1)…"
        }
        let post = Post(key: record.key, id: record.postID, provider: record.provider,
                        tags: record.tags, thumbUrl: record.thumbnailRemoteURL,
                        pageUrl: record.pageURL ?? "", type: "video")
        download(post, refreshSource: true, hanimeVariant: nextVariant)
        return true
    }
    private func failedTransfer(_ key: String, reason: String) {
        guard let record = records.first(where: { $0.key == key }),
              record.state != .cancelled, record.state != .complete else { return }
        if retryHanimeStream(key, reason: reason) { return }
        tasks.removeValue(forKey: key)
        if record.provider.lowercased() == Provider.pornhub.rawValue,
           !refreshedPornhubTransfers.contains(key) {
            refreshedPornhubTransfers.insert(key)
            // The cached video URL may have expired or returned an HTML error
            // page. Resolve one fresh signed URL from the original post.
            retry(record)
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
        hlsLocations.store(location, taskID: taskID)
        // AVFoundation owns HLS .movpkg packages. Retain its destination as
        // soon as it is assigned, including across background relaunches.
        Task { @MainActor in
            guard self.tasks[key]?.taskIdentifier == taskID else { return }
            self.update(key) { $0.localMediaPath = location.path }
        }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        // A location callback does not establish that the transfer succeeded.
        // Only didCompleteWithError(nil) can start verification.
        hlsLocations.store(location, taskID: assetDownloadTask.taskIdentifier)
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
        let hlsLocation = isHLS ? hlsLocations.take(taskID: taskID) : nil
        Task { @MainActor in
            guard self.tasks[key]?.taskIdentifier == taskID else { return }
            if let message {
                if self.retryHanimeStream(key, reason: message) { return }
                self.tasks.removeValue(forKey: key)
                self.update(key) { if $0.state != .cancelled { $0.state = .failed; $0.errorMessage = message } }
            } else if isHLS {
                guard let record = self.records.first(where: { $0.key == key }),
                      record.state == .downloading || record.state == .paused else { return }
                let destination = hlsLocation ?? record.localMediaPath.map { URL(fileURLWithPath: $0) }
                guard let destination else {
                    self.failedTransfer(key, reason: "HLS finished without a local video package.")
                    return
                }
                self.update(key) { $0.localMediaPath = destination.path }
                await self.finished(key, location: destination)
            }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in BackgroundDownloadEvents.complete(identifier) }
    }
}

enum OfflineHLSReadiness {
    static func isVerified(playable: Bool, duration: Double, cacheReady: Bool?) -> Bool {
        playable && duration.isFinite && duration > 0 && cacheReady == true
    }
}

enum DownloadSourcePolicy {
    static func validate(media: ResolvedMedia, for post: Post) throws -> (url: URL, isHLS: Bool) {
        guard let url = URL(string: media.mediaUrl), url.scheme == "https" else {
            throw URLError(.badURL)
        }
        let fileType = url.pathExtension.lowercased()
        let isHLS = fileType == "m3u8" || url.path.hasPrefix("/hls/") ||
            (media.type == "hls" && !["mp4", "m4v", "mov"].contains(fileType))
        if post.providerKey == .hanime {
            // An image can be a useful poster, but it must never be marked as
            // the completed offline video. Hanime requires first-party media.
            guard HanimeGeneratedAPI.permittedStreamURL(url),
                  isHLS || ["mp4", "m4v"].contains(fileType) else {
                throw APIError.server("Hanime returned a preview instead of a video stream. Retry to resolve the HLS source.")
            }
        }
        return (url, isHLS)
    }
}

enum DownloadResponseValidator {
    static func invalidVideoPayload(_ header: Data) -> Bool {
        if header.isEmpty { return true }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) ||
           header.starts(with: [0x89, 0x50, 0x4E, 0x47]) ||
           header.starts(with: Array("GIF8".utf8)) ||
           header.starts(with: Array("BM".utf8)) ||
           header.starts(with: [0x49, 0x49, 0x2A, 0x00]) ||
           header.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if header.count >= 12 {
            let magic = String(decoding: header.prefix(12), as: UTF8.self)
            if magic.hasPrefix("RIFF"), magic.hasSuffix("WEBP") { return true }
            if String(decoding: header[4..<8], as: UTF8.self) == "ftyp",
               ["avif", "avis", "heic", "heix", "mif1", "msf1"]
                .contains(String(decoding: header[8..<12], as: UTF8.self)) { return true }
        }
        let prefix = String(decoding: header, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.hasPrefix("#extm3u") || prefix.hasPrefix("<html") ||
            prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("{\"error\"") ||
            prefix.hasPrefix("{\"message\"")
    }

    static func failure(response: HTTPURLResponse?, header: Data, expectedVideo: Bool = false) -> String? {
        guard let response else { return "The download server returned no HTTP response." }
        guard (200..<300).contains(response.statusCode) else {
            return "The media server returned HTTP \(response.statusCode). The source may have expired or be unavailable in your region."
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if expectedVideo && (mime.hasPrefix("image/") || mime.contains("mpegurl") ||
                             invalidVideoPayload(header)) {
            return "The media server returned a preview, playlist, or invalid payload rather than a video file."
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
