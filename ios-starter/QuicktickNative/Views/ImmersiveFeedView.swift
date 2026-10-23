import SwiftUI
import AVKit
import ImageIO

struct ImmersiveFeedView: View {
    @EnvironmentObject private var store: AppStore
    let posts: [Post]
    let offline: Bool
    var onClose: (() -> Void)? = nil
    let collectionTab: Int?
    @Binding var showSettings: Bool
    init(posts: [Post], offline: Bool, activePostID: Binding<String?>, onClose: (() -> Void)? = nil, showSettings: Binding<Bool> = .constant(false), collectionTab: Int? = nil) {
        self.posts = posts; self.offline = offline; self.onClose = onClose; self.collectionTab = collectionTab
        _showSettings = showSettings
        _activeID = activePostID
    }
    @Binding private var activeID: String?
    // SwiftUI's scroll target is a restoration request, not playback truth.
    // On some OS versions it remains on an offscreen page after paging.
    @State private var scrollTargetID: String?
    // A deliberate paging request must not be undone by interim geometry
    // snapshots of the outgoing page while the scroll animation settles.
    @State private var pageTransitionProtectedUntil = Date.distantPast
    @State private var dragOriginID: String?
    @State private var activeIndex = 0
    @State private var activeSince = Date.distantPast
    @State private var searchVisible = false
    @State private var preferencesVisible = false
    @StateObject private var previews = ImmersivePreviewCache()

    private var mediaPosts: [Post] { collectionTab == 2 ? posts : posts.filter(\.isImmersiveMedia) }
    private var presentationActive: Bool {
        collectionTab.map { store.activeTab == $0 } ?? (offline ? store.activeTab == 3 : (onClose != nil ? store.activeTab == 0 : store.activeTab == 1))
    }
    private var playbackOwner: String { offline ? "offline-immersive" : (collectionTab == 2 ? "favorites-immersive" : (onClose != nil ? "home-immersive" : "immersive")) }

