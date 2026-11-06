import SwiftUI

/// Pull refresh is a gesture that *begins* at the top, not one that happens
/// to end there. A long downward swipe from the middle can otherwise reload
/// the whole feed and throw the reader back to the first post.
struct HomePullRefreshGate {
    private var beganAtTop: Bool?

    mutating func observe(startOffset: CGFloat?) {
        // LazyVStack unmounts the header well below the fold. An absent
        // preference must NOT use a zero offset: zero means "at the top" and
        // accidentally turns an ordinary upward journey into a full refresh.
        if beganAtTop == nil { beganAtTop = startOffset.map { (-12...22).contains($0) } ?? false }
    }

    mutating func finish(translation: CGSize) -> Bool {
        defer { beganAtTop = nil }
        return beganAtTop == true && translation.height >= 105
            && abs(translation.width) < translation.height * 0.65
    }

    mutating func cancel() { beganAtTop = nil }
}

/// Geometric preferences arrive for nearly every scroll pixel. The last
/// observed rectangles are transient playback state, not UI state: publishing
/// them through @State invalidated the entire media feed on every frame.
private final class HomeVisibleFrameCache {
    var frames: [String: CGRect] = [:]
    // Drag/geometry samples are deliberately not @State. Updating @State for
    // every pixel of a UIScrollView drag invalidates the entire LazyVStack.
    var topOffset: CGFloat?
    var pullRefreshGate = HomePullRefreshGate()
    var lastMotionSample = Date.distantPast
    var lastIntelligencePause = Date.distantPast
    var lastAnchorPublished = Date.distantPast
    var lastVisibilityAnalysis = Date.distantPast
    var lastVisibleTop: String?
    var visibleTopSince = Date.distantPast
    var remountGraceUntil = Date.distantPast
    var scrollRestTask: Task<Void, Never>?
    var upwardDragActive = false
    var upwardDragSequence = 0
    var paginatedDragSequence = 0
}

enum HomePaginationPolicy {
    static func shouldLoad(upwardDragSequence: Int, consumedSequence: Int,
                           loading: Bool, hasMore: Bool) -> Bool {
        upwardDragSequence > consumedSequence && !loading && hasMore
    }
}

private struct HomeFullImagePresentation: Identifiable {
    let id: String
    let url: String
    let previewURL: String
}

