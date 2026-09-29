import Foundation
import SwiftUI

struct ExcludedTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var enabled = true
}

@MainActor final class AppState: ObservableObject {
    @Published var enabledSources: Set<SourceID> = [.danbooru, .redgifs] { didSet { save() } }
    @Published var excluded: [ExcludedTag] = [] { didSet { save() } }
    @Published var likes: [Post] = [] { didSet { save() } }
    @Published var recentSearches: [String] = [] { didSet { save() } }
    @Published var signals: [String: Double] = [:] { didSet { save() } }
    @Published var autoplay = true { didSet { save() } }
    @Published var mute = true { didSet { save() } }
    @Published var onboarded = false { didSet { save() } }
    @Published var error: String?
    let danbooru = DanbooruProvider()
    let redgifs = RedGIFsProvider()
    let downloads = DownloadManager()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 48 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        if let data = UserDefaults.standard.data(forKey: "quicktick.state"), let stored = try? JSONDecoder().decode(Snapshot.self, from: data) {
            enabledSources = stored.enabledSources
            excluded = stored.excluded
            likes = stored.likes
            recentSearches = stored.recentSearches
            signals = stored.signals
            autoplay = stored.autoplay
            mute = stored.mute
            onboarded = stored.onboarded
        }
    }
    private struct Snapshot: Codable {
        let enabledSources: Set<SourceID>
        let excluded: [ExcludedTag]
        let likes: [Post]
        let recentSearches: [String]
        let signals: [String: Double]
        let autoplay: Bool
        let mute: Bool
        let onboarded: Bool
    }
    private func save() {
        let snapshot = Snapshot(enabledSources: enabledSources, excluded: excluded, likes: likes, recentSearches: recentSearches, signals: signals, autoplay: autoplay, mute: mute, onboarded: onboarded)
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: "quicktick.state") }
    }
    var activeExclusions: [String] { excluded.filter(\.enabled).map(\.name) }
    var recommendationTags: [String] { RecommendationEngine.topTags(from: signals, excluded: activeExclusions) }
    func provider(_ id: SourceID) -> any MediaProvider { id == .danbooru ? danbooru : redgifs }
    func like(_ post: Post) {
        if let index = likes.firstIndex(where: { $0.id == post.id }) { likes.remove(at: index) }
        else { likes.insert(post, at: 0); record(post, weight: 5) }
    }
    func isLiked(_ post: Post) -> Bool { likes.contains(where: { $0.id == post.id }) }
    func record(_ post: Post, weight: Double) { RecommendationEngine.record(post, weight: weight, into: &signals) }
    func addSearch(_ term: String) {
        guard !term.isEmpty else { return }
        recentSearches.removeAll { $0 == term }
        recentSearches.insert(term, at: 0)
        recentSearches = Array(recentSearches.prefix(20))
    }
    func clearRecommendations() { signals.removeAll() }
    func clearCache() { URLCache.shared.removeAllCachedResponses() }
}

@MainActor final class FeedModel: ObservableObject {
    @Published var posts: [Post] = []
    @Published var loading = false
    @Published var error: String?
    @Published var sort: FeedSort = .recommended
    @Published var source: SourceID = .danbooru
    @Published var search = ""
    private var cursors: [SourceID: String?] = [:]
    private var exhausted: Set<SourceID> = []
    private var generation = UUID()
    private var task: Task<Void, Never>?
    let animatedOnly: Bool
    init(animatedOnly: Bool = false) { self.animatedOnly = animatedOnly }

    func reset(app: AppState) {
        task?.cancel()
        generation = UUID()
        posts = []; cursors = [:]; exhausted = []; error = nil
        loadMore(app: app)
    }
    func loadMore(app: AppState) {
        guard !loading, !exhausted.contains(source), app.enabledSources.contains(source) else { return }
        loading = true
        let current = generation
        let chosenSource = source
        let terms = TagRules.terms(search)
        let recommendations = sort == .recommended && terms.isEmpty ? app.recommendationTags : []
        let query = FeedQuery(tags: terms.isEmpty ? recommendations : terms, exclusions: app.activeExclusions, sort: sort == .recommended ? .popular : sort, animatedOnly: animatedOnly, cursor: cursors[source] ?? nil)
        task = Task {
            do {
                let page = try await app.provider(chosenSource).fetch(query)
                guard !Task.isCancelled, generation == current else { return }
                posts += page.posts.filter { post in !posts.contains(where: { $0.id == post.id }) }
                cursors[chosenSource] = page.nextCursor
                if page.nextCursor == nil { exhausted.insert(chosenSource) }
                error = nil
            } catch {
                if !Task.isCancelled && generation == current { self.error = error.localizedDescription }
            }
            if generation == current { loading = false }
        }
    }
}

struct DownloadItem: Identifiable, Codable {
    enum Status: String, Codable { case active, completed, failed, cancelled }
    let id: String
    let post: Post
    var status: Status
    var progress: Double
    var localName: String?
    var error: String?
}

@MainActor final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private let directory: URL
    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved.map { item in var copy = item; if copy.status == .active { copy.status = .failed; copy.error = "Interrupted" }; return copy }
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
    }
    func start(_ post: Post) {
        if items.contains(where: { $0.id == post.id && ($0.status == .active || $0.status == .completed) }) { return }
        items.removeAll { $0.id == post.id }
        items.insert(DownloadItem(id: post.id, post: post, status: .active, progress: 0, localName: nil, error: nil), at: 0)
        persist()
        tasks[post.id] = Task {
            do {
                var request = URLRequest(url: post.mediaURL)
                request.setValue("Quicktick/1.0", forHTTPHeaderField: "User-Agent")
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NetworkError.invalidResponse }
                try Task.checkCancellation()
                let ext = post.mediaURL.pathExtension.isEmpty ? (post.kind == .video ? "mp4" : "jpg") : post.mediaURL.pathExtension
                let name = post.id.replacingOccurrences(of: ":", with: "-") + "." + ext
                let destination = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                update(post.id) { $0.status = .completed; $0.progress = 1; $0.localName = name }
            } catch {
                update(post.id) { $0.status = error is CancellationError ? .cancelled : .failed; $0.error = error.localizedDescription }
            }
            tasks[post.id] = nil
        }
    }
    private func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index]); persist()
    }
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func retry(_ id: String) { if let post = items.first(where: { $0.id == id })?.post { start(post) } }
    func fileURL(_ item: DownloadItem) -> URL? { item.localName.map { directory.appendingPathComponent($0) } }
}
