import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection = 0
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.rectangle.fill"), ("Downloads", "arrow.down.circle.fill"), ("Favorites", "heart.fill"), ("Settings", "gearshape.fill")]
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeFeedView() }.tag(0)
            NavigationStack { ImmersiveFeedView(posts: store.posts, offline: false) }.tag(1)
            NavigationStack { DownloadsFeedView() }.tag(2)
            NavigationStack { FavoritesView() }.tag(3)
            NavigationStack { SettingsView() }.tag(4)
        }.toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(tabs.indices, id: \.self) { index in
                        Button { selection = index } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tabs[index].1).font(.system(size: 20, weight: .semibold))
                                Text(tabs[index].0).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            }.foregroundStyle(selection == index ? AppTheme.accent : .white.opacity(0.55))
                                .frame(maxWidth: .infinity, minHeight: 58).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(tabs[index].0).accessibilityIdentifier("tab-\(tabs[index].0)")
                    }
                }.padding(.horizontal, 8).background {
                    if selection == 1 { Rectangle().fill(.ultraThinMaterial) }
                    else { AppTheme.background }
                }
                    .overlay(alignment: .top) { Rectangle().fill(AppTheme.gradient).frame(height: 1) }
            }.tint(AppTheme.accent)
            .background(AppTheme.canvas)
    }
}