/// A single full-bleed artwork treatment for every provider's topic tiles.
/// The label stays legible *inside* the chip instead of displacing the cover.
private struct HomeArtworkChip: View {
    let title: String
    let imageURL: String
    var selected = false
    var width: CGFloat = 182
    var height: CGFloat = 210
    var placeholder = "tag.fill"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !imageURL.isEmpty {
                CachedMediaImage(url: imageURL, pixels: 480, fill: true)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Rectangle().fill(AppTheme.gradient)
                    .overlay {
                        Image(systemName: placeholder)
                            .font(.system(size: 43, weight: .light))
                            .foregroundStyle(.white.opacity(0.55))
                    }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.87)],
                           startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .shadow(color: .black.opacity(0.75), radius: 4)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
            .strokeBorder(selected ? AppTheme.accent : .white.opacity(0.17), lineWidth: selected ? 2.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
    }
}

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showSettings: Bool
    @Binding var scrollAnchor: String?
    @AppStorage(VideoPlaybackPreferences.autoplayKey) private var autoplayVideos = true
    @AppStorage("quicktick-suggested-themes-v1") private var suggestedThemesEnabled = true
    @AppStorage(SuggestedThemeMode.storageKey) private var suggestedThemesMode = SuggestedThemeMode.balanced.rawValue
    @State private var showSearch = false
    @State private var showProviderWebsite = false
    @State private var immersive = false
    @State private var immersivePostID: String?
    @State private var visibleFrameCache = HomeVisibleFrameCache()
    // Video eligibility changes only when the feed changes, not on every
    // scroll/layout pass. Avoid rebuilding a Set from the whole feed per frame.
    @State private var playableIDs: Set<String> = []
    @State private var isScrollMoving = false
    @State private var pullRefreshInFlight = false
    @State private var visualThemeTerms: [String] = []
    @State private var themeSuggestions: [HomeThemeSuggestion] = []
    @State private var publicPopularFranchisePosts: [Post] = []
    @State private var redgifsNiches: [RedgifsNiche] = []
    @State private var pornhubCategoryPreviews: [String: String] = [:]
    @State private var openingNicheID: String?
    @State private var showAllRedgifsNiches = false
    @State private var showAllHanimeTopics = false
    @State private var presentedFullImage: HomeFullImagePresentation?
    @State private var themeRefreshCycle = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var postSignature: String {
        "\(store.feedRevision)|\(store.posts.count)|\(store.posts.first?.stableID ?? "")|\(store.posts.last?.stableID ?? "")"
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                feedScroll(viewport: viewport, proxy: proxy)
            }
        }
        .sheet(isPresented: $showProviderWebsite) {
            SourceWebsiteView(url: NativeProviderAPI.origin(store.selectedProvider)).ignoresSafeArea()
        }
        .fullScreenCover(item: $presentedFullImage) { selection in
            FullComicView(url: selection.url, previewURL: selection.previewURL)
        }
        .fullScreenCover(isPresented: $showAllRedgifsNiches) {
            RedgifsNicheBrowserView(featured: redgifsNiches, showSettings: $showSettings,
                                    onReturnToFYP: {
                showAllRedgifsNiches = false
                if !store.queryText.isEmpty || store.feedSort != "recommended" {
                    store.commitSearch(query: "", sort: "recommended")
                    Task { await store.refresh() }
                }
            })
            .environmentObject(store)
        }
        .sheet(isPresented: $showAllHanimeTopics) {
            NavigationStack { HanimeTopicsBrowserView() }
                .environmentObject(store)
        }
    }

    // Keep the root body small: the Home feed has independent scroll,
    // navigation, playback and gesture modifiers, and Swift 6 cannot reliably
    // type-check all of those inside one nested GeometryReader expression.
    private func feedScroll(viewport: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        let revision = store.feedRevision
        let cardInset = AppTheme.isDeSlopified ? AppTheme.contentMargin : 0
        let scrollContent = ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.feedSort == "recommended" ? "For you" : "Trending")
                            .font(.system(size: AppTheme.isDeSlopified ? 26 : 33,
                                          weight: AppTheme.isDeSlopified ? .semibold : .bold,
                                          design: AppTheme.isDeSlopified ? .default : .rounded))
                            .tracking(AppTheme.isDeSlopified ? -0.4 : -1.3)
                        Text(store.feedSort == "recommended" ? "Selected for your interests" : "Popular from your sources")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryLabel)
                            .accessibilityIdentifier("home-title")
                    }
                    Spacer()
                    Button { Task { await refreshFromGesture() } } label: {
                        Group {
                            if pullRefreshInFlight { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .semibold)) }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .disabled(pullRefreshInFlight)
                    .accessibilityLabel("Refresh feed")
                    .accessibilityIdentifier("home-refresh")
                    if !AppTheme.isDeSlopified {
                    Image(systemName: store.feedSort == "recommended" ? "sparkles" : "flame.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 17))
                        .rotationEffect(.degrees(-9))
                        .accessibilityHidden(true)
                    }
                }
                .id("home-top")
                .background(GeometryReader { origin in
                    Color.clear.preference(key: HomeTopOffsetPreference.self,
                                           value: origin.frame(in: .named("home-viewport")).minY)
                })
                .padding(.top, 14)
                .padding(.horizontal, 16)
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        ForEach([("Recommended", "recommended"), ("Popular", "popular")], id: \.1) { title, mode in
                            Button {
                                // Keep the selector mounted while the next
                                // feed is requested. Directly assigning
                                // feedSort cleared the whole LazyVStack in
                                // didSet and could swallow a quick second
                                // iPad tap (Popular -> Recommended).
                                store.commitSearch(query: store.queryText, sort: mode)
                                Task { await store.refresh() }
                            } label: {
                                Text(title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                                    .foregroundStyle(store.feedSort == mode ? .white : AppTheme.secondaryLabel)
                                    .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
                                    .background {
                                        if store.feedSort == mode {
                                            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                                                .fill(AppTheme.gradient)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("feed-\(mode)")
                            .accessibilityAddTraits(store.feedSort == mode ? .isSelected : [])
                        }
                    }
                    .padding(4)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("home-search-button")
                }
                .padding(.horizontal, 16)
                if !store.queryText.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.selectedTopicTerm == nil ? "Filtered feed" : "Topic selected")
                                .font(.caption.weight(.semibold))
                            Text(store.selectedTopicTerm?.replacingOccurrences(of: "_", with: " ") ?? store.queryText)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryLabel)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button {
                            // Topic cards rotate after refresh; this permanent
                            // exit stays available even if a topic vanishes.
                            store.commitSearch(query: "", sort: "recommended")
                            Task { await store.refresh() }
                        } label: {
                            Label("For you", systemImage: "arrow.uturn.backward")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 38)
                                .background(AppTheme.gradient, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-clear-topic")
                        .accessibilityLabel("Return to regular Recommended feed")
                    }
                    .padding(12)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.border))
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("home-active-filter")
                }
                if store.selectedProvider == .redgifs {
                    redgifsNicheRow
                } else if store.selectedProvider == .hanime ||
                            (suggestedThemesEnabled && !themeSuggestions.isEmpty) {
                    suggestedThemeRow
                }
                if store.selectedProvider == .pornhub {
                    homeCategoryRow
                }
                if store.posts.isEmpty && !store.bootstrapped {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(AppTheme.surface)
                        .frame(height: 220)
                        .overlay { ProgressView().tint(AppTheme.accent) }
                        .accessibilityIdentifier("feed-restoring")
                } else if let error = store.lastError, store.posts.isEmpty, store.bootstrapped, !store.isLoading {
                    ContentUnavailableView { Label("Could not load feed", systemImage: "wifi.exclamationmark") } description: { Text(error) } actions: {
                        Button("Try again") { Task { await store.refresh() } }
                        if [.nhentai, .kemono, .coomer, .erome, .hanime, .pornhub].contains(store.selectedProvider) {
                            Button("Browse inside QuickTick") { showProviderWebsite = true }
                        }
                        if store.selectedProvider == .hanime,
                           let website = URL(string: "https://hanime.tv/") {
                            Link("Verify Hanime in Safari", destination: website)
                            Button("Configure Hanime API") { showSettings = true }
                        }
                    }
                } else if store.posts.isEmpty && !store.isLoading && store.bootstrapped {
                    ContentUnavailableView("No posts yet", systemImage: "rectangle.stack", description: Text("Choose another source or adjust your search."))
                }
                ForEach(store.posts, id: \.stableID) { post in
                    PostCardView(post: post, available: CGSize(width: max(1, min(AppTheme.feedWidth, viewport.size.width) - cardInset * 2), height: viewport.size.height),
                                 onOpenFullImage: {
                        // Keep the cover alive even when a sort/refresh swaps
                        // out the post's LazyVStack card during presentation.
                        presentedFullImage = HomeFullImagePresentation(
                            id: post.stableID,
                            url: post.mediaUrl.isEmpty ? post.cardPreviewURL : post.mediaUrl,
                            previewURL: post.cardPreviewURL)
                    })
                        .padding(.horizontal, cardInset)
                        .frame(maxWidth: .infinity)
                        .id(post.stableID)
                        .onAppear { maybeLoadMoreAfterUserScroll(visibleID: post.stableID) }
                }
                if store.isLoading {
                    RoundedRectangle(cornerRadius: 22).fill(AppTheme.surface).frame(height: 220)
                        .overlay {
                            VStack(spacing: 7) {
                                InfinityLoader(size: 46)
                                Text("Loading posts").font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                            }
                        }
                        .accessibilityIdentifier("feed-loading")
                }
                if store.hasMore {
                    Button("Load more") { Task { await store.loadMore() } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 16)
                }
            }.frame(maxWidth: AppTheme.feedWidth).frame(maxWidth: .infinity).padding(.bottom, 18)
        }
        let restoredScroll = scrollContent
        // A regular feed must keep free scroll offsets through rotation and
        // keyboard changes. Restore its anchor only when this host mounts;
        // continuously binding a .top target fought scrollTo and focus changes.
        .task {
            if let scrollAnchor, store.posts.contains(where: { $0.stableID == scrollAnchor }) {
                proxy.scrollTo(scrollAnchor, anchor: .top)
            }
        }
        .onChange(of: store.feedRevision) { _, _ in
            visibleFrameCache.lastVisibleTop = nil
            visibleFrameCache.visibleTopSince = .distantPast
            proxy.scrollTo("home-top", anchor: .top)
        }
        let scrollControls = restoredScroll
        .overlay(alignment: .bottomLeading) {
            if !isScrollMoving {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("home-top", anchor: .top) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.27), lineWidth: 1))
                        .shadow(color: AppTheme.accent.opacity(0.28), radius: 14, y: 5)
                        .shadow(color: .black.opacity(0.34), radius: 9, y: 4)
                }
                .buttonStyle(.plain)
                .frame(width: 48, height: 48)
                .fixedSize()
                .contentShape(Rectangle())
                .padding(.leading, viewport.size.width > 700 ? 88 : 14)
                // The root dock is an overlay, not an ordinary tab bar.
                // Reserve its height plus the home-indicator inset so this
                // control remains hittable on every iPhone.
                .padding(.bottom, viewport.size.width > 600 ? 14 :
                         (store.audio.currentPost == nil ? 90 : 168) + max(34, viewport.safeAreaInsets.bottom))
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                .accessibilityLabel("Scroll to top")
                .accessibilityIdentifier("home-scroll-top")
            }
        }
        .coordinateSpace(name: "home-viewport")
        .onPreferenceChange(HomeTopOffsetPreference.self) { visibleFrameCache.topOffset = $0 }
        let gesturedScroll = scrollControls
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { touch in
            let gutter = (viewport.size.width - AppTheme.feedWidth) / 2
            guard gutter >= 48,
                  touch.location.x < gutter || touch.location.x > viewport.size.width - gutter else { return }
            likeVisiblePost(in: viewport.size)
        })
        // Track the offset on the FIRST drag event. Checking only onEnded
        // mistakes scrolling back up to the header for a refresh. Use one
        // gesture recognizer so native refresh cannot independently fire.
        .simultaneousGesture(DragGesture(minimumDistance: 18)
            .onChanged { drag in
                if drag.translation.height < -18,
                   abs(drag.translation.height) > abs(drag.translation.width) * 1.2,
                   !visibleFrameCache.upwardDragActive {
                    visibleFrameCache.upwardDragActive = true
                    visibleFrameCache.upwardDragSequence &+= 1
                }
                // Reconstruct the header position at gesture START, not after
                // a long swipe has already carried it into the visible area.
                visibleFrameCache.pullRefreshGate.observe(startOffset: visibleFrameCache.topOffset.map { $0 - drag.translation.height })
            }
            .onEnded { drag in
            visibleFrameCache.upwardDragActive = false
            guard visibleFrameCache.pullRefreshGate.finish(translation: drag.translation) else { return }
            Task { await refreshFromGesture() }
        })
        let trackedScroll = gesturedScroll
        .onPreferenceChange(HomeVisibleFrames.self) { frames in
            guard store.feedRevision == revision else { return }
            guard frames != visibleFrameCache.frames else { return }
            // Geometry changes reveal actual scrolling without attaching a
            // gesture that competes with normal vertical paging. Hide the
            // shortcut during motion; restore it after a quiet interval.
            let moved = frames.contains { id, rect in
                guard let previous = visibleFrameCache.frames[id] else { return false }
                return abs(previous.minY - rect.minY) > 2
            }
            if moved { noteScrollMotion() }
            visibleFrameCache.frames = frames
            // Preference updates are emitted almost once per display frame.
            // Playback selection, impression protection, and recommendation
            // bookkeeping are much more expensive than storing the geometry;
            // sample them at ~10 Hz while scrolling to keep rendering fluid.
            let sampleTime = Date()
            if moved && sampleTime.timeIntervalSince(visibleFrameCache.lastVisibilityAnalysis) < 0.10 { return }
            visibleFrameCache.lastVisibilityAnalysis = sampleTime
            let bounds = CGRect(origin: .zero, size: viewport.size)
            var visible = Set<String>()
            var top: String?
            var topY = CGFloat.infinity
            for (id, rect) in frames where rect.intersects(bounds) {
                visible.insert(id)
                if rect.minY < topY { top = id; topY = rect.minY }
            }
            // Scroll restoration does not need a 60 Hz update. In particular,
            // the RootView binding should not be dirtied on every new row of
            // a fast fling; it is only a coarse return-to-position bookmark.
            if let top, scrollAnchor != top, Date().timeIntervalSince(visibleFrameCache.lastAnchorPublished) >= 0.18 {
                visibleFrameCache.lastAnchorPublished = .now
                scrollAnchor = top
            }
            if let top, top != visibleFrameCache.lastVisibleTop {
                let now = Date()
                if !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented,
                   store.feedSort == "recommended", !store.isLoading,
                   let previousID = visibleFrameCache.lastVisibleTop,
                   let previousIndex = store.posts.firstIndex(where: { $0.stableID == previousID }),
                   let nextIndex = store.posts.firstIndex(where: { $0.stableID == top }) {
                    let dwell = now.timeIntervalSince(visibleFrameCache.visibleTopSince)
                    if QuickSkipDecision.dislikes(elapsed: dwell, from: previousIndex, to: nextIndex) {
                        store.recordQuickSkip(store.posts[previousIndex])
                    }
                    store.neutralizeQuickSkip(store.posts[nextIndex])
                }
                visibleFrameCache.lastVisibleTop = top
                visibleFrameCache.visibleTopSince = now
            }
            store.protectVisibleHomePosts(visible)
            selectVisiblePlayback(viewport: viewport.size)
        }
        let mountedScroll = trackedScroll
        .onAppear {
            playableIDs = Set(store.posts.filter(\.isImmersiveMedia).map(\.stableID))
            visibleFrameCache.remountGraceUntil = Date().addingTimeInterval(0.85)
            // Tab transitions clear the active player, but the Home feed's
            // previously visible post is still known before SwiftUI delivers
            // fresh geometry preferences. Restore it immediately so cards can
            // start preparing playback rather than waiting for a second scroll.
            if store.activeTab == 0, store.inlinePlaybackID == nil,
               let retained = store.retainedHomePlaybackID, playableIDs.contains(retained) {
                store.inlinePlaybackID = retained
            }
            // Switching back from Immersive remounts Home. Frame preferences
            // can arrive before the resumed feed is fully laid out, so retry
            // selection through the first few layout passes.
            Task { @MainActor in
                for delay in [120, 260, 420, 1_100] {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard store.activeTab == 0 else { return }
                    selectVisiblePlayback(viewport: viewport.size)
                }
            }
        }
        .onDisappear {
            visibleFrameCache.scrollRestTask?.cancel()
            visibleFrameCache.scrollRestTask = nil
            visibleFrameCache.pullRefreshGate.cancel()
            // Geometry from the outgoing tab is invalid on the next mount.
            visibleFrameCache.frames = [:]
        }
        let preparedScroll = mountedScroll
        .task(id: "\(visibleCandidate(viewport: viewport.size) ?? ""):\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.isStudioPresented):\(store.feedRevision):\(store.fullScreenPlaybackID ?? "")") {
            guard !Task.isCancelled, store.feedRevision == revision else { return }
            selectVisiblePlayback(viewport: viewport.size)
        }
        .task(id: "\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.isStudioPresented):\(store.feedRevision):\(autoplayVideos)") {
            guard !Task.isCancelled, store.activeTab == 0, store.isForeground, !store.isStudioPresented, store.feedRevision == revision else { return }
            await warmNext(after: store.inlinePlaybackID)
        }
        .task(id: "\(store.feedRevision):\(store.posts.first?.stableID ?? "")") {
            guard !Task.isCancelled, store.activeTab == 0, store.isForeground, !store.isStudioPresented else { return }
            // Start the first visible posters immediately, including when
            // autoplay is disabled. Match the 1024px card cache bucket so a
            // first scroll never redownloads what look-ahead already fetched.
            let firstScreen = Array(store.posts.prefix(3))
            await withTaskGroup(of: Void.self) { group in
                for post in firstScreen {
                    group.addTask(priority: .utility) {
                        for url in post.previewImageURLs {
                            guard !Task.isCancelled else { return }
                            if (try? await MediaImagePipeline.shared.image(raw: url, pixels: 1024)) != nil { return }
                        }
                    }
                }
            }
        }
        #if DEBUG
        let debugScroll = preparedScroll
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                Text("active=\(store.inlinePlaybackID ?? "nil") candidate=\(visibleCandidate(viewport: viewport.size) ?? "nil") paused=\(store.pausedPlaybackID ?? "nil") foreground=\(store.isForeground) frames=\(visibleFrameCache.frames.count) player=\(store.players.activeKey ?? "nil") owner=\(store.players.activeOwner ?? "nil")")
                    .font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("home-playback-debug")
            }
        }
        #else
        let debugScroll = preparedScroll
        #endif
        let navigableScroll = debugScroll
        .background(ThemeBackdrop())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("QuickTick")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .accessibilityIdentifier("quicktick-brand")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    Menu { ForEach(Provider.allCases) { p in Button(p.displayName) { store.selectedProvider = p; Task { await store.refresh() } } } } label: {
                        ProviderLogoView(provider: store.selectedProvider)
                            .frame(width: 52, height: 44)
                            .background(AppTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.15)))
                            .accessibilityLabel("Provider: \(store.selectedProvider.displayName)")
                    }
                    SettingsLauncher(isPresented: $showSettings)
                }
            }
        }

        // Refresh is deliberately owned by the top-origin drag above. Native
        // .refreshable also treats a swipe arriving at the top as a refresh.
        .navigationDestination(isPresented: $immersive) { ImmersiveFeedView(posts: store.posts, offline: false, activePostID: $immersivePostID, onClose: { immersive = false }, showSettings: $showSettings) }
        .onChange(of: immersive) { _, showing in if showing { store.inlinePlaybackID = nil } }
        .sheet(isPresented: $showSearch) { NativeSearchBar() }
        // Break the independent async discovery lanes into separate view
        // expressions. One enormous modifier chain exhausted Swift's type
        // checker during Release archive even though each task is valid.
        let franchiseScroll = navigableScroll
            .task(id: "franchise-discovery:\(store.selectedProvider.rawValue):\(suggestedThemesMode):\(suggestedThemesEnabled):\(store.bootstrapped)") {
                await discoverPopularFranchises()
            }
        let nicheScroll = franchiseScroll
            .task(id: "redgifs-niches:\(store.selectedProvider.rawValue):\(store.bootstrapped)") {
                await discoverRedgifsNiches()
            }
        let visualScroll = nicheScroll
            .task(id: store.selectedProvider) {
                await discoverVisualThemes()
            }
        let postChangeScroll = visualScroll
            .onChange(of: postSignature) { _, _ in
                playableIDs = Set(store.posts.filter(\.isImmersiveMedia).map(\.stableID))
                // Do not replace topic cards during a feed pagination.
                if themeSuggestions.isEmpty { refreshThemeSuggestions() }
            }
        let tasteChangeScroll = postChangeScroll
            .onChange(of: store.favorites.count) { _, _ in refreshThemeSuggestions() }
            .onChange(of: store.tasteChoice(for: store.selectedProvider)) { _, _ in refreshThemeSuggestions() }
            .onChange(of: store.exclusions) { _, _ in refreshThemeSuggestions() }
        let preferenceScroll = tasteChangeScroll
            .onChange(of: suggestedThemesEnabled) { _, _ in refreshThemeSuggestions() }
            .onChange(of: suggestedThemesMode) { _, _ in refreshThemeSuggestions() }
        let finalScroll = preferenceScroll
            .onChange(of: store.selectedProvider) { _, _ in
                visualThemeTerms = []
                publicPopularFranchisePosts = []
                redgifsNiches = []
                openingNicheID = nil
                themeSuggestions = []
                refreshThemeSuggestions()
            }
        return finalScroll
    }

    private func discoverPopularFranchises() async {
        guard store.bootstrapped, store.selectedProvider == .rule34,
              suggestedThemesEnabled, suggestedThemesMode != SuggestedThemeMode.tags.rawValue else {
            publicPopularFranchisePosts = []
            return
        }
        // This broad public popularity lane does not inherit liked tags.
        do { try await Task.sleep(for: .milliseconds(1_400)) } catch { return }
        guard !Task.isCancelled else { return }
        do {
            let page = try await store.api.posts(
                provider: .rule34, query: ParsedQuery(included: [], excluded: []),
                page: 1, sort: "popular")
            guard !Task.isCancelled, store.selectedProvider == .rule34 else { return }
            var discovered = page.items
            if let next = try? await store.api.posts(
                provider: .rule34, query: ParsedQuery(included: [], excluded: []),
                page: 2, sort: "popular"),
               !Task.isCancelled, store.selectedProvider == .rule34 {
                let seen = Set(page.items.map(\.stableID))
                discovered += next.items.filter { !seen.contains($0.stableID) }
            }
            guard !Task.isCancelled, store.selectedProvider == .rule34 else { return }
            publicPopularFranchisePosts = discovered
            refreshThemeSuggestions()
        } catch {
            // Discovery failure must not stall or replace the main feed.
        }
    }

    private func discoverRedgifsNiches() async {
        guard store.bootstrapped, store.selectedProvider == .redgifs else {
            redgifsNiches = []
            return
        }
        do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
        guard !Task.isCancelled else { return }
        do {
            let discovered = try await store.api.redgifsNiches(limit: 16)
            guard !Task.isCancelled, store.selectedProvider == .redgifs else { return }
            redgifsNiches = discovered
        } catch {
            redgifsNiches = []
        }
    }

    private func discoverVisualThemes() async {
        let provider = store.selectedProvider
        let discovered = await store.visual.discoveryTerms(provider: provider)
        guard !Task.isCancelled, store.selectedProvider == provider else { return }
        visualThemeTerms = discovered
        refreshThemeSuggestions()
    }

    private func refreshThemeSuggestions() {
        guard suggestedThemesEnabled else { themeSuggestions = []; return }
        let provider = store.selectedProvider
        let taste = store.tasteChoice(for: provider)
        let proposed = HomeThemeSuggestions.make(provider: provider,
            learned: store.learnedInterests, chosen: taste.into,
            visual: visualThemeTerms, favorites: Array(store.favorites.values),
            posts: store.posts, popular: publicPopularFranchisePosts,
            excluded: store.exclusions + taste.notInto,
            limit: 5, rotation: themeRefreshCycle,
            mode: SuggestedThemeMode(rawValue: suggestedThemesMode) ?? .balanced)
        if proposed != themeSuggestions { themeSuggestions = proposed }
    }

    /// Personal suggestions work on *every* provider and use real covers or
    /// thumbnails from posts matching this provider's learned interests.
    @ViewBuilder private var suggestedThemeRow: some View {
        if !themeSuggestions.isEmpty || store.selectedProvider == .hanime {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(AppTheme.accent)
                    Text(store.selectedProvider == .hanime ? "Hanime topics" : "Suggested topics")
                        .font(.subheadline.weight(.bold))
                    Text(store.selectedProvider == .rule34 && suggestedThemesMode == SuggestedThemeMode.franchises.rawValue
                         ? "Franchise discovery" : "Based on your taste")
                        .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    Spacer()
                    if store.selectedProvider == .hanime {
                        Button {
                            showAllHanimeTopics = true
                        } label: {
                            Label("See more", systemImage: "square.grid.2x2")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-hanime-see-more")
                    }
                }.padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(themeSuggestions) { theme in
                            let selected = QueryParser.parse(store.queryText).included.contains(theme.term)
                            Button {
                                let current = QueryParser.parse(store.queryText)
                                store.commitSuggestedTopic(selected ? nil : theme.term,
                                                           excluded: current.excluded)
                                Task { await store.refresh() }
                            } label: {
                                HomeArtworkChip(title: theme.label, imageURL: theme.imageURL,
                                                selected: selected)
                            }
                            .buttonStyle(QuicktickPressStyle())
                            .accessibilityLabel("Suggested theme: \(theme.label)")
                            .accessibilityIdentifier("suggested-theme-\(theme.term)")
                        }
                    }.padding(.horizontal, 16)
                }
            }.accessibilityIdentifier("home-suggested-themes")
        }
    }

    private var recommendedRedgifsNiches: [RedgifsNiche] {
        let taste = RedgifsNicheAffinity(liked: Array(store.favorites.values), observed: store.posts)
        return taste.rankNiches(redgifsNiches)
    }

    /// RedGIFs' actual communities, represented by thumbnails from their
    /// popular clips. Tapping one opens that niche's immersive vertical feed.
    @ViewBuilder private var redgifsNicheRow: some View {
        if !redgifsNiches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2.fill").foregroundStyle(AppTheme.accent)
                    Text("RedGIFs niches").font(.subheadline.weight(.bold))
                    Text(store.favorites.values.contains(where: { $0.providerKey == .redgifs })
                         ? "For you" : "Explore")
                        .font(.caption2).foregroundStyle(AppTheme.secondaryLabel).lineLimit(1)
                        .accessibilityLabel("Niches ranked from your Likes and related communities")
                    Spacer()
                    Button {
                        showAllRedgifsNiches = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Show all")
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-redgifs-show-all")
                }.padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recommendedRedgifsNiches) { niche in
                            Button {
                                openRedgifsNiche(niche)
                            } label: {
                                HomeArtworkChip(title: niche.name, imageURL: niche.imageURL)
                                    .overlay(alignment: .topTrailing) {
                                        if openingNicheID == niche.id {
                                            ProgressView().tint(.white).padding(12)
                                        }
                                    }
                            }
                            .buttonStyle(QuicktickPressStyle())
                            .disabled(openingNicheID != nil)
                            .accessibilityLabel("Explore RedGIFs niche: \(niche.name)")
                            .accessibilityIdentifier("redgifs-niche-\(niche.id)")
                        }
                    }.padding(.horizontal, 16)
                }
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-redgifs-niches")
        }
    }

    private func openRedgifsNiche(_ niche: RedgifsNiche) {
        guard openingNicheID == nil, store.selectedProvider == .redgifs else { return }
        openingNicheID = niche.id
        let query = "niche:" + niche.id
        store.commitSearch(query: query, sort: "popular")
        Task { @MainActor in
            await store.refresh(immersive: true)
            defer { openingNicheID = nil }
            guard store.selectedProvider == .redgifs,
                  store.queryText == query,
                  let first = store.posts.first(where: \.isImmersiveMedia) else { return }
            immersivePostID = first.stableID
            immersive = true
        }
    }

    /// Provider categories live on Home as one-tap discovery chips. They are
    /// intentionally not part of the Search sheet's autocomplete suggestions.
    private var homeCategoryRow: some View {
        let provider = store.selectedProvider
        let selected = ProviderSearchCategories.split(QueryParser.parse(store.queryText), provider: provider).category
        return VStack(alignment: .leading, spacing: 10) {
            Text("Categories")
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                ForEach(ProviderSearchCategories.suggestions(provider: provider)) { item in
                    let active = selected == item.value
                    let preview = pornhubCategoryPreview(item.value)
                    Button {
                        let current = QueryParser.parse(store.queryText)
                        let keywords = ProviderSearchCategories.split(current, provider: provider).keywords
                        let next = ParsedQuery(included: (active ? [] : [item.value]) + keywords,
                                               excluded: current.excluded)
                        store.commitSearch(query: QueryParser.formatted(next), sort: store.feedSort)
                        Task { await store.refresh() }
                    } label: {
                        HomeArtworkChip(title: item.label, imageURL: preview ?? "",
                                        selected: active, width: 174, height: 198,
                                        placeholder: "square.grid.2x2.fill")
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityIdentifier("home-category-\(item.value)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
                }.padding(.horizontal, 16)
            }
        }
        .accessibilityIdentifier("home-categories")
        .task(id: store.selectedProvider) { await discoverPornhubCategoryPreviews() }
    }

    private func pornhubCategoryPreview(_ token: String) -> String? {
        if let cached = pornhubCategoryPreviews[token] { return cached }
        // A word in a title is not evidence of a video's category. Only a
        // category-specific website result or verified API category qualifies.
        return (store.posts + Array(store.favorites.values)).first {
            $0.providerKey == .pornhub && $0.category == token &&
                URL(string: $0.cardPreviewURL)?.scheme == "https"
        }?.cardPreviewURL
    }

    @MainActor private func discoverPornhubCategoryPreviews() async {
        guard store.selectedProvider == .pornhub else {
            pornhubCategoryPreviews = [:]
            return
        }
        // Each category is independently verified against the first-party
        // catalog. A failed or blocked category keeps its honest placeholder.
        // Fetch serially and away from first paint to avoid a burst of calls.
        try? await Task.sleep(for: .milliseconds(1_300))
        for category in ProviderSearchCategories.suggestions(provider: .pornhub) {
            guard !Task.isCancelled, store.selectedProvider == .pornhub else { return }
            guard pornhubCategoryPreviews[category.value] == nil else { continue }
            if let preview = try? await store.api.pornhubCategoryPreview(token: category.value),
               URL(string: preview)?.scheme == "https" {
                pornhubCategoryPreviews[category.value] = preview
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    private func refreshFromGesture() async {
        guard !pullRefreshInFlight else { return }
        pullRefreshInFlight = true
        defer { pullRefreshInFlight = false }
        await store.refresh()
        themeRefreshCycle &+= 1
        refreshThemeSuggestions()
    }

    private func maybeLoadMoreAfterUserScroll(visibleID: String) {
        guard store.activeTab == 0, store.lastError == nil,
              store.posts.suffix(8).contains(where: { $0.stableID == visibleID }),
              HomePaginationPolicy.shouldLoad(
                  upwardDragSequence: visibleFrameCache.upwardDragSequence,
                  consumedSequence: visibleFrameCache.paginatedDragSequence,
                  loading: store.isLoading, hasMore: store.hasMore) else { return }
        // One page at most per deliberate upward gesture. A preview resize or
        // a SwiftUI remount cannot silently chain dozens of page requests.
        visibleFrameCache.paginatedDragSequence = visibleFrameCache.upwardDragSequence
        Task { await store.loadMore() }
    }

    private func likeVisiblePost(in viewport: CGSize) {
        let bounds = CGRect(origin: .zero, size: viewport)
        guard let chosen = visibleFrameCache.frames
            .filter({ $0.value.intersects(bounds) })
            .max(by: { $0.value.intersection(bounds).height < $1.value.intersection(bounds).height }),
              let post = store.posts.first(where: { $0.stableID == chosen.key }),
              store.favorites[post.stableID] == nil else { return }
        store.toggleFavorite(post)
    }

    private func noteScrollMotion() {
        let now = Date()
        // Scroll geometry can publish at display refresh frequency. Updating
        // SwiftUI state for timing samples caused visible hitching.
        if now.timeIntervalSince(visibleFrameCache.lastIntelligencePause) >= 0.3 {
            visibleFrameCache.lastIntelligencePause = now
            store.noteFeedMotion()
        }
        visibleFrameCache.lastMotionSample = now
        if !isScrollMoving {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isScrollMoving = true }
        }
        guard visibleFrameCache.scrollRestTask == nil else { return }
        visibleFrameCache.scrollRestTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { break }
                if Date().timeIntervalSince(visibleFrameCache.lastMotionSample) >= 0.6 {
                    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) { isScrollMoving = false }
                    break
                }
            }
            visibleFrameCache.scrollRestTask = nil
        }
    }

    private func selectVisiblePlayback(viewport: CGSize) {
        guard !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented else { return }
        let candidate = visibleCandidate(viewport: viewport)
        if store.inlinePlaybackID != candidate { store.inlinePlaybackID = candidate }
    }
    private func visibleCandidate(viewport: CGSize) -> String? {
        guard !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented else { return nil }
        if let fullScreen = store.fullScreenPlaybackID { return fullScreen }
        // A remounted Home has an empty frame-preference dictionary until the
        // first layout. Returning nil here cleared the just-restored player
        // and sometimes left it paused permanently.
        if visibleFrameCache.frames.isEmpty, let retained = store.retainedHomePlaybackID,
           playableIDs.contains(retained), store.posts.contains(where: { $0.stableID == retained }) {
            return retained
        }
        let selected = VisiblePostSelector.select(frames: visibleFrameCache.frames,
            viewport: CGRect(origin: .zero, size: viewport), current: store.inlinePlaybackID,
            eligible: playableIDs)
        if let selected { return selected }
        if let current = store.inlinePlaybackID, playableIDs.contains(current),
           let frame = visibleFrameCache.frames[current], frame.height > 0,
           frame.intersection(CGRect(origin: .zero, size: viewport)).height >= min(frame.height, viewport.height) * 0.20 {
            // Between two cards the next media may not yet meet the selection
            // threshold. Keep the old player alive through that short gap.
            return current
        }
        // Partial layout preferences can describe only the header or an
        // offscreen cell during a tab remount. Don't clear a known playable
        // card in that brief window; a final selection runs once layout has
        // stabilized. Ordinary scrolling never uses this fallback.
        if Date() < visibleFrameCache.remountGraceUntil,
           let retained = store.retainedHomePlaybackID, playableIDs.contains(retained),
           store.posts.contains(where: { $0.stableID == retained }) {
            return retained
        }
        return nil
    }
    private func warmNext(after key: String?) async {
        guard !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented, !Task.isCancelled else { return }
        guard let key, let index = store.posts.firstIndex(where: { $0.stableID == key }) else { return }
        // Home previews are the cheap look-ahead path. Creating/prerolling an
        // offscreen AVPlayer downloaded multiple videos while the user swiped,
        // fighting the visible player and the UI compositor for bandwidth.
        store.players.retain([key])
        // Decode modest previews before they enter the viewport. Video CDN
        // resolution remains exclusive to the visible player.
        for next in store.posts.dropFirst(index + 1).prefix(2) {
            guard !Task.isCancelled else { return }
            for candidate in next.previewImageURLs {
                guard !Task.isCancelled else { return }
                if (try? await MediaImagePipeline.shared.image(raw: candidate, pixels: 1024)) != nil { break }
            }
        }
    }

    private var searchBar: some View {
        NativeSearchBar(focusRequested: $showSearch)
    }
}

