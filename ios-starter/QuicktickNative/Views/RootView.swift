import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @State private var brieflyNamedTab: Int?
    @State private var tabNameTask: Task<Void, Never>?
    @AppStorage("quicktick-first-run-completed-v2") private var firstRunCompleted = false
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
                    // Full-width, screen-edge dock instead of a floating pill.
                    // The dock background extends behind the home indicator;
                    // its buttons occupy the entire available horizontal space.
                    HStack(spacing: 0) { tabButtons(vertical: false) }
                        .padding(.horizontal, 4)
                        .padding(.top, 5)
                        .padding(.bottom, 0)
                        .background {
                            AppTheme.elevatedSurface.ignoresSafeArea(edges: .bottom)
                        }
                        .overlay(alignment: .top) {
                            Rectangle().fill(AppTheme.border).frame(height: 1)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("bottom-navigation-bar")
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
.onChange(of: store.activeTab) { _, tab in
            tabNameTask?.cancel()
            guard !reduceMotion else { brieflyNamedTab = nil; return }
            withAnimation(.easeIn(duration: 0.11)) { brieflyNamedTab = tab }
            tabNameTask = Task {
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.14)) { brieflyNamedTab = nil }
            }
        }
        .onDisappear { tabNameTask?.cancel() }
        .tint(.white)
        .background(AppTheme.background)
        .modifier(ProfileImportConfirmation(enabled: !showSettings && firstRunCompleted))
        .fullScreenCover(isPresented: Binding(
            get: {
                store.bootstrapped && !firstRunCompleted
                    && (!ProcessInfo.processInfo.arguments.contains("--ui-testing")
                        || ProcessInfo.processInfo.arguments.contains("--ui-testing-first-run"))
            },
            set: { _ in }
        )) {
            FirstRunSetupView()
                .environmentObject(store)
        }
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
                Group {
                    if store.activeTab == index && brieflyNamedTab == index {
                        Text(tabs[index].0)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .transition(.opacity)
                    } else {
                        Image(systemName: tabs[index].1)
                            .font(.system(size: 20, weight: .semibold))
                            .transition(.opacity)
                    }
                }
                                .foregroundStyle(store.activeTab == index ? .white : .white.opacity(0.65))
                .frame(width: vertical ? 46 : nil, height: vertical ? 46 : 54)
                .frame(maxWidth: vertical ? nil : .infinity)
                .contentShape(Rectangle())
                .background {
                    if store.activeTab == index {
                        RoundedRectangle(cornerRadius: vertical ? 18 : 10, style: .continuous)
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
