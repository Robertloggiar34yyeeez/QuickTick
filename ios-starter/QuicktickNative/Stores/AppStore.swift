import Foundation
import SwiftUI
import UIKit

struct VisualRefreshProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var status: String
    var running: Bool
    var fraction: Double { total == 0 ? (running ? 0 : 1) : Double(completed) / Double(total) }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedProvider: Provider = .rule34 {
        didSet {
            guard oldValue != selectedProvider else { return }
            savedFeeds.removeAll()
            if selectedProvider != .rule34 {
                let plainQuery = SearchFilters.split(queryText).tags
                if plainQuery != queryText { queryText = plainQuery; return }
            }
            invalidateFeed()
        }
    }
    @Published var posts: [Post] = [] {
        didSet { postsByID = Dictionary(posts.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    private var postsByID: [String: Post] = [:]
    func postForID(_ id: String) -> Post? { postsByID[id] }
    @Published var activeTab = 0 { didSet { if oldValue != activeTab { idleTask?.cancel(); fullScreenPlaybackID = nil; protectedHomePostIDs = []; inlinePlaybackID = nil; pausedPlaybackID = nil; players.pauseAll() } } }
    @Published var isForeground = true { didSet {
        guard oldValue != isForeground else { return }
        if !isForeground { idleTask?.cancel(); stopActiveLearning(); cancelManualVisualRefresh(); players.suspendActivePlayback() }
        else {
            // A rapid inactive→active transition can coalesce SwiftUI task IDs
            // while the app is suspended. Resume the retained player directly,
            // only if its existing feed and visible-post owners still agree.
            let savedOwner = players.suspendedOwner ?? players.activeOwner
            let owner = savedOwner ?? ([0: "home", 1: "immersive", 2: "favorites", 3: "downloads"][activeTab] ?? "home")
            let allowed: Set<String>
            if activeTab == 1 || (activeTab == 0 && owner == "home-immersive") { allowed = Set(posts.map(\.stableID)) }
            else if activeTab == 2 && owner == "favorites-immersive" { allowed = Set(favorites.keys) }
            else if activeTab == 3 && owner == "offline-immersive" { allowed = Set(downloads.records.compactMap { $0.offlinePost?.stableID }) }
            else { allowed = Set(inlinePlaybackID.map { [$0] } ?? []) }
            players.resumeSuspendedPlayback(allowed: allowed, owner: owner, muted: muted, pausedKey: pausedPlaybackID)
            if bootstrapped { visualScanStatus = visualAnalysisEnabled ? "Updating visual recommendations…" : nil; scheduleIdleIntelligence() }
        }
    } }
    @Published var pausedPlaybackID: String?
    @Published var fullScreenPlaybackID: String?
    @Published var inlinePlaybackID: String? { didSet { if oldValue != inlinePlaybackID { idleTask?.cancel(); pausedPlaybackID = nil; if players.activeOwner != "immersive", players.activeOwner?.hasSuffix("-immersive") != true { players.transitionVisiblePost() } } } }
    @Published var queryText = "" { didSet { if oldValue != queryText && !committingSearch { invalidateFeed() } } }
    @Published var feedSort = "recommended" { didSet { if oldValue != feedSort && !committingSearch { invalidateFeed() } } }
    @Published private(set) var feedRevision = UUID()
    @Published var favorites: [String: Post] = [:] {
        didSet {
            favoriteExclusionIDs = Set(favorites.values.flatMap { FeedExclusions.identifiers($0) })
            // Refresh from the complete latest snapshot and cancel obsolete
            // updates. Neither model inference nor network work blocks taps.
            favoriteSyncTask?.cancel()
            let snapshot = Array(favorites.values)
            favoriteSyncTask = Task(priority: .utility) { [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.recommendations.configureFavorites(snapshot)
                guard !Task.isCancelled else { return }
                await self.visual.reconcileFavorites(snapshot)
            }
        }
    }
    private var favoriteSyncTask: Task<Void, Never>?
    private var favoriteExclusionIDs: Set<String> = []
    @Published var exclusions: [String] = []
    @Published var tasteSetup = TasteSetup()
    @Published var lastError: String?
    @Published private(set) var providerCooldowns: [Provider: Date] = [:]
    var feedRetryAfter: Date? { providerCooldowns[selectedProvider] }
    private func recordFeedError(_ error: Error, provider: Provider) {
        if let deadline = (error as? APIError)?.retryAfter { providerCooldowns[provider] = deadline }
        lastError = error.localizedDescription
    }
    @Published private(set) var syncID = ""
    @Published private(set) var cloudSyncEnabled = false
    @Published private(set) var recommendationMode = "On-device recommendations"
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var learnedInterests: [String] = []
    @Published var resetStatus: String?
    @Published var storageWarning: String?
    @Published var pendingProfileImport: RecommendationTransfer?
    @Published var profileTransferError: String?
    @Published var immersionFraming = false { didSet { persistLocal() } }
    @Published var muted = false { didSet { persistLocal() } }
    @Published private(set) var feedMediaOnly = false
    private var candidateContext: String?
    private var nextPage = 1
    private var publishedNextPage = 1
    private var publishedQuery = ""
    private var publishedSort = "recommended"
    private var encountered: Set<String> = []
    private var generation = UUID()
    @Published var visualAnalysisEnabled = (UserDefaults.standard.object(forKey: "quicktick-visual-analysis-v1") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(visualAnalysisEnabled, forKey: "quicktick-visual-analysis-v1"); scheduleIdleIntelligence() }
    }
    let visual = VisualAnalysisService()
    @Published private(set) var visualScanStatus: String?
    @Published private(set) var manualVisualProgress: VisualRefreshProgress?
    var isManualVisualScanRunning: Bool { manualVisualProgress?.running == true }
    private var manualVisualTask: Task<Void, Never>?
    private var manualVisualID = UUID()
    private var feedExclusions = FeedExclusions()
    private var visualScores: [String: Double] = [:]
    private var activeLearningTask: Task<Void, Never>?
    private var activeLearningID = UUID()
    private var memoryCooldown = Date.distantPast
    private var idleTask: Task<Void, Never>?
    private var plannedAcquisition: RecommendationEngine.CandidateRequest?
    private var candidateCursors: [String: Int] = [:]
    private var lastFeedMotion = Date.distantPast
    private var motionTask: Task<Void, Never>?
    private var visualDiscoveryRound = 0
    private var persistenceTask: Task<Void, Never>?
    private var pendingSkipIntents: Set<String> = []
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
    @Published private(set) var bootstrapped = false
    private var lastSyncAttempt = Date.distantPast
    private var syncTask: Task<Void, Never>?
    private var restoreFailed = false

    let api: QuicktickAPIClient
    let recommendations = RecommendationEngine()
    let players = PlayerPool()
    let recommendationPersistence = RecommendationPersistence()
    lazy var resolver = MediaResolver(api: api)
    lazy var downloads = DownloadManager(resolver: resolver)
    lazy var sync = QuicktickSyncService(api: api)

    init(api: QuicktickAPIClient = QuicktickAPIClient(), localStorage: LocalStateStore = LocalStateStore()) {
        self.localStorage = localStorage
        self.api = api
        players.onPlaybackStart = { [weak self] in
            self?.idleTask?.cancel()
            self?.stopActiveLearning(); self?.startActiveLearning()
            if self?.visualScanStatus != nil, self?.visualScanStatus != "Visual update paused for playback" { self?.visualScanStatus = "Visual update paused for playback" }
        }
    }

    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            pageFlight?.cancel(); hasMore = false; lastError = nil
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-sync-login") { syncID = UITestSyncSupport.syncID; cloudSyncEnabled = true; await api.setCloudSyncEnabled(true) }
            tasteSetup.sources[selectedProvider.rawValue] = TasteChoice(done: true)
            posts = (try? await UITestMediaFactory.shared.posts(sort: feedSort)) ?? []
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-download-images") { downloads.useUITestDownloads(posts) }
            hasMore = false; bootstrapped = true
            FeedFrameMonitor.shared.startIfRequested()
            return
        }
        #endif
        do {
            let savedState = try localStorage.load()
            local = savedState
            cloudSyncEnabled = savedState.cloudSyncEnabled ?? false
            await api.setCloudSyncEnabled(cloudSyncEnabled)
            favorites = local.snapshot.favorites; exclusions = local.snapshot.exclusions.tags
            tasteSetup = local.snapshot.preferences.value
            immersionFraming = savedState.immersionFraming
            // Older releases defaulted to muted before audio was configured.
            // Enable audio once on upgrade, then preserve explicit mute choices.
            muted = savedState.audioPreferenceVersion == nil ? false : savedState.muted
        } catch { restoreFailed = true; storageWarning = error.localizedDescription }
        if let saved = KeychainStore.get(account: "quicktick-sync-id"), (try? QuicktickSyncCrypto.parse(saved)) != nil {
            syncID = saved
        } else if cloudSyncEnabled {
            let generated = QuicktickSyncCrypto.generate()
            do { try KeychainStore.set(generated, account: "quicktick-sync-id"); syncID = generated }
            catch { lastError = "Keychain: \(error.localizedDescription)" }
        }
        if let local = await recommendationPersistence.load() {
            await restoreRecommendationState(local)
        }
        await recommendations.configureFavorites(Array(favorites.values))
        await visual.reconcileFavorites(Array(favorites.values))
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
        bootstrapped = true
        visualScanStatus = visualAnalysisEnabled ? "Updating visual recommendations…" : nil
        await refresh()
        FeedFrameMonitor.shared.startIfRequested()
        Task(priority: .utility) { await downloads.restoreTasks(); await syncWhenActive() }
    }

    func setCloudSyncEnabled(_ enabled: Bool) async throws {
        syncTask?.cancel(); syncFlight?.cancel()
        cloudSyncEnabled = enabled
        await api.setCloudSyncEnabled(enabled)
        if enabled, syncID.isEmpty {
            let generated = QuicktickSyncCrypto.generate()
            do { try KeychainStore.set(generated, account: "quicktick-sync-id"); syncID = generated }
            catch { cloudSyncEnabled = false; await api.setCloudSyncEnabled(false); throw error }
        }
        local.cloudSyncEnabled = enabled
        syncFailed = false
        syncStatus = enabled ? "Website Sync enabled. Use Sync now or connect your existing ID." : "Website Sync is off. Your profile stays on this device."
        persistLocal()
    }

    func connectSyncID(_ value: String) async throws {
        guard cloudSyncEnabled else { throw APIError.server("Enable optional website Sync first.") }
        let canonical = try QuicktickSyncCrypto.parse(value).full
        if let flight = syncFlight { _ = try? await flight.value }
        guard !isSyncing else { throw APIError.server("Sync is already running. Please wait.") }
        isSyncing = true; syncFailed = false; syncStatus = "Checking cloud profileÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦"
        defer { isSyncing = false }
        do {
            // Verify the server response and decrypt before replacing a working identity.
            let (remote, _) = try await sync.pull(syncID: canonical)
            try Task.checkCancellation()
            guard cloudSyncEnabled else { throw CancellationError() }
            try KeychainStore.set(canonical, account: "quicktick-sync-id")
            syncID = canonical
            syncTask?.cancel()
            if let remote { try await applySyncSnapshot(remote) }
            syncStatus = "Saving merged profileÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦"
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
        guard cloudSyncEnabled, bootstrapped, !syncID.isEmpty, !isSyncing, Date().timeIntervalSince(lastSyncAttempt) >= 30 else { return }
        lastSyncAttempt = .now
        do {
            try await syncNow()
            if posts.isEmpty { await refresh() }
        } catch { /* syncNow exposes the error in Settings without hiding the feed. */ }
    }

    func handleMemoryPressure() {
        memoryCooldown = .now.addingTimeInterval(30); stopActiveLearning()
        cancelManualVisualRefresh()
        semanticTask?.cancel(); idleTask?.cancel()
        players.retain(Set(players.activeKey.map { [$0] } ?? []))
        Task { await MediaImagePipeline.shared.clearDecoded(); await recommendations.releaseSemanticModel(); await visual.releaseModels() }
    }

    private func invalidateFeed() {
        fullScreenPlaybackID = nil
        idleTask?.cancel(); plannedAcquisition = nil
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel(); semanticTask = nil
        generation = UUID(); feedRevision = generation; posts = []; encountered = []; nextPage = 1
        publishedNextPage = 1; publishedQuery = queryText; publishedSort = feedSort
        hasMore = true; candidateContext = nil; isLoading = false; lastError = nil; inlinePlaybackID = nil; players.releaseAll()
        learnedInterests = []; recommendationMode = "On-device recommendations"
    }

    func refresh(immersive: Bool = false, trainSearch: Bool = false) async {
        if let deadline = feedRetryAfter, deadline > .now {
            let mediaOnly = immersive || activeTab == 1
            if feedMediaOnly != mediaOnly { invalidateFeed(); feedMediaOnly = mediaOnly }
            // Preference edits still apply locally while the provider is cooling
            // down. No network retry or model inference is needed for this rank.
            if feedSort == "recommended", QueryParser.parse(queryText).included.isEmpty {
                posts = feedExclusions.filter(posts, favorites: Array(favorites.values), recommended: true, favoriteIDs: favoriteExclusionIDs)
            }
            lastError = APIError.rateLimited(selectedProvider, deadline).localizedDescription; return
        }
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel(); idleTask?.cancel()
        let flight = Task { await performRefresh(immersive: immersive, trainSearch: trainSearch) }
        refreshFlight = flight
        await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
    }
    private struct SavedFeed {
        var provider: Provider
        var query: String
        var sort: String
        var publishedQuery: String
        var publishedSort: String
        var posts: [Post]
        var encountered: Set<String>
        var nextPage: Int
        var hasMore: Bool
        var context: String?
        var protected: Set<String>
    }
    private var savedFeeds: [Int: SavedFeed] = [:]
    private var committingSearch = false
    var searchDrafts: [Int: SearchDraft] = [:]
    func commitSearch(query: String, sort: String) {
        committingSearch = true
        queryText = query; feedSort = sort
        committingSearch = false
    }
    func selectFeedTab(_ tab: Int) async {
        guard (0...3).contains(tab) else { return }
        if tab == activeTab {
            if tab < 2 { await refresh(immersive: tab == 1) }
            return
        }
        if activeTab < 2 {
            savedFeeds[activeTab] = SavedFeed(provider: selectedProvider, query: queryText, sort: feedSort, publishedQuery: publishedQuery, publishedSort: publishedSort,
                posts: posts, encountered: Set(posts.map(\.stableID)), nextPage: publishedNextPage, hasMore: hasMore,
                context: candidateContext, protected: protectedImmersiveIDs)
        }
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel()
        generation = UUID(); feedRevision = generation; isLoading = false
        fullScreenPlaybackID = nil; activeTab = tab
        guard tab < 2 else { return }
        feedMediaOnly = tab == 1
        if let saved = savedFeeds[tab], saved.provider == selectedProvider {
            commitSearch(query: saved.query, sort: saved.sort)
            let blocked = Set((exclusions + QueryParser.parse(saved.query).excluded + tasteChoice(for: selectedProvider).notInto).map { $0.lowercased() })
            posts = saved.posts.filter { !RecommendationTagRules.rejects($0, exclusions: Array(blocked)) }; encountered = saved.encountered; nextPage = saved.nextPage
            publishedNextPage = nextPage; publishedQuery = saved.publishedQuery; publishedSort = saved.publishedSort
            hasMore = saved.hasMore; candidateContext = saved.context
            protectedImmersiveIDs = saved.protected; lastError = nil
            if (posts.isEmpty && nextPage <= 1) || publishedQuery != queryText || publishedSort != feedSort { await refresh(immersive: tab == 1) }
            return
        }
        commitSearch(query: "", sort: "recommended")
        posts = []; encountered = []; nextPage = 1; candidateContext = nil; protectedImmersiveIDs = []
        await refresh(immersive: tab == 1)
    }
    private func performRefresh(immersive: Bool, trainSearch: Bool) async {
        guard !Task.isCancelled else { return }
        let mediaOnly = immersive || activeTab == 1
        feedMediaOnly = mediaOnly
        protectedImmersiveIDs = []; immersivePlaybackID = nil
        generation = UUID(); feedRevision = generation; inlinePlaybackID = nil; players.pauseAll()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { posts = (try? await UITestMediaFactory.shared.posts(sort: feedSort)) ?? []; hasMore = false; return }
        #endif
        plannedAcquisition = nil
        let feedStarted = Date()
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
                let search = SearchFilters.split(queryText).tags
                Task(priority: .utility) { await recordSearch(provider: provider, query: search) }
            }
            let personalized = requestedSort == "recommended" && parsed.included.isEmpty
            let banned = Set((exclusions + parsed.excluded + tasteChoice(for: provider).notInto).map(RecommendationTagRules.canonical))
            let context = provider.rawValue + "|batch40|" + (mediaOnly ? "clips" : "all") + "|" + banned.sorted().joined(separator: ",")
            candidateContext = personalized ? context : nil
            var requestedPage = 1
            guard generation == token, !Task.isCancelled else { return }
            encountered = []
            var filtered: [Post] = []
            // Skip consumed/filtered pages; never reinsert them just to fill a batch.
            var broaden = false
            for _ in 0..<5 {
                guard generation == token, !Task.isCancelled else { return }
                let response = try await fetchCandidates(provider: provider, parsed: parsed, context: personalized ? context : nil, page: requestedPage, sort: requestedSort, mediaOnly: mediaOnly, forceBroad: broaden)
                let acquisition = response.request
                let page = response.page
                requestedPage = acquisition?.page ?? requestedPage
                guard generation == token, !Task.isCancelled else { return }
                requestedPage += 1
                nextPage = requestedPage; hasMore = (page.hasMore ?? !page.items.isEmpty) || acquisition?.focused == true
                var incoming = page.items.filter { post in
                    encountered.insert(post.stableID).inserted && (!mediaOnly || post.isImmersiveMedia)
                        && !RecommendationTagRules.rejects(post, exclusions: Array(banned))
                }
                if personalized { incoming = await recommendations.unseenRecommendations(incoming) }
                incoming = feedExclusions.filter(incoming, favorites: Array(favorites.values), recommended: personalized, favoriteIDs: favoriteExclusionIDs)
                if personalized {
                    // Metadata and cached appearance vectors only: no model
                    // loading, network requests or pixel decoding on first paint.
                    let cachedAppearance = await visual.scores(incoming)
                    filtered = await recommendations.rankFast(incoming, taste: tasteChoice(for: provider),
                        recent: [], visualScores: cachedAppearance)
                } else { filtered = incoming }
                if filtered.isEmpty, let acquisition, acquisition.focused {
                    broaden = true
                    if page.hasMore == false { Task { await recommendations.markCandidateDrained(context: acquisition.context) } }
                }
                if !filtered.isEmpty || !hasMore { break }
            }
            let immediate = filtered
            guard generation == token, !Task.isCancelled else { return }
            posts = immediate
            if personalized {
                await recommendations.recordOffered(immediate)
                scheduleRecommendationPersistence()
            }
            publishedNextPage = nextPage; publishedQuery = requestedQuery; publishedSort = requestedSort
            FeedPerformance.emit("first_posts", started: feedStarted, count: immediate.count)
            isLoading = false
            releasedLoading = true
            recommendationMode = "On-device recommendations"
            scheduleIdleIntelligence()
            if generation == token, !restoreFailed { lastError = nil }
        } catch {
            if generation == token, !Task.isCancelled { recordFeedError(error, provider: provider) }
        }
    }

    func loadMore(immersive: Bool = false) async {
        if let deadline = feedRetryAfter, deadline > .now { return }
        // The initial page belongs to bootstrap/refresh. Lazy footer appearance
        // must not race credential restoration or start a second page-one request.
        guard nextPage > 1, !isLoading, hasMore, publishedQuery == queryText, publishedSort == feedSort else { return }
        idleTask?.cancel()
        // Reserve loading synchronously, so multiple lazy-cell callbacks share one page request.
        isLoading = true
        let flight = Task { await performLoadMore(immersive: immersive) }; pageFlight = flight
        await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
    }
    private func performLoadMore(immersive: Bool) async {
        let token = generation
        let pageStarted = Date()
        defer { if token == generation { isLoading = false } }
        guard !Task.isCancelled, hasMore else { return }
        let provider = selectedProvider
        do {
            let parsed = QueryParser.parse(queryText)
            lastError = nil
            // Skip sparse, duplicate and fully filtered pages without waiting for
            // a last-card onAppear that will never fire again.
            var broaden = false
            for attempt in 0..<5 {
            guard generation == token, !Task.isCancelled else { return }
            let response = try await fetchCandidates(provider: provider, parsed: parsed, context: candidateContext, page: nextPage, sort: feedSort, mediaOnly: feedMediaOnly, forceBroad: broaden)
            let acquisition = response.request
            let requestedPage = acquisition?.page ?? nextPage
            let page = response.page
            guard generation == token, !Task.isCancelled else { return }
            nextPage = requestedPage + 1; hasMore = (page.hasMore ?? !page.items.isEmpty) || acquisition?.focused == true
            let banned = Set((exclusions + parsed.excluded + tasteChoice(for: provider).notInto).map(RecommendationTagRules.canonical))
            var candidates = page.items.filter {
                encountered.insert($0.stableID).inserted && (!feedMediaOnly || $0.isImmersiveMedia)
                    && !RecommendationTagRules.rejects($0, exclusions: Array(banned))
            }
            if candidateContext != nil { candidates = await recommendations.unseenRecommendations(candidates) }
            candidates = feedExclusions.filter(candidates, favorites: Array(favorites.values), existing: posts,
                recommended: candidateContext != nil, favoriteIDs: favoriteExclusionIDs)
            let ranked: [Post]
            if candidateContext != nil {
                let cachedAppearance = await visual.scores(candidates)
                ranked = await recommendations.rankFast(candidates, taste: tasteChoice(for: provider),
                    recent: Array(posts.suffix(10)), visualScores: cachedAppearance)
            } else { ranked = candidates }
            guard generation == token, !Task.isCancelled else { return }
            if ranked.isEmpty, let acquisition, acquisition.focused {
                broaden = true
                if page.hasMore == false { Task { await recommendations.markCandidateDrained(context: acquisition.context) } }
                guard generation == token, !Task.isCancelled else { return }
            }
            posts.append(contentsOf: ranked)
            if candidateContext != nil {
                await recommendations.recordOffered(ranked)
                scheduleRecommendationPersistence()
            }
            publishedNextPage = nextPage
            FeedPerformance.emit("pagination", started: pageStarted, count: ranked.count)
            scheduleIdleIntelligence()
            if !hasMore || (!(immersive || feedMediaOnly) && !ranked.isEmpty) || ((immersive || feedMediaOnly) && ranked.contains(where: \.isImmersiveMedia)) { break }
            if attempt == 4 { lastError = "No new posts in the last five pages. Tap Load more to continue." }
            }
            guard generation == token, !Task.isCancelled else { return }
        } catch { if token == generation, !Task.isCancelled { recordFeedError(error, provider: provider) } }
    }

    private func fetchCandidates(provider: Provider, parsed: ParsedQuery, context: String?, page: Int, sort: String, mediaOnly: Bool, forceBroad: Bool = false) async throws -> (page: PostPage, request: RecommendationEngine.CandidateRequest?) {
        var acquisition = context == nil || forceBroad ? nil : plannedAcquisition
        plannedAcquisition = nil
        // Source-of-candidates needs interests immediately, not only after idle.
        if let context, acquisition == nil, !forceBroad {
            acquisition = await recommendations.candidateRequest(context: context, provider: provider,
                taste: tasteChoice(for: provider), excluded: exclusions + parsed.excluded)
        }
        if let context {
            let key = acquisition?.context ?? context + "|query:"
            acquisition = RecommendationEngine.CandidateRequest(context: key, query: acquisition?.query ?? parsed,
                page: candidateCursors[key] ?? acquisition?.page ?? page, focused: acquisition?.focused ?? false)
        }
        let requestGeneration = generation
        var query = acquisition?.query ?? parsed
        query.excluded = RecommendationTagRules.queryExclusions(query.excluded + exclusions + tasteChoice(for: provider).notInto)
        do {
            let result = try await api.posts(provider: provider, query: query, page: acquisition?.page ?? page, sort: sort, immersive: mediaOnly)
            try Task.checkCancellation()
            if generation == requestGeneration, let acquisition {
                // Exhausted queries must not silently rewind to page one.
                let next = acquisition.page + 1
                candidateCursors[acquisition.context] = next
                Task { await recommendations.advanceCandidatePage(context: acquisition.context, nextPage: next) }
            }
            return (result, acquisition)
        } catch {
            // A failed interest search must not remove a provider's working
            // public browse feed. Explicit user searches never broaden silently.
            if let failure = error as? APIError, case .providerStatus(_, let status) = failure, (400..<500).contains(status) { throw error }
            guard (error as? APIError)?.retryAfter == nil, let context, acquisition?.focused == true, !Task.isCancelled else { throw error }
            let key = context + "|query:"
            let broad = RecommendationEngine.CandidateRequest(context: key, query: ParsedQuery(included: [], excluded: query.excluded), page: candidateCursors[key] ?? page, focused: false)
            let result = try await api.posts(provider: provider, query: broad.query, page: broad.page, sort: sort, immersive: mediaOnly)
            try Task.checkCancellation()
            if generation == requestGeneration {
                let next = broad.page + 1
                candidateCursors[key] = next
                Task { await recommendations.advanceCandidatePage(context: key, nextPage: next) }
            }
            return (result, broad)
        }
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
        Task(priority: .utility) { await record(event, post: post) }
        local.snapshot.favoriteMeta[post.stableID] = FavoriteMeta(liked: favorites[post.stableID] != nil, updatedAt: timestamp())
        persistLocal(); queueSync()
    }

    func less(_ post: Post) {
        // Immediate removal and feedback: no pixel inference on the feed path.
        feedExclusions.viewed(post)
        posts.removeAll { $0.stableID == post.stableID }
        Task(priority: .utility) { await record(.less, post: post) }
    }

    func download(_ post: Post) {
        downloads.download(post)
    }

    func recordImpression(_ post: Post) {
        if activeTab == 1 { protectedImmersiveIDs.insert(post.stableID) }
        guard !feedExclusions.hasViewed(post.stableID) else { return }
        feedExclusions.viewed(post)
        Task(priority: .utility) { await record(.impression, post: post) }
    }

    func notePreviewFingerprint(_ post: Post, hash: UInt64?) {
        if let hash { feedExclusions.registerFingerprint(post.stableID, hash: hash) }
    }
    func recordQuickSkip(_ post: Post) {
        guard feedSort == "recommended", favorites[post.stableID] == nil else { return }
        let key = post.stableID
        guard pendingSkipIntents.insert(key).inserted else { return }
        plannedAcquisition = nil
        Task(priority: .utility) { [weak self] in
            guard let self, pendingSkipIntents.contains(key) else { return }
            await recommendations.recordReversibleSkip(post)
            // Returning during an actor hop must win even if the skip task
            // happened to execute after the neutralization task.
            if !pendingSkipIntents.contains(key) {
                _ = await recommendations.neutralizeReversibleSkip(key)
            }
            scheduleRecommendationPersistence()
        }
    }
    func neutralizeQuickSkip(_ post: Post) {
        let key = post.stableID
        pendingSkipIntents.remove(key)
        plannedAcquisition = nil
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            if await recommendations.neutralizeReversibleSkip(key) {
                scheduleRecommendationPersistence()
            }
        }
    }
    private func scheduleRecommendationPersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            await self?.persistRecommendations()
        }
    }
    func recordReplay(_ post: Post) { Task { await record(.replay, post: post) } }
    func recordComplete(_ post: Post) { Task { await record(.complete, post: post) } }
    func recordWatch(_ post: Post, seconds: Double, completion: Double) { Task { await record(.watched(seconds: seconds, completion: completion), post: post) } }

    private var protectedHomePostIDs: Set<String> = []
    func protectVisibleHomePosts(_ keys: Set<String>) {
        guard activeTab == 0 else { return }
        protectedHomePostIDs = keys
    }

    private var tailRankTask: Task<Void, Never>?
    private var immersivePlaybackID: String?
    private var protectedImmersiveIDs: Set<String> = []
    func protectImmersivePost(_ key: String?) {
        guard activeTab == 1 else { return }
        guard immersivePlaybackID != key else { return }
        immersivePlaybackID = key
        if let key { protectedImmersiveIDs.insert(key) }
        let token = generation
        tailRankTask?.cancel()
        // Do not sort and republish the full tail on every paging frame.
        // Wait for the active page to settle, then rerank only unseen content.
        tailRankTask = Task(priority: .utility) {
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard !Task.isCancelled else { return }
            await adaptRecommendationTail(token: token)
        }
    }
    func adaptRecommendationTail(token: UUID) async {
        let tab = activeTab
        guard tab == 0 || tab == 1, feedSort == "recommended",
              Date().timeIntervalSince(lastFeedMotion) >= 0.45,
              let active = tab == 1 ? immersivePlaybackID : inlinePlaybackID else { return }
        let source = posts
        guard let activeIndex = source.firstIndex(where: { $0.stableID == active }) else { return }
        let protected = (tab == 1 ? protectedImmersiveIDs : protectedHomePostIDs).union([active])
        let prefixCount = max(activeIndex, source.lastIndex(where: { protected.contains($0.stableID) }) ?? activeIndex) + 1
        let prefix = Array(source.prefix(prefixCount))
        let tail = feedExclusions.filter(Array(source.dropFirst(prefixCount)), favorites: Array(favorites.values), existing: prefix, recommended: candidateContext != nil, favoriteIDs: favoriteExclusionIDs)
        let ranked = await recommendations.rank(tail, taste: tasteChoice(for: selectedProvider), recent: prefix, visualScores: visualScores)
        let stillProtected = tab == 1 ? protectedImmersiveIDs : protectedHomePostIDs
        guard !Task.isCancelled, generation == token, activeTab == tab, feedSort == "recommended",
              posts.map(\.stableID) == source.map(\.stableID),
              (tab == 1 ? immersivePlaybackID : inlinePlaybackID) == active,
              stillProtected.isSubset(of: Set(prefix.map(\.stableID))) else { return }
        if ranked.map(\.stableID) != Array(source.dropFirst(prefixCount)).map(\.stableID) { posts = prefix + ranked }
    }

    func resetRecommendations() async {
        cancelManualVisualRefresh()
        stopActiveLearning()
        idleTask?.cancel(); feedExclusions.restore([]); visualScores = [:]; candidateCursors = [:]
        await visual.reset()
        await recommendations.reset()
        await persistRecommendations()
        resetStatus = "Learned history cleared on this device."
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

    func exportRecommendationProfile() async throws -> RecommendationTransfer {
        try RecommendationTransfer(preferences: tasteSetup, exclusions: exclusions,
            state: await recommendations.snapshot(), semanticProfiles: await recommendations.semantic.transferableProfiles()).validated()
    }

    func previewRecommendationImport(_ url: URL) async {
        do { pendingProfileImport = try await RecommendationTransferReader().read(url) }
        catch { profileTransferError = "Could not open recommendation profile: \(error.localizedDescription)" }
    }

    func importRecommendationProfile(_ document: RecommendationTransfer) async {
        do {
            guard bootstrapped else { throw APIError.server("Wait for the current profile to finish loading, then try again.") }
            let valid = try document.validated()
            invalidateFeed()
            var state = RecommendationState(); state.profiles = valid.profiles
            await recommendations.load(state)
            await recommendations.semantic.replaceProfiles(valid.semanticProfiles)
            tasteSetup = valid.preferences; exclusions = valid.exclusions
            local.snapshot.preferences.updatedAt = timestamp(); local.snapshot.exclusions.updatedAt = timestamp()
            persistLocal(); await persistRecommendations()
            pendingProfileImport = nil
            // Local transfer does not enable website Sync or upload a profile.
            await refresh(immersive: activeTab == 1)
        } catch { profileTransferError = error.localizedDescription }
    }

    private func record(_ event: RecommendationEvent, post: Post) async {
        let envelope = FeedbackEnvelope(post: post, event: event)
        plannedAcquisition = nil
        await visual.stage(envelope, queueAnalysis: visualAnalysisEnabled)
        await applyFeedback(envelope)
        // A queued acquisition must not keep using the previous preference state.
        plannedAcquisition = nil
        persistenceTask?.cancel()
        persistenceTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.persistRecommendations()
        }
        scheduleIdleIntelligence()
    }
    private func recordSearch(provider: Provider, query: String) async {
        guard !query.isEmpty else { return }
        let post = Post(key: "search", id: "search", provider: provider.rawValue, tags: QueryParser.parse(query).included)
        let envelope = FeedbackEnvelope(post: post, event: .download, query: query)
        await visual.stage(envelope, queueAnalysis: false)
        await applyFeedback(envelope); plannedAcquisition = nil; startActiveLearning()
    }
    private func applyFeedback(_ envelope: FeedbackEnvelope) async {
        if let query = envelope.query, let provider = envelope.post.providerKey {
            await recommendations.recordSearch(provider: provider, query: query, eventID: envelope.id)
        } else { await recommendations.record(envelope.event, post: envelope.post, eventID: envelope.id) }
        if await recommendationPersistence.save(await recommendationState()) { await visual.acknowledge(envelope.id) }
    }
    private func stopActiveLearning() {
        activeLearningID = UUID(); activeLearningTask?.cancel(); activeLearningTask = nil
    }
    private func startActiveLearning() {
        guard bootstrapped, activeLearningTask == nil, isForeground, !isManualVisualScanRunning, semanticPreparationID == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") && !ProcessInfo.processInfo.arguments.contains("--ui-testing-active-learning") { return }
        #endif
        let id = UUID(); activeLearningID = id
        activeLearningTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer { if activeLearningID == id { activeLearningTask = nil } }
            await recommendations.configureTaxonomy(await visual.metadataTaxonomy())
            // Replaying a saved event is idempotent even if termination happened
            // between saving the engine ledger and acknowledging its outbox.
            for envelope in await visual.pendingFeedback() {
                guard !Task.isCancelled else { return }; await applyFeedback(envelope)
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            while !Task.isCancelled, isForeground, activeLearningID == id {
                let battery = UIDevice.current.batteryLevel
                let allowed = visualAnalysisEnabled && !isManualVisualScanRunning && !isLoading && memoryCooldown <= .now
                    // Even cached decoding competes with AVKit and gesture
                    // rendering. Resume taste work only after scrolling rests.
                    && Date().timeIntervalSince(lastFeedMotion) >= 1.5
                    && (battery < 0 || battery >= 0.15) && !ProcessInfo.processInfo.isLowPowerModeEnabled
                    && ProcessInfo.processInfo.thermalState.rawValue < 2
                if allowed {
                    let heavy = players.activeKey == nil && inlinePlaybackID == nil && activeTab != 1
                        && fullScreenPlaybackID == nil && Date().timeIntervalSince(lastFeedMotion) >= 1.5
                    let token = generation
                    if await visual.processNext(heavy: heavy), !Task.isCancelled {
                        let scores = await visual.scores(Array(posts.prefix(128)))
                        let fingerprints = await visual.fingerprints()
                        guard !Task.isCancelled else { return }
                        if token == generation { visualScores = scores; feedExclusions.setFingerprints(fingerprints) }
                        // Existing visibility/scroll guards protect every displayed card.
                        await adaptRecommendationTail(token: token)
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func noteFeedMotion() {
        // Never tear down/restart model tasks on every scrolling frame.
        // Ongoing workers check lastFeedMotion and defer expensive inference.
        lastFeedMotion = .now
        idleTask?.cancel()
        if visualScanStatus != nil, visualScanStatus != "Visual update paused while scrolling" { visualScanStatus = "Visual update paused while scrolling" }
        guard motionTask == nil else { return }
        motionTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                if Date().timeIntervalSince(lastFeedMotion) >= 1.5 {
                    motionTask = nil
                    scheduleIdleIntelligence()
                    return
                }
            }
        }
    }
    private var semanticPreparationID: UUID?
    private func scheduleIdleIntelligence() {
        startActiveLearning()
        idleTask?.cancel()
        guard !isManualVisualScanRunning else { return }
        idleTask = Task(priority: .background) { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }
            let token = generation
            defer { if generation == token, !Task.isCancelled { visualScanStatus = nil } }
            guard Date().timeIntervalSince(lastFeedMotion) >= 1.5 else { return }
            if let context = candidateContext {
                let request = await recommendations.candidateRequest(context: context, provider: selectedProvider,
                    taste: tasteChoice(for: selectedProvider), excluded: exclusions + QueryParser.parse(queryText).excluded)
                guard !Task.isCancelled, generation == token else { return }
                plannedAcquisition = request
                visualDiscoveryRound += 1
                let queries = await visual.discoveryQueries(provider: selectedProvider)
                if visualDiscoveryRound % 3 == 1, !queries.isEmpty {
                    let terms = queries[(visualDiscoveryRound / 3) % queries.count]
                    let key = context + "|query:" + terms.joined(separator: " ")
                    plannedAcquisition = RecommendationEngine.CandidateRequest(context: key,
                        query: ParsedQuery(included: terms, excluded: request.query.excluded), page: candidateCursors[key] ?? 1, focused: true)
                }
            }
            visualScores = await visual.scores(posts)
            guard !Task.isCancelled, generation == token else { return }
            await adaptRecommendationTail(token: token)
            await visual.reconcileFavorites(Array(favorites.values))
            // Queue a bounded batch and return rather than parking a worker
            // for minutes while the user scrolls, plays clips or uses Low Power
            // Mode. The background worker processes queued previews when safe.
            if visualAnalysisEnabled {
                let idle = VisualAnalysisService.resourcesAllowAnalysis(
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermal: ProcessInfo.processInfo.thermalState.rawValue,
                    playback: players.activeKey != nil || inlinePlaybackID != nil
                        || activeTab == 1 || fullScreenPlaybackID != nil || !isForeground,
                    loading: isLoading)
                if idle {
                    for post in posts.prefix(4) {
                        guard !Task.isCancelled, generation == token else { return }
                        _ = await visual.enqueue(post, priority: 1)
                    }
                    let history = await visual.historicalQueue(Array(favorites.values))
                    var queued = 0
                    for post in history.prefix(24) {
                        guard !Task.isCancelled, generation == token else { return }
                        if !(await visual.enqueue(post, priority: 3)) { break }
                        queued += 1
                    }
                    if queued > 0 {
                        visualScanStatus = "Queued \(queued) favorites for visual analysis"
                    }
                } else {
                    visualScanStatus = "Visual analysis paused until the device is idle"
                }
            }
            guard !Task.isCancelled, generation == token else { return }
            feedExclusions.setFingerprints(await visual.fingerprints())
            visualScores = await visual.scores(posts)
            // Prepare future candidate acquisition in the background. The feed never waits for it.
            if plannedAcquisition == nil, let context = candidateContext {
                let provider = selectedProvider
                let request = await recommendations.candidateRequest(context: context, provider: provider,
                    taste: tasteChoice(for: provider), excluded: exclusions + QueryParser.parse(queryText).excluded)
                guard !Task.isCancelled, generation == token, !isLoading else { return }
                plannedAcquisition = request
            }
            guard players.activeKey == nil, isForeground, !isLoading else { return }
            let battery = UIDevice.current.batteryLevel
            guard battery < 0 || battery >= 0.15 else { return }
            let preparation = UUID(); semanticPreparationID = preparation
            stopActiveLearning()
            defer {
                if semanticPreparationID == preparation { semanticPreparationID = nil; startActiveLearning() }
            }
            await visual.waitForWorker()
            guard !Task.isCancelled, generation == token, !isManualVisualScanRunning else { return }
            await visual.releaseModels()
            await recommendations.prepareSemantic(Array(posts.prefix(8)), taste: tasteChoice(for: selectedProvider))
            await recommendations.releaseSemanticModel()
            guard !Task.isCancelled, generation == token else { return }
            await persistRecommendations()
            await adaptRecommendationTail(token: token)
        }
    }

    /// Explicit user action, independent of the automatic idle-learning toggle.
    /// Existing scans are reused; like ledgers are never reset or counted twice.
    func startManualVisualRefresh() {
        guard !isManualVisualScanRunning else { return }
        idleTask?.cancel(); stopActiveLearning()
        let id = UUID(); manualVisualID = id
        manualVisualProgress = VisualRefreshProgress(completed: 0, total: 0, status: "Checking for new posts…", running: true)
        players.pauseAll()
        manualVisualTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer { if manualVisualID == id { manualVisualTask = nil } }
            // Drain a cancelled text prediction before starting a visual pass.
            await recommendations.releaseSemanticModel()
            await visual.waitForWorker()
            let history = await visual.historicalQueue(Array(favorites.values))
            guard !Task.isCancelled, manualVisualID == id else { return }
            manualVisualProgress = VisualRefreshProgress(completed: 0, total: history.count, status: "Scanning new posts…", running: true)
            var checked = 0
            var lastProgress = Date.distantPast
            for post in history {
                guard !Task.isCancelled, manualVisualID == id else { return }
                while !VisualAnalysisService.resourcesAllowAnalysis(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermal: ProcessInfo.processInfo.thermalState.rawValue,
                    playback: players.activeKey != nil || !isForeground, loading: isLoading) {
                    let paused = VisualRefreshProgress(completed: checked, total: history.count,
                        status: "Paused for playback, loading or power conditions", running: true)
                    if manualVisualProgress != paused { manualVisualProgress = paused }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard !Task.isCancelled, manualVisualID == id else { return }
                }
                await visual.analyzeFavorite(post, useVision: true)
                guard !Task.isCancelled, manualVisualID == id else { return }
                checked += 1
                if Date().timeIntervalSince(lastProgress) >= 0.2 || checked == history.count {
                    manualVisualProgress = VisualRefreshProgress(completed: checked, total: history.count,
                        status: "Checking favorites Ãƒâ€šÃ‚· \(checked)/\(history.count)", running: true)
                    lastProgress = .now
                }
                await Task.yield()
            }
            guard !Task.isCancelled, manualVisualID == id else { return }
            let fingerprints = await visual.fingerprints()
            let scores = await visual.scores(posts)
            guard !Task.isCancelled, manualVisualID == id else { return }
            feedExclusions.setFingerprints(fingerprints); visualScores = scores
            await adaptRecommendationTail(token: feedRevision)
            guard !Task.isCancelled, manualVisualID == id else { return }
            let remaining = await visual.historicalQueue(Array(favorites.values))
            manualVisualProgress = VisualRefreshProgress(completed: checked, total: history.count,
                status: history.isEmpty ? "All favorite previews already analyzed" :
                    (remaining.isEmpty ? "Visual taste updated: \(checked) posts checked" :
                    "Checked \(checked) favorites; \(remaining.count) previews unavailable or pending retry"),
                running: false)
            visualScanStatus = nil
            scheduleIdleIntelligence()
        }
    }
    func cancelManualVisualRefresh() {
        guard isManualVisualScanRunning else { return }
        manualVisualID = UUID(); manualVisualTask?.cancel(); manualVisualTask = nil
        if var progress = manualVisualProgress {
            progress.running = false; progress.status = "Update stopped Ãƒâ€šÃ‚· \(progress.completed)/\(progress.total) checked"
            manualVisualProgress = progress
        }
    }

    func restoreRecommendationState(_ state: RecommendationState) async {
        await recommendations.load(state)
        feedExclusions.restore(state.profiles.values.flatMap(\.recentSeen))
        candidateCursors = state.candidatePages
    }
    func recommendationState() async -> RecommendationState {
        var state = await recommendations.snapshot()
        // Candidate round counters are owned by the ranking actor. Replacing
        // them with AppStore's query cursors previously reset the rotation on
        // every persistence cycle and repeatedly reacquired the same page.
        state.candidatePages.merge(candidateCursors) { _, latestCursor in latestCursor }
        return state
    }
    private func persistRecommendations() async {
        await recommendationPersistence.save(await recommendationState())
        let provider = selectedProvider; let token = generation
        let interests = await recommendations.positiveTerms(provider: provider, taste: tasteChoice(for: provider))
        if generation == token, selectedProvider == provider, learnedInterests != interests { learnedInterests = interests }
    }

    func setTaste(into: [String], notInto: [String]) {
        let negative = TasteChoice.normalized(notInto)
        let positive = TasteChoice.normalized(into).filter { !negative.contains($0) }
        tasteSetup.sources[selectedProvider.rawValue] = TasteChoice(done: true, into: positive, notInto: negative)
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
        guard cloudSyncEnabled else { throw APIError.server("Website Sync is off.") }
        if let flight = syncFlight { try await flight.value; return }
        guard !isSyncing else { throw APIError.server("Sync is already running. Please wait.") }
        let identity = syncID
        _ = try QuicktickSyncCrypto.parse(identity)
        isSyncing = true; syncFailed = false; syncStatus = "SyncingÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦"
        let flight = Task { @MainActor in
            let (remote, _) = try await self.sync.pull(syncID: identity)
            try Task.checkCancellation()
            guard self.cloudSyncEnabled, self.syncID == identity else { throw CancellationError() }
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
        local.cloudSyncEnabled = cloudSyncEnabled
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
        guard cloudSyncEnabled, !syncID.isEmpty else { return }
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
