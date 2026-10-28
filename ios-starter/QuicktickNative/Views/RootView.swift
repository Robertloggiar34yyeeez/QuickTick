import SwiftUI

/// Directional swipes belong to the navigation controls only. Media and the
/// rest of the screen keep their own horizontal/vertical gestures.
enum TabSwipePolicy {
    /// Scrub at actual button spacing, including the Create gap. Translation
    /// moves the active indicator one point per point of finger movement;
    /// velocity never predicts an extra page and cannot skip to an edge.
    static func scrubDestination(current: Int, translation: CGSize, vertical: Bool,
                                 axisLength: CGFloat, visibleIndices: [Int]) -> Int? {
        guard let layout = layout(current: current, axisLength: axisLength,
                                  visibleIndices: visibleIndices, vertical: vertical) else { return nil }
        let primary = vertical ? translation.height : translation.width
        let cross = vertical ? translation.width : translation.height
        guard abs(primary) >= 16, abs(primary) > abs(cross) * 1.5 else { return nil }
        let position = min(layout.last, max(layout.first, layout.start + primary))
        let best = layout.feeds.min { lhs, rhs in
            let lhsDistance = abs(lhs.center - position) - (lhs.id == current ? 8 : 0)
            let rhsDistance = abs(rhs.center - position) - (rhs.id == current ? 8 : 0)
            return lhsDistance < rhsDistance
        }
        guard let best, best.id != current else { return nil }
        return best.id
    }

    /// One continuous pill lives behind the whole dock. Moving it by absolute
    /// finger distance avoids a visual jump while crossing the Create gap.
    static func indicatorPosition(current: Int, translation: CGSize,
                                  vertical: Bool, axisLength: CGFloat,
                                  visibleIndices: [Int]) -> CGFloat {
        guard let layout = layout(current: current, axisLength: axisLength,
                                  visibleIndices: visibleIndices, vertical: vertical) else { return 0 }
        let primary = vertical ? translation.height : translation.width
        let cross = vertical ? translation.width : translation.height
        guard abs(primary) >= 16, abs(primary) > abs(cross) * 1.5 else { return layout.start }
        return min(layout.last, max(layout.first, layout.start + primary))
    }

    private struct Layout {
        let feeds: [(id: Int, center: CGFloat)]
        let start: CGFloat
        let first: CGFloat
        let last: CGFloat
        let step: CGFloat
    }

