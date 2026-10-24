import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @State private var brieflyNamedTab: Int?
    @State private var tabNameTask: Task<Void, Never>?
    @State private var refreshingTab: Int?
    @State private var tabSelectionTask: Task<Void, Never>?
    @State private var refreshSpinDegrees = 0.0
    @AppStorage("quicktick-first-run-completed-v2") private var firstRunCompleted = false
    @AppStorage("quicktick-show-ai-tab-v1") private var showAITab = true
    @State private var aiTabSessionOverride: Bool?
    @AppStorage("quicktick-modern-ui-v1") private var modernUI = true
    @AppStorage("quicktick-accent-palette-v1") private var accentPalette = "violet"
    @State private var showSettings = false
    @State private var showStudio = false
    @State private var homeAnchor: String?
    @State private var immersiveAnchor: String?
    // Keep the existing store tab identifiers stable for playback, tests and
    // restored feeds. Create is a separate destination between tabs 1 and 2.
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"),
                        ("Create", "plus"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]
    private var aiTabVisible: Bool { aiTabSessionOverride ?? showAITab }
    private var visibleTabIndices: [Int] { aiTabVisible ? [0, 1, 2, 3, 4] : [0, 1, 3, 4] }

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
                        .padding(.horizontal, modernUI ? 8 : 4)
                        .padding(.top, modernUI ? 8 : 4)
                        .padding(.bottom, 0)
                        .background {
                            if modernUI && !AppTheme.isCosmic {
                                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .bottom)
                            } else {
                                AppTheme.navigationSurface.ignoresSafeArea(edges: .bottom)
                            }
                        }
                        .overlay(alignment: .top) {
                            if modernUI {
                                Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
                            } else {
                                AppTheme.gradient.frame(height: 1).opacity(0.55)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("bottom-navigation-bar")
                        .id(aiTabVisible ? "five-tabs" : "four-tabs")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .leading) {
                if sideNavigation {
                    VStack(spacing: 6) { tabButtons(vertical: true) }
                        .padding(6)
                        .background(AppTheme.isCosmic ? AnyShapeStyle(AppTheme.navigationSurface) : AnyShapeStyle(Material.ultraThinMaterial),
                                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 4)
                        .padding(.leading, 16)
                        .id(aiTabVisible ? "five-side-tabs" : "four-side-tabs")
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.84), value: sideNavigation)
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
        .onChange(of: showAITab) { _, _ in
            // AppStorage can update while Settings is still being dismissed.
            // Keep the dock transaction in sync across both layouts.
            brieflyNamedTab = nil
        }
        .onDisappear { tabNameTask?.cancel(); tabSelectionTask?.cancel() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: accentPalette)
        // A single environment tint reaches NavigationStacks, toolbars,
        // menus and all presented settings/model-library sheets.
        .tint(AppTheme.accent)
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
                .tint(AppTheme.accent)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(showAITab: Binding(
                    get: { aiTabVisible },
                    set: { enabled in
                        // Update this view's mounted dock in the same turn as
                        // the tap, then persist the preference for next launch.
                        aiTabSessionOverride = enabled
                        showAITab = enabled
                    }))
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSettings = false } } }
            }
            .tint(AppTheme.accent)
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
            .tint(AppTheme.accent)
        }
        .overlay(alignment: .topTrailing) { FloatingPiPView().environmentObject(store) }
    }

    @ViewBuilder private func tabButtons(vertical: Bool) -> some View {
        ForEach(visibleTabIndices, id: \.self) { index in
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
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: modernUI ? 20 : 17, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.25)))
                        .shadow(color: AppTheme.accent.opacity(modernUI ? 0.36 : 0.28), radius: modernUI ? 18 : 13, y: 3)
                        .frame(maxWidth: vertical ? nil : .infinity)
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Create image")
                .accessibilityIdentifier("tab-Create")
            } else {
                let tabID = index < 2 ? index : index - 1
                Button {
                    let isRefresh = tabID < 2 && store.activeTab == tabID
                    if isRefresh {
                        refreshSpinDegrees = 0
                        withAnimation(.smooth(duration: 0.18)) { refreshingTab = tabID }
                        if !reduceMotion {
                            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                                refreshSpinDegrees = 360
                            }
                        }
                    }
                    // A quick Immersive → Home double tap must not let an
                    // older asynchronous selection restore Immersive later.
                    tabSelectionTask?.cancel()
                    tabSelectionTask = Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        await store.selectFeedTab(tabID)
                        guard !Task.isCancelled else { return }
                        if isRefresh {
                            try? await Task.sleep(for: .milliseconds(450))
                            if refreshingTab == tabID {
                                withAnimation(.smooth(duration: 0.28)) { refreshingTab = nil }
                                refreshSpinDegrees = 0
                            }
                        }
                    }
                } label: {
                    Group {
                        if refreshingTab == tabID {
                            ZStack {
                                Circle().stroke(.white.opacity(0.16), lineWidth: 2.5)
                                Circle()
                                    .trim(from: 0.04, to: 0.73)
                                    .stroke(AngularGradient(colors: [.white.opacity(0.07), .white.opacity(0.45), .white], center: .center),
                                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                                    .rotationEffect(.degrees(refreshSpinDegrees))
                                Circle().fill(.white).frame(width: 3.5, height: 3.5)
                            }
                            .frame(width: 23, height: 23)
                            .accessibilityLabel("Refreshing feed")
                            .transition(.opacity.combined(with: .scale(scale: 0.65)))
                        } else if store.activeTab == tabID && brieflyNamedTab == tabID {
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
                            RoundedRectangle(cornerRadius: vertical ? 18 : (modernUI ? 18 : 12), style: .continuous)
                                .fill(AppTheme.gradient)
                                .matchedGeometryEffect(id: "selected-tab", in: navigationSelection)
                        }
                    }
                }
                .buttonStyle(QuicktickPressStyle())
                .animation(reduceMotion ? nil : AppTheme.spring, value: store.activeTab)
                .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: refreshingTab)
                .accessibilityLabel(tabs[index].0)
                .accessibilityIdentifier("tab-\(tabs[index].0)")
                .accessibilityAddTraits(store.activeTab == tabID ? .isSelected : [])
            }
        }
    }
}
