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

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showSettings: Bool
    @Binding var scrollAnchor: String?
    @AppStorage(VideoPlaybackPreferences.autoplayKey) private var autoplayVideos = true
    @State private var showSearch = false
    @State private var immersive = false
    @State private var immersivePostID: String?
    @State private var visibleFrames: [String: CGRect] = [:]
    // Video eligibility changes only when the feed changes, not on every
    // scroll/layout pass. Avoid rebuilding a Set from the whole feed per frame.
    @State private var playableIDs: Set<String> = []
    @State private var lastVisibleTop: String?
    @State private var visibleTopSince = Date.distantPast
    @State private var isScrollMoving = false
    @State private var scrollRestTask: Task<Void, Never>?
    @State private var lastMotionSample = Date.distantPast
    @State private var lastIntelligencePause = Date.distantPast
    @State private var topOffset: CGFloat?
    @State private var pullRefreshInFlight = false
    @State private var pullRefreshGate = HomePullRefreshGate()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                feedScroll(viewport: viewport, proxy: proxy)
            }
        }
    }

    // Keep the root body small: the Home feed has independent scroll,
    // navigation, playback and gesture modifiers, and Swift 6 cannot reliably
    // type-check all of those inside one nested GeometryReader expression.
    private func feedScroll(viewport: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        let revision = store.feedRevision
        let scrollContent = ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.feedSort == "recommended" ? "For you" : "Trending")
                            .font(.system(size: 33, weight: .bold, design: .rounded))
                            .tracking(-1.3)
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
                    Image(systemName: store.feedSort == "recommended" ? "sparkles" : "flame.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 17))
                        .rotationEffect(.degrees(-9))
                        .accessibilityHidden(true)
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
                if store.selectedProvider == .hhaven || store.selectedProvider == .pornhub {
                    homeCategoryRow
                }
                if let error = store.lastError {
                    ContentUnavailableView { Label("Could not load feed", systemImage: "wifi.exclamationmark") } description: { Text(error) } actions: { Button("Try again") { Task { await store.refresh() } } }
                } else if store.posts.isEmpty && !store.isLoading {
                    ContentUnavailableView("No posts yet", systemImage: "rectangle.stack", description: Text("Choose another source or adjust your search."))
                }
                ForEach(store.posts, id: \.stableID) { post in
                    PostCardView(post: post, available: CGSize(width: min(680, viewport.size.width), height: viewport.size.height))
                        .frame(maxWidth: .infinity)
                        .id(post.stableID)
                        .onAppear {
                        if store.activeTab == 0, let index = store.posts.firstIndex(where: { $0.stableID == post.stableID }), index >= store.posts.count - 4 { Task { await store.loadMore() } }
                    }
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
                        .onAppear { if store.activeTab == 0 && !store.isLoading && store.lastError == nil { Task { await store.loadMore() } } }
                }
            }.frame(maxWidth: AppTheme.feedWidth).frame(maxWidth: .infinity).padding(.bottom, 18)
        }
        return scrollContent
        // A regular feed must keep free scroll offsets through rotation and
        // keyboard changes. Restore its anchor only when this host mounts;
        // continuously binding a .top target fought scrollTo and focus changes.
        .task {
            if let scrollAnchor, store.posts.contains(where: { $0.stableID == scrollAnchor }) {
                proxy.scrollTo(scrollAnchor, anchor: .top)
            }
        }
        .onChange(of: store.feedRevision) { _, _ in
            lastVisibleTop = nil
            visibleTopSince = .distantPast
            proxy.scrollTo("home-top", anchor: .top)
        }
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
                .padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                .accessibilityLabel("Scroll to top")
                .accessibilityIdentifier("home-scroll-top")
            }
        }
        .coordinateSpace(name: "home-viewport")
        .onPreferenceChange(HomeTopOffsetPreference.self) { topOffset = $0 }
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
                // Reconstruct the header position at gesture START, not after
                // a long swipe has already carried it into the visible area.
                pullRefreshGate.observe(startOffset: topOffset.map { $0 - drag.translation.height })
            }
            .onEnded { drag in
            guard pullRefreshGate.finish(translation: drag.translation) else { return }
            Task { await refreshFromGesture() }
        })
        .onPreferenceChange(HomeVisibleFrames.self) { frames in
            guard store.feedRevision == revision else { return }
            guard frames != visibleFrames else { return }
            // Geometry changes reveal actual scrolling without attaching a
            // gesture that competes with normal vertical paging. Hide the
            // shortcut during motion; restore it after a quiet interval.
            let moved = frames.contains { id, rect in
                guard let previous = visibleFrames[id] else { return false }
                return abs(previous.minY - rect.minY) > 2
            }
            if moved { noteScrollMotion() }
            visibleFrames = frames
            let bounds = CGRect(origin: .zero, size: viewport.size)
            let top = frames.filter { $0.value.intersects(bounds) }.min { $0.value.minY < $1.value.minY }?.key
            if let top, scrollAnchor != top { scrollAnchor = top }
            if let top, top != lastVisibleTop {
                let now = Date()
                if !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented,
                   store.feedSort == "recommended", !store.isLoading,
                   let previousID = lastVisibleTop,
                   let previousIndex = store.posts.firstIndex(where: { $0.stableID == previousID }),
                   let nextIndex = store.posts.firstIndex(where: { $0.stableID == top }) {
                    let dwell = now.timeIntervalSince(visibleTopSince)
                    if QuickSkipDecision.dislikes(elapsed: dwell, from: previousIndex, to: nextIndex) {
                        store.recordQuickSkip(store.posts[previousIndex])
                    }
                    store.neutralizeQuickSkip(store.posts[nextIndex])
                }
                lastVisibleTop = top
                visibleTopSince = now
            }
            store.protectVisibleHomePosts(Set(frames.filter { $0.value.intersects(bounds) }.keys))
            selectVisiblePlayback(viewport: viewport.size)
        }
        .onAppear {
            playableIDs = Set(store.posts.filter(\.isImmersiveMedia).map(\.stableID))
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
                for delay in [120, 260, 420] {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard store.activeTab == 0 else { return }
                    selectVisiblePlayback(viewport: viewport.size)
                }
            }
        }
        .onDisappear {
            scrollRestTask?.cancel(); pullRefreshGate.cancel()
            // Geometry from the outgoing tab is invalid on the next mount.
            visibleFrames = [:]
        }
        .task(id: "\(visibleCandidate(viewport: viewport.size) ?? ""):\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.isStudioPresented):\(store.feedRevision):\(store.fullScreenPlaybackID ?? "")") {
            guard !Task.isCancelled, store.feedRevision == revision else { return }
            selectVisiblePlayback(viewport: viewport.size)
        }
        .task(id: "\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.isStudioPresented):\(store.feedRevision):\(autoplayVideos)") {
            guard !Task.isCancelled, store.activeTab == 0, store.isForeground, !store.isStudioPresented, store.feedRevision == revision else { return }
            await warmNext(after: store.inlinePlaybackID)
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                Text("active=\(store.inlinePlaybackID ?? "nil") candidate=\(visibleCandidate(viewport: viewport.size) ?? "nil") paused=\(store.pausedPlaybackID ?? "nil") foreground=\(store.isForeground) frames=\(visibleFrames.count) player=\(store.players.activeKey ?? "nil") owner=\(store.players.activeOwner ?? "nil")")
                    .font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("home-playback-debug")
            }
        }
        #endif
        .background(AppTheme.canvas)
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
        .onChange(of: store.posts) { _, posts in
            playableIDs = Set(posts.filter(\.isImmersiveMedia).map(\.stableID))
        }
    }

    /// Provider categories live on Home as one-tap discovery chips. They are
    /// intentionally not part of the Search sheet's autocomplete suggestions.
    private var homeCategoryRow: some View {
        let provider = store.selectedProvider
        let selected = ProviderSearchCategories.split(QueryParser.parse(store.queryText), provider: provider).category
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Categories")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryLabel)
                ForEach(ProviderSearchCategories.suggestions(provider: provider)) { item in
                    let active = selected == item.value
                    Button {
                        let current = QueryParser.parse(store.queryText)
                        let keywords = ProviderSearchCategories.split(current, provider: provider).keywords
                        let next = ParsedQuery(included: (active ? [] : [item.value]) + keywords,
                                               excluded: current.excluded)
                        store.commitSearch(query: QueryParser.formatted(next), sort: store.feedSort)
                        Task { await store.refresh() }
                    } label: {
                        Text(item.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(active ? .white : AppTheme.secondaryLabel)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(active ? AnyShapeStyle(AppTheme.gradient) : AnyShapeStyle(AppTheme.elevatedSurface),
                                        in: Capsule())
                            .overlay(Capsule().stroke(active ? AppTheme.accent : AppTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityIdentifier("home-category-\(item.value)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }.padding(.horizontal, 16)
        }.accessibilityIdentifier("home-categories")
    }

    private func refreshFromGesture() async {
        guard !pullRefreshInFlight else { return }
        pullRefreshInFlight = true
        defer { pullRefreshInFlight = false }
        await store.refresh()
    }

    private func likeVisiblePost(in viewport: CGSize) {
        let bounds = CGRect(origin: .zero, size: viewport)
        guard let chosen = visibleFrames
            .filter({ $0.value.intersects(bounds) })
            .max(by: { $0.value.intersection(bounds).height < $1.value.intersection(bounds).height }),
              let post = store.posts.first(where: { $0.stableID == chosen.key }),
              store.favorites[post.stableID] == nil else { return }
        store.toggleFavorite(post)
    }

    private func noteScrollMotion() {
        let now = Date()
        // Scroll geometry can publish at display refresh frequency. Updating
        // tasks and object graphs sixty times per second caused visible hitching.
        if now.timeIntervalSince(lastIntelligencePause) >= 0.3 {
            lastIntelligencePause = now
            store.noteFeedMotion()
        }
        guard now.timeIntervalSince(lastMotionSample) >= 0.12 else { return }
        lastMotionSample = now
        scrollRestTask?.cancel()
        if !isScrollMoving {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isScrollMoving = true }
        }
        scrollRestTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) { isScrollMoving = false }
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
        if visibleFrames.isEmpty, let retained = store.retainedHomePlaybackID,
           playableIDs.contains(retained), store.posts.contains(where: { $0.stableID == retained }) {
            return retained
        }
        return VisiblePostSelector.select(frames: visibleFrames, viewport: CGRect(origin: .zero, size: viewport), current: store.inlinePlaybackID, eligible: playableIDs)
    }
    private func warmNext(after key: String?) async {
        guard !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented, !Task.isCancelled else { return }
        guard let key, let index = store.posts.firstIndex(where: { $0.stableID == key }) else { store.players.retain([]); return }
        // Home previews are the cheap look-ahead path. Creating/prerolling an
        // offscreen AVPlayer downloaded multiple videos while the user swiped,
        // fighting the visible player and the UI compositor for bandwidth.
        store.players.retain([key])
        guard let next = store.posts.dropFirst(index + 1).first else { return }
        _ = try? await MediaImagePipeline.shared.image(raw: next.cardPreviewURL, pixels: 512)
    }

    private var searchBar: some View {
        NativeSearchBar(focusRequested: $showSearch)
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
