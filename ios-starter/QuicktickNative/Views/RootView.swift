import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]
    var body: some View {
        TabView(selection: $store.activeTab) {
            NavigationStack { HomeFeedView(showSettings: $showSettings) }.tag(0)
            NavigationStack { ImmersiveFeedView(posts: store.posts, offline: false, showSettings: $showSettings) }.tag(1)
            NavigationStack { FavoritesView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }.tag(2)
            NavigationStack { DownloadsFeedView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }.tag(3)
        }.toolbar(.hidden, for: .tabBar)
            
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(tabs.indices, id: \.self) { index in
                        Button { store.activeTab = index } label: {
                            Image(systemName: tabs[index].1).font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(store.activeTab == index ? .white : .white.opacity(0.55))
                                .frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
                                .background {
                                    if store.activeTab == index { RoundedRectangle(cornerRadius: 17).fill(AppTheme.gradient) }
                                }
                        }.buttonStyle(.plain).accessibilityLabel(tabs[index].0).accessibilityIdentifier("tab-\(tabs[index].0)")
                    }
                }.padding(.horizontal, 12).padding(.vertical, 6).background(.black)
                    .overlay(alignment: .top) { Color.white.opacity(0.1).frame(height: 0.5) }
            }.tint(.white).background(.black)
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSettings = false } } } }
            }
    }
}