/// Full-screen, paginated niche browser. Selection and playback live in
/// the same presentation so a sheet dismissal cannot drop the chosen filter.
private struct RedgifsNicheBrowserView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let featured: [RedgifsNiche]
    @Binding var showSettings: Bool
    let onReturnToFYP: () -> Void
    @State private var niches: [RedgifsNiche] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var loadingNicheID: String?
    @State private var selectionID = UUID()
    @State private var selectedNiche: RedgifsNiche?
    @State private var selectedPostID: String?
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filtered: [RedgifsNiche] {
        let matching = searchText.isEmpty ? niches
            : niches.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        let taste = RedgifsNicheAffinity(liked: Array(store.favorites.values), observed: store.posts)
        return taste.rankNiches(matching)
    }

    var body: some View {
        Group {
            if let selectedNiche {
                // The niche player is a full-screen cover in its own right.
                // Keeping it inside NavigationStack makes UIKit reserve the
                // navigation/safe-area bounds and shrinks the video canvas
                // compared with the regular edge-to-edge Immersive feed.
                ImmersiveFeedView(posts: store.posts, offline: false,
                                  activePostID: $selectedPostID,
                                  onClose: { closeImmersive() },
                                  showSettings: $showSettings)
                    .id(selectedNiche.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.canvas.ignoresSafeArea())
            } else {
                NavigationStack {
                    directoryView
                }
            }
        }
        .tint(AppTheme.accent)
        .task { if niches.isEmpty { niches = featured; await loadNextPage() } }
    }

    private var directoryView: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: columns(for: geometry.size.width), spacing: 12) {
                    ForEach(filtered) { niche in
                        nicheCard(niche, width: cardWidth(for: geometry.size.width))
                            .onAppear {
                                if searchText.isEmpty, niche.id == niches.suffix(6).first?.id {
                                    Task { await loadNextPage() }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                if loading { ProgressView("Loading niches…").padding(18) }
                if let errorMessage {
                    VStack(spacing: 9) {
                        Text(errorMessage)
                            .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                            .multilineTextAlignment(.center)
                        if hasMore {
                            Button("Retry loading niches") { Task { await loadNextPage() } }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                if hasMore && !loading && loadingNicheID == nil {
                    Button("Load more niches") { Task { await loadNextPage() } }
                        .padding(.bottom, 24)
                }
            }
        }
        .background(ThemeBackdrop())
        .navigationTitle("RedGIFs niches")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter loaded niches")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("redgifs-all-close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Return to FYP", action: onReturnToFYP)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("redgifs-return-fyp")
            }
        }
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        let count = columnCount(for: width)
        let width = cardWidth(for: width)
        return Array(repeating: GridItem(.fixed(width), spacing: 12), count: count)
    }

    private func columnCount(for width: CGFloat) -> Int {
        if width >= 1050 { return 5 }
        if width >= 720 { return 4 }
        if width >= 560 { return 3 }
        return 2
    }

    private func cardWidth(for width: CGFloat) -> CGFloat {
        let count = columnCount(for: width)
        return max(116, (width - 32 - CGFloat(count - 1) * 12) / CGFloat(count))
    }

    private func nicheCard(_ niche: RedgifsNiche, width: CGFloat) -> some View {
        let posterWidth = width - 18
        return Button {
            openNiche(niche)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedMediaImage(url: niche.imageURL, pixels: 420, fill: true)
                    .frame(width: posterWidth, height: posterWidth * 1.2)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                Text(niche.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: posterWidth, height: 36, alignment: .topLeading)
                HStack(spacing: 4) {
                    Text(niche.postCount > 0 ? "\(niche.postCount) clips" : "Explore niche")
                        .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    if loadingNicheID == niche.id {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: posterWidth, height: 16, alignment: .leading)
            }
            .frame(width: posterWidth, alignment: .leading)
            .padding(9)
            .background(AppTheme.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(AppTheme.border))
        }
        .buttonStyle(QuicktickPressStyle())
        .frame(width: width)
        .disabled(loadingNicheID == niche.id)
        .accessibilityLabel("Open niche \(niche.name)")
        .accessibilityIdentifier("redgifs-all-niche-\(niche.id)")
    }

    private func openNiche(_ niche: RedgifsNiche) {
        guard store.selectedProvider == .redgifs else { return }
        // A second tap supersedes the in-flight selection. Keeping all cards
        // disabled during a network request made valid niche taps appear dead.
        let requestID = UUID()
        selectionID = requestID
        loadingNicheID = niche.id
        errorMessage = nil
        let query = "niche:" + niche.id
        store.commitSearch(query: query, sort: "popular")
        Task { @MainActor in
            await store.refresh(immersive: true)
            guard selectionID == requestID else { return }
            loadingNicheID = nil
            guard store.selectedProvider == .redgifs, store.queryText == query else { return }
            // A failed request must not open stale FYP posts from the previous
            // provider feed. NativeProviderAPI labels every niche result.
            // The request itself is constrained to this niche. Some API rows
            // omit their category metadata, so a second exact-category gate
            // can incorrectly turn a valid video response into an empty feed.
            guard store.lastError == nil,
                  let first = store.posts.first(where: {
                      $0.isImmersiveMedia && $0.providerKey == .redgifs
                  }) else {
                errorMessage = store.lastError ?? "No playable clips were returned for \(niche.name). Try another niche."
                return
            }
            selectedPostID = first.stableID
            selectedNiche = niche
        }
    }

    private func closeImmersive() {
        // Immersive's Return to FYP clears the query before onClose, while its
        // normal back button preserves it. Keep those two actions distinct.
        if store.queryText.isEmpty {
            onReturnToFYP()
        } else {
            selectedNiche = nil
            selectedPostID = nil
        }
    }

    @MainActor private func loadNextPage() async {
        guard !loading, hasMore else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let result = try await store.api.redgifsNichesPage(page: page, limit: 24)
            var known = Set(niches.map(\.id))
            for niche in result.items where known.insert(niche.id).inserted {
                niches.append(niche)
            }
            hasMore = result.hasMore
            page += 1
        } catch is CancellationError {
            // Closing the gallery cancels pending requests.
        } catch {
            errorMessage = "Niches could not be loaded: \(error.localizedDescription)"
        }
    }
}

