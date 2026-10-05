import SwiftUI

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showSettings: Bool
    @State private var showFloatingSearch = false
    @State private var showSearch = false
    @State private var onboarding = false
    @State private var immersive = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home").font(.largeTitle.weight(.bold)).accessibilityIdentifier("home-title")
                    Text("Adaptive recommendations").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }.id("home-top").padding(.top, 16)
                HStack(spacing: 12) {
                    Menu {
                        Picker("Feed order", selection: $store.feedSort) {
                            Text("Recommended").tag("recommended")
                            Text("Popular").tag("popular")
                            Text("Recent").tag("recent")
                        }
                    } label: {
                        Label(store.feedSort.capitalized, systemImage: "chevron.up.chevron.down")
                            .font(.subheadline.weight(.semibold)).padding(14)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.14)))
                    }.accessibilityLabel("Feed order")
                    Button { Task { await store.refresh() } } label: {
                        Text("Refresh").font(.subheadline.weight(.semibold)).padding(14)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                searchBar
                if let error = store.lastError { Text(error).foregroundStyle(.orange).padding() }
                ForEach(store.posts, id: \.stableID) { post in
                    PostCardView(post: post).onAppear {
                        if let index = store.posts.firstIndex(where: { $0.stableID == post.stableID }), index >= store.posts.count - 4 { Task { await store.loadMore() } }
                    }
                }
                if store.isLoading { ProgressView() }
                if store.hasMore {
                    Button("Load more") { Task { await store.loadMore() } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .task(id: "\(store.posts.count):\(store.isLoading)") {
                            if !store.isLoading && store.lastError == nil { await store.loadMore() }
                        }
                }
            }.background { GeometryReader { geometry in
                Color.clear.preference(key: HomeSearchOffset.self, value: geometry.frame(in: .named("home-feed")).minY)
            } }.padding(.horizontal, 16).padding(.bottom, 18)
        }
        .overlay(alignment: .bottomLeading) {
            if showFloatingSearch {
                Button {
                    store.inlinePlaybackID = nil
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("home-top", anchor: .top) }
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 18, weight: .bold)).frame(width: 48, height: 48)
                        .background(AppTheme.gradient, in: Circle()).shadow(color: .black.opacity(0.5), radius: 10)
                }.buttonStyle(.plain).padding(16).accessibilityLabel("Scroll to top").accessibilityIdentifier("home-scroll-top")
            }
        }
        .background(AppTheme.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .coordinateSpace(name: "home-feed")
        .onPreferenceChange(HomeSearchOffset.self) { offset in showFloatingSearch = offset < -60 }
        .toolbar {
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

    private var searchBar: some View {
        NativeSearchBar()
    }
}

private struct HomeSearchOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
