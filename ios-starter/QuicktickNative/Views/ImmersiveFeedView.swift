import SwiftUI
import AVKit

struct ImmersiveFeedView: View {
    @EnvironmentObject private var store: AppStore
    let posts: [Post]
    let offline: Bool
    @State private var activeID: String?
    @State private var searchVisible = false

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(posts, id: \.stableID) { post in
                        ImmersiveItemView(post: post, offline: offline, active: activeID == post.stableID)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(post.stableID)
                    }
                }.scrollTargetLayout()
            }.scrollTargetBehavior(.paging)
                .scrollPosition(id: $activeID)
                .scrollIndicators(.hidden)
        }
        .navigationTitle(offline ? "Offline Immersive" : "Immersive")
        .navigationBarTitleDisplayMode(.inline)
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
                NativeSearchBar(immersive: true).padding(.horizontal).background(.ultraThinMaterial)
            }
        }
        .task { activeID = posts.first?.stableID }
        .task(id: activeID) { await prewarm() }
        .onChange(of: posts.map(\.stableID)) { _, keys in
            if activeID == nil || !keys.contains(activeID ?? "") { activeID = keys.first }
        }
        .onDisappear { store.players.releaseAll() }
    }
    private func prewarm() async {
        guard let activeID, let index = posts.firstIndex(where: { $0.stableID == activeID }) else { return }
        let range = max(0, index - 1)...min(posts.count - 1, index + 1)
        store.players.retain(Set(range.map { posts[$0].stableID }))
        for i in range where i != index {
            let post = posts[i]
            if offline {
                if let url = URL(string: post.mediaUrl), url.isFileURL { store.players.prewarm(key: post.stableID, url: url) }
            } else if let resolved = try? await store.resolver.resolve(post), let url = URL(string: resolved.mediaUrl) {
                guard !Task.isCancelled else { return }
                store.players.prewarm(key: post.stableID, url: url)
            }
        }
        if !offline, index >= posts.count - 4 { await store.loadMore(immersive: true) }
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
    @State private var exposureStarted: Date?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let player {
                NativePlayerSurface(player: player, fill: store.immersionFraming, ready: $ready)
                    .opacity(ready ? 1 : 0)
            }
            if !ready || post.type == "image" || post.type == "gif" { PosterView(url: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl) }
            Color.clear.contentShape(Rectangle())
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { gesture in
                    switch gesture {
                    case .first: interacted = true; if store.favorites[post.stableID] == nil { store.toggleFavorite(post) }
                    case .second: playing.toggle(); playing ? player?.play() : player?.pause()
                    }
                })
            VStack {
                if let error { Text(error).padding().background(.ultraThinMaterial) }
                Spacer()
                HStack {
                    Button(store.favorites[post.stableID] == nil ? "Like" : "Liked") { interacted = true; store.toggleFavorite(post) }
                    if !offline {
                        Button("Less") { interacted = true; store.less(post) }
                        Button("Download") { store.download(post) }
                        Button { showComments = true } label: { Image(systemName: "bubble.left") }
                    }
                    Button { store.muted.toggle(); player?.isMuted = store.muted } label: { Image(systemName: store.muted ? "speaker.slash" : "speaker.wave.2") }
                }.buttonStyle(.bordered).padding(8).background(.ultraThinMaterial)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(post.tags.prefix(8), id: \.self) { tag in
                        Menu(tag) { Button("Add to search") { store.includeTag(tag) }; Button("Exclude from search") { store.excludeTag(tag) } }
                    } }
                }.padding(.horizontal)
                Rectangle().fill(.white.opacity(0.35)).frame(height: 32).overlay { Image(systemName: "arrow.left.and.right").foregroundStyle(.white) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                        guard let player, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
                        if scrubOrigin == nil { scrubOrigin = player.currentTime().seconds; player.pause() }
                        let seconds = max(0, min(duration, (scrubOrigin ?? 0) + Double(value.translation.width) / 300 * duration))
                        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                    }.onEnded { _ in scrubOrigin = nil; if playing { player?.play() } })
            }
        }
        .sheet(isPresented: $showComments) { CommentsView(post: post) }
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
        guard post.type != "image", post.type != "gif" else { return }
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
            let p = store.players.player(for: post.stableID, url: url)
            player = p; p.isMuted = store.muted
            let duration: Double
            if let asset = p.currentItem?.asset { duration = try await asset.load(.duration).seconds }
            else { duration = 0 }
            guard !Task.isCancelled else { return }
            if let resume = store.resumePosition(post.stableID), resume >= 0, duration.isFinite, duration > 0 {
                _ = await p.seek(to: CMTime(seconds: min(resume, max(0, duration - 1)), preferredTimescale: 600))
            } else if store.resumePosition(post.stableID) == nil, post.providerKey == .hanime, duration.isFinite, duration > 185 {
                _ = await p.seek(to: CMTime(seconds: 180, preferredTimescale: 600))
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