/// Browses the full set of topics exposed by the accessible Hanime catalog,
/// plus tags from saved posts. More catalog pages can be requested in place;
/// the five personalized chips on Home are not the directory's limit.
private struct HanimeTopicsBrowserView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var catalogPosts: [Post] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var errorMessage: String?

    private var topics: [String] {
        let evidence = store.posts + Array(store.favorites.values) + catalogPosts
        let chosen = store.tasteChoice(for: .hanime).into
        let terms = chosen + store.learnedInterests + evidence
            .filter { $0.providerKey == .hanime }.flatMap(\.tags)
        let excluded = Set(store.exclusions.map { $0.lowercased() })
        var seen = Set<String>()
        return terms.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ").lowercased()
            guard !value.isEmpty, value.count <= 80,
                  !value.contains(":"), !value.contains("/"),
                  !excluded.contains(value), seen.insert(value).inserted else { return nil }
            return value
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visibleTopics: [String] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? topics : topics.filter { $0.localizedCaseInsensitiveContains(term) }
    }

    private var topicPreviews: [String: String] {
        var previews: [String: String] = [:]
        for post in catalogPosts + store.posts + Array(store.favorites.values)
        where post.providerKey == .hanime && URL(string: post.cardPreviewURL)?.scheme == "https" {
            for tag in post.tags {
                let key = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "_", with: " ").lowercased()
                if previews[key] == nil { previews[key] = post.cardPreviewURL }
            }
        }
        return previews
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                Text("Topics from the available Hanime catalog and your saved videos")
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    .padding(.bottom, 8)
                let previews = topicPreviews
                ForEach(visibleTopics, id: \.self) { term in
                    let preview = previews[term]
                    Button {
                        let current = QueryParser.parse(store.queryText)
                        store.commitSuggestedTopic(term, excluded: current.excluded)
                        dismiss()
                        Task { await store.refresh() }
                    } label: {
                        HStack(spacing: 12) {
                            if let preview {
                                CachedMediaImage(url: preview, pixels: 240, fill: true)
                                    .frame(width: 76, height: 84)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 11))
                            } else {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(AppTheme.gradient)
                                    .opacity(0.35)
                                    .overlay(Image(systemName: "tag.fill")
                                        .foregroundStyle(.white.opacity(0.65)))
                                    .frame(width: 76, height: 84)
                            }
                            Text(term.capitalized)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AppTheme.accent)
                        }
                        .padding(14)
                        .background(AppTheme.elevatedSurface,
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hanime-topic-\(term)")
                }
                if loading { ProgressView("Loading Hanime topics…").frame(maxWidth: .infinity).padding() }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                }
                if hasMore && !loading {
                    Button("Load more topics") { Task { await loadNextPage() } }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .accessibilityIdentifier("hanime-topics-load-more")
                }
            }
            .padding(16)
        }
        .background(ThemeBackdrop())
        .navigationTitle("All Hanime topics")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search topics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .task { await loadNextPage() }
    }

    @MainActor private func loadNextPage() async {
        guard !loading, hasMore, store.selectedProvider == .hanime else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await store.api.posts(provider: .hanime,
                query: QueryParser.parse(""), page: page, sort: "popular")
            guard !Task.isCancelled else { return }
            let known = Set(catalogPosts.map(\.stableID))
            let unique = result.items.filter { !known.contains($0.stableID) }
            catalogPosts.append(contentsOf: unique)
            hasMore = (result.hasMore ?? false) && !unique.isEmpty && page < 25
            page += 1
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "More topics are unavailable: \(error.localizedDescription)"
        }
    }
}

