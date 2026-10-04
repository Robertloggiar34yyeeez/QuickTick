import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedProvider: Provider = .rule34 {
        didSet {
            guard oldValue != selectedProvider else { return }
            generation = UUID(); posts = []; nextPage = 1; hasMore = true; isLoading = false
            players.releaseAll()
        }
    }
    @Published var posts: [Post] = []
    @Published var queryText = ""
    @Published var favorites: [String: Post] = [:]
    @Published var exclusions: [String] = []
    @Published var tasteSetup = TasteSetup()
    @Published var lastError: String?
    @Published private(set) var syncID = ""
    @Published private(set) var recommendationMode = "Local 0.6.24"
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var learnedInterests: [String] = []
    @Published var resetStatus: String?
    @Published var storageWarning: String?
    @Published var immersionFraming = false { didSet { persistLocal() } }
    @Published var muted = false { didSet { persistLocal() } }
    private var nextPage = 1
    private var encountered: Set<String> = []
    private var generation = UUID()
    private var local = LocalAppState()
    private let localStorage = LocalStateStore()
    @Published private(set) var syncStatus = "Not yet synced"
    @Published private(set) var syncFailed = false
    @Published private(set) var isSyncing = false
    private var syncFlight: Task<Void, Error>?
    private var syncRevision = 0
    private var bootstrapped = false
    private var lastSyncAttempt = Date.distantPast
    private var syncTask: Task<Void, Never>?
    private var restoreFailed = false

    let api: QuicktickAPIClient
    let recommendations = RecommendationEngine()
    let players = PlayerPool()
    let recommendationPersistence = RecommendationPersistence()
    let recommendationBridge: RecommendationBridge
    lazy var resolver = MediaResolver(api: api)
    lazy var downloads = DownloadManager(resolver: resolver)
    lazy var sync = QuicktickSyncService(api: api)

    init(api: QuicktickAPIClient = QuicktickAPIClient()) {
        self.api = api
        self.recommendationBridge = RecommendationBridge(api: api)
    }

    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-sync-login") { syncID = UITestSyncSupport.syncID }
            tasteSetup.sources[selectedProvider.rawValue] = TasteChoice(done: true)
            posts = [Post(key: "test:video", id: "1", provider: "Rule34", tags: ["test_tag"], type: "video"), Post(key: "test:image", id: "2", provider: "Rule34", tags: ["still_tag"], type: "image"), Post(key: "test:next", id: "3", provider: "Rule34", type: "video")]
            hasMore = false
            return
        }
        #endif
        do {
            let savedState = try localStorage.load()
            local = savedState
            favorites = local.snapshot.favorites; exclusions = local.snapshot.exclusions.tags
            tasteSetup = local.snapshot.preferences.value
            immersionFraming = savedState.immersionFraming; muted = savedState.muted
        } catch { restoreFailed = true; storageWarning = error.localizedDescription }
        if let saved = KeychainStore.get(account: "quicktick-sync-id"), (try? QuicktickSyncCrypto.parse(saved)) != nil {
            syncID = saved
        } else {
            let generated = QuicktickSyncCrypto.generate()
            do { try KeychainStore.set(generated, account: "quicktick-sync-id"); syncID = generated }
            catch { lastError = "Keychain: \(error.localizedDescription)" }
        }
        if let local = await recommendationPersistence.load() { await recommendations.load(local) }
        let recommendationWarning = await recommendationPersistence.lastError
        if let recommendationWarning { storageWarning = recommendationWarning }
        var credentials = ProviderCredentials()
        credentials.rule34User = KeychainStore.get(account: "rule34-user") ?? ""
        credentials.rule34Key = KeychainStore.get(account: "rule34-key") ?? ""
        credentials.pornhubSession = KeychainStore.get(account: "pornhub-session") ?? ""
        local.snapshot.rule34.credentials = Rule34Credentials(userId: credentials.rule34User, apiKey: credentials.rule34Key, remember: !credentials.rule34Key.isEmpty)
        local.snapshot.pornhub.auth.username = KeychainStore.get(account: "pornhub-username") ?? ""
        local.snapshot.pornhub.auth.session = credentials.pornhubSession
        await api.setCredentials(credentials)
        downloads.onCompleted = { [weak self] post in Task { await self?.record(.download, post: post) } }
        await downloads.restoreTasks()
        bootstrapped = true
        Task { await syncWhenActive() }
        await refresh()
    }

    func connectSyncID(_ value: String) async throws {
        let canonical = try QuicktickSyncCrypto.parse(value).full
        if let flight = syncFlight { _ = try? await flight.value }
        guard !isSyncing else { throw APIError.server("Sync is already running. Please wait.") }
        isSyncing = true; syncFailed = false; syncStatus = "Checking cloud profile…"
        defer { isSyncing = false }
        do {
            // Verify the server response and decrypt before replacing a working identity.
            let (remote, _) = try await sync.pull(syncID: canonical)
            try KeychainStore.set(canonical, account: "quicktick-sync-id")
            syncID = canonical
            syncTask?.cancel()
            if let remote { try await applySyncSnapshot(remote) }
            await recommendationBridge.clearBackoff()
            syncStatus = "Saving merged profile…"
            let revision = syncRevision
            try await sync.push(syncID: canonical, snapshot: currentSnapshot())
            syncStatus = remote == nil ? "Cloud profile created. Use this same ID on your other devices." : "Cloud profile merged and synced."
            syncFailed = false; lastSyncAttempt = .now
            if syncRevision != revision { queueSync() }
        } catch {
            syncFailed = true; syncStatus = error.localizedDescription
            throw error
        }
    }

    func syncWhenActive() async {
        guard bootstrapped, !syncID.isEmpty, !isSyncing, Date().timeIntervalSince(lastSyncAttempt) >= 30 else { return }
        lastSyncAttempt = .now
        do {
            try await syncNow()
            if posts.isEmpty { await refresh() }
        } catch { /* syncNow exposes the error in Settings without hiding the feed. */ }
    }

    func refresh(immersive: Bool = false, trainSearch: Bool = false) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        generation = UUID()
        let token = generation
        let provider = selectedProvider
        isLoading = true
        var releasedLoading = false
        defer { if generation == token && !releasedLoading { isLoading = false } }
        do {
            let parsed = QueryParser.parse(queryText)
            if trainSearch && !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await recommendations.recordSearch(provider: selectedProvider, query: queryText)
            }
            let page = try await api.posts(provider: provider, query: parsed, page: 1)
            guard generation == token else { return }
            nextPage = 2; hasMore = page.hasMore ?? !page.items.isEmpty
            let taste = tasteChoice(for: selectedProvider)
            encountered = []
            let filtered = page.items.filter { post in
                guard encountered.insert(post.stableID).inserted else { return false }
                let lowered = Set(post.tags.map { $0.lowercased() })
                return (exclusions + parsed.excluded).allSatisfy { !lowered.contains($0.lowercased()) }
            }

            let immediate = parsed.included.isEmpty ? await recommendations.rank(filtered, taste: taste, recent: posts) : filtered
            guard generation == token else { return }
            posts = immediate
            isLoading = false
            releasedLoading = true
            var gorseScores: [String: Double] = [:]
            var mode = "Local 0.6.24"
            if parsed.included.isEmpty, !syncID.isEmpty, filtered.count >= 2 {
                let positive = await recommendations.positiveTerms(provider: selectedProvider, taste: taste)
                let negative = await recommendations.negativeTerms(provider: selectedProvider, taste: taste)
                if let remote = await recommendationBridge.rank(posts: filtered, provider: selectedProvider, syncID: syncID, positiveTerms: positive, negativeTerms: negative) {
                    gorseScores = remote
                    mode = "Hybrid local + Gorse"
                } else {
                    mode = "Local 0.6.24 fallback"
                }
            }

            let ranked = parsed.included.isEmpty
                ? await recommendations.rank(filtered, taste: taste, recent: posts, collaborativeScores: gorseScores)
                : filtered
            guard generation == token else { return }
            // Do not reorder a playing feed after background recommendations arrive.
            if !immersive, nextPage == 2, posts.map(\.stableID) == immediate.map(\.stableID) { posts = ranked }
            recommendationMode = mode
            learnedInterests = await recommendations.positiveTerms(provider: provider, taste: taste)
            await persistRecommendations()
            if !restoreFailed { lastError = nil }
        } catch {
            if generation == token { lastError = error.localizedDescription }
        }
    }

    func loadMore(immersive: Bool = false) async {
        guard !isLoading, hasMore else { return }
        let token = generation
        let provider = selectedProvider
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let parsed = QueryParser.parse(queryText)
            lastError = nil
            // Skip sparse, duplicate and fully filtered pages without waiting for
            // a last-card onAppear that will never fire again.
            for attempt in 0..<5 {
            let page = try await api.posts(provider: provider, query: parsed, page: nextPage)
            guard generation == token else { return }
            nextPage += 1; hasMore = page.hasMore ?? !page.items.isEmpty
            let banned = Set((exclusions + parsed.excluded).map { $0.lowercased() })
            let candidates = page.items.filter { encountered.insert($0.stableID).inserted && banned.isDisjoint(with: Set($0.tags.map { $0.lowercased() })) }
            let ranked = parsed.included.isEmpty ? await recommendations.rank(candidates, taste: tasteChoice(for: provider), recent: posts) : candidates
            guard generation == token else { return }
            posts.append(contentsOf: ranked)
            if !hasMore || (!immersive && !ranked.isEmpty) || (immersive && ranked.contains(where: \.isImmersiveMedia)) { break }
            if attempt == 4 { lastError = "No new clips in the last five pages. Tap Load more to continue." }
            }
        } catch { if token == generation { lastError = error.localizedDescription } }
    }

    func toggleFavorite(_ post: Post) {
        let event: RecommendationEvent
        if favorites[post.stableID] != nil {
            favorites.removeValue(forKey: post.stableID)
            event = .unlike
        } else {
            favorites[post.stableID] = post
            event = .like
        }
        Task { await record(event, post: post) }
        local.snapshot.favoriteMeta[post.stableID] = FavoriteMeta(liked: favorites[post.stableID] != nil, updatedAt: timestamp())
        persistLocal(); queueSync()
    }

    func less(_ post: Post) { posts.removeAll { $0.stableID == post.stableID }; Task { await record(.less, post: post) } }

    func download(_ post: Post) {
        downloads.download(post)
    }

    func recordImpression(_ post: Post) { Task { await record(.impression, post: post, bridgeType: "impression") } }
    func recordQuickSkip(_ post: Post) { Task { await record(.quickSkip, post: post, bridgeType: "skip") } }
    func recordReplay(_ post: Post) { Task { await record(.replay, post: post, bridgeType: "replay") } }
    func recordComplete(_ post: Post) { Task { await record(.complete, post: post, bridgeType: "complete") } }
    func recordWatch(_ post: Post, seconds: Double, completion: Double) { Task { await record(.watched(seconds: seconds, completion: completion), post: post, bridgeType: "watch", value: seconds) } }

    func resetRecommendations() async {
        await recommendations.reset()
        await recommendationPersistence.clear()
        if !syncID.isEmpty {
            var failures = 0
            for provider in Provider.allCases { if !(await recommendationBridge.reset(provider: provider, syncID: syncID)) { failures += 1 } }
            resetStatus = failures == 0 ? "Local and collaborative history reset." : "Local history reset. Collaborative reset unavailable for \(failures) providers."
        }
        recommendationMode = "Local 0.6.24"
        await refresh()
    }

    func applySyncSnapshot(_ snapshot: QuicktickSyncSnapshot) async throws {
            let merged = try currentSnapshot().merging(snapshot)
            let credentials = merged.rule34.credentials
            let session = merged.pornhub.auth.session
            try KeychainStore.set(credentials.remember ? credentials.userId : "", account: "rule34-user")
            try KeychainStore.set(credentials.remember ? credentials.apiKey : "", account: "rule34-key")
            try KeychainStore.set(session, account: "pornhub-session")
            try KeychainStore.set(merged.pornhub.auth.username, account: "pornhub-username")
            await api.setCredentials(ProviderCredentials(rule34User: credentials.userId, rule34Key: credentials.apiKey, pornhubSession: session))
            local.snapshot = merged
            favorites = local.snapshot.favorites; exclusions = local.snapshot.exclusions.tags
            tasteSetup = local.snapshot.preferences.value
            persistLocal()
    }

    func includeTag(_ tag: String) {
        let parsed = QueryParser.parse(queryText)
        let next = (parsed.included + [tag]).uniqued() + parsed.excluded.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }.map { "-\($0)" }
        queryText = next.joined(separator: " ")
    }

    func excludeTag(_ tag: String) {
        let parsed = QueryParser.parse(queryText)
        let included = parsed.included.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
        let excluded = (parsed.excluded + [tag]).uniqued().map { "-\($0)" }
        queryText = (included + excluded).joined(separator: " ")
    }

    func tasteChoice(for provider: Provider) -> TasteChoice {
        tasteSetup.sources[provider.rawValue] ?? TasteChoice()
    }

    private func record(_ event: RecommendationEvent, post: Post, bridgeType explicitType: String? = nil, value: Double = 1) async {
        await recommendations.record(event, post: post)
        await persistRecommendations()
        guard let provider = post.providerKey, !syncID.isEmpty else { return }
        let taste = tasteChoice(for: provider)
        let positive = await recommendations.positiveTerms(provider: provider, taste: taste)
        let negative = await recommendations.negativeTerms(provider: provider, taste: taste)
        let bridgeType = explicitType ?? {
            switch event {
            case .impression: return "impression"
            case .like: return "like"
            case .unlike: return "unlike"
            case .less: return "less"
            case .download: return "download"
            case .quickSkip: return "skip"
            case .watched: return "watch"
            case .replay: return "replay"
            case .complete: return "complete"
            }
        }()
        await recommendationBridge.feedback(post: post, provider: provider, syncID: syncID, type: bridgeType, value: value, positiveTerms: positive, negativeTerms: negative)
    }

    private func persistRecommendations() async {
        await recommendationPersistence.save(await recommendations.snapshot())
        learnedInterests = await recommendations.positiveTerms(provider: selectedProvider, taste: tasteChoice(for: selectedProvider))
    }

    func setTaste(into: [String], notInto: [String]) {
        tasteSetup.sources[selectedProvider.rawValue] = TasteChoice(done: true, into: into, notInto: notInto)
        local.snapshot.preferences.updatedAt = timestamp()
        persistLocal(); queueSync(); Task { await refresh() }
    }

    func setExclusions(_ tags: [String]) {
        exclusions = tags; local.snapshot.exclusions.updatedAt = timestamp()
        persistLocal(); queueSync()
    }

    func resumePosition(_ key: String) -> Double? { local.resumePositions[key] }
    func saveResume(_ key: String, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        local.resumePositions[key] = seconds; persistLocal()
    }

    var rememberedProviderAccess: Bool { local.snapshot.rule34.credentials.remember }
    var syncedPornhubUsername: String { local.snapshot.pornhub.auth.username }

    func saveCredentials(user: String, key: String, session: String, remember: Bool, username: String? = nil, touch: Bool = true) async {
        do {
            try KeychainStore.set(remember ? user : "", account: "rule34-user")
            try KeychainStore.set(remember ? key : "", account: "rule34-key")
            try KeychainStore.set(session, account: "pornhub-session")
            await api.setCredentials(ProviderCredentials(rule34User: user, rule34Key: key, pornhubSession: session))
            local.snapshot.rule34.credentials = Rule34Credentials(userId: user, apiKey: key, remember: remember)
            if let username { try KeychainStore.set(username, account: "pornhub-username"); local.snapshot.pornhub.auth.username = username }
            local.snapshot.pornhub.auth.session = session
            if touch { local.snapshot.rule34.updatedAt = timestamp(); local.snapshot.pornhub.updatedAt = timestamp() }
            persistLocal()
        } catch { lastError = error.localizedDescription }
    }

    func syncNow() async throws {
        if let flight = syncFlight { try await flight.value; return }
        guard !isSyncing else { throw APIError.server("Sync is already running. Please wait.") }
        let identity = syncID
        _ = try QuicktickSyncCrypto.parse(identity)
        isSyncing = true; syncFailed = false; syncStatus = "Syncing…"
        let flight = Task { @MainActor in
            let (remote, _) = try await self.sync.pull(syncID: identity)
            guard self.syncID == identity else { throw CancellationError() }
            if let remote { try await self.applySyncSnapshot(remote) }
            let revision = self.syncRevision
            try await self.sync.push(syncID: identity, snapshot: self.currentSnapshot())
            self.syncStatus = "Synced. Favorites, access settings and interests are up to date."
            self.lastSyncAttempt = .now
            if self.syncRevision != revision { self.queueSync() }
        }
        syncFlight = flight
        defer { syncFlight = nil; isSyncing = false }
        do { try await flight.value }
        catch { syncFailed = true; syncStatus = error.localizedDescription; throw error }
    }

    private func timestamp() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func currentSnapshot() -> QuicktickSyncSnapshot {
        var snapshot = local.snapshot
        snapshot.updatedAt = timestamp(); snapshot.favorites = favorites.mapValues { post in
            var safe = post
            if URL(string: safe.mediaUrl)?.isFileURL == true { safe.mediaUrl = "" }
            if URL(string: safe.previewUrl)?.isFileURL == true { safe.previewUrl = "" }
            if URL(string: safe.thumbUrl)?.isFileURL == true { safe.thumbUrl = "" }
            return safe
        }
        snapshot.exclusions.tags = exclusions; snapshot.preferences.value = tasteSetup
        return snapshot
    }
    private func persistLocal() {
        guard !restoreFailed else { return }
        local.snapshot = currentSnapshot(); local.immersionFraming = immersionFraming; local.muted = muted
        // Credentials/session material belongs in Keychain, never in the ordinary state file.
        var disk = local
        disk.snapshot.rule34.credentials = Rule34Credentials()
        disk.snapshot.pornhub.auth = PornhubAuth()
        do { try localStorage.save(disk) } catch { lastError = error.localizedDescription }
    }
    private func queueSync() {
        syncRevision += 1
        syncTask?.cancel()
        syncTask = Task {
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation(); try await syncNow() }
            catch is CancellationError {} catch { syncFailed = true; syncStatus = error.localizedDescription }
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}
