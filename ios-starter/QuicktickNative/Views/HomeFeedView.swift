import SwiftUI

struct HomeFeedView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showFloatingSearch = false
    @State private var onboarding = false
    @State private var immersive = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                searchBar.background { GeometryReader { geometry in
                    Color.clear.preference(key: HomeSearchOffset.self, value: geometry.frame(in: .named("home-feed")).minY)
                } }
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
            }.padding(.horizontal)
        }
        .background(AppTheme.canvas)
        .navigationTitle("Quicktick")
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .coordinateSpace(name: "home-feed")
        .onPreferenceChange(HomeSearchOffset.self) { offset in showFloatingSearch = offset < -60 }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu(store.selectedProvider.displayName) { ForEach(Provider.allCases) { p in Button(p.displayName) { store.selectedProvider = p; Task { await store.refresh() } } } }
            }
            ToolbarItem(placement: .topBarTrailing) { HStack {
                Button { immersive = true } label: { Image(systemName: "play.rectangle") }
                Button { showFloatingSearch.toggle() } label: { Image(systemName: "magnifyingglass") }
            } }
        }
        .safeAreaInset(edge: .top) {
            if showFloatingSearch { searchBar.padding(.horizontal).background(AppTheme.background) }
        }
        .refreshable { await store.refresh() }
        .navigationDestination(isPresented: $immersive) { ImmersiveFeedView(posts: store.posts, offline: false, onClose: { immersive = false }) }
        .onChange(of: immersive) { _, showing in if showing { store.inlinePlaybackID = nil } }
        .sheet(isPresented: $onboarding) { TasteOnboardingView() }
        .onChange(of: store.posts) { _, posts in
            if !posts.isEmpty && !store.tasteChoice(for: store.selectedProvider).done { onboarding = true }
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
