import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection = 0
    @State private var showSettings = false
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeFeedView(showSettings: $showSettings) }.tag(0)
            NavigationStack { ImmersiveFeedView(posts: store.posts, offline: false, showSettings: $showSettings) }.tag(1)
            NavigationStack { FavoritesView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }.tag(2)
            NavigationStack { DownloadsFeedView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }.tag(3)
        }.toolbar(.hidden, for: .tabBar)
            .onChange(of: selection) { _, _ in store.inlinePlaybackID = nil }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(tabs.indices, id: \.self) { index in
                        Button { selection = index } label: {
                            Image(systemName: tabs[index].1).font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(selection == index ? .white : .white.opacity(0.55))
                                .frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
                                .background {
                                    if selection == index { RoundedRectangle(cornerRadius: 17).fill(AppTheme.gradient) }
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