    var body: some View {
        GeometryReader { geo in
          ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(mediaPosts, id: \.stableID) { post in
                        ImmersiveItemView(post: post, offline: offline, active: activeID == post.stableID, presentationActive: presentationActive, playbackOwner: playbackOwner, collection: collectionTab != nil, previews: previews)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .contentShape(Rectangle())
                            .allowsHitTesting(activeID == post.stableID && presentationActive)
                            .accessibilityHidden(activeID != post.stableID)
                            .background {
                                GeometryReader { page in
                                    Color.clear.preference(key: ImmersiveVisibleFrames.self, value: [post.stableID: page.frame(in: .named("immersive-viewport"))])
                                }
                            }
                            .id(post.stableID)
                    }
                }.scrollTargetLayout().frame(width: geo.size.width)
                if mediaPosts.isEmpty {
                    ContentUnavailableView {
                        Label(store.isLoading ? "Loading clips" : "No videos or GIFs", systemImage: "play.rectangle")
                    } description: {
                        Text(store.lastError ?? (offline ? "Download a video or GIF to watch it here." : "No new clips matched. Try another source or adjust your interests."))
                    } actions: {
                        if !offline && collectionTab == nil {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = max(0, Int(min(86400, ceil((store.feedRetryAfter ?? .distantPast).timeIntervalSince(context.date)))))
                                Button(seconds > 0 ? "Retry in \(seconds)s" : "Try again") {
                                    Task { await store.refresh(immersive: true) }
                                }.disabled(store.isLoading || seconds > 0)
                            }
                            Button("Adjust interests") { preferencesVisible = true }.disabled(store.isLoading)
                            if !store.queryText.isEmpty {
                                Button("Clear search") { store.queryText = ""; Task { await store.refresh(immersive: true) } }.disabled(store.isLoading)
                            }
                        }
                    }
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }.scrollTargetBehavior(.paging)
                // Handle paging on the scroll container. Media and controls
                // may intercept drags before a cell-only gesture sees them.
                .highPriorityGesture(DragGesture(minimumDistance: 28)
                    .onChanged { _ in
                        if dragOriginID == nil { dragOriginID = activeID }
                    }
                    .onEnded { drag in
                        defer { dragOriginID = nil }
                        guard let origin = dragOriginID ?? activeID else { return }
                        pageSwipe(from: origin, translation: drag.translation,
                                  viewportHeight: geo.size.height, scrollProxy: scrollProxy)
                    }, including: .subviews)
                .scrollPosition(id: $scrollTargetID, anchor: .top)
                // ScrollView's settled target is the source of truth after a
                // page swipe. Geometry callbacks can omit the target while a
                // lazy cell mounts, leaving the previous video's rail active.
                .onChange(of: scrollTargetID) { _, target in
                    guard presentationActive, store.isForeground, let target,
                          target != activeID,
                          mediaPosts.contains(where: { $0.stableID == target }) else { return }
                    if Date() < pageTransitionProtectedUntil, let activeID,
                       target != activeID {
                        scrollTargetID = activeID
                        return
                    }
                    activeID = target
                }
                .coordinateSpace(name: "immersive-viewport")
                .onPreferenceChange(ImmersiveVisibleFrames.self) { frames in
                    guard presentationActive, store.isForeground else { return }
                    let viewport = CGRect(origin: .zero, size: geo.size)
                    if scrollTargetID == activeID && Date() < pageTransitionProtectedUntil { return }
                    // The scroll target is authoritative while it remains on
                    // screen. An intermediate geometry callback must not
                    // revert a swipe to the outgoing, partially visible page.
                    if let target = scrollTargetID, let rect = frames[target],
                       rect.intersects(viewport) { return }
                    // Geometry preference changes on every drag frame; publish
                    // only to rescue a truly offscreen/stale scroll target.
                    let key = VisiblePostSelector.immersive(frames: frames,
                        viewport: viewport,
                        current: activeID, keys: Set(frames.keys))
                    if let key, key != activeID { activeID = key; scrollTargetID = key }
                }
                .scrollIndicators(.hidden)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
          }
        }
        .navigationTitle(offline ? "Offline Immersive" : "Immersive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let onClose { Button(action: onClose) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Back") }
                    Text(offline ? "Offline" : "Immersive").font(.subheadline.weight(.semibold)).shadow(color: .black, radius: 4)
                    Spacer(minLength: 0)
                    if !offline && onClose == nil {
                        Menu { ForEach(Provider.allCases) { provider in
                            Button(provider.displayName) { store.selectedProvider = provider; Task { await store.refresh(immersive: true) } }
                        }; Divider(); Button("Personalize recommendations") { preferencesVisible = true } } label: {
                            Text(store.selectedProvider.displayName).font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).frame(height: 44)
                                .background(.black.opacity(0.55), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.15)))
                        }
                    }
                    if !offline && collectionTab == nil {
                        Button { searchVisible.toggle() } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).accessibilityLabel("Search")
                        SettingsLauncher(isPresented: $showSettings)
                    }
                }.padding(.horizontal, 16).frame(height: 52)

            }
        }
        .task(id: presentationActive) {
            guard presentationActive else { return }
            if activeID == nil { activeID = mediaPosts.first?.stableID }
            scrollTargetID = activeID
            activeSince = .now
        }
        .task(id: "\(activeID ?? ""):\(mediaPosts.count):\(presentationActive):\(store.feedMediaOnly):\(store.isForeground):\(store.feedRevision):\(mediaPosts.dropFirst(activeIndex + 1).first?.stableID ?? "")") { await prewarm() }
        .onChange(of: store.feedRevision) { _, _ in
            activeSince = .distantPast
            activeIndex = 0; activeID = mediaPosts.first?.stableID; scrollTargetID = activeID
        }
        .onChange(of: mediaPosts.map(\.stableID)) { _, keys in
            if activeID == nil || !keys.contains(activeID ?? "") {
                activeID = keys.isEmpty ? nil : keys[min(activeIndex, keys.count - 1)]
                scrollTargetID = activeID
                if keys.isEmpty { activeIndex = 0 }
            }
        }
        .onChange(of: activeID) { oldID, key in
            let now = Date()
            if !offline, collectionTab == nil, presentationActive, store.isForeground,
               store.feedSort == "recommended", let oldID, let key,
               let previous = mediaPosts.firstIndex(where: { $0.stableID == oldID }),
               let next = mediaPosts.firstIndex(where: { $0.stableID == key }) {
                if QuickSkipDecision.dislikes(elapsed: now.timeIntervalSince(activeSince),
                                             from: previous, to: next) {
                    store.recordQuickSkip(mediaPosts[previous])
                }
                // Going back removes a prior instant-skip dislike; it does not
                // generate positive feedback or undo an explicit thumbs-down.
                store.neutralizeQuickSkip(mediaPosts[next])
            }
            activeSince = now
            store.protectImmersivePost(key)
            if let index = mediaPosts.firstIndex(where: { $0.stableID == key }) { activeIndex = index }
        }
        .onDisappear { if store.players.activeOwner == playbackOwner { store.players.releaseAll() } }
        .sheet(isPresented: $preferencesVisible) { TasteOnboardingView() }
        .sheet(isPresented: $searchVisible) { NativeSearchBar(immersive: true) }
        .quicktickEdgeBack {
            // Nested viewers close to their originating feed. The primary
            // Immersive tab returns to Home without affecting page navigation.
            if let onClose { onClose() }
            else { Task { await store.selectFeedTab(0) } }
        }
    }
    private func pageSwipe(from origin: String, translation: CGSize, viewportHeight: CGFloat, scrollProxy: ScrollViewProxy) {
        guard presentationActive, abs(translation.height) > max(55, viewportHeight * 0.12),
              abs(translation.height) > abs(translation.width) * 1.25,
              let index = mediaPosts.firstIndex(where: { $0.stableID == origin }) else { return }
        let next = index + (translation.height < 0 ? 1 : -1)
        guard mediaPosts.indices.contains(next) else { return }
        let key = mediaPosts[next].stableID
        pageTransitionProtectedUntil = Date().addingTimeInterval(1.2)
        activeID = key
        scrollTargetID = key
        withAnimation(.easeOut(duration: 0.22)) { scrollProxy.scrollTo(key, anchor: .top) }
    }
    private func prewarm() async {
        guard presentationActive, store.isForeground, !store.isManualVisualScanRunning, !Task.isCancelled else { return }
        guard offline || collectionTab != nil || store.feedMediaOnly else { return }
        let clips = mediaPosts
        guard let activeID, let index = clips.firstIndex(where: { $0.stableID == activeID }) else {
            if clips.isEmpty && !offline && collectionTab == nil && !store.isLoading && store.hasMore { await store.loadMore(immersive: true) }
            return
        }
        // Prioritize the immediate next clip instead of two competing downloads.
        // Retain the previous player for a quick reverse swipe.
        let playerRange = max(0, index - 1)...min(clips.count - 1, index + 1)
        let previewRange = max(0, index - 1)...min(clips.count - 1, index + 1)
        store.players.retain(Set(playerRange.map { clips[$0].stableID }))
        previews.retain(Set(previewRange.map { clips[$0].stableID }))
        let offlineMode = offline
        let presentingTab = collectionTab ?? (offline ? 3 : (onClose != nil ? 0 : 1))
        let feedStore = store
        let resolver = store.resolver
        let pool = store.players
        let previewCache = previews
        await withTaskGroup(of: Void.self) { group in
            // Fetch the visible poster first; decoding future posters must
            // not compete at the same priority with the current media startup.
            group.addTask(priority: .userInitiated) { await previewCache.load(clips[index]) }
            // Keep one upcoming thumbnail warm; decoding old posters and a
            // second future poster during every page swipe caused CPU spikes.
            for i in previewRange where i > index {
                let post = clips[i]
                group.addTask(priority: .utility) {
                    await previewCache.load(post)
                }
            }
            group.addTask(priority: .utility) {
                // Nearest first; do not compete with the visible player.
                for i in playerRange where i > index && clips[i].type.lowercased() == "video" {
                    let post = clips[i]
                    let url: URL?
                    if offlineMode { url = URL(string: post.mediaUrl) }
                    else { url = try? await resolver.resolve(post).mediaUrlURL }
                    guard !Task.isCancelled else { return }
                    let stillPresenting = await MainActor.run { feedStore.isForeground && !feedStore.isManualVisualScanRunning && feedStore.activeTab == presentingTab }
                    guard stillPresenting, !Task.isCancelled else { return }
                    if let url { await pool.prewarm(key: post.stableID, url: url) }
                }
            }
            if !offline, collectionTab == nil, index >= clips.count - 8 {
                group.addTask { await feedStore.loadMore(immersive: true) }
            }
        }
    }

}

