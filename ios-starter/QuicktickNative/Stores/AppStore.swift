import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedProvider: Provider = .rule34 {
        didSet {
            guard oldValue != selectedProvider else { return }
            invalidateFeed()
        }
    }
    @Published var posts: [Post] = []
    @Published var activeTab = 0 { didSet { if oldValue != activeTab { inlinePlaybackID = nil; pausedPlaybackID = nil; players.pauseAll() } } }
    @Published var isForeground = true { didSet { if !isForeground { players.pauseAll() } } }
    @Published var pausedPlaybackID: String?
    @Published var inlinePlaybackID: String? { didSet { if oldValue != inlinePlaybackID { pausedPlaybackID = nil; players.pauseAll() } } }
    @Published var queryText = "" { didSet { if oldValue != queryText { invalidateFeed() } } }
    @Published var feedSort = "recommended" { didSet { if oldValue != feedSort { invalidateFeed() } } }
    @Published private(set) var feedRevision = UUID()
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
    @Published private(set) var feedMediaOnly = false
    private var candidateContext: String?
    private var nextPage = 1
    private var encountered: Set<String> = []
    private var generation = UUID()
    private var semanticTask: Task<Void, Never>?
    private var refreshFlight: Task<Void, Never>?
    private var pageFlight: Task<Void, Never>?
    private var local = LocalAppState()
    private let localStorage: LocalStateStore
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

    init(api: QuicktickAPIClient = QuicktickAPIClient(), localStorage: LocalStateStore = LocalStateStore()) {
        self.localStorage = localStorage
        self.api = api
        self.recommendationBridge = RecommendationBridge(api: api)
    }

    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            pageFlight?.cancel(); hasMore = false; lastError = nil
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-sync-login") { syncID = UITestSyncSupport.syncID }
            tasteSetup.sources[selectedProvider.rawValue] = TasteChoice(done: true)
            posts = (try? await UITestMediaFactory.shared.posts(sort: feedSort)) ?? []
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-download-images") { downloads.useUITestDownloads(posts) }
            hasMore = false
            return
        }
        #endif
        do {
            let savedState = try localStorage.load()
            local = savedState
            favorites = local.snapshot.favorites; exclusions = local.snapshot.exclusions.tags
            tasteSetup = local.snapshot.preferences.value
            immersionFraming = savedState.immersionFraming
            // Older releases defaulted to muted before audio was configured.
            // Enable audio once on upgrade, then preserve explicit mute choices.
            muted = savedState.audioPreferenceVersion == nil ? false : savedState.muted
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

    func handleMemoryPressure() {
        semanticTask?.cancel()
        players.retain(Set(players.activeKey.map { [$0] } ?? []))
        Task { await MediaImagePipeline.shared.clearDecoded(); await recommendations.releaseSemanticModel() }
    }

    private func invalidateFeed() {
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel(); semanticTask = nil
        generation = UUID(); feedRevision = generation; posts = []; encountered = []; nextPage = 1
        hasMore = true; candidateContext = nil; isLoading = false; lastError = nil; inlinePlaybackID = nil; players.releaseAll()
        learnedInterests = []; recommendationMode = "Local 0.6.24"
    }

    func refresh(immersive: Bool = false, trainSearch: Bool = false) async {
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel()
        let flight = Task { await performRefresh(immersive: immersive, trainSearch: trainSearch) }
        refreshFlight = flight
        await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
    }
    private func performRefresh(immersive: Bool, trainSearch: Bool) async {
        guard !Task.isCancelled else { return }
        let mediaOnly = immersive || activeTab == 1
        feedMediaOnly = mediaOnly
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { posts = (try? await UITestMediaFactory.shared.posts(sort: feedSort)) ?? []; hasMore = false; return }
        #endif
        generation = UUID(); feedRevision = generation; inlinePlaybackID = nil; players.pauseAll()
        let token = generation
        let requestedSort = feedSort
        let requestedQuery = queryText
        let provider = selectedProvider
        isLoading = true
        var releasedLoading = false
        defer { if generation == token && !releasedLoading { isLoading = false } }
        do {
            let parsed = QueryParser.parse(requestedQuery)
            if trainSearch && !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await recommendations.recordSearch(provider: selectedProvider, query: queryText)
            }
            let personalized = requestedSort == "recommended" && parsed.included.isEmpty
            let banned = Set((exclusions + parsed.excluded).map { $0.lowercased() })
            let context = provider.rawValue + "|" + (mediaOnly ? "clips" : "all") + "|" + banned.sorted().joined(separator: ",")
            candidateContext = personalized ? context : nil
            let previous = Set(posts.map(\.stableID))
            var requestedPage = personalized ? await recommendations.candidatePage(context: context) : 1
            guard generation == token, !Task.isCancelled else { return }
            encountered = []
            var filtered: [Post] = []
            // Skip consumed/filtered pages; never reinsert them just to fill a batch.
            for _ in 0..<5 {
                let page = try await api.posts(provider: provider, query: parsed, page: requestedPage, sort: requestedSort, immersive: mediaOnly)
                guard generation == token, !Task.isCancelled else { return }
                requestedPage += 1
                nextPage = requestedPage; hasMore = page.hasMore ?? !page.items.isEmpty
                var incoming = page.items.filter { post in
                    encountered.insert(post.stableID).inserted && (!mediaOnly || post.isImmersiveMedia)
                        && banned.isDisjoint(with: Set(post.tags.map { $0.lowercased() }))
                }
                if personalized {
                    incoming = await recommendations.unseen(incoming.filter { !previous.contains($0.stableID) })
                    guard generation == token, !Task.isCancelled else { return }
                    await recommendations.advanceCandidatePage(context: context, nextPage: hasMore ? nextPage : 1)
                }
                filtered = incoming
                if !filtered.isEmpty || !hasMore { break }
            }
            let taste = tasteChoice(for: provider)
            let firstBatchNextPage = nextPage

            let immediate = parsed.included.isEmpty && feedSort == "recommended" ? await recommendations.rank(filtered, taste: taste, recent: posts) : filtered
            guard generation == token, !Task.isCancelled else { return }
            posts = immediate
            semanticTask?.cancel()
            if requestedSort == "recommended" {
                semanticTask = Task(priority: .utility) { [weak self] in
                    guard let self else { return }
                    await recommendations.prepareSemantic(filtered)
                    guard !Task.isCancelled, generation == token else { return }
                    await adaptRecommendationTail(token: token)
                }
            }
            isLoading = false
            releasedLoading = true
            var gorseScores: [String: Double] = [:]
            var mode = "Local 0.6.24"
            if parsed.included.isEmpty, feedSort == "recommended", !syncID.isEmpty, filtered.count >= 2 {
                let positive = await recommendations.positiveTerms(provider: provider, taste: taste)
                let negative = await recommendations.negativeTerms(provider: provider, taste: taste)
                if let remote = await recommendationBridge.rank(posts: filtered, provider: provider, syncID: syncID, positiveTerms: positive, negativeTerms: negative) {
                    gorseScores = remote
                    mode = "Hybrid local + Gorse"
                } else {
                    mode = "Local 0.6.24 fallback"
                }
            }

            let ranked = parsed.included.isEmpty && feedSort == "recommended"
                ? await recommendations.rank(filtered, taste: taste, recent: posts, collaborativeScores: gorseScores)
                : filtered
            guard generation == token, !Task.isCancelled else { return }
            // Do not reorder a playing feed after background recommendations arrive.
            if !mediaOnly, inlinePlaybackID == nil, nextPage == firstBatchNextPage, posts.map(\.stableID) == immediate.map(\.stableID) { posts = ranked }
            recommendationMode = mode
            let interests = await recommendations.positiveTerms(provider: provider, taste: taste)
            guard generation == token, !Task.isCancelled else { return }
            learnedInterests = interests
            await persistRecommendations()
            if generation == token, !restoreFailed { lastError = nil }
        } catch {
            if generation == token, !Task.isCancelled { lastError = error.localizedDescription }
        }
    }

    func loadMore(immersive: Bool = false) async {
        // The initial page belongs to bootstrap/refresh. Lazy footer appearance
        // must not race credential restoration or start a second page-one request.
        guard nextPage > 1, !isLoading, hasMore else { return }
        // Reserve loading synchronously, so multiple lazy-cell callbacks share one page request.
        isLoading = true
        let flight = Task { await performLoadMore(immersive: immersive) }; pageFlight = flight
        await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
    }
    private func performLoadMore(immersive: Bool) async {
        let token = generation
        defer { if token == generation { isLoading = false } }
        guard !Task.isCancelled, hasMore else { return }
        let provider = selectedProvider
        do {
            let parsed = QueryParser.parse(queryText)
            lastError = nil
            // Skip sparse, duplicate and fully filtered pages without waiting for
            // a last-card onAppear that will never fire again.
            for attempt in 0..<5 {
            let page = try await api.posts(provider: provider, query: parsed, page: nextPage, sort: feedSort, immersive: feedMediaOnly)
            guard generation == token, !Task.isCancelled else { return }
            nextPage += 1; hasMore = page.hasMore ?? !page.items.isEmpty
            let banned = Set((exclusions + parsed.excluded).map { $0.lowercased() })
            var candidates = page.items.filter { encountered.insert($0.stableID).inserted && (!feedMediaOnly || $0.isImmersiveMedia) && banned.isDisjoint(with: Set($0.tags.map { $0.lowercased() })) }
            if let context = candidateContext {
                candidates = await recommendations.unseen(candidates)
                guard generation == token, !Task.isCancelled else { return }
                await recommendations.advanceCandidatePage(context: context, nextPage: hasMore ? nextPage : 1)
            }
            let ranked = parsed.included.isEmpty && feedSort == "recommended" ? await recommendations.rank(candidates, taste: tasteChoice(for: provider), recent: posts) : candidates
            guard generation == token, !Task.isCancelled else { return }
            posts.append(contentsOf: ranked)
            if feedSort == "recommended" {
                semanticTask?.cancel()
                let semanticCandidates = candidates
                semanticTask = Task(priority:.utility) { [weak self] in
                    guard let self else { return }
                    await recommendations.prepareSemantic(semanticCandidates)
                    guard !Task.isCancelled, generation == token else { return }
                    await adaptRecommendationTail(token:token)
                }
            }
            if !hasMore || (!(immersive || feedMediaOnly) && !ranked.isEmpty) || ((immersive || feedMediaOnly) && ranked.contains(where: \.isImmersiveMedia)) { break }
            if attempt == 4 { lastError = "No new posts in the last five pages. Tap Load more to continue." }
            }
            guard generation == token, !Task.isCancelled else { return }
            await persistRecommendations()
        } catch { if token == generation, !Task.isCancelled { lastError = error.localizedDescription } }
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

    func adaptRecommendationTail(token: UUID) async {
        // A tab transition briefly has no active Home post. Ranking that whole
        // array would move the saved scroll anchor before playback reactivates.
        guard activeTab == 0, let active = inlinePlaybackID else { return }
        let source = posts
        guard let activeIndex = source.firstIndex(where: { $0.stableID == active }) else { return }
        // Freeze everything through the visible post: engagement never moves the current card.
        let prefixCount = activeIndex + 1
        let tail = Array(source.dropFirst(prefixCount))
        let ranked = await recommendations.rank(tail, taste: tasteChoice(for: selectedProvider), recent: Array(source.prefix(prefixCount)))
        guard generation == token, feedSort == "recommended", posts.map(\.stableID) == source.map(\.stableID), inlinePlaybackID == active else { return }
        posts = Array(source.prefix(prefixCount)) + ranked
    }

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
        if feedSort == "recommended" { await adaptRecommendationTail(token: generation) }
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
        let provider = selectedProvider; let token = generation
        let interests = await recommendations.positiveTerms(provider: provider, taste: tasteChoice(for: provider))
        if generation == token, selectedProvider == provider { learnedInterests = interests }
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
            if touch, !syncID.isEmpty { queueSync() }
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
        local.audioPreferenceVersion = 1
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
