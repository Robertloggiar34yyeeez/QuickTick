import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        TabView {
            NavigationStack { HomeFeedView() }.tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { ImmersiveFeedView(posts: store.posts, offline: false) }.tabItem { Label("Immersive", systemImage: "play.rectangle.fill") }
            NavigationStack { DownloadsFeedView() }.tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            NavigationStack { FavoritesView() }.tabItem { Label("Favorites", systemImage: "heart.fill") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
