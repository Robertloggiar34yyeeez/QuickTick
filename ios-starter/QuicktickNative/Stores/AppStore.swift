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
    @Published var activeTab = 0 { didSet { if oldValue != activeTab { fullScreenPlaybackID = nil; protectedHomePostIDs = []; inlinePlaybackID = nil; pausedPlaybackID = nil; players.pauseAll() } } }
    @Published var isForeground = true { didSet {
        guard oldValue != isForeground else { return }
        if !isForeground { players.suspendActivePlayback() }
        else {
            // A rapid inactive→active transition can coalesce SwiftUI task IDs
            // while the app is suspended. Resume the retained player directly,
            // only if its existing feed and visible-post owners still agree.
            let owner = [0: "home", 1: "immersive", 2: "favorites", 3: "downloads"][activeTab] ?? "home"
            let allowed = activeTab == 1 ? Set(posts.map(\.stableID)) : Set(inlinePlaybackID.map { [$0] } ?? [])
            players.resumeSuspendedPlayback(allowed: allowed, owner: owner, muted: muted, pausedKey: pausedPlaybackID)
        }
    } }
    @Published var pausedPlaybackID: String?
    @Published var fullScreenPlaybackID: String?
    @Published var inlinePlaybackID: String? { didSet { if oldValue != inlinePlaybackID {
        idleTask?.cancel(); pausedPlaybackID = nil; players.transitionVisiblePost()
        if inlinePlaybackID == nil { scheduleIdleIntelligence() }
    } } }
    @Published var queryText = "" { didSet { if oldValue != queryText { invalidateFeed() } } }
    @Published var feedSort = "recommended" { didSet { if oldValue != feedSort { invalidateFeed() } } }
    @Published private(set) var feedRevision = UUID()
    @Published var favorites: [String: Post] = [:]
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
    private var encountered: Set<String> = []
    private var generation = UUID()
    @Published var visualAnalysisEnabled = UserDefaults.standard.bool(forKey: "quicktick-visual-analysis-v1") {
        didSet { UserDefaults.standard.set(visualAnalysisEnabled, forKey: "quicktick-visual-analysis-v1"); scheduleIdleIntelligence() }
    }
    let visual = VisualAnalysisService()
    private var feedExclusions = FeedExclusions()
    private var visualScores: [String: Double] = [:]
    private var idleTask: Task<Void, Never>?
    private var plannedAcquisition: RecommendationEngine.CandidateRequest?
    private var candidateCursors: [String: Int] = [:]
    private var historyOffset = 0
    private var persistenceTask: Task<Void, Never>?
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
            await recommendations.load(local)
            feedExclusions.restore(local.profiles.values.flatMap(\.recentSeen))
            candidateCursors = local.candidatePages
        }
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
        await refresh()
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
        isSyncing = true; syncFailed = false; syncStatus = "Checking cloud profileÃ¢â‚¬Â¦"
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
            syncStatus = "Saving merged profileÃ¢â‚¬Â¦"
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
        semanticTask?.cancel(); idleTask?.cancel()
        players.retain(Set(players.activeKey.map { [$0] } ?? []))
        Task { await MediaImagePipeline.shared.clearDecoded(); await recommendations.releaseSemanticModel() }
    }

    private func invalidateFeed() {
        fullScreenPlaybackID = nil
        idleTask?.cancel(); plannedAcquisition = nil
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel(); semanticTask = nil
        generation = UUID(); feedRevision = generation; posts = []; encountered = []; nextPage = 1
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
                posts = feedExclusions.filter(posts, favorites: Array(favorites.values), recommended: true)
            }
            lastError = APIError.rateLimited(selectedProvider, deadline).localizedDescription; return
        }
        refreshFlight?.cancel(); pageFlight?.cancel(); semanticTask?.cancel(); idleTask?.cancel()
        let flight = Task { await performRefresh(immersive: immersive, trainSearch: trainSearch) }
        refreshFlight = flight
        await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
    }
    func selectFeedTab(_ tab: Int) async {
        guard (0...3).contains(tab) else { return }
        fullScreenPlaybackID = nil
        activeTab = tab
        guard tab < 2 else { return }
        feedSort = "recommended"
        queryText = ""
        await refresh(immersive: tab == 1)
    }
    private func performRefresh(immersive: Bool, trainSearch: Bool) async {
        guard !Task.isCancelled else { return }
        let mediaOnly = immersive || activeTab == 1
        feedMediaOnly = mediaOnly
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
                let search = queryText
                Task(priority: .utility) { await recommendations.recordSearch(provider: provider, query: search) }
            }
            let personalized = requestedSort == "recommended" && parsed.included.isEmpty
            let banned = Set((exclusions + parsed.excluded + (personalized ? tasteChoice(for: provider).notInto : [])).map { $0.lowercased() })
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
                        && banned.isDisjoint(with: Set(post.tags.map { $0.lowercased() }))
                }
                if personalized {
                    incoming = feedExclusions.filter(incoming, favorites: Array(favorites.values), recommended: true)
                }
                filtered = incoming
                if incoming.isEmpty, let acquisition, acquisition.focused {
                    broaden = true
                    if page.hasMore == false { Task { await recommendations.markCandidateDrained(context: acquisition.context) } }
                }
                if !filtered.isEmpty || !hasMore { break }
            }
            let immediate = filtered
            guard generation == token, !Task.isCancelled else { return }
            posts = immediate
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
        guard nextPage > 1, !isLoading, hasMore else { return }
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
            let banned = Set((exclusions + parsed.excluded + (candidateContext != nil ? tasteChoice(for: provider).notInto : [])).map { $0.lowercased() })
            var candidates = page.items.filter { encountered.insert($0.stableID).inserted && (!feedMediaOnly || $0.isImmersiveMedia) && banned.isDisjoint(with: Set($0.tags.map { $0.lowercased() })) }
            candidates = feedExclusions.filter(candidates, favorites: Array(favorites.values), existing: posts,
                recommended: candidateContext != nil)
            let ranked = candidates
            guard generation == token, !Task.isCancelled else { return }
            if ranked.isEmpty, let acquisition, acquisition.focused {
                broaden = true
                if page.hasMore == false { Task { await recommendations.markCandidateDrained(context: acquisition.context) } }
                guard generation == token, !Task.isCancelled else { return }
            }
            posts.append(contentsOf: ranked)
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
        if let context {
            let key = acquisition?.context ?? context + "|query:"
            acquisition = RecommendationEngine.CandidateRequest(context: key, query: acquisition?.query ?? parsed,
                page: candidateCursors[key] ?? acquisition?.page ?? page, focused: acquisition?.focused ?? false)
        }
        let requestGeneration = generation
        do {
            let result = try await api.posts(provider: provider, query: acquisition?.query ?? parsed, page: acquisition?.page ?? page, sort: sort, immersive: mediaOnly)
            try Task.checkCancellation()
            if generation == requestGeneration, let acquisition {
                let next = (result.hasMore ?? !result.items.isEmpty) ? acquisition.page + 1 : 1
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
            let broad = RecommendationEngine.CandidateRequest(context: key, query: ParsedQuery(included: [], excluded: acquisition?.query.excluded ?? (exclusions + parsed.excluded)), page: candidateCursors[key] ?? page, focused: false)
            let result = try await api.posts(provider: provider, query: broad.query, page: broad.page, sort: sort, immersive: mediaOnly)
            try Task.checkCancellation()
            if generation == requestGeneration {
                let next = (result.hasMore ?? !result.items.isEmpty) ? broad.page + 1 : 1
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
        Task { await record(event, post: post) }
        local.snapshot.favoriteMeta[post.stableID] = FavoriteMeta(liked: favorites[post.stableID] != nil, updatedAt: timestamp())
        persistLocal(); queueSync()
    }

    func less(_ post: Post) { posts.removeAll { $0.stableID == post.stableID }; Task { await record(.less, post: post) } }

    func download(_ post: Post) {
        downloads.download(post)
    }

    func recordImpression(_ post: Post) {
        guard !feedExclusions.recent.contains(post.stableID) else { return }
        feedExclusions.viewed(post)
        Task(priority: .utility) { await record(.impression, post: post) }
    }
    func recordQuickSkip(_ post: Post) { Task { await record(.quickSkip, post: post) } }
    func recordReplay(_ post: Post) { Task { await record(.replay, post: post) } }
    func recordComplete(_ post: Post) { Task { await record(.complete, post: post) } }
    func recordWatch(_ post: Post, seconds: Double, completion: Double) { Task { await record(.watched(seconds: seconds, completion: completion), post: post) } }

    private var protectedHomePostIDs: Set<String> = []
    func protectVisibleHomePosts(_ keys: Set<String>) {
        guard activeTab == 0 else { return }
        protectedHomePostIDs = keys
    }

    func adaptRecommendationTail(token: UUID) async {
        // A tab transition briefly has no active Home post. Ranking that whole
        // array would move the saved scroll anchor before playback reactivates.
        guard activeTab == 0, inlinePlaybackID != nil || !protectedHomePostIDs.isEmpty else { return }
        let active = inlinePlaybackID
        let source = posts
        let activeIndex = source.firstIndex(where: { $0.stableID == active }) ?? 0
        // Several cards can be visible, particularly on iPad. Moving a still
        // below the active video can expose another clip and steal playback.
        // Geometry remains owned by Home; this set only protects ranking.
        let protected = protectedHomePostIDs.union(active.map { [$0] } ?? [])
        let prefixCount = max(activeIndex, source.lastIndex(where: { protected.contains($0.stableID) }) ?? activeIndex) + 1
        let tail = Array(source.dropFirst(prefixCount))
        let ranked = await recommendations.rank(tail, taste: tasteChoice(for: selectedProvider), recent: Array(source.prefix(prefixCount)), visualScores: visualScores)
        guard generation == token, activeTab == 0, feedSort == "recommended", posts.map(\.stableID) == source.map(\.stableID), inlinePlaybackID == active,
              protectedHomePostIDs.isSubset(of: Set(source.prefix(prefixCount).map(\.stableID))) else { return }
        posts = Array(source.prefix(prefixCount)) + ranked
    }

    func resetRecommendations() async {
        idleTask?.cancel(); feedExclusions.restore([]); visualScores = [:]; candidateCursors = [:]; historyOffset = 0
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
        await visual.record(event, post: post)
        await recommendations.record(event, post: post)
        persistenceTask?.cancel()
        persistenceTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.persistRecommendations()
        }
        scheduleIdleIntelligence()
    }

    private func scheduleIdleIntelligence() {
        idleTask?.cancel()
        idleTask = Task(priority: .background) { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }
            let token = generation
            if let context = candidateContext {
                let request = await recommendations.candidateRequest(context: context, provider: selectedProvider,
                    taste: tasteChoice(for: selectedProvider), excluded: exclusions + QueryParser.parse(queryText).excluded)
                guard !Task.isCancelled, generation == token else { return }
                plannedAcquisition = request
            }
            visualScores = await visual.scores(posts)
            guard !Task.isCancelled, generation == token else { return }
            await adaptRecommendationTail(token: token)
            let history = Array(favorites.values).sorted { $0.stableID < $1.stableID }
            var offset = historyOffset < history.count ? historyOffset : 0
            repeat {
                guard !Task.isCancelled, generation == token else { return }
                let idle = VisualAnalysisService.resourcesAllowAnalysis(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermal: ProcessInfo.processInfo.thermalState.rawValue,
                    playback: players.activeKey != nil || fullScreenPlaybackID != nil || !isForeground, loading: isLoading)
                if idle {
                    for post in history.dropFirst(offset).prefix(4) {
                        guard !Task.isCancelled, players.activeKey == nil, !isLoading else { break }
                        await visual.analyzeFavorite(post, useVision: visualAnalysisEnabled)
                        offset += 1
                        historyOffset = offset
                    }
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            } while offset < history.count
            guard !Task.isCancelled, generation == token else { return }
            feedExclusions.setFingerprints(await visual.fingerprints())
            visualScores = await visual.scores(posts)
            // Prepare future candidate acquisition in the background. The feed never waits for it.
            if let context = candidateContext {
                let provider = selectedProvider
                let request = await recommendations.candidateRequest(context: context, provider: provider,
                    taste: tasteChoice(for: provider), excluded: exclusions + QueryParser.parse(queryText).excluded)
                guard !Task.isCancelled, generation == token, !isLoading else { return }
                plannedAcquisition = request
            }
            guard players.activeKey == nil, isForeground, !isLoading else { return }
            await recommendations.prepareSemantic(Array(posts.prefix(8)), taste: tasteChoice(for: selectedProvider))
            guard !Task.isCancelled, generation == token else { return }
            await persistRecommendations()
            await adaptRecommendationTail(token: token)
        }
    }

    private func persistRecommendations() async {
        await recommendationPersistence.save(await recommendations.snapshot())
        let provider = selectedProvider; let token = generation
        let interests = await recommendations.positiveTerms(provider: provider, taste: tasteChoice(for: provider))
        if generation == token, selectedProvider == provider { learnedInterests = interests }
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
        isSyncing = true; syncFailed = false; syncStatus = "SyncingÃ¢â‚¬Â¦"
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
