import SwiftUI

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showSettings: Bool
    @Binding var scrollAnchor: String?
    @State private var showSearch = false
    @State private var onboarding = false
    @State private var immersive = false
    @State private var immersivePostID: String?
    @State private var visibleFrames: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { viewport in
        let revision = store.feedRevision
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home").font(.system(.title, design: .rounded).weight(.bold)).accessibilityIdentifier("home-title")
                    Text(store.feedSort == "recommended" ? "Selected for your interests" : "Browse your sources").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }.id("home-top").padding(.top, 16).padding(.horizontal, 16)
                HStack(spacing: 8) {
                    ForEach([("Home", "recent"), ("Recommended", "recommended"), ("Popular", "popular")], id: \.1) { title, mode in
                        Button { store.feedSort = mode; Task { await store.refresh() } } label: {
                            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                                .background(store.feedSort == mode ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
                                .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius).stroke(.white.opacity(store.feedSort == mode ? 0.18 : 0.04)))
                        }.buttonStyle(.plain).accessibilityIdentifier("feed-\(mode)").accessibilityAddTraits(store.feedSort == mode ? .isSelected : [])
                    }
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44,height: 44).background(AppTheme.gradient,in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).accessibilityLabel("Refresh feed")
                }
                searchBar.id("home-search").padding(.horizontal, 16)
                Text(store.visualScanStatus ?? "")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .accessibilityIdentifier("visual-scan-progress")
                Button { onboarding = true } label: {
                    Label("What would you like to see?", systemImage: "sparkles")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).padding(.horizontal, 16).accessibilityIdentifier("personalize-feed")
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
        .onChange(of: store.feedRevision) { _, _ in proxy.scrollTo("home-top", anchor: .top) }
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
            if frames != visibleFrames { store.noteFeedMotion() }
            visibleFrames = frames
            let bounds = CGRect(origin: .zero, size: viewport.size)
            store.protectVisibleHomePosts(Set(frames.filter { $0.value.intersects(bounds) }.keys))
            if store.activeTab == 0, store.isForeground, store.fullScreenPlaybackID == nil {
                for (id, frame) in frames where frame.intersection(bounds).height >= min(frame.height * 0.5, bounds.height * 0.5) {
                    if let post = store.postForID(id) { store.recordImpression(post) }
                }
            }
            selectVisiblePlayback(viewport: viewport.size)
        }
        .task(id: "\(visibleCandidate(viewport: viewport.size) ?? ""):\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.feedRevision):\(store.fullScreenPlaybackID ?? "")") {
            guard !Task.isCancelled, store.feedRevision == revision else { return }
            selectVisiblePlayback(viewport: viewport.size)
        }
        .task(id: "\(store.inlinePlaybackID ?? ""):\(store.activeTab):\(store.isForeground):\(store.feedRevision)") {
            guard !Task.isCancelled, store.activeTab == 0, store.isForeground, store.feedRevision == revision else { return }
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
            ToolbarItem(placement: .topBarLeading) { Text("QuickTick").font(.subheadline.weight(.semibold)) }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    Menu { ForEach(Provider.allCases) { p in Button(p.displayName) { store.selectedProvider = p; Task { await store.refresh() } } } } label: {
                        Text(store.selectedProvider.displayName).font(.caption.weight(.medium)).padding(.horizontal, 12).frame(height: 44)
                            .background(AppTheme.surface, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.15)))
                    }
                    Button { showSearch = true; withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("home-search", anchor: .top) } } label: { Image(systemName: "magnifyingglass").font(.system(size: 19)).frame(width: 44, height: 44).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).accessibilityLabel("Toggle search")
                    SettingsLauncher(isPresented: $showSettings)
                }
            }
        }

        .refreshable { await store.refresh() }
        .navigationDestination(isPresented: $immersive) { ImmersiveFeedView(posts: store.posts, offline: false, activePostID: $immersivePostID, onClose: { immersive = false }, showSettings: $showSettings) }
        .onChange(of: immersive) { _, showing in if showing { store.inlinePlaybackID = nil } }
        .sheet(isPresented: $onboarding) { TasteOnboardingView() }
        .onChange(of: store.posts) { _, posts in
            if !posts.isEmpty && !store.tasteChoice(for: store.selectedProvider).done { onboarding = true }
        }
        }
        }
    }

    private func selectVisiblePlayback(viewport: CGSize) {
        guard store.activeTab == 0, store.isForeground else { return }
        let candidate = visibleCandidate(viewport: viewport)
        if store.inlinePlaybackID != candidate { store.inlinePlaybackID = candidate }
    }
    private func visibleCandidate(viewport: CGSize) -> String? {
        guard store.activeTab == 0, store.isForeground else { return nil }
        if let fullScreen = store.fullScreenPlaybackID { return fullScreen }
        let playable = Set(store.posts.filter(\.isImmersiveMedia).map(\.stableID))
        return VisiblePostSelector.select(frames: visibleFrames, viewport: CGRect(origin: .zero, size: viewport), current: store.inlinePlaybackID, eligible: playable)
    }
    private func warmNext(after key: String?) async {
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
