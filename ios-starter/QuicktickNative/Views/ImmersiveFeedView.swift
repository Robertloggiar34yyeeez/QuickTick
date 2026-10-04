import SwiftUI
import AVKit
import ImageIO

struct ImmersiveFeedView: View {
    @EnvironmentObject private var store: AppStore
    let posts: [Post]
    let offline: Bool
    var onClose: (() -> Void)? = nil
    @State private var activeID: String?
    @State private var activeIndex = 0
    @State private var searchVisible = false
    @StateObject private var previews = ImmersivePreviewCache()

    private var mediaPosts: [Post] { posts.filter(\.isImmersiveMedia) }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(mediaPosts, id: \.stableID) { post in
                        ImmersiveItemView(post: post, offline: offline, active: activeID == post.stableID, previews: previews)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(post.stableID)
                    }
                }.scrollTargetLayout().frame(width: geo.size.width)
                if mediaPosts.isEmpty {
                    ContentUnavailableView(store.isLoading ? "Loading clips" : "No videos or GIFs", systemImage: "play.rectangle", description: Text(store.lastError ?? "Choose another source or search to find clips."))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }.scrollTargetBehavior(.paging)
                .scrollPosition(id: $activeID, anchor: .top)
                .scrollIndicators(.hidden)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .navigationTitle(offline ? "Offline Immersive" : "Immersive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Text(offline ? "Offline" : "Immersive").font(.headline)
                    HStack(spacing: 12) {
                    if let onClose { Button(action: onClose) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Back") }
                    if !offline && onClose == nil {
                        Menu { ForEach(Provider.allCases) { provider in
                            Button(provider.displayName) { store.selectedProvider = provider; Task { await store.refresh(immersive: true) } }
                        } } label: { Text(store.selectedProvider.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent) }
                    }
                    Spacer(minLength: 0)
                    if !offline {
                        Button { searchVisible.toggle() } label: { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Search")
                    }
                    }
                }.padding(.horizontal, 16).frame(height: 52)
                if searchVisible && !offline { NativeSearchBar(immersive: true).padding(.horizontal, 12).padding(.bottom, 8) }
            }.background(.ultraThinMaterial).overlay(alignment: .bottom) { Color.white.opacity(0.12).frame(height: 0.5) }
        }
        .task { if activeID == nil { activeID = mediaPosts.first?.stableID }; if !offline && posts.isEmpty { await store.refresh(immersive: true) } }
        .task(id: "\(activeID ?? ""):\(mediaPosts.count)") { await prewarm() }
        .onChange(of: mediaPosts.map(\.stableID)) { _, keys in
            if activeID == nil || !keys.contains(activeID ?? "") {
                activeID = keys.isEmpty ? nil : keys[min(activeIndex, keys.count - 1)]
                if keys.isEmpty { activeIndex = 0 }
            }
        }
        .onChange(of: activeID) { _, key in if let index = mediaPosts.firstIndex(where: { $0.stableID == key }) { activeIndex = index } }
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
        previews.retain(Set(range.map { clips[$0].stableID }))
        let offlineMode = offline
        let feedStore = store
        let resolver = store.resolver
        let pool = store.players
        let previewCache = previews
        await withTaskGroup(of: Void.self) { group in
            for i in range {
                let post = clips[i]
                group.addTask { await previewCache.load(post) }
            }
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
    @ObservedObject var previews: ImmersivePreviewCache
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var playing = true
    @State private var watched = 0.0
    @State private var reportedWatch = 0.0
    @State private var interacted = false
    @State private var progress = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var error: String?
    @State private var showComments = false
    @State private var showTags = false
    @State private var gifURL: URL?
    @State private var exposureStarted: Date?
    @State private var likePulse = false
    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .center) {
                AppTheme.canvas
                if let image = previews.images[post.stableID] {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped().blur(radius: 24)
                        .overlay(Color.black.opacity(0.25))
                }
                if let player {
                    NativePlayerSurface(player: player, fill: store.immersionFraming, ready: $ready)
                        .opacity(ready ? 1 : 0)
                }
                if post.type.lowercased() == "gif", active, let gifURL {
                    AnimatedGIFSurface(url: gifURL, playing: playing).allowsHitTesting(false)
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
                            playing.toggle(); playing ? player?.play() : player?.pause()
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
            .overlay(alignment: .bottomTrailing) { actionRail.padding(.trailing, 12).padding(.bottom, 100) }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5)
                        Spacer(minLength: 0)
                        Button("View tags") { showTags = true }.font(.caption.weight(.semibold))
                        Button { store.muted.toggle() } label: {
                            Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("Mute")
                    }.padding(.horizontal, 16).background(.ultraThinMaterial)
                    if post.type.lowercased() == "video" { timeline }
                }
            }
            .overlay(alignment: .top) {
                if let error { Text(error).font(.caption).padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding() }
                if active, !offline, let message = store.lastError {
                    Button { Task { await store.loadMore(immersive: true) } } label: {
                        VStack { Text(message); Text("Load more").bold() }.font(.caption).padding(12)
                    }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
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
        .task(id: active) {
            guard active else { endExposure(); player = nil; ready = false; gifURL = nil; return }
            exposureStarted = .now
            progress = 0; duration = 0; scrubbing = false; error = nil
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
        .onReceive(clock) { _ in
            guard active, !scrubbing, let player else { return }
            let seconds = player.currentTime().seconds
            let length = player.currentItem?.duration.seconds ?? 0
            guard seconds.isFinite, length.isFinite, length > 0 else { return }
            duration = length; progress = min(1, max(0, seconds / length))
        }
        .onDisappear { endExposure(); player = nil; ready = false; gifURL = nil }
        .onChange(of: store.muted) { _, value in player?.isMuted = value }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            if !offline { store.recordComplete(post); store.recordReplay(post) }
            player?.seek(to: .zero); if playing { player?.play() }
        }
    }

    private var actionRail: some View {
        VStack(spacing: 8) {
            railButton("Like", symbol: "heart.fill", selected: store.favorites[post.stableID] != nil) {
                interacted = true; store.toggleFavorite(post)
            }.accessibilityValue(store.favorites[post.stableID] == nil ? "Not liked" : "Liked")
            if !offline {
                railButton("Comments", symbol: "bubble.right.fill") { showComments = true }
                railButton("Less", symbol: "hand.thumbsdown.fill") { interacted = true; store.less(post) }
                railButton("Download", symbol: "arrow.down.to.line") { store.download(post) }
            }
        }.padding(6).background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
    }
    private func railButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 25, weight: .semibold))
                .foregroundStyle(selected ? Color.pink : .white)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .frame(width: 44, height: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityIdentifier(active ? "immersive-\(title)" : "inactive-\(title)-\(post.stableID)")
    }
    private var timeline: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: scrubbing ? 6 : 3)
                Capsule().fill(.white).frame(width: max(0, geo.size.width * progress), height: scrubbing ? 6 : 3)
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
        }.frame(height: 44).padding(.horizontal, 12).background(.ultraThinMaterial)
    }
    private func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }
    private func prepare() async {
        guard post.isImmersiveMedia else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
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
                p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            } else if store.resumePosition(post.stableID) == nil, post.providerKey == .hanime {
                p.seek(to: CMTime(seconds: 180, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
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
        } else if url.isEmpty {
            placeholder
        } else {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: placeholder
                default: placeholder.overlay { ProgressView().tint(.white) }
                }
            }
        }
    }
    private var placeholder: some View {
        AppTheme.canvas.aspectRatio(4/3, contentMode: .fit).overlay { Image(systemName: "play.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.25)) }
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
        let raw = post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl
        guard let url = URL(string: raw), !raw.isEmpty else { return }
        do {
            let data: Data
            if url.isFileURL { data = try Data(contentsOf: url) }
            else {
                let (body, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                data = body
            }
            guard !Task.isCancelled, retained.contains(key), data.count <= 8_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
            images[key] = UIImage(cgImage: thumbnail)
        } catch { /* Keep the gradient while a preview is unavailable. */ }
    }
}
