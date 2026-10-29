import SwiftUI
import UIKit

/// Directional swipes belong to the navigation controls only. Media and the
/// rest of the screen keep their own horizontal/vertical gestures.
enum TabSwipePolicy {
    /// Fast Feed dock scrubbing is iPad-only. On iPhone, keep one-point-per-
    /// point navigation to avoid accidental multi-tab jumps near media.
    private static func scrubGain(accelerated: Bool) -> CGFloat { accelerated ? 2.65 : 1 }
    private static func minimumTravel(accelerated: Bool) -> CGFloat { accelerated ? 12 : 16 }

    static func scrubDestination(current: Int, translation: CGSize, vertical: Bool,
                                 axisLength: CGFloat, visibleIndices: [Int],
                                 accelerated: Bool = false) -> Int? {
        guard let layout = layout(current: current, axisLength: axisLength,
                                  visibleIndices: visibleIndices, vertical: vertical) else { return nil }
        let primary = vertical ? translation.height : translation.width
        let cross = vertical ? translation.width : translation.height
        guard abs(primary) >= minimumTravel(accelerated: accelerated),
              abs(primary) > abs(cross) * 1.5 else { return nil }
        let position = min(layout.last, max(layout.first, layout.start + primary * scrubGain(accelerated: accelerated)))
        let best = layout.feeds.min { lhs, rhs in
            let lhsDistance = abs(lhs.center - position) - (lhs.id == current ? 8 : 0)
            let rhsDistance = abs(rhs.center - position) - (rhs.id == current ? 8 : 0)
            return lhsDistance < rhsDistance
        }
        guard let best, best.id != current else { return nil }
        return best.id
    }