private struct HomeTopOffsetPreference: PreferenceKey {
    // nil means the top header is not mounted/visible in this lazy list.
    // Previously 0 was the default, so a drag begun halfway down the feed
    // could be mistaken for a valid top-origin pull-to-refresh gesture.
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct HomeVisibleFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

struct HomeThemeSuggestion: Identifiable, Equatable {
    let term: String
    let label: String
    let imageURL: String
    var kind: String = "tag"
    var id: String { kind + ":" + term }
}

enum SuggestedThemeMode: String, CaseIterable, Identifiable {
    static let storageKey = "quicktick-suggested-r34-mode-v1"
    case tags, franchises, balanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tags: "Tags"
        case .franchises: "Franchises"
        case .balanced: "Mix"
        }
    }
}

enum HomeThemeSuggestions {
    private static let generic: Set<String> = ["hentai", "porn", "nsfw", "english", "translated",
        "uncensored", "video", "image", "animated", "manga", "full_color", "high_quality"]

    static func make(provider: Provider, learned: [String], chosen: [String],
                     visual: [String], favorites: [Post], posts: [Post], popular: [Post] = [],
                     excluded: [String], limit: Int = 8, rotation: Int = 0,
                     mode: SuggestedThemeMode = .tags) -> [HomeThemeSuggestion] {
        if provider == .hanime {
            return hanimeTags(learned: learned, chosen: chosen, favorites: favorites,
                              posts: posts, excluded: excluded, limit: limit, rotation: rotation)
        }
        // Bound this to nearby evidence: Home's body is refreshed by scroll
        // state, so image-chip ranking must never scan a huge saved library.
        let liked = Array(favorites.lazy.filter { $0.providerKey == provider }.prefix(96))
            .sorted { $0.stableID < $1.stableID }
        let visible = Array(posts.lazy.filter { $0.providerKey == provider }.prefix(80))
        let evidence = liked + visible.filter { candidate in
            !liked.contains { $0.stableID == candidate.stableID }
        }
        let banned = Set(excluded.map(normalize))
        var scores: [String: Int] = [:]
        func add(_ tags: [String], weight: Int) {
            for token in Set(tags.map(normalize)) {
                guard TasteTagSuggestions.isUseful(token), !generic.contains(token),
                      !banned.contains(token), !token.contains(":"), !token.contains("/") else { continue }
                scores[token, default: 0] += weight
            }
        }
        add(learned, weight: 18)
        add(chosen, weight: 20)
        add(visual, weight: 17)
        // Favorites are an explicit signal even before the learned profile
        // snapshot has been saved by the idle persistence worker.
        for favorite in liked { add(favorite.tags, weight: 5) }
        let ranked = scores.keys.sorted {
            scores[$0, default: 0] == scores[$1, default: 0]
                ? $0 < $1 : scores[$0, default: 0] > scores[$1, default: 0]
        }
        // Rotate only among high-confidence, taste-backed terms. Never invent
        // categories just to make a refresh look different.
        let leading = Array(ranked.prefix(max(limit, 12)))
        let offset = leading.isEmpty ? 0 : (rotation % leading.count + leading.count) % leading.count
        let rotated = Array(leading.dropFirst(offset)) + Array(leading.prefix(offset))
        let ordered = rotated + Array(ranked.dropFirst(leading.count))
        var usedImages = Set<String>()
        var result: [HomeThemeSuggestion] = []
        for term in ordered.prefix(32) {
            let matches = evidence.filter { post in
                let captionTokens = "_" + normalize(post.caption ?? "")
                    .map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + "_"
                return post.tags.contains(where: { normalize($0) == term }) ||
                captionTokens.contains("_" + term + "_")
            }
            let imageOffset = matches.isEmpty ? 0 : (rotation % matches.count + matches.count) % matches.count
            let rotatedMatches = Array(matches.dropFirst(imageOffset)) + Array(matches.prefix(imageOffset))
            guard let sample = rotatedMatches.first(where: {
                !$0.cardPreviewURL.isEmpty && !usedImages.contains($0.cardPreviewURL)
                    && URL(string: $0.cardPreviewURL)?.scheme == "https"
            }) ?? rotatedMatches.first(where: {
                !$0.cardPreviewURL.isEmpty && URL(string: $0.cardPreviewURL)?.scheme == "https"
            }) else { continue }
            usedImages.insert(sample.cardPreviewURL)
            let query = provider == .rule34 ? term : term.replacingOccurrences(of: "_", with: " ")
            result.append(HomeThemeSuggestion(term: query,
                label: term.replacingOccurrences(of: "_", with: " ").capitalized,
                imageURL: sample.cardPreviewURL))
            if result.count >= limit { break }
        }
        guard provider == .rule34, mode != .tags else { return result }
        let validFranchiseEvidence = evidence.filter {
            !RecommendationTagRules.rejects($0, exclusions: excluded)
        }
        let franchises = FranchiseThemeSuggestions.make(evidence: validFranchiseEvidence,
            favorites: Set(liked.map(\.stableID)), learned: learned,
            chosen: chosen, visual: visual, excluded: excluded,
            limit: limit, rotation: rotation, popular: popular)
        if mode == .franchises { return franchises }
        // Discovery mixes popular, actually observed franchises with familiar
        // tags. Alternate categories to prevent a single liked character or
        // an overrepresented franchise from owning the entire chip row.
        var diverse: [HomeThemeSuggestion] = []
        var seenImages = Set<String>()
        for index in 0..<max(result.count, franchises.count) {
            let candidates = index.isMultiple(of: 2)
                ? [franchises[safe: index], result[safe: index]]
                : [result[safe: index], franchises[safe: index]]
            for suggestion in candidates.compactMap({ $0 }) {
                guard diverse.count < limit,
                      !diverse.contains(where: { $0.term == suggestion.term }),
                      seenImages.insert(suggestion.imageURL).inserted else { continue }
                diverse.append(suggestion)
            }
            if diverse.count == limit { break }
        }
        return diverse
    }