private struct ImmersiveVisibleFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ImmersiveItemView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    let offline: Bool
    let active: Bool
    let presentationActive: Bool
    let playbackOwner: String
    let collection: Bool
    @ObservedObject var previews: ImmersivePreviewCache
    @State private var mediaSize: CGSize?
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var playing = true
    @State private var watched = 0.0
    @State private var reportedWatch = 0.0
    @State private var loopStart = 0.0
    @State private var interacted = false
    @State private var progress = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var error: String?
    @State private var mediaRetry = 0
    @State private var showComments = false
    @State private var showTags = false
    @State private var gifURL: URL?
    @State private var exposureStarted: Date?
    @State private var exposure = PlaybackExposure()
    @State private var gifDecoded = false
    @State private var gifClock = 0.0
    @State private var lastGIFSample = Date()
    @State private var likePulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .center) {
                AppTheme.canvas
                if post.type.lowercased() != "image" && gifURL == nil {
                    // A nonblack poster surface exists immediately, even on a
                    // slow network. The blurred thumbnail remains underneath
                    // the video until AVPlayerLayer has an actual frame.
                    RoundedRectangle(cornerRadius: 0)
                        .fill(AppTheme.gradient)
                        .opacity(0.32)
                        .overlay {
                            LinearGradient(colors: [AppTheme.accent.opacity(0.2), .black.opacity(0.25), AppTheme.accent.opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                        .ignoresSafeArea()
                    if !ready {
                        Group {
                            if let image = previews.images[post.stableID] {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else if active {
                                // Keep the tinted surface visible rather than
                                // flashing the image view's black placeholder.
                                // The cache replaces this with a blurred still.
                                Color.clear
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 13)
                        .clipped()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                    }
                }
                if post.type.lowercased() == "gif", active, !gifDecoded {
                    ZStack {
                        AppTheme.gradient.opacity(0.25)
                        if let thumbnail = previews.images[post.stableID] {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 12)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)
                }
                if post.type.lowercased() == "image" {
                    CachedMediaImage(url: post.cardPreviewURL, pixels: 1440, comic: false)
                        .frame(width: geo.size.width, height: geo.size.height).allowsHitTesting(false)
                }
                if let player {
                    NativePlayerSurface(player: player, fill: geo.size.width <= 600 && store.immersionFraming, ready: $ready, accessibilityID: "immersive-video-surface")
                        .frame(width: fittedSize(geo.size).width, height: fittedSize(geo.size).height)
                        .opacity(ready ? 1 : 0)
                        .animation(.easeOut(duration: 0.18), value: ready)
                        .allowsHitTesting(false)
                }
                if post.type.lowercased() == "gif", active, let gifURL {
                    AnimatedGIFSurface(url: gifURL, playing: playing, onSize: { mediaSize = $0; gifDecoded = true; lastGIFSample = .now }).frame(width: fittedSize(geo.size).width, height: fittedSize(geo.size).height).allowsHitTesting(false)
                }
                Color.clear.contentShape(Rectangle())
                    .accessibilityIdentifier("immersive-media-\(post.stableID)")
                    .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { gesture in
                        switch gesture {
                        case .first:
                            interacted = true
                            if store.favorites[post.stableID] == nil { store.toggleFavorite(post) }
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { likePulse = true }
                        case .second:
                            if post.isImmersiveMedia { playing.toggle(); playing ? player?.play() : player?.pause() }
                        }
                    })
                if likePulse {
                    Image(systemName: "heart.fill").font(.system(size: 88)).foregroundStyle(.white)
                        .shadow(color: .pink.opacity(0.8), radius: 20).transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                if !playing && !scrubbing {
                    Image(systemName: "play.fill").font(.system(size: 48)).foregroundStyle(.white.opacity(0.7))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .overlay(alignment: .bottomTrailing) {
                if active && presentationActive { actionRail.padding(.trailing, geo.size.width > 600 ? 24 : 12).padding(.bottom, 100) }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5)
                        Button("View tags") { showTags = true }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                        Spacer(minLength: 0)
                    }.shadow(color: .black, radius: 4).padding(.leading, 16).padding(.trailing, 88)
                    if active && presentationActive && post.type.lowercased() == "video" {
                        ImmersiveTimeline(player: player, playing: playing, scrubbing: $scrubbing)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let error {
                    VStack(spacing: 8) {
                        Text(error).font(.caption)
                        Button("Retry media") {
                            store.players.release(post.stableID); player = nil; ready = false; self.error = nil
                            mediaRetry += 1
                        }.frame(minHeight: 44)
                    }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
                if active, !offline, !collection, let message = store.lastError {
                    Button { Task { await store.loadMore(immersive: true) } } label: {
                        VStack { Text(message); Text("Load more").bold() }.font(.caption).padding(12)
                    }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .overlay {
                if active, post.isImmersiveMedia, !ready, gifURL == nil, error == nil {
                    ProgressView("Loading media").tint(.white).font(.caption)
                        .padding(12).background(.black.opacity(0.45), in: Capsule()).allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .sheet(isPresented: $showComments) { CommentsView(post: post) }
        .sheet(isPresented: $showTags) { PostTagsView(post: post) }
        .task(id: likePulse) {
            guard likePulse else { return }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { likePulse = false }
        }
        .task(id: "\(active):\(presentationActive):\(store.activeTab):\(store.isForeground):\(store.feedRevision):\(store.isManualVisualScanRunning):\(mediaRetry)") {
            guard active, presentationActive, store.isForeground, !store.isManualVisualScanRunning else { endExposure(); player = nil; ready = false; gifURL = nil; return }
            exposureStarted = .now; exposure = PlaybackExposure(); loopStart = 0; gifDecoded = false; gifClock = 0; lastGIFSample = .now
            progress = 0; duration = 0; scrubbing = false; error = nil
            await prepare()
            guard !Task.isCancelled else { return }
            if !offline { store.recordImpression(post) }
            sampleExposure()
            var restoredResume = false
            var stalledSeconds = 0
            var lastTime = -1.0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                if let player {
                    if player.currentItem?.status == .failed {
                        error = "This clip could not load. Retry or scroll to the next clip."; ready = false
                        continue
                    }
                    let seconds = player.currentTime().seconds
                    let length = player.currentItem?.duration.seconds ?? 0
                    // Read already available item metadata; remote track loading
                    // must never suspend playback health/error monitoring.
                    if let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0, mediaSize != size { mediaSize = size }
                    if !restoredResume, player.currentItem?.status == .readyToPlay, length.isFinite, length > 0 {
                        restoredResume = true
                        if let resume = PlaybackPosition.resume(store.resumePosition(post.stableID), duration: length), abs(seconds - resume) > 2 {
                            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600), completionHandler: { _ in })
                        }
                    }
                    if seconds.isFinite, length.isFinite, length > 0 {
                        duration = length; progress = min(1, max(0, seconds / length))
                    }
                    if playing && !scrubbing && (!seconds.isFinite || abs(seconds - lastTime) < 0.05) { stalledSeconds += 1 }
                    else { stalledSeconds = 0; if player.timeControlStatus == .playing { error = nil } }
                    lastTime = seconds
                    if stalledSeconds >= 20 { error = "Playback is not advancing. Retry media or swipe to another clip." }
                }
                sampleExposure()
                if watched > reportedWatch {
                    if !offline, watched - reportedWatch >= 10 {
                        store.recordWatch(post, seconds: watched - reportedWatch, completion: PlaybackExposure.completion(position: progress, watched: watched, duration: duration))
                        reportedWatch = watched
                    }
                }
            }
        }
        .onDisappear { endExposure(); player = nil; ready = false; gifURL = nil }
        .onChange(of: scrubbing) { _, _ in exposure = PlaybackExposure() }
        .onChange(of: store.muted) { _, value in player?.isMuted = value }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, presentationActive, store.isForeground, let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            sampleExposure()
            let length = player?.currentItem?.duration.seconds ?? 0
            let played = PlaybackExposure.completion(position: 1, watched: watched - loopStart, duration: length)
            if !offline, played >= 0.8 { store.recordComplete(post); if loopStart > 0 { store.recordReplay(post) } }
            loopStart = watched
            guard let player else { return }
            let pool = store.players
            let key = post.stableID
            let owner = playbackOwner
            player.seek(to: .zero) { finished in
                Task { @MainActor in
                    guard finished, playing, store.isForeground, pool.activeKey == key, pool.activeOwner == owner else { return }
                    player.play()
                }
            }
        }
    }

    private var actionRail: some View {
        VStack(spacing: 8) {
            railButton("Like", symbol: "heart.fill", selected: store.favorites[post.stableID] != nil) {
                interacted = true; store.toggleFavorite(post)
            }.accessibilityValue(store.favorites[post.stableID] == nil ? "Not liked" : "Liked")
            if !offline {
                railButton("Less", symbol: "minus.circle") { interacted = true; store.less(post) }
                railButton("Comments", symbol: "bubble.right") { showComments = true }
                ImmersiveDownloadControl(manager: store.downloads, post: post, active: active && presentationActive)
            }
            if post.isImmersiveMedia {
                railButton("Mute", symbol: store.muted ? "speaker.slash" : "speaker.wave.2") { store.muted.toggle() }
            }
        }
    }
    private func railButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 25, weight: .semibold))
                .foregroundStyle(selected ? Color.pink : .white)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .frame(width: 48, height: 48).contentShape(Circle())
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityIdentifier(active ? "immersive-\(title)" : "inactive-\(title)-\(post.stableID)")
    }
    private func prepare() async {
        guard post.isImmersiveMedia else { return }
        do {
            let url: URL
            if offline {
                guard let local = URL(string: post.mediaUrl), local.isFileURL, FileManager.default.fileExists(atPath: local.path) else { throw APIError.server("Offline file is missing.") }
                url = local
            } else {
                let resolved = try await store.resolver.resolve(post, refresh: mediaRetry > 0)
                guard let remote = URL(string: resolved.mediaUrl) else { throw URLError(.badURL) }
                url = remote
            }
            guard !Task.isCancelled, active, presentationActive, store.isForeground, !store.isManualVisualScanRunning else { return }
            if post.type.lowercased() == "gif" { gifURL = url; return }
            let p = store.players.activate(key: post.stableID, url: url, muted: store.muted, owner: playbackOwner)
            player = p; p.isMuted = store.muted
            if !playing { p.pause() }; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func fittedSize(_ available: CGSize) -> CGSize {
        if available.width <= 600 { return available }
        let size = mediaSize ?? post.nativeSize
        return MediaSizing.immersive(aspect: size.map { $0.width / max(1,$0.height) } ?? 16/9, available: available)
    }
    private func sampleExposure() {
        let now = Date()
        let running = ready && player?.timeControlStatus == .playing && !scrubbing
        var media = player?.currentTime().seconds
        var advancing = running
        if gifURL != nil {
            advancing = gifDecoded && playing && active && presentationActive
            if advancing { gifClock += min(2, max(0, now.timeIntervalSince(lastGIFSample))) }
            lastGIFSample = now; media = gifClock
        }
        watched += exposure.sample(media: media, wall: now.timeIntervalSinceReferenceDate, playing: advancing)
    }
    private func endExposure() {
        sampleExposure()
        store.players.pause(post.stableID, owner: playbackOwner)
        guard exposureStarted != nil else { return }
        if let player, player.currentItem?.status == .readyToPlay { store.saveResume(post.stableID, seconds: player.currentTime().seconds) }
        if !offline {
            if watched - reportedWatch > 0 { store.recordWatch(post, seconds: watched - reportedWatch, completion: PlaybackExposure.completion(position: progress, watched: watched, duration: duration)) }
        }
        watched = 0
        reportedWatch = 0
        exposureStarted = nil
    }
}


// Only the small timeline observes playback ticks; the full video page does not
// rebuild ten times per second while the scroll view animates.
private struct ImmersiveTimeline: View {
    let player: AVPlayer?
    let playing: Bool
    @Binding var scrubbing: Bool
    @State private var progress = 0.0
    @State private var duration = 0.0
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(scrubbing ? 0.3 : 0.18)).frame(height: scrubbing ? 6 : 2)
                Capsule().fill(.white.opacity(scrubbing ? 1 : 0.8)).frame(width: max(0, geo.size.width * progress), height: scrubbing ? 6 : 2)
                Circle().fill(.white).frame(width: scrubbing ? 12 : 5, height: scrubbing ? 12 : 5)
                    .offset(x: max(0, min(geo.size.width - 6, geo.size.width * progress - 3)))
                if scrubbing {
                    Text("\(timeLabel(duration * progress)) / \(timeLabel(duration))")
                        .font(.caption.monospacedDigit()).padding(8).background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity).offset(y: -30)
                }
            }.frame(height: 44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard duration > 0, player != nil else { return }
                    if !scrubbing { scrubbing = true; player?.pause() }
                    progress = min(1, max(0, value.location.x / max(1, geo.size.width)))
                }.onEnded { _ in
                    guard scrubbing else { return }
                    player?.seek(to: CMTime(seconds: duration * progress, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    scrubbing = false; if playing { player?.play() }
                })
                .accessibilityElement().accessibilityLabel("Video progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
                .accessibilityIdentifier("immersive-progress")
                .accessibilityAdjustableAction { direction in
                    guard duration > 0 else { return }
                    let delta = direction == .increment ? 0.05 : -0.05
                    progress = min(1, max(0, progress + delta))
                    player?.seek(to: CMTime(seconds: duration * progress, preferredTimescale: 600))
                }
        }.frame(height: 44).padding(.horizontal, 12)
            .onReceive(clock) { _ in
                guard !scrubbing, let player else { return }
                let seconds = player.currentTime().seconds
                let length = player.currentItem?.duration.seconds ?? 0
                guard seconds.isFinite, length.isFinite, length > 0 else { return }
                duration = length; progress = min(1, max(0, seconds / length))
            }
    }
    private func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }

}

