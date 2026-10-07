import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]

    var body: some View {
        GeometryReader { geometry in
            let sideNavigation = store.activeTab == 1 && geometry.size.width > 600
            // Preserve each navigation/scroll history with our own controls.
            // iPadOS otherwise creates a floating TabView bar without tabItem labels.
            ZStack {
                NavigationStack { HomeFeedView(showSettings: $showSettings) }.tabVisibility(store.activeTab == 0)
                NavigationStack { ImmersiveFeedView(posts: store.posts, offline: false, showSettings: $showSettings) }.tabVisibility(store.activeTab == 1)
                NavigationStack { FavoritesView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }.tabVisibility(store.activeTab == 2)
                NavigationStack { DownloadsFeedView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }.tabVisibility(store.activeTab == 3)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !sideNavigation {
                    HStack(spacing: 6) { tabButtons(vertical: false) }
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.black)
                        .overlay(alignment: .top) { Color.white.opacity(0.1).frame(height: 0.5) }
                }
            }
            .overlay(alignment: .leading) {
                if sideNavigation {
                    VStack(spacing: 6) { tabButtons(vertical: true) }
                        .padding(6).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14), lineWidth: 1))
                        .padding(.leading, 16).accessibilityIdentifier("immersive-navigation-rail")
                }
            }
        }.tint(.white).background(.black)
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSettings = false } } } }
            }
    }

    @ViewBuilder private func tabButtons(vertical: Bool) -> some View {
        ForEach(tabs.indices, id: \.self) { index in
            Button { store.activeTab = index } label: {
                Image(systemName: tabs[index].1).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(store.activeTab == index ? .white : .white.opacity(0.55))
                    .frame(width: vertical ? 48 : nil, height: 54)
                    .frame(maxWidth: vertical ? nil : .infinity).contentShape(Rectangle())
                    .background {
                        if store.activeTab == index { RoundedRectangle(cornerRadius: 17).fill(AppTheme.gradient) }
                    }
            }.buttonStyle(.plain).accessibilityLabel(tabs[index].0).accessibilityIdentifier("tab-\(tabs[index].0)")
                .accessibilityAddTraits(store.activeTab == index ? .isSelected : [])
        }
    }
}

private extension View {
    func tabVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }
}