    private static func layout(current: Int, axisLength: CGFloat,
                               visibleIndices: [Int], vertical: Bool) -> Layout? {
        guard (0...3).contains(current), axisLength > 0,
              !visibleIndices.isEmpty else { return nil }
        let step = vertical ? CGFloat(52) : axisLength / CGFloat(visibleIndices.count)
        var cursor: CGFloat = 0
        var feeds: [(id: Int, center: CGFloat)] = []
        for visualID in visibleIndices {
            let length = vertical ? CGFloat(visualID == 2 ? 52 : 46) : step
            if visualID != 2 {
                feeds.append((visualID < 2 ? visualID : visualID - 1, cursor + length / 2))
            }
            cursor += length + (vertical ? 6 : 0)
        }
        guard let start = feeds.first(where: { $0.id == current })?.center,
              let first = feeds.first?.center, let last = feeds.last?.center else { return nil }
        return Layout(feeds: feeds, start: start, first: first, last: last, step: step)
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var brieflyNamedTab: Int?
    @State private var tabNameTask: Task<Void, Never>?
    @State private var refreshingTab: Int?
    @State private var tabSelectionTask: Task<Void, Never>?
    @GestureState private var navigationDrag = CGSize.zero
    @State private var refreshSpinDegrees = 0.0
    @AppStorage("quicktick-first-run-completed-v2") private var firstRunCompleted = false
    @AppStorage("quicktick-show-ai-tab-v1") private var showAITab = true
    @State private var aiTabSessionOverride: Bool?
    @AppStorage("quicktick-modern-ui-v1") private var modernUI = true
    @AppStorage("quicktick-accent-palette-v1") private var accentPalette = "violet"
    @AppStorage(BackgroundArtworkStore.enabledKey) private var showsCustomBackground = false
    @State private var showSettings = false
    @State private var showStudio = false
    @State private var showWeeklyWrapped = false
    @State private var tabTransitionDirection: CGFloat = 1
    @AppStorage("quicktick-wrapped-last-week-v1") private var wrappedLastShownWeek = ""
    @State private var homeAnchor: String?
    @State private var immersiveAnchor: String?
    // Keep the existing store tab identifiers stable for playback, tests and
    // restored feeds. Create is a separate destination between tabs 1 and 2.
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"),
                        ("Create", "plus"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]
    private var aiTabVisible: Bool { aiTabSessionOverride ?? showAITab }
    private var visibleTabIndices: [Int] { aiTabVisible ? [0, 1, 2, 3, 4] : [0, 1, 3, 4] }

    var body: some View { presentedRoot }

    private var rootShell: some View {
        GeometryReader { geometry in
            navigationLayout(size: geometry.size)
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
        .onChange(of: store.bootstrapped) { _, _ in presentWrappedIfNeeded() }
        .onChange(of: firstRunCompleted) { _, _ in presentWrappedIfNeeded() }
        .onChange(of: store.favorites.count) { _, _ in presentWrappedIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { presentWrappedIfNeeded() }
        }
        .onAppear { presentWrappedIfNeeded() }
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
        .background(ThemeBackdrop().id(showsCustomBackground))
        .modifier(ProfileImportConfirmation(enabled: !showSettings && firstRunCompleted))
    }

    private var presentedRoot: some View {
        rootShell
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
        .fullScreenCover(isPresented: $showWeeklyWrapped) {
            TasteWrappedView(weekly: true, onClose: { showWeeklyWrapped = false })
                .environmentObject(store)
                .tint(AppTheme.accent)
        }
        .overlay(alignment: .topTrailing) { FloatingPiPView().environmentObject(store) }
    }

    private func presentWrappedIfNeeded() {
        guard store.bootstrapped, firstRunCompleted, store.favorites.count >= 3,
              scenePhase == .active, !showSettings, !showStudio, !showWeeklyWrapped,
              store.activeTab == 0,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        let components = Calendar(identifier: .iso8601)
            .dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        guard let year = components.yearForWeekOfYear, let week = components.weekOfYear else { return }
        let key = "\(year)-\(week)"
        guard wrappedLastShownWeek != key else { return }
        // Only mark displayed after conditions are met. Re-opening Settings
        // on the same day should not trigger the weekly cover a second time.
        wrappedLastShownWeek = key
        showWeeklyWrapped = true
    }

    @ViewBuilder private var activeFeed: some View {
        switch store.activeTab {
        case 1:
            NavigationStack {
                ImmersiveFeedView(posts: store.posts, offline: false,
                                  activePostID: $immersiveAnchor, showSettings: $showSettings)
            }
        case 2:
            NavigationStack {
                FavoritesView().toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) }
                }
            }
        case 3:
            NavigationStack {
                DownloadsFeedView().toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) }
                }
            }
        default:
            NavigationStack { HomeFeedView(showSettings: $showSettings, scrollAnchor: $homeAnchor) }
        }
    }

    private func navigationLayout(size: CGSize) -> some View {
        let sideNavigation = store.activeTab == 1 && size.width > 600
        let bottomLength = max(1, size.width - CGFloat((modernUI ? 8 : 4) * 2))
        // Keep the dock geometry as Int arithmetic until the final conversion.
        // A single mixed overloaded expression here exceeded Swift's type-check budget.
        let dockItemCount: Int = visibleTabIndices.count
        let dockItemHeight: Int = dockItemCount * 46
        let dockGapHeight: Int = Swift.max(0, dockItemCount - 1) * 6
        let createGapHeight: Int = aiTabVisible ? 6 : 0
        let sideLength: CGFloat = CGFloat(dockItemHeight + dockGapHeight + createGapHeight)
        return VStack(spacing: 0) {
            activeFeed
                .id(store.activeTab)
                .transition(.asymmetric(
                    insertion: .offset(x: tabTransitionDirection * min(110, size.width * 0.18))
                        .combined(with: .opacity),
                    removal: .opacity))
                .offset(x: sideNavigation ? 0 : navigationDrag.width * 0.20,
                        y: sideNavigation ? navigationDrag.height * 0.14 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !sideNavigation {
                BackgroundAudioMiniPlayer(audio: store.audio)
                    .padding(.horizontal, 12).padding(.bottom, 3)
                bottomDock(axisLength: bottomLength)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .leading) {
            if sideNavigation { sideDock(axisLength: sideLength) }
        }
        .overlay(alignment: .bottom) {
            if sideNavigation {
                BackgroundAudioMiniPlayer(audio: store.audio)
                    .frame(maxWidth: 350).padding(.bottom, 10)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.84),
                   value: sideNavigation)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.29, dampingFraction: 0.91),
                   value: store.activeTab)
    }

    private func dockDrag(vertical: Bool, axisLength: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($navigationDrag) { value, state, _ in state = value.translation }
            .onEnded { swipeTabs($0.translation, vertical: vertical, axisLength: axisLength) }
    }

    private func bottomSelectionIndicator(axisLength: CGFloat) -> some View {
        let slotWidth = axisLength / CGFloat(visibleTabIndices.count)
        let center = TabSwipePolicy.indicatorPosition(
            current: store.activeTab, translation: navigationDrag, vertical: false,
            axisLength: axisLength, visibleIndices: visibleTabIndices)
        return RoundedRectangle(cornerRadius: modernUI ? 18 : 12, style: .continuous)
            .fill(AppTheme.gradient)
            .frame(width: slotWidth, height: 54)
            .offset(x: center - slotWidth / 2)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                       value: store.activeTab)
            .allowsHitTesting(false)
    }

    private func sideSelectionIndicator(axisLength: CGFloat) -> some View {
        let center = TabSwipePolicy.indicatorPosition(
            current: store.activeTab, translation: navigationDrag, vertical: true,
            axisLength: axisLength, visibleIndices: visibleTabIndices)
        return RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppTheme.gradient)
            .frame(width: 46, height: 46)
            .offset(y: center - 23)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                       value: store.activeTab)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func dockDestinationHint(vertical: Bool, axisLength: CGFloat) -> some View {
        if let destination = swipePreview(vertical: vertical, axisLength: axisLength) {
            Text(feedName(destination))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, vertical ? 12 : 14).padding(.vertical, 7)
                .background(AppTheme.elevatedSurface, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.border))
                .offset(x: vertical ? 100 : 0, y: vertical ? 0 : -40)
                .allowsHitTesting(false)
        }
    }

    private func bottomDock(axisLength: CGFloat) -> some View {
        HStack(spacing: 0) { tabButtons(vertical: false, axisLength: axisLength) }
            .contentShape(Rectangle())
            .background(alignment: .leading) { bottomSelectionIndicator(axisLength: axisLength) }
            .highPriorityGesture(dockDrag(vertical: false, axisLength: axisLength))
            .padding(.horizontal, modernUI ? 8 : 4)
            .padding(.top, modernUI ? 8 : 4)
            .padding(.bottom, 0)
            .background {
                if modernUI && !AppTheme.prefersOpaqueChrome {
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
            .overlay(alignment: .top) { dockDestinationHint(vertical: false, axisLength: axisLength) }
            .sensoryFeedback(.selection,
                trigger: swipePreview(vertical: false, axisLength: axisLength) ?? store.activeTab)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bottom-navigation-bar")
            .id(aiTabVisible ? "five-tabs" : "four-tabs")
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func sideDock(axisLength: CGFloat) -> some View {
        VStack(spacing: 6) { tabButtons(vertical: true, axisLength: axisLength) }
            .contentShape(Rectangle())
            .background(alignment: .top) { sideSelectionIndicator(axisLength: axisLength) }
            .highPriorityGesture(dockDrag(vertical: true, axisLength: axisLength))
            .padding(6)
            .background(AppTheme.prefersOpaqueChrome
                ? AnyShapeStyle(AppTheme.navigationSurface) : AnyShapeStyle(Material.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(AppTheme.isDeSlopified ? 0 : 0.4), radius: 18, y: 4)
            .overlay(alignment: .trailing) { dockDestinationHint(vertical: true, axisLength: axisLength) }
            .sensoryFeedback(.selection,
                trigger: swipePreview(vertical: true, axisLength: axisLength) ?? store.activeTab)
            .padding(.leading, 16)
            .id(aiTabVisible ? "five-side-tabs" : "four-side-tabs")
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func swipeTabs(_ translation: CGSize, vertical: Bool, axisLength: CGFloat) {
        guard !showStudio, !showSettings,
              let tab = TabSwipePolicy.scrubDestination(current: store.activeTab,
                                                         translation: translation, vertical: vertical,
                                                         axisLength: axisLength, visibleIndices: visibleTabIndices)
        else { return }
        tabSelectionTask?.cancel()
        tabTransitionDirection = CGFloat(tab < store.activeTab ? -1 : 1)
        var refresh = false
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.29, dampingFraction: 0.91)) {
            refresh = store.beginFeedTabSelection(tab)
        }
        tabSelectionTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if refresh { await store.refresh(immersive: tab == 1) }
        }
    }

    private func swipePreview(vertical: Bool, axisLength: CGFloat) -> Int? {
        guard !showStudio, !showSettings else { return nil }
        return TabSwipePolicy.scrubDestination(current: store.activeTab,
                                               translation: navigationDrag, vertical: vertical,
                                               axisLength: axisLength, visibleIndices: visibleTabIndices)
    }

    private func feedName(_ tab: Int) -> String {
        switch tab {
        case 1: "Immersive"
        case 2: "Favorites"
        case 3: "Downloads"
        default: "Home"
        }
    }

    @ViewBuilder private func tabButtons(vertical: Bool, axisLength: CGFloat) -> some View {
        let highlightedTab = swipePreview(vertical: vertical, axisLength: axisLength) ?? store.activeTab
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
                        .shadow(color: AppTheme.accent.opacity(AppTheme.isDeSlopified ? 0 : (modernUI ? 0.36 : 0.28)), radius: modernUI ? 18 : 13, y: 3)
                        .frame(maxWidth: vertical ? nil : .infinity)
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Create image")
                .accessibilityIdentifier("tab-Create")
            } else {
                let tabID = index < 2 ? index : index - 1
                Button {
                    let isRefresh = tabID < 2 && store.activeTab == tabID
                    // Apply the selection while the button action is still
                    // running. With an async-only switch, the next rapid tap
                    // could be lost while SwiftUI remounted the dock.
                    tabSelectionTask?.cancel()
                    tabTransitionDirection = CGFloat(tabID < store.activeTab ? -1 : 1)
                    var requiresRefresh = false
                    withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.29, dampingFraction: 0.91)) {
                        requiresRefresh = store.beginFeedTabSelection(tabID)
                    }
                    if isRefresh {
                        refreshSpinDegrees = 0
                        withAnimation(.smooth(duration: 0.18)) { refreshingTab = tabID }
                        if !reduceMotion {
                            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                                refreshSpinDegrees = 360
                            }
                        }
                    }
                    tabSelectionTask = Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        if requiresRefresh { await store.refresh(immersive: tabID == 1) }
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
                        } else if highlightedTab == tabID && brieflyNamedTab == tabID {
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
                    .foregroundStyle(highlightedTab == tabID ? .white : .white.opacity(0.62))
                    .frame(width: vertical ? 46 : nil, height: vertical ? 46 : 54)
                    .frame(maxWidth: vertical ? nil : .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuicktickPressStyle())
                .animation(reduceMotion ? nil : AppTheme.spring, value: store.activeTab)
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.87), value: highlightedTab)
                .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: refreshingTab)
                .accessibilityLabel(tabs[index].0)
                .accessibilityIdentifier("tab-\(tabs[index].0)")
                .accessibilityAddTraits(store.activeTab == tabID ? .isSelected : [])
            }
        }
    }
}