    private static func normalize(_ term: String) -> String {
        term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }

    /// Hanime discovery is keyword/tag-based, unlike the former Haven sections.
    /// Cards may omit art until matching accessible posts have loaded.
    private static func hanimeTags(learned: [String], chosen: [String], favorites: [Post],
                                   posts: [Post], excluded: [String], limit: Int,
                                   rotation: Int) -> [HomeThemeSuggestion] {
        let fallback = ["dark skin", "fantasy", "ahegao", "monster girl", "elf",
                        "cosplay", "romance", "magic", "demon", "adventure"]
        let evidence = Array((favorites + posts).filter { $0.providerKey == .hanime }.prefix(120))
        let discovered = evidence.flatMap(\.tags).filter { TasteTagSuggestions.isUseful(normalize($0)) }
        let preferred = chosen + learned.filter { discovered.map(normalize).contains(normalize($0)) }
        var terms: [String] = []
        var seen = Set<String>()
        let blocked = Set(excluded.map(normalize))
        for raw in preferred + discovered + fallback {
            let normalized = normalize(raw)
            guard !normalized.isEmpty, !blocked.contains(normalized),
                  !generic.contains(normalized), seen.insert(normalized).inserted else { continue }
            terms.append(normalized)
        }
        let lead = Array(terms.prefix(max(limit, 10)))
        let shift = lead.isEmpty ? 0 : (rotation % lead.count + lead.count) % lead.count
        let ordered = Array(lead.dropFirst(shift)) + Array(lead.prefix(shift))
        return Array(ordered.prefix(limit)).map { tag in
            let sample = evidence.first { post in
                post.tags.contains(where: { normalize($0) == tag }) &&
                    URL(string: post.cardPreviewURL)?.scheme == "https"
            }
            return HomeThemeSuggestion(term: tag.replacingOccurrences(of: "_", with: " "),
                                       label: tag.replacingOccurrences(of: "_", with: " ").capitalized,
                                       imageURL: sample?.cardPreviewURL ?? "")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Small reviewed franchise dictionary. A chip appears only when it has a
/// real preview from this provider; these names never manufacture a result.
enum FranchiseThemeSuggestions {
    static let names: [String: String] = [
        "street_fighter": "Street Fighter", "brawl_stars": "Brawl Stars",
        "fortnite": "Fortnite", "sonic_the_hedgehog": "Sonic",
        "final_fantasy": "Final Fantasy", "metroid": "Metroid",
        "tomb_raider": "Tomb Raider", "super_mario_bros": "Super Mario",
        "god_of_war": "God of War", "pokemon": "Pokémon",
        "genshin_impact": "Genshin Impact", "honkai_star_rail": "Honkai: Star Rail",
        "overwatch": "Overwatch", "league_of_legends": "League of Legends",
        "the_legend_of_zelda": "Zelda", "one_piece": "One Piece",
        "naruto": "Naruto", "dragon_ball": "Dragon Ball",
        "my_hero_academia": "My Hero Academia", "demon_slayer": "Demon Slayer",
        "jujutsu_kaisen": "Jujutsu Kaisen", "chainsaw_man": "Chainsaw Man",
        "resident_evil": "Resident Evil", "nier_automata": "NieR: Automata",
        "mortal_kombat": "Mortal Kombat", "apex_legends": "Apex Legends"
    ]
    private static let aliases: [String: String] = [
        "pokemon_(series)": "pokemon", "pocket_monsters": "pokemon",
        "overwatch_(game)": "overwatch", "zelda": "the_legend_of_zelda",
        "legend_of_zelda": "the_legend_of_zelda",
        "super_mario": "super_mario_bros", "mario": "super_mario_bros",
        "nier:_automata": "nier_automata", "kimetsu_no_yaiba": "demon_slayer",
        "boku_no_hero_academia": "my_hero_academia",
        "jjk": "jujutsu_kaisen", "honkai:_star_rail": "honkai_star_rail"
    ]
    private static func canonical(_ raw: String) -> String {
        let cleaned = raw.hasPrefix("franchise:") ? String(raw.dropFirst("franchise:".count)) : raw
        let base = TasteConcepts.canonical(cleaned)
        return aliases[base] ?? base
    }
    static func identified(in post: Post) -> Set<String> {
        let direct = Set(post.tags.prefix(128).map(canonical))
        let reviewed = TasteConcepts.resolve(post.tags).franchises
        return Set(direct.union(reviewed).filter { names[$0] != nil })
    }
    static func make(evidence: [Post], favorites: Set<String>,
                     learned: [String], chosen: [String], visual: [String],
                     excluded: [String], limit: Int, rotation: Int,
                     popular: [Post] = []) -> [HomeThemeSuggestion] {
        let banned = Set(excluded.map(canonical))
        let affinity = Set((learned + chosen + visual).map(canonical))
        let likedFranchises = Set(evidence.lazy.filter { favorites.contains($0.stableID) }
            .flatMap { identified(in: $0) })
        // Popular's own sort:score catalog is the primary source of franchise
        // topics, independently of likes. Known franchises are allowed but
        // strongly downweighted so discovery does not loop the same series.
        let freshPopular = Array(popular.lazy.filter {
            $0.providerKey == .rule34 && !RecommendationTagRules.rejects($0, exclusions: excluded)
        }.prefix(240))
        let catalog = freshPopular.isEmpty ? evidence : freshPopular
        var scores: [String: Double] = [:]
        var examples: [String: [Post]] = [:]
        for post in catalog {
            let popularity = log2(max(0, post.score) + 2)
            for franchise in identified(in: post) where !banned.contains(franchise) {
                let discovery = !freshPopular.isEmpty
                let familiar = likedFranchises.contains(franchise)
                scores[franchise, default: 0] += discovery
                    ? (familiar ? 0.2 : 1) * (4 + min(10, popularity) * 0.65)
                    : (favorites.contains(post.stableID) ? 10 : 3)
                        + min(10, popularity) * 0.65 + (affinity.contains(franchise) ? 14 : 0)
                examples[franchise, default: []].append(post)
            }
        }
        let ranked = scores.keys.sorted {
            // Put new, public-catalog franchises ahead of previously liked
            // ones even when one familiar franchise dominates top-scored posts.
            if !freshPopular.isEmpty, likedFranchises.contains($0) != likedFranchises.contains($1) {
                return !likedFranchises.contains($0)
            }
            return scores[$0, default: 0] == scores[$1, default: 0]
                ? $0 < $1 : scores[$0, default: 0] > scores[$1, default: 0]
        }
        let pool = Array(ranked.prefix(max(limit, 14)))
        let shift = pool.isEmpty ? 0 : (rotation % pool.count + pool.count) % pool.count
        let ordered = Array(pool.dropFirst(shift)) + Array(pool.prefix(shift))
            + Array(ranked.dropFirst(pool.count))
        var seen = Set<String>(), result: [HomeThemeSuggestion] = []
        for franchise in ordered {
            let choices = examples[franchise] ?? []
            let index = choices.isEmpty ? 0 : rotation % choices.count
            let rotated = Array(choices.dropFirst(index)) + Array(choices.prefix(index))
            guard let sample = rotated.first(where: {
                !$0.cardPreviewURL.isEmpty && URL(string: $0.cardPreviewURL)?.scheme == "https"
                    && !seen.contains($0.cardPreviewURL)
            }) else { continue }
            seen.insert(sample.cardPreviewURL)
            // Search the *actual* booru tag spelling when the alias database
            // maps it to a canonical franchise name.
            let searchTag = sample.tags.first(where: { canonical($0) == franchise }) ?? franchise
            result.append(HomeThemeSuggestion(term: searchTag,
                label: names[franchise] ?? franchise, imageURL: sample.cardPreviewURL, kind: "franchise"))
            if result.count >= limit { break }
        }
        return result
    }
}
