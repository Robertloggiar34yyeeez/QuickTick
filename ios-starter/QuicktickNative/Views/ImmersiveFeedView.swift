import SwiftUI
import AVKit

struct ImmersiveFeedView: View {
    @EnvironmentObject private var store: AppStore
    let posts: [Post]
    let offline: Bool
    @State private var activeID: String?
    @State private var searchVisible = false

    private var mediaPosts: [Post] { posts.filter(\.isImmersiveMedia) }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(mediaPosts, id: \.stableID) { post in
                        ImmersiveItemView(post: post, offline: offline, active: activeID == post.stableID)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(post.stableID)
                    }
                }.scrollTargetLayout()
                if mediaPosts.isEmpty {
                    ContentUnavailableView(store.isLoading ? "Loading clips" : "No videos or GIFs", systemImage: "play.rectangle", description: Text(store.lastError ?? "Choose another source or search to find clips."))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }.scrollTargetBehavior(.paging)
                .scrollPosition(id: $activeID)
                .scrollIndicators(.hidden)
        }
        .navigationTitle(offline ? "Offline Immersive" : "Immersive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if !offline {
                Menu(store.selectedProvider.displayName) { ForEach(Provider.allCases) { provider in
                    Button(provider.displayName) { store.selectedProvider = provider; Task { await store.refresh(immersive: true) } }
                } }
                Button { searchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .safeAreaInset(edge: .top) {
            if searchVisible && !offline {
                NativeSearchBar(immersive: true).padding(.horizontal).background(AppTheme.surface)
            }
        }
        .task { activeID = mediaPosts.first?.stableID; if !offline { await store.refresh(immersive: true) } }
        .task(id: "\(activeID ?? ""):\(mediaPosts.count)") { await prewarm() }
        .onChange(of: mediaPosts.map(\.stableID)) { _, keys in
            if activeID == nil || !keys.contains(activeID ?? "") { activeID = keys.first }
        }
        .onDisappear { store.players.releaseAll() }
    }
    private func prewarm() async {
        let clips = mediaPosts
        guard let activeID, let index = clips.firstIndex(where: { $0.stableID == activeID }) else {
            if !offline && !store.isLoading && store.hasMore { await store.loadMore(immersive: true) }
            return
        }
        let range = max(0, index - 1)...min(clips.count - 1, index + 3)
        store.players.retain(Set(range.map { clips[$0].stableID }))
        let offlineMode = offline
        let feedStore = store
        let resolver = store.resolver
        let pool = store.players
        await withTaskGroup(of: Void.self) { group in
            for i in range where i != index && clips[i].type.lowercased() == "video" {
                let post = clips[i]
                group.addTask {
                    let url: URL?
                    if offlineMode { url = URL(string: post.mediaUrl) }
                    else { url = try? await resolver.resolve(post).mediaUrlURL }
                    guard !Task.isCancelled, let url else { return }
                    await pool.prewarm(key: post.stableID, url: url)
                }
            }
            if !offline, index >= clips.count - 8 {
                group.addTask { await feedStore.loadMore(immersive: true) }
            }
        }
    }

}

