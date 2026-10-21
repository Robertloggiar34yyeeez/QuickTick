import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @State private var showSettings = false
    @State private var homeAnchor: String?
    @State private var immersiveAnchor: String?
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]

    var body: some View {
        GeometryReader { geometry in
            let sideNavigation = store.activeTab == 1 && geometry.size.width > 600
            // Keep a single mounted navigation stack for playback and VoiceOver.
            VStack(spacing: 0) {
                Group {
                    switch store.activeTab {
                    case 1:
                        NavigationStack { ImmersiveFeedView(posts: store.posts, offline: false, activePostID: $immersiveAnchor, showSettings: $showSettings) }
                    case 2:
                        NavigationStack { FavoritesView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }
                    case 3:
                        NavigationStack { DownloadsFeedView().toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) } } }
                    default:
                        NavigationStack { HomeFeedView(showSettings: $showSettings, scrollAnchor: $homeAnchor).id(store.feedRevision) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !sideNavigation {
                    HStack(spacing: 4) { tabButtons(vertical: false) }
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 5)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .background(AppTheme.background)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .leading) {
                if sideNavigation {
                    VStack(spacing: 6) { tabButtons(vertical: true) }
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 4)
                        .padding(.leading, 16)
                }
            }
        }
        .tint(.white)
        .background(AppTheme.background)
        .modifier(ProfileImportConfirmation(enabled: !showSettings))
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSettings = false } } }
            }
        }
    }

    @ViewBuilder private func tabButtons(vertical: Bool) -> some View {
        ForEach(tabs.indices, id: \.self) { index in
            Button {
                Task { await store.selectFeedTab(index) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tabs[index].1)
                        .font(.system(size: 20, weight: .semibold))
                    if !vertical && store.activeTab == index {
                        Text(tabs[index].0)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .foregroundStyle(store.activeTab == index ? .white : .white.opacity(0.65))
                .frame(width: vertical ? 48 : nil, height: vertical ? 48 : 52)
                .frame(maxWidth: vertical ? nil : .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background {
                    if store.activeTab == index {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppTheme.gradient)
                            .matchedGeometryEffect(id: "selected-tab", in: navigationSelection)
                    }
                }
            }
            .buttonStyle(QuicktickPressStyle())
            .animation(reduceMotion ? nil : AppTheme.spring, value: store.activeTab)
            .accessibilityLabel(tabs[index].0)
            .accessibilityIdentifier("tab-\(tabs[index].0)")
            .accessibilityAddTraits(store.activeTab == index ? .isSelected : [])
        }
    }
}