private struct ImmersiveDownloadControl: View {
    @ObservedObject var manager: DownloadManager
    let post: Post
    let active: Bool
    @State private var showError = false
    private var record: DownloadRecord? { manager.records.first { $0.key == post.stableID } }
    private var status: String {
        switch record?.state {
        case .some(.complete): return "Saved"
        case .some(.queued), .some(.downloading): return "Downloading"
        case .some(.paused): return "Paused"
        case .some(.failed): return "Failed"
        default: return "Not downloaded"
        }
    }
    var body: some View {
        Button {
            if let record, record.state == .paused { manager.resume(record) }
            else if let record, record.state == .failed || record.state == .cancelled { manager.retry(record) }
            else { manager.download(post) }
        } label: {
            Group {
                if record?.state == .downloading || record?.state == .queued { ProgressView().tint(.white) }
                else { Image(systemName: record?.state == .complete ? "checkmark.circle.fill" : "arrow.down.to.line").font(.system(size: 25, weight: .semibold)) }
            }.foregroundStyle(.white).frame(width: 48, height: 48).contentShape(Circle())
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("Download").accessibilityValue(status)
            .accessibilityIdentifier(active ? "immersive-Download" : "inactive-Download-\(post.stableID)")
            .alert("Download failed", isPresented: $showError) {
                Button("Retry") { if let record { manager.retry(record) } }
                Button("OK", role: .cancel) {}
            } message: { Text(record?.errorMessage ?? "Please try again.") }
            .onChange(of: record?.state) { _, state in if active, state == .failed { showError = true } }
    }
}

struct PosterView: View {
    let url: String
    var onDecoded: ((DecodedMediaImage) -> Void)? = nil
    var body: some View { CachedMediaImage(url: url, pixels: 1024, onDecoded: onDecoded) }
}

struct CachedMediaImage: View {
    let url: String
    var preview = ""
    var pixels = 1024
    var comic = false
    var fill = false
    var onDecoded: ((DecodedMediaImage) -> Void)?
    @State private var decoded: DecodedMediaImage?
    @State private var previewDecoded: DecodedMediaImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image = decoded ?? previewDecoded { Image(uiImage: UIImage(cgImage: image.image)).resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
            else { Color(white: 0.035).overlay { Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").foregroundStyle(.white.opacity(0.25)) } }
        }.task(id: "\(url):\(pixels):\(comic)") {
            decoded = nil; failed = false
            do { let image = try await MediaImagePipeline.shared.image(raw: url, pixels: pixels, comicPreview: comic); try Task.checkCancellation(); decoded = image; onDecoded?(image) }
            catch { if !Task.isCancelled { failed = !url.isEmpty } }
        }
        .task(id: "\(url):\(preview)") {
            previewDecoded = nil
            guard !preview.isEmpty, preview != url else { return }
            if let image = try? await MediaImagePipeline.shared.image(raw: preview, pixels: 512, comicPreview: comic), !Task.isCancelled {
                previewDecoded = image
            }
        }
        .onDisappear {
            // Lazy stacks can retain row state after it leaves the viewport.
            // Let the bounded shared cache own offscreen decoded image memory.
            decoded = nil; previewDecoded = nil
        }
    }
}

// Shared only by this feed: retain previews for the same bounded window as players.
@MainActor private final class ImmersivePreviewCache: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    private var retained: Set<String> = []
    private var loading: Set<String> = []
    func retain(_ keys: Set<String>) { retained = keys; images = images.filter { keys.contains($0.key) } }
    func load(_ post: Post) async {
        let key = post.stableID
        guard images[key] == nil, !loading.contains(key), retained.contains(key) else { return }
        loading.insert(key); defer { loading.remove(key) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            images[key] = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 320)).image { context in
                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 160, width: 200, height: 160))
            }
            return
        }
        #endif
        let urls = [post.thumbUrl, post.cardPreviewURL]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, raw in
                let ext = URL(string: raw)?.pathExtension.lowercased() ?? ""
                guard !["mp4", "webm", "mov", "m3u8", "gif"].contains(ext) else { return }
                if !result.contains(raw) { result.append(raw) }
            }
        for raw in urls {
            guard !Task.isCancelled, retained.contains(key) else { return }
            guard let decoded = try? await MediaImagePipeline.shared.image(raw: raw, pixels: 384) else { continue }
            guard !Task.isCancelled, retained.contains(key) else { return }
            images[key] = UIImage(cgImage: decoded.image)
            return
        }
        // Keep the tinted poster surface if the provider has no thumbnail.
    }
}
