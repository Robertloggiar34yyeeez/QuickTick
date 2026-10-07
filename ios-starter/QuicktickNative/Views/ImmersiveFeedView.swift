import SwiftUI
import AVKit
import ImageIO

struct ImmersiveFeedView: View {
    @EnvironmentObject private var store: AppStore
    let posts: [Post]
    let offline: Bool
    var onClose: (() -> Void)? = nil
    @Binding var showSettings: Bool
    init(posts: [Post], offline: Bool, onClose: (() -> Void)? = nil, showSettings: Binding<Bool> = .constant(false)) {
        self.posts = posts; self.offline = offline; self.onClose = onClose
        _showSettings = showSettings
    }
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
                        ImmersiveItemView(post: post, offline: offline, active: activeID == post.stableID, presentationActive: offline || onClose != nil || store.activeTab == 1, previews: previews)
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
                        SettingsLauncher(isPresented: $showSettings)
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
        .onDisappear { if store.players.activeOwner == "immersive" { store.players.releaseAll() } }
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
    let presentationActive: Bool
    @ObservedObject var previews: ImmersivePreviewCache
    @State private var mediaSize: CGSize?
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
                    NativePlayerSurface(player: player, fill: geo.size.width <= 600 && store.immersionFraming, ready: $ready)
                        .frame(width: fittedSize(geo.size).width, height: fittedSize(geo.size).height)
                        .opacity(ready ? 1 : 0)
                }
                if post.type.lowercased() == "gif", active, let gifURL {
                    AnimatedGIFSurface(url: gifURL, playing: playing, onSize: { mediaSize = $0 }).frame(width: fittedSize(geo.size).width, height: fittedSize(geo.size).height).allowsHitTesting(false)
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
            .overlay(alignment: .bottomTrailing) { actionRail.padding(.trailing, geo.size.width > 600 ? max(16, (geo.size.width - fittedSize(geo.size).width) / 2 + 12) : 12).padding(.bottom, 100) }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5)
                        Spacer(minLength: 0)
                        Button("View tags") { showTags = true }.font(.caption.weight(.semibold))
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
        .task(id: "\(active):\(presentationActive):\(store.activeTab):\(store.isForeground):\(store.feedRevision)") {
            guard active, presentationActive, store.isForeground else { endExposure(); player = nil; ready = false; gifURL = nil; return }
            exposureStarted = .now
            progress = 0; duration = 0; scrubbing = false; error = nil
            await prepare()
            guard !Task.isCancelled else { return }
            if !offline { store.recordImpression(post) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                if player?.timeControlStatus == .playing || (gifURL != nil && playing) {
                    watched += 1
                    if !offline, watched - reportedWatch >= 10 {
                        store.recordWatch(post, seconds: watched - reportedWatch, completion: progress)
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
            guard active, presentationActive, store.isForeground, let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
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
                railButton("Less", symbol: "minus.circle") { interacted = true; store.less(post) }
                railButton("Comments", symbol: "bubble.right") { showComments = true }
                railButton("Download", symbol: "arrow.down.to.line") { store.download(post) }
            }
            railButton("Mute", symbol: store.muted ? "speaker.slash" : "speaker.wave.2") { store.muted.toggle() }
        }
    }
    private func railButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 25, weight: .semibold))
                .foregroundStyle(selected ? Color.pink : .white)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .frame(width: 48, height: 48).contentShape(Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityIdentifier(active ? "immersive-\(title)" : "inactive-\(title)-\(post.stableID)")
    }
    private var timeline: some View {
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
    }
    private func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
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
            guard !Task.isCancelled, active, presentationActive, store.isForeground else { return }
            if post.type.lowercased() == "gif" { gifURL = url; return }
            let p = store.players.activate(key: post.stableID, url: url, muted: store.muted, owner: "immersive")
            player = p; p.isMuted = store.muted
            // Start immediately. Duration metadata must never delay the first frame.
            if let resume = store.resumePosition(post.stableID), resume > 0 {
                p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            } else if store.resumePosition(post.stableID) == nil, post.providerKey == .hanime {
                p.seek(to: CMTime(seconds: 180, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            }
            if playing { p.play() }; error = nil
            if let asset = p.currentItem?.asset, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let actual = size.applying(transform)
                if !Task.isCancelled, active, abs(actual.height) > 0 { mediaSize = CGSize(width: abs(actual.width), height: abs(actual.height)) }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func fittedSize(_ available: CGSize) -> CGSize {
        if available.width <= 600 { return available }
        let size = mediaSize ?? post.nativeSize
        return MediaSizing.size(native: size, aspect: size.map { $0.width / max(1,$0.height) } ?? 4/3, available: available)
    }
    private func endExposure() {
        store.players.pause(post.stableID, owner: "immersive")
        guard let started = exposureStarted else { return }
        let elapsed = Date().timeIntervalSince(started)
        if let player, player.currentItem?.status == .readyToPlay { store.saveResume(post.stableID, seconds: player.currentTime().seconds) }
        if !offline {
            if watched - reportedWatch >= 2 { store.recordWatch(post, seconds: watched - reportedWatch, completion: progress) }
            if elapsed < 1.25 && !interacted { store.recordQuickSkip(post) }
        }
        watched = 0
        reportedWatch = 0
        exposureStarted = nil
    }
}

struct PosterView: View {
    let url: String
    var body: some View { CachedMediaImage(url: url, pixels: 1024) }
}

struct CachedMediaImage: View {
    let url: String
    var pixels = 1024
    var comic = false
    var onDecoded: ((DecodedMediaImage) -> Void)?
    @State private var decoded: DecodedMediaImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let decoded { Image(uiImage: UIImage(cgImage: decoded.image)).resizable().scaledToFit() }
            else { Color(white: 0.035).overlay { Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").foregroundStyle(.white.opacity(0.25)) } }
        }.task(id: "\(url):\(pixels):\(comic)") {
            decoded = nil; failed = false
            do { let image = try await MediaImagePipeline.shared.image(raw: url, pixels: pixels, comicPreview: comic); try Task.checkCancellation(); decoded = image; onDecoded?(image) }
            catch { if !Task.isCancelled { failed = !url.isEmpty } }
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
        do {
            let decoded = try await MediaImagePipeline.shared.image(raw: post.cardPreviewURL, pixels: 960)
            guard !Task.isCancelled, retained.contains(key) else { return }
            images[key] = UIImage(cgImage: decoded.image)
        } catch { /* Black fallback when the provider supplies no preview. */ }
    }
}
