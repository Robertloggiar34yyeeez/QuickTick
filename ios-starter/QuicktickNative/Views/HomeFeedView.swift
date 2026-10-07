import SwiftUI

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showSettings: Bool
    @State private var showSearch = false
    @State private var onboarding = false
    @State private var immersive = false
    @State private var visibleFrames: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home").font(.system(.title, design: .rounded).weight(.bold)).accessibilityIdentifier("home-title")
                    Text(store.feedSort == "recommended" ? "Selected for your interests" : "Browse your sources").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }.id("home-top").padding(.top, 16)
                HStack(spacing: 8) {
                    ForEach([("Home", "recent"), ("Recommended", "recommended"), ("Popular", "popular")], id: \.1) { title, mode in
                        Button { store.feedSort = mode } label: {
                            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                                .background(store.feedSort == mode ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
                                .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius).stroke(.white.opacity(store.feedSort == mode ? 0.18 : 0.04)))
                        }.buttonStyle(.plain).accessibilityIdentifier("feed-\(mode)").accessibilityAddTraits(store.feedSort == mode ? .isSelected : [])
                    }
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44,height: 44).background(AppTheme.gradient,in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).accessibilityLabel("Refresh feed")
                }
                searchBar
                if let error = store.lastError {
                    ContentUnavailableView { Label("Could not load feed", systemImage: "wifi.exclamationmark") } description: { Text(error) } actions: { Button("Try again") { Task { await store.refresh() } } }
                } else if store.posts.isEmpty && !store.isLoading {
                    ContentUnavailableView("No posts yet", systemImage: "rectangle.stack", description: Text("Choose another source or adjust your search."))
                }
                ForEach(store.posts, id: \.stableID) { post in
                    PostCardView(post: post, available: CGSize(width: min(680, viewport.size.width - 32), height: viewport.size.height))
                        .frame(maxWidth: .infinity)
                        .background { GeometryReader { geometry in Color.clear.preference(key: HomeVisibleFrames.self, value: [post.stableID: geometry.frame(in: .named("home-viewport"))]) } }
                        .onAppear {
                        if let index = store.posts.firstIndex(where: { $0.stableID == post.stableID }), index >= store.posts.count - 4 { Task { await store.loadMore() } }
                    }
                }
                if store.isLoading { RoundedRectangle(cornerRadius: 22).fill(AppTheme.surface).frame(height: 220).overlay { ProgressView("Loading posts") }.accessibilityIdentifier("feed-loading") }
                if store.hasMore {
                    Button("Load more") { Task { await store.loadMore() } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .onAppear { if !store.isLoading && store.lastError == nil { Task { await store.loadMore() } } }
                }
            }.frame(maxWidth: AppTheme.feedWidth).frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 18)
        }
        .overlay(alignment: .bottomLeading) {
            Group {
                Button {
                    store.inlinePlaybackID = nil
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("home-top", anchor: .top) }
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 18, weight: .bold)).frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: Circle()).shadow(color: .black.opacity(0.5), radius: 10)
                }.buttonStyle(.plain).padding(16).accessibilityLabel("Scroll to top").accessibilityIdentifier("home-scroll-top")
            }
        }
        .coordinateSpace(name: "home-viewport")
        .onPreferenceChange(HomeVisibleFrames.self) { visibleFrames = $0 }
        .task(id: visibleCandidate(viewport: viewport.size)) {
            let candidate = visibleCandidate(viewport: viewport.size)
            do { try await Task.sleep(for: .milliseconds(120)); try Task.checkCancellation() } catch { return }
            guard store.activeTab == 0, store.isForeground else { return }
            store.inlinePlaybackID = candidate
            await warmNext(after: candidate)
        }
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
                    Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass").font(.system(size: 19)).frame(width: 44, height: 44).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).accessibilityLabel("Toggle search")
                    SettingsLauncher(isPresented: $showSettings)
                }
            }
        }

        .safeAreaInset(edge: .top) {
            if showSearch { searchBar.padding(.horizontal).background(AppTheme.background) }
        }
        .refreshable { await store.refresh() }
        .navigationDestination(isPresented: $immersive) { ImmersiveFeedView(posts: store.posts, offline: false, onClose: { immersive = false }, showSettings: $showSettings) }
        .onChange(of: immersive) { _, showing in if showing { store.inlinePlaybackID = nil } }
        .sheet(isPresented: $onboarding) { TasteOnboardingView() }
        .onChange(of: store.feedSort) { _, _ in Task { await store.refresh() } }
        .onChange(of: store.posts) { _, posts in
            if !posts.isEmpty && !store.tasteChoice(for: store.selectedProvider).done { onboarding = true }
        }
        }
        }
    }

    private func visibleCandidate(viewport: CGSize) -> String? {
        guard store.activeTab == 0, store.isForeground else { return nil }
        let key = VisiblePostSelector.select(frames: visibleFrames, viewport: CGRect(origin: .zero, size: viewport), current: store.inlinePlaybackID)
        return store.posts.first(where: { $0.stableID == key })?.isImmersiveMedia == true ? key : nil
    }
    private func warmNext(after key: String?) async {
        guard let key, let index = store.posts.firstIndex(where: { $0.stableID == key }) else { store.players.retain([]); return }
        let next = Array(store.posts.dropFirst(index + 1).prefix(2))
        store.players.retain(Set([key] + next.map(\.stableID)))
        for post in next {
            guard !Task.isCancelled, store.inlinePlaybackID == key, store.activeTab == 0 else { return }
            if post.type.lowercased() == "video", let media = try? await store.resolver.resolve(post), let url = media.mediaUrlURL {
                guard !Task.isCancelled, store.inlinePlaybackID == key else { return }; store.players.prewarm(key: post.stableID, url: url)
            }
            _ = try? await MediaImagePipeline.shared.image(raw: post.cardPreviewURL, pixels: 1024)
        }
    }

    private var searchBar: some View {
        NativeSearchBar()
    }
}

private struct HomeVisibleFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

