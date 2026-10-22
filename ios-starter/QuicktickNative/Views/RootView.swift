import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @State private var brieflyNamedTab: Int?
    @State private var tabNameTask: Task<Void, Never>?
    @AppStorage("quicktick-first-run-completed-v2") private var firstRunCompleted = false
    @State private var showSettings = false
    @State private var showStudio = false
    @State private var homeAnchor: String?
    @State private var immersiveAnchor: String?
    // Keep the existing store tab identifiers stable for playback, tests and
    // restored feeds. Create is a separate destination between tabs 1 and 2.
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"),
                        ("Create", "plus"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]

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
                        NavigationStack { HomeFeedView(showSettings: $showSettings, scrollAnchor: $homeAnchor) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !sideNavigation {
                    // Full-width dock with a raised, high-contrast creation
                    // action in the center. Preserve safe-area touch targets.
                    HStack(spacing: 0) { tabButtons(vertical: false) }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .padding(.bottom, 0)
                        .background {
                            AppTheme.navigationSurface.ignoresSafeArea(edges: .bottom)
                        }
                        .overlay(alignment: .top) {
                            AppTheme.gradient.frame(height: 1).opacity(0.55)
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
        .fullScreenCover(isPresented: $showStudio, onDismiss: { store.isStudioPresented = false }) {
            NavigationStack {
                ImageStudioView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showStudio = false }
                        }
                    }
            }
            .environmentObject(store)
        }
    }

    @ViewBuilder private func tabButtons(vertical: Bool) -> some View {
        ForEach(tabs.indices, id: \.self) { index in
            if index == 2 {
                Button {
                    store.isStudioPresented = true
                    store.inlinePlaybackID = nil
                    store.players.releaseAll()
                    showStudio = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: vertical ? 46 : 54, height: vertical ? 46 : 52)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.25)))
                        .shadow(color: AppTheme.accent.opacity(0.28), radius: 13, y: 3)
                        .frame(maxWidth: vertical ? nil : .infinity)
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Create image")
                .accessibilityIdentifier("tab-Create")
            } else {
                let tabID = index < 2 ? index : index - 1
                Button {
                    Task { await store.selectFeedTab(tabID) }
                } label: {
                    Group {
                        if store.activeTab == tabID && brieflyNamedTab == tabID {
                            Text(tabs[index].0)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .transition(.opacity)
                        } else {
                            Image(systemName: tabs[index].1)
                                .font(.system(size: 20, weight: .semibold))
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(store.activeTab == tabID ? .white : .white.opacity(0.62))
                    .frame(width: vertical ? 46 : nil, height: vertical ? 46 : 54)
                    .frame(maxWidth: vertical ? nil : .infinity)
                    .contentShape(Rectangle())
                    .background {
                        if store.activeTab == tabID {
                            RoundedRectangle(cornerRadius: vertical ? 18 : 12, style: .continuous)
                                .fill(AppTheme.gradient)
                                .matchedGeometryEffect(id: "selected-tab", in: navigationSelection)
                        }
                    }
                }
                .buttonStyle(QuicktickPressStyle())
                .animation(reduceMotion ? nil : AppTheme.spring, value: store.activeTab)
                .accessibilityLabel(tabs[index].0)
                .accessibilityIdentifier("tab-\(tabs[index].0)")
                .accessibilityAddTraits(store.activeTab == tabID ? .isSelected : [])
            }
        }
    }
}