    /// One continuous pill lives behind the whole dock. Moving it by absolute
    /// scaled finger distance keeps preview and final selection synchronized.
    static func indicatorPosition(current: Int, translation: CGSize,
                                  vertical: Bool, axisLength: CGFloat,
                                  visibleIndices: [Int], accelerated: Bool = false) -> CGFloat {
        guard let layout = layout(current: current, axisLength: axisLength,
                                  visibleIndices: visibleIndices, vertical: vertical) else { return 0 }
        let primary = vertical ? translation.height : translation.width
        let cross = vertical ? translation.width : translation.height
        guard abs(primary) >= minimumTravel(accelerated: accelerated),
              abs(primary) > abs(cross) * 1.5 else { return layout.start }
        return min(layout.last, max(layout.first, layout.start + primary * scrubGain(accelerated: accelerated)))
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
        let step = vertical ? CGFloat(72) : axisLength / CGFloat(visibleIndices.count)
        var cursor: CGFloat = 0
        var feeds: [(id: Int, center: CGFloat)] = []
        for visualID in visibleIndices {
            let length = vertical ? CGFloat(visualID == 2 ? 68 : 62) : step
            if visualID != 2 {
                feeds.append((visualID < 2 ? visualID : visualID - 1, cursor + length / 2))
            }
            cursor += length + (vertical ? 10 : 0)
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
    @AppStorage(AppTheme.automaticSeasonalKey) private var automaticSeasonalThemes = true
    @AppStorage(AppTheme.activeSeasonalKey) private var activeSeasonalPalette = ""
    @AppStorage("quicktick-ipad-side-navigation-v1") private var ipadSidebarEnabled = false
    @AppStorage(BackgroundArtworkStore.enabledKey) private var showsCustomBackground = false
    @State private var showSettings = false
    @State private var showStudio = false
    @State private var showWeeklyWrapped = false
    @State private var showBirthdaySetup = false
    @State private var showBirthdayGreeting = false
    @AppStorage(BirthdayProfile.nameKey) private var birthdayName = ""
    @AppStorage(BirthdayProfile.birthdateKey) private var birthdayDate = 0.0
    @AppStorage(BirthdayProfile.promptedKey) private var birthdayPrompted = false
    @AppStorage(BirthdayProfile.greetedYearKey) private var birthdayGreetedYear = 0
    @State private var tabEntranceOpacity = 1.0
    @State private var collectionImmersive = false
    @State private var favoritesScrollToTop = 0
    @State private var downloadsScrollToTop = 0
    @AppStorage("quicktick-wrapped-last-week-v1") private var wrappedLastShownWeek = ""
    @State private var homeAnchor: String?
    @State private var immersiveAnchor: String?
    // Keep the existing store tab identifiers stable for playback, tests and
    // restored feeds. Create is a separate destination between tabs 1 and 2.
    private let tabs = [("Home", "house.fill"), ("Immersive", "play.fill"),
                        ("Create", "plus"), ("Favorites", "heart"), ("Downloads", "arrow.down.to.line")]
    private var aiTabVisible: Bool { aiTabSessionOverride ?? showAITab }
    private var fastDockEnabled: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var visibleTabIndices: [Int] { aiTabVisible ? [0, 1, 2, 3, 4] : [0, 1, 3, 4] }

    var body: some View { presentedRoot }

    private var rootShell: some View {
        GeometryReader { geometry in
            navigationLayout(size: geometry.size)
        }
        .onChange(of: store.activeTab) { _, tab in
            collectionImmersive = false
            tabNameTask?.cancel()
            guard !reduceMotion else { brieflyNamedTab = nil; return }
            withAnimation(.easeIn(duration: 0.11)) { brieflyNamedTab = tab }
            tabNameTask = Task {
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.14)) { brieflyNamedTab = nil }
            }
        }
        .onChange(of: store.bootstrapped) { _, _ in presentOccasionsIfNeeded() }
        .onChange(of: firstRunCompleted) { _, _ in presentOccasionsIfNeeded() }
        .onChange(of: store.favorites.count) { _, _ in presentWrappedIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                AppTheme.refreshSeasonalPalette()
                presentOccasionsIfNeeded()
            }
        }
        .onChange(of: automaticSeasonalThemes) { _, _ in AppTheme.refreshSeasonalPalette() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            AppTheme.refreshSeasonalPalette()
        }
        .onAppear {
            AppTheme.refreshSeasonalPalette()
            presentOccasionsIfNeeded()
        }
        .onChange(of: showAITab) { _, _ in
            // AppStorage can update while Settings is still being dismissed.
            // Keep the dock transaction in sync across both layouts.
            brieflyNamedTab = nil
        }
        .onDisappear { tabNameTask?.cancel(); tabSelectionTask?.cancel() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: accentPalette)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: activeSeasonalPalette)
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
        .sheet(isPresented: $showBirthdaySetup, onDismiss: {
            // SwiftUI's sheet dismissal must finish before a fullscreen greeting.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(550))
                presentOccasionsIfNeeded()
            }
        }) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Make QuickTick yours", systemImage: "gift.fill")
                            .font(.title2.bold())
                        Text("What's your name and birthday? Both are optional. We'll celebrate with an animation on your day.")
                            .foregroundStyle(AppTheme.secondaryLabel)
                        BirthdayProfileEditor()
                    }
                    .padding(22)
                }
                .background(ThemeBackdrop())
                .navigationTitle("A little celebration")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            birthdayPrompted = true
                            showBirthdaySetup = false
                        }
                    }
                }
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
        .fullScreenCover(isPresented: $showBirthdayGreeting) {
            BirthdayCelebrationView(name: birthdayName,
                                    onClose: { showBirthdayGreeting = false })
                .tint(AppTheme.accent)
        }
        .overlay(alignment: .topTrailing) { FloatingPiPView().environmentObject(store) }
    }

    private func presentOccasionsIfNeeded() {
        guard store.bootstrapped, firstRunCompleted, scenePhase == .active,
              !showSettings, !showStudio, !showWeeklyWrapped, !showBirthdayGreeting,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        if !birthdayPrompted {
            showBirthdaySetup = true
            return
        }
        guard !showBirthdaySetup else { return }
        let year = Calendar.current.component(.year, from: .now)
        if BirthdayProfile.isBirthday(birthdayDate), birthdayGreetedYear != year {
            birthdayGreetedYear = year
            showBirthdayGreeting = true
            return
        }
        presentWrappedIfNeeded()
    }

    private func presentWrappedIfNeeded() {
        guard store.bootstrapped, firstRunCompleted, store.favorites.count >= 3,
              scenePhase == .active, !showSettings, !showStudio, !showWeeklyWrapped,
              !showBirthdaySetup, !showBirthdayGreeting, birthdayPrompted,
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
                FavoritesView(scrollToTopRevision: favoritesScrollToTop,
                              onImmersiveChange: { collectionImmersive = $0 }).toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) }
                }
            }
        case 3:
            NavigationStack {
                DownloadsFeedView(scrollToTopRevision: downloadsScrollToTop,
                                  onImmersiveChange: { collectionImmersive = $0 }).toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SettingsLauncher(isPresented: $showSettings) }
                }
            }
        default:
            NavigationStack { HomeFeedView(showSettings: $showSettings, scrollAnchor: $homeAnchor) }
        }
    }

    private func navigationLayout(size: CGSize) -> some View {
        let pinnedSideNavigation = ipadSidebarEnabled && size.width > 600
        let immersiveCanvas = store.activeTab == 1 || collectionImmersive
        let sideNavigation = size.width > 600 && (immersiveCanvas || pinnedSideNavigation)
        let bottomLength = max(1, size.width - CGFloat((modernUI ? 8 : 4) * 2))
        // Keep the dock geometry as Int arithmetic until the final conversion.
        // A single mixed overloaded expression here exceeded Swift's type-check budget.
        let dockItemCount: Int = visibleTabIndices.count
        let dockItemHeight: Int = dockItemCount * 62
        let dockGapHeight: Int = Swift.max(0, dockItemCount - 1) * 10
        let createGapHeight: Int = aiTabVisible ? 6 : 0
        let sideLength: CGFloat = CGFloat(dockItemHeight + dockGapHeight + createGapHeight)
        return ZStack(alignment: .bottom) {
            activeFeed
                // Swapping two live media stacks through an animated
                // transition briefly doubled decoding and player work.
                // The dock indicator follows the finger, but the current
                // feed must stay still during a navigation-bar scrub.
                .opacity(tabEntranceOpacity)
                // The sidebar floats above the canvas. Reserving 174 points
                // on one side shifted every iPad post away from the physical
                // screen center, including immersive Favorites and Downloads.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Lists reserve space to scroll past the floating bar;
                    // immersive clips, including Likes/Downloads, fill the
                    // canvas behind its translucent controls.
                    if !sideNavigation && !immersiveCanvas {
                        Color.clear.frame(height: store.audio.currentPost == nil ? 76 : 154)
                    }
                }
            if !sideNavigation {
                VStack(spacing: 3) {
                    BackgroundAudioMiniPlayer(audio: store.audio)
                        .padding(.horizontal, 12)
                    // iPhone keeps the regular edge-attached tab bar even in
                    // immersive feeds. Only iPad uses floating side navigation.
                    bottomDock(axisLength: bottomLength, floating: false)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .leading) {
            if sideNavigation { sideDock(axisLength: sideLength, immersive: immersiveCanvas) }
        }
        .overlay(alignment: .bottom) {
            if sideNavigation {
                BackgroundAudioMiniPlayer(audio: store.audio)
                    .frame(maxWidth: 350).padding(.bottom, 10)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.84),
                   value: sideNavigation)
    }

    private func dockDrag(vertical: Bool, axisLength: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: fastDockEnabled ? 12 : 16)
            .updating($navigationDrag) { value, state, _ in state = value.translation }
            .onEnded { swipeTabs($0.translation, vertical: vertical, axisLength: axisLength) }
    }

    private func bottomSelectionIndicator(axisLength: CGFloat) -> some View {
        let slotWidth = axisLength / CGFloat(visibleTabIndices.count)
        let center = TabSwipePolicy.indicatorPosition(
            current: store.activeTab, translation: navigationDrag, vertical: false,
            axisLength: axisLength, visibleIndices: visibleTabIndices, accelerated: fastDockEnabled)
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
            axisLength: axisLength, visibleIndices: visibleTabIndices, accelerated: fastDockEnabled)
        return RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppTheme.gradient)
            .frame(width: brieflyNamedTab == nil ? 62 : 138, height: 62)
            .offset(y: center - 31)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                       value: store.activeTab)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func dockDestinationHint(vertical: Bool, axisLength: CGFloat) -> some View {
        if !vertical, let destination = swipePreview(vertical: vertical, axisLength: axisLength) {
            Text(feedName(destination))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, vertical ? 12 : 14).padding(.vertical, 7)
                .background(AppTheme.elevatedSurface, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.border))
                .offset(y: -40)
                .allowsHitTesting(false)
        }
    }

    private func bottomDock(axisLength: CGFloat, floating: Bool) -> some View {
        HStack(spacing: 0) { tabButtons(vertical: false, axisLength: axisLength) }
            .contentShape(Rectangle())
            .background(alignment: .leading) { bottomSelectionIndicator(axisLength: axisLength) }
            .highPriorityGesture(dockDrag(vertical: false, axisLength: axisLength))
            .padding(.horizontal, modernUI ? 8 : 4)
            .padding(.top, modernUI ? 8 : 4)
            .padding(.bottom, 0)
            .background {
                if floating {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.prefersOpaqueChrome ? AnyShapeStyle(AppTheme.navigationSurface) : AnyShapeStyle(Material.ultraThinMaterial))
                } else if modernUI && !AppTheme.prefersOpaqueChrome {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .bottom)
                } else {
                    AppTheme.navigationSurface.ignoresSafeArea(edges: .bottom)
                }
            }
            .overlay(alignment: .top) {
                if floating {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                } else if modernUI {
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
                } else {
                    AppTheme.gradient.frame(height: 1).opacity(0.55)
                }
            }
            .shadow(color: .black.opacity(floating ? 0.32 : 0), radius: floating ? 16 : 0, y: 5)
            .padding(.horizontal, floating ? 10 : 0)
            .padding(.bottom, floating ? 8 : 0)
            .overlay(alignment: .top) { dockDestinationHint(vertical: false, axisLength: axisLength) }
            .sensoryFeedback(.selection,
                trigger: swipePreview(vertical: false, axisLength: axisLength) ?? store.activeTab)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bottom-navigation-bar")
            .id(aiTabVisible ? "five-tabs" : "four-tabs")
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func sideDock(axisLength: CGFloat, immersive: Bool) -> some View {
        VStack(spacing: 10) { tabButtons(vertical: true, axisLength: axisLength) }
            .contentShape(Rectangle())
            .background(alignment: .top) { sideSelectionIndicator(axisLength: axisLength) }
            .highPriorityGesture(dockDrag(vertical: true, axisLength: axisLength))
            .padding(9)
            // Immersive playback needs transparent chrome so the video
            // canvas remains visible underneath the floating navigation.
            // A simple translucent fill avoids an expensive live blur.
            .background(immersive ? Color.black.opacity(0.24) : AppTheme.navigationSurface,
                         in: RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous)
                .stroke(immersive ? .white.opacity(0.16) : AppTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(immersive || AppTheme.isDeSlopified ? 0 : 0.4), radius: 18, y: 4)
            .sensoryFeedback(.selection,
                trigger: swipePreview(vertical: true, axisLength: axisLength) ?? store.activeTab)
            .padding(.leading, 12)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: brieflyNamedTab)
            .id(aiTabVisible ? "five-side-tabs" : "four-side-tabs")
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func swipeTabs(_ translation: CGSize, vertical: Bool, axisLength: CGFloat) {
        guard !showStudio, !showSettings,
              let tab = TabSwipePolicy.scrubDestination(current: store.activeTab,
                                                         translation: translation, vertical: vertical,
                                                         axisLength: axisLength, visibleIndices: visibleTabIndices,
                                                         accelerated: fastDockEnabled)
        else { return }
        selectTab(tab)
    }

    private func swipePreview(vertical: Bool, axisLength: CGFloat) -> Int? {
        guard !showStudio, !showSettings else { return nil }
        return TabSwipePolicy.scrubDestination(current: store.activeTab,
                                               translation: navigationDrag, vertical: vertical,
                                               axisLength: axisLength, visibleIndices: visibleTabIndices,
                                               accelerated: fastDockEnabled)
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
                    Group {
                        if vertical {
                            HStack(spacing: 12) {
                                Image(systemName: "plus").frame(width: 28)
                            }
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .padding(.horizontal, 13)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .bold))
                        }
                    }
                        .foregroundStyle(.white)
                        .frame(width: vertical ? (brieflyNamedTab == nil ? 62 : 138) : 54, height: vertical ? 68 : 52)
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
                    selectTab(tabID)
                } label: {
                    Group {
                        if vertical {
                            HStack(spacing: 12) {
                                if refreshingTab == tabID {
                                    refreshSpinner
                                        .frame(width: 28)
                                        .accessibilityLabel("Refreshing feed")
                                        .transition(.opacity)
                                } else {
                                    Image(systemName: tabs[index].1)
                                        .font(.system(size: 21, weight: .semibold))
                                        .frame(width: 28)
                                        .transition(.opacity)
                                }
                                if brieflyNamedTab == tabID {
                                    Text(tabs[index].0)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .lineLimit(1).minimumScaleFactor(0.85)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .transition(.opacity.combined(with: .offset(x: -4)))
                                }
                            }
                            .padding(.horizontal, 13)
                        } else if refreshingTab == tabID {
                            refreshSpinner
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
                    .frame(width: vertical ? (brieflyNamedTab == nil ? 62 : 138) : nil, height: vertical ? 62 : 54)
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

    private var refreshSpinner: some View {
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
    }

    private func selectTab(_ tabID: Int) {
        let previous = store.activeTab
        if tabID == 2 { favoritesScrollToTop &+= 1 }
        if tabID == 3 { downloadsScrollToTop &+= 1 }
        let isRefresh = tabID < 2 && previous == tabID
        tabSelectionTask?.cancel()
        if previous != tabID, !reduceMotion {
            tabEntranceOpacity = 0.94
        } else {
            tabEntranceOpacity = 1
        }
        // Commit synchronously: quick successive taps must never be dropped.
        let requiresRefresh = store.beginFeedTabSelection(tabID)
        if isRefresh {
            refreshSpinDegrees = 0
            withAnimation(.smooth(duration: 0.18)) { refreshingTab = tabID }
            if !reduceMotion {
                withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                    refreshSpinDegrees = 360
                }
            }
        } else {
            refreshingTab = nil
            refreshSpinDegrees = 0
        }
        tabSelectionTask = Task { @MainActor in
            if previous != tabID {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    tabEntranceOpacity = 1
                }
            }
            if requiresRefresh { await store.refresh(immersive: tabID == 1) }
            guard !Task.isCancelled else { return }
            if isRefresh {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                if refreshingTab == tabID {
                    withAnimation(.smooth(duration: 0.28)) { refreshingTab = nil }
                    refreshSpinDegrees = 0
                }
            }
        }
    }
}
