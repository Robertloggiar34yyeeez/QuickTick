import SwiftUI

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showSettings: Bool
    @Binding var scrollAnchor: String?
    @AppStorage("quicktick-first-run-completed-v2") private var firstRunCompleted = false
    @State private var showSearch = false
    @State private var onboarding = false
    @State private var immersive = false
    @State private var immersivePostID: String?
    @State private var visibleFrames: [String: CGRect] = [:]
    @State private var lastVisibleTop: String?
    @State private var visibleTopSince = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var feedSelection

    var body: some View {
        GeometryReader { viewport in
        let revision = store.feedRevision
        ScrollViewReader { proxy in
        ScrollView {
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
                    Image(systemName: store.feedSort == "recommended" ? "sparkles" : "flame.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 17))
                        .rotationEffect(.degrees(-9))
                        .accessibilityHidden(true)
                }
                .id("home-top")
                .padding(.top, 14)
                .padding(.horizontal, 16)
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        ForEach([("Recommended", "recommended"), ("Popular", "popular")], id: \.1) { title, mode in
                            Button {
                                store.feedSort = mode
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
                                                .matchedGeometryEffect(id: "feed-mode", in: feedSelection)
                                        }
                                    }
                            }
                            .buttonStyle(QuicktickPressStyle())
                            .animation(reduceMotion ? nil : AppTheme.spring, value: store.feedSort)
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
                Button { onboarding = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Make it yours")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            Text("Fine-tune your feed and interests")
                                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(AppTheme.accent.opacity(0.26), lineWidth: 1))
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityIdentifier("personalize-feed")
                .padding(.horizontal, 16)
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
                if store.isLoading { RoundedRectangle(cornerRadius: 22).fill(AppTheme.surface).frame(height: 220).overlay { ProgressView("Loading posts") }.accessibilityIdentifier("feed-loading") }
                if store.hasMore {
                    Button("Load more") { Task { await store.loadMore() } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 16)
                        .onAppear { if store.activeTab == 0 && !store.isLoading && store.lastError == nil { Task { await store.loadMore() } } }
                }
            }.frame(maxWidth: AppTheme.feedWidth).frame(maxWidth: .infinity).padding(.bottom, 18)
        }
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
            Group {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("home-top", anchor: .top) }
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 18, weight: .bold)).frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: Circle()).shadow(color: .black.opacity(0.5), radius: 10)
                }.buttonStyle(.plain).padding(16).accessibilityLabel("Scroll to top").accessibilityIdentifier("home-scroll-top")
            }
        }
        .coordinateSpace(name: "home-viewport")
        .onPreferenceChange(HomeVisibleFrames.self) { frames in
            guard store.feedRevision == revision else { return }
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
        .task(id: "\(visibleCandidate(viewport: viewport.size) ?? ""):\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.isStudioPresented):\(store.feedRevision):\(store.fullScreenPlaybackID ?? "")") {
            guard !Task.isCancelled, store.feedRevision == revision else { return }
            selectVisiblePlayback(viewport: viewport.size)
        }
        .task(id: "\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.isStudioPresented):\(store.feedRevision)") {
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
                        Text(store.selectedProvider.displayName).font(.caption.weight(.medium)).padding(.horizontal, 10).frame(height: 44)
                            .background(AppTheme.surface, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.15)))
                    }
                    SettingsLauncher(isPresented: $showSettings)
                }
            }
        }

        .onChange(of: store.feedRevision) { _, _ in
            // Keep the search sheet alive while new results are committed.
            // Scroll, rather than replacing the whole NavigationStack subtree.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                proxy.scrollTo("home-top", anchor: .top)
            }
        }
        .refreshable { await store.refresh() }
        .navigationDestination(isPresented: $immersive) { ImmersiveFeedView(posts: store.posts, offline: false, activePostID: $immersivePostID, onClose: { immersive = false }, showSettings: $showSettings) }
        .onChange(of: immersive) { _, showing in if showing { store.inlinePlaybackID = nil } }
        .sheet(isPresented: $onboarding) { TasteOnboardingView() }
        .sheet(isPresented: $showSearch) { NativeSearchBar() }
        .onChange(of: store.posts) { _, posts in
            // The first-run wizard owns initial taste setup. Do not queue a
            // second modal underneath its full-screen presentation.
            if firstRunCompleted && !posts.isEmpty
                && !store.tasteChoice(for: store.selectedProvider).done { onboarding = true }
        }
        }
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
        let playable = Set(store.posts.filter(\.isImmersiveMedia).map(\.stableID))
        return VisiblePostSelector.select(frames: visibleFrames, viewport: CGRect(origin: .zero, size: viewport), current: store.inlinePlaybackID, eligible: playable)
    }
    private func warmNext(after key: String?) async {
        guard !immersive, store.activeTab == 0, store.isForeground, !store.isStudioPresented, !Task.isCancelled else { return }
        guard let key, let index = store.posts.firstIndex(where: { $0.stableID == key }) else { store.players.retain([]); return }
        let next = Array(store.posts.dropFirst(index + 1).prefix(2))
        let nextVideo = store.posts.dropFirst(index + 1).prefix(4).first { $0.type.lowercased() == "video" }
        store.players.retain(Set([key] + [nextVideo?.stableID].compactMap { $0 }))
        let feedStore = store
        let resolver = store.resolver
        // A slow thumbnail must never hold up video preparation.
        await withTaskGroup(of: Void.self) { group in
            if let post = nextVideo {
                group.addTask {
                    guard let media = try? await resolver.resolve(post), let url = media.mediaUrlURL else { return }
                    await MainActor.run {
                        guard !Task.isCancelled, feedStore.inlinePlaybackID == key, feedStore.activeTab == 0, feedStore.isForeground else { return }
                        feedStore.players.prewarm(key: post.stableID, url: url)
                    }
                }
            }
            for post in next {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return }
                    _ = try? await MediaImagePipeline.shared.image(raw: post.cardPreviewURL, pixels: 1024)
                }
            }
        }
    }

    private var searchBar: some View {
        NativeSearchBar(focusRequested: $showSearch)
    }
}

struct HomeVisibleFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}