private struct ImmersiveItemView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    let offline: Bool
    let active: Bool
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var playing = true
    @State private var watched = 0.0
    @State private var reportedWatch = 0.0
    @State private var interacted = false
    @State private var scrubOrigin: Double?
    @State private var error: String?
    @State private var showComments = false
    @State private var showTags = false
    @State private var gifURL: URL?
    @State private var exposureStarted: Date?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let player {
                NativePlayerSurface(player: player, fill: store.immersionFraming, ready: $ready)
                    .opacity(ready ? 1 : 0)
            }
            if !ready { PosterView(url: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl) }
            if post.type.lowercased() == "gif", active, playing, let gifURL {
                AnimatedGIFSurface(url: gifURL)
            }
            Color.clear.contentShape(Rectangle())
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { gesture in
                    switch gesture {
                    case .first: interacted = true; if store.favorites[post.stableID] == nil { store.toggleFavorite(post) }
                    case .second: playing.toggle(); playing ? player?.play() : player?.pause()
                    }
                })
            VStack {
                if let error { Text(error).padding().background(AppTheme.surface) }
                Spacer()
                VStack(spacing: 4) {
                    HStack {
                        Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5)
                        Spacer()
                        Button("View tags") { showTags = true }.font(.caption.weight(.semibold))
                    }.padding(.horizontal, 16)
                    HStack(spacing: 0) {
                        ActionIcon(title: "Like", symbol: store.favorites[post.stableID] == nil ? "heart" : "heart.fill", selected: store.favorites[post.stableID] != nil) { interacted = true; store.toggleFavorite(post) }
                        if !offline {
                            ActionIcon(title: "Less", symbol: "hand.thumbsdown") { interacted = true; store.less(post) }
                            ActionIcon(title: "Download", symbol: "arrow.down.to.line") { store.download(post) }
                            ActionIcon(title: "Comments", symbol: "bubble.left") { showComments = true }
                        }
                        ActionIcon(title: "Mute", symbol: store.muted ? "speaker.slash" : "speaker.wave.2") { store.muted.toggle(); player?.isMuted = store.muted }
                    }
                }.padding(.top, 20).background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                Rectangle().fill(AppTheme.gradient).frame(height: 16).overlay { Image(systemName: "arrow.left.and.right").foregroundStyle(.white) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                        guard let player, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
                        if scrubOrigin == nil { scrubOrigin = player.currentTime().seconds; player.pause() }
                        let seconds = max(0, min(duration, (scrubOrigin ?? 0) + Double(value.translation.width) / max(1, UIScreen.main.bounds.width) * duration))
                        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                    }.onEnded { _ in scrubOrigin = nil; if playing { player?.play() } })
            }
        }
        .sheet(isPresented: $showComments) { CommentsView(post: post) }
        .sheet(isPresented: $showTags) { PostTagsView(post: post) }
        .task(id: active) {
            guard active else { endExposure(); return }
            exposureStarted = .now
            await prepare()
            guard !Task.isCancelled else { return }
            if !offline { store.recordImpression(post) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                if player?.timeControlStatus == .playing {
                    watched += 1
                    if !offline, watched - reportedWatch >= 10 {
                        store.recordWatch(post, seconds: watched - reportedWatch, completion: 0)
                        reportedWatch = watched
                    }
                }
            }
        }
        .onDisappear { endExposure() }
        .onChange(of: store.muted) { _, value in player?.isMuted = value }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            if !offline { store.recordComplete(post); store.recordReplay(post) }
            player?.seek(to: .zero); if playing { player?.play() }
        }
    }
    private func prepare() async {
        guard post.isImmersiveMedia else { return }
        do {
            let url: URL
            if offline {
                guard let local = URL(string: post.mediaUrl), local.isFileURL, FileManager.default.fileExists(atPath: local.path) else { throw APIError.server("Offline file is missing.") }
                url = local
            } else {
                let resolved = try await store.resolver.resolve(post)
                guard let remote = URL(string: resolved.mediaUrl) else { throw URLError(.badURL) }
                url = remote
            }
            guard !Task.isCancelled else { return }
            if post.type.lowercased() == "gif" { gifURL = url; return }
            let p = store.players.player(for: post.stableID, url: url)
            player = p; p.isMuted = store.muted
            // Start immediately. Duration metadata must never delay the first frame.
            if let resume = store.resumePosition(post.stableID), resume > 0 {
                p.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            } else if store.resumePosition(post.stableID) == nil, post.providerKey == .hanime {
                p.seek(to: CMTime(seconds: 180, preferredTimescale: 600))
            }
            if playing { p.play() }; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func endExposure() {
        player?.pause()
        guard let started = exposureStarted else { return }
        let elapsed = Date().timeIntervalSince(started)
        if let player, player.currentItem?.status == .readyToPlay { store.saveResume(post.stableID, seconds: player.currentTime().seconds) }
        if !offline {
            if watched - reportedWatch >= 2 { store.recordWatch(post, seconds: watched - reportedWatch, completion: 0) }
            if elapsed < 1.25 && !interacted { store.recordQuickSkip(post) }
        }
        watched = 0
        reportedWatch = 0
        exposureStarted = nil
    }
}

struct PosterView: View {
    let url: String
    var body: some View {
        if let file = URL(string: url), file.isFileURL, let image = UIImage(contentsOfFile: file.path) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
        }
    }
}
