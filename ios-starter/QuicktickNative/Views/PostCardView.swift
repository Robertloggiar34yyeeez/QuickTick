import SwiftUI
import AVKit
import ImageIO
import QuartzCore
import Combine

struct PostCardView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    var available = CGSize(width: 400, height: 800)
    var playbackTab = 0
    var offline = false
    var onDelete: (() -> Void)?
    @State private var nativeSize: CGSize?
    @State private var comments = false
    @State private var tags = false
    @State private var fullImage = false
    @State private var pendingVideoFullscreen = false
    @State private var player: AVPlayer?
    @State private var gifURL: URL?
    @State private var ready = false
    @State private var playing = false
    @State private var preparing = false
    @State private var mediaAspect: CGFloat = 4 / 3
    @State private var playbackError: String?
    @State private var watchSeconds = 0.0
    @State private var completion = 0.0
    private var playbackOwner: String { offline ? "downloads" : (playbackTab == 2 ? "favorites" : "home") }
    private var fullBleed: Bool { playbackTab == 0 && !offline }
    private var cardRadius: CGFloat { fullBleed ? 0 : 22 }
    private var mediaSize: CGSize {
        let aspect = (post.nativeSize.map {
            post.type.lowercased() == "image" && $0.height > $0.width * 4
                ? CGFloat(2) / 3 : $0.width / $0.height
        }) ?? mediaAspect
        return fullBleed
            ? MediaSizing.feedCard(aspect: aspect, available: available)
            : MediaSizing.size(native: nativeSize ?? post.nativeSize, aspect: aspect, available: available)
    }
    var body: some View {
        VStack(spacing: 0) {
            media.frame(width: mediaSize.width, height: mediaSize.height).clipped().contentShape(Rectangle())
                .background {
                    if playbackTab == 0 || playbackTab == 2 {
                        GeometryReader { geometry in
                            Color.clear.preference(key: HomeVisibleFrames.self, value: [post.stableID: geometry.frame(in: .named("home-viewport"))])
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("post-media-\(post.stableID)")
            if let playbackError { Text(playbackError).font(.caption).foregroundStyle(.orange).padding(8) }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(AppTheme.accent).frame(width: 6, height: 6)
                    Text(post.provider.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4).foregroundStyle(.white.opacity(0.85))
                    Text("·").foregroundStyle(AppTheme.secondaryLabel)
                    Text(post.isImmersiveMedia ? "Motion" : "Image")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    Spacer()
                    Button { tags = true } label: {
                        Label("Tags", systemImage: "number")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 11)
                            .frame(minHeight: 44)
                            .background(.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityLabel("View tags")
                }
                HStack(spacing: 0) {
                    if offline {
                        if let onDelete { ActionIcon(title: "Delete", symbol: "trash", action: onDelete) }
                    } else {
                    ActionIcon(title: "Like", symbol: store.favorites[post.stableID] == nil ? "heart" : "heart.fill", selected: store.favorites[post.stableID] != nil) { store.toggleFavorite(post) }
                    ActionIcon(title: "Less", symbol: "hand.thumbsdown") { store.less(post) }
                        .accessibilityIdentifier("dislike-\(post.stableID)")
                    ActionIcon(title: "Download", symbol: "arrow.down.to.line") { store.download(post) }
                    ActionIcon(title: "Comments", symbol: "bubble.left") { comments = true }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 7)
            .background(AppTheme.navigationSurface)
        }.frame(width: mediaSize.width).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius))
            .overlay(RoundedRectangle(cornerRadius: cardRadius).stroke(.white.opacity(0.07), lineWidth: 1))
            .sensoryFeedback(.selection, trigger: store.favorites[post.stableID] != nil)
            .sheet(isPresented: $comments) { CommentsView(post: post) }
            .sheet(isPresented: $tags) { PostTagsView(post: post) }
            .fullScreenCover(isPresented: $fullImage) { FullComicView(url: post.mediaUrl.isEmpty ? post.cardPreviewURL : post.mediaUrl,
                previewURL: post.cardPreviewURL) }
            .fullScreenCover(isPresented: Binding(
                get: { store.fullScreenPlaybackID == post.stableID },
                set: { if !$0 { store.fullScreenPlaybackID = nil } }
            ), onDismiss: {
                if store.isForeground, store.activeTab == playbackTab, store.pausedPlaybackID != post.stableID { player?.play() }
            }) {
                if let player { FullScreenVideoView(player: player, postID: post.stableID) { store.fullScreenPlaybackID = nil } }
            }
            .task(id: "\(store.inlinePlaybackID ?? ""): \(store.pausedPlaybackID ?? ""): \(store.isForeground): \(store.isStudioPresented): \(store.activeTab): \(store.feedRevision):\(store.isManualVisualScanRunning)") {
                guard !Task.isCancelled else { return }
                guard store.inlinePlaybackID == post.stableID, store.activeTab == playbackTab, store.isForeground, !store.isStudioPresented, !store.isManualVisualScanRunning else { stopPlayback(); return }
                await preparePlayback()
            }
            .onDisappear {
                // Home visibility owns the active ID. A delayed disappearance
                // from the outgoing tab must not clear a reactivated Home post.
                if store.fullScreenPlaybackID != post.stableID,
                   playbackTab != 0 || store.activeTab != playbackTab || store.inlinePlaybackID != post.stableID { stopPlayback() }
            }
            .onReceive((player?.publisher(for: \.timeControlStatus).eraseToAnyPublisher()) ?? Just(AVPlayer.TimeControlStatus.paused).eraseToAnyPublisher()) { if player != nil { playing = $0 == .playing } }
            .onReceive((player?.currentItem?.publisher(for: \.status).eraseToAnyPublisher()) ?? Just(AVPlayerItem.Status.unknown).eraseToAnyPublisher()) { status in
                if status == .failed { playbackError = player?.currentItem?.error?.localizedDescription ?? "Video unavailable. Tap Play to retry."; playing = false; store.players.release(post.stableID) }
            }
            .onChange(of: comments) { _, shown in if shown { store.pausedPlaybackID = post.stableID; store.players.pause(post.stableID) } }
            .onChange(of: fullImage) { _, shown in if shown { store.players.pauseAll() } }
            .onChange(of: player != nil) { _, exists in
                guard exists, pendingVideoFullscreen, store.activeTab == playbackTab else { return }
                pendingVideoFullscreen = false
                store.fullScreenPlaybackID = post.stableID
            }
            .onDisappear { pendingVideoFullscreen = false }
            .onChange(of: store.muted) { _, value in player?.isMuted = value }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
                guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
                if store.inlinePlaybackID == post.stableID, store.activeTab == 0, store.isForeground {
                    store.recordComplete(post); store.recordReplay(post)
                    let length = player?.currentItem?.duration.seconds ?? 0
                    let start = VideoIntroPolicy.startTime(duration: length, enabled: UserDefaults.standard.bool(forKey: "quicktick-skip-video-intros-v1"), provider: post.provider)
                    player?.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                    if store.pausedPlaybackID != post.stableID { player?.play() }
                }
            }
    }

    @ViewBuilder private var media: some View {
        Group {
            if let player, store.fullScreenPlaybackID != post.stableID {
                ZStack {
                    PosterView(url: post.cardPreviewURL) { store.notePreviewFingerprint(post, hash: $0.perceptualHash) }
                    NativePlayerSurface(player: player, fill: false, ready: $ready)
                        .frame(width: mediaSize.width, height: mediaSize.height)
                        .opacity(ready ? 1 : 0)
                }.aspectRatio(mediaSize.width / max(1,mediaSize.height), contentMode: .fit)
            } else if let gifURL {
                AnimatedGIFSurface(url: gifURL, playing: playing, naturalAspect: true, onSize: { nativeSize = $0; mediaAspect = $0.width / max(1,$0.height) })
            } else if post.type.lowercased() == "image" {
                CachedMediaImage(url: post.cardPreviewURL, preview: post.previewUrl == post.cardPreviewURL ? post.thumbUrl : post.previewUrl, pixels: Int(mediaSize.width * 3), comic: true, fill: true) { decoded in
                    nativeSize = decoded.nativeSize; mediaAspect = CGFloat(decoded.image.width) / CGFloat(decoded.image.height)
                    store.notePreviewFingerprint(post, hash: decoded.perceptualHash)
                }
            } else { PosterView(url: post.cardPreviewURL) { store.notePreviewFingerprint(post, hash: $0.perceptualHash) } }
        }
        .frame(width: mediaSize.width, height: mediaSize.height)
        .allowsHitTesting(false)
        .overlay {
            if post.type.lowercased() == "video" {
                Button {
                    if player != nil {
                        store.fullScreenPlaybackID = post.stableID
                    } else {
                        pendingVideoFullscreen = true
                        store.inlinePlaybackID = post.stableID
                    }
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open full screen video")
                .accessibilityIdentifier("fullscreen-\(post.stableID)")
            } else if !post.isImmersiveMedia {
                Color.clear.contentShape(Rectangle()).onTapGesture { fullImage = true }
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) {
            if post.isImmersiveMedia {
                Button {
                    if store.inlinePlaybackID == post.stableID {
                        store.pausedPlaybackID = store.pausedPlaybackID == post.stableID ? nil : post.stableID
                    } else { store.inlinePlaybackID = post.stableID }
                } label: {
                    HStack(spacing: 8) {
                        if preparing { InfinityLoader(size: 24) } else { Image(systemName: playing ? "pause.fill" : "play.fill") }
                        Text(playing ? "Pause" : "Play")
                    }.font(.subheadline.weight(.semibold)).padding(12).frame(minHeight: 44).background(.ultraThinMaterial, in: Capsule())
                }.disabled(preparing).buttonStyle(.plain).padding(10)
                    .accessibilityIdentifier("inline-play-\(post.stableID)")
                    .accessibilityLabel(playing ? "Pause media" : "Play media")
                    .accessibilityValue(playing ? "Playing" : "Paused")
            } else {
                Button { fullImage = true } label: {
                    Label("View full", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold)).padding(12).background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(.plain).padding(10).accessibilityLabel("View full image")
            }
        }
    }
    private func preparePlayback() async {
        preparing = true; playbackError = nil; playing = false
        defer { preparing = false; reportWatch() }
        do {
            let resolved: ResolvedMedia
            if offline {
                guard let local = URL(string: post.mediaUrl), local.isFileURL, FileManager.default.fileExists(atPath: local.path) else { throw APIError.server("Downloaded file is missing.") }
                resolved = ResolvedMedia(mediaUrl: post.mediaUrl, type: post.type)
            } else { resolved = try await store.resolver.resolve(post) }
            guard !Task.isCancelled, store.inlinePlaybackID == post.stableID, store.activeTab == playbackTab, store.isForeground, let url = URL(string: resolved.mediaUrl) else { return }
            if post.type.lowercased() == "gif" {
                gifURL = url; playing = store.pausedPlaybackID != post.stableID; preparing = false
                if playing, store.activeTab == 0 { store.recordImpression(post) }
                while !Task.isCancelled, store.inlinePlaybackID == post.stableID, store.activeTab == playbackTab, store.isForeground {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    if playing, store.activeTab == 0 { watchSeconds += 1; if watchSeconds >= 10 { reportWatch() } }
                }
                return
            }
            let p: AVPlayer
            if store.pausedPlaybackID == post.stableID { p = store.players.player(for: post.stableID, url: url); p.pause() }
            else { p = store.players.activate(key: post.stableID, url: url, muted: store.muted, owner: playbackOwner) }
            player = p; preparing = false
            // Start playback first; size discovery adjusts the card independently.
            if let asset = p.currentItem?.asset, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let display = size.applying(transform)
                if !Task.isCancelled, store.inlinePlaybackID == post.stableID, abs(display.height) > 0 { nativeSize = CGSize(width: abs(display.width), height: abs(display.height)); mediaAspect = abs(display.width / display.height) }
            }
            if store.pausedPlaybackID != post.stableID, store.activeTab == 0 { store.recordImpression(post) }
            while !Task.isCancelled, store.inlinePlaybackID == post.stableID, store.activeTab == playbackTab, store.isForeground {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                if p.timeControlStatus == .playing, store.activeTab == 0 {
                    watchSeconds += 1
                    let length = p.currentItem?.duration.seconds ?? 0
                    if length.isFinite, length > 0 { completion = min(1,max(0,p.currentTime().seconds / length)) }
                    if watchSeconds >= 10 { reportWatch() }
                }
            }
        } catch { if !Task.isCancelled { playbackError = error.localizedDescription; playing = false } }
    }
    private func reportWatch() {
        if watchSeconds >= 2 { store.recordWatch(post, seconds: watchSeconds, completion: completion) }
        watchSeconds = 0
    }
    private func stopPlayback() { store.players.pause(post.stableID, owner: playbackOwner); player = nil; gifURL = nil; ready = false; playing = false }
}

private struct FullScreenVideoView: View {
    @EnvironmentObject private var store: AppStore
    let player: AVPlayer
    let postID: String
    let onClose: () -> Void
    var body: some View {
        FullScreenPlayerController(player: player, onSwipeDown: {
            store.pausedPlaybackID = player.timeControlStatus == .paused ? postID : nil
            onClose()
        }).ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button {
                    store.pausedPlaybackID = player.timeControlStatus == .paused ? postID : nil
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .bold))
                        .frame(width: 48, height: 48).background(.black.opacity(0.7), in: Circle())
                }.buttonStyle(.plain).foregroundStyle(.white).padding(12).accessibilityLabel("Close full screen video")
            }
            .background(.black)
            .quicktickEdgeBack {
                store.pausedPlaybackID = player.timeControlStatus == .paused ? postID : nil
                onClose()
            }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                guard store.isForeground, store.fullScreenPlaybackID == postID else { return }
                if status == .playing { store.pausedPlaybackID = nil }
                else if status == .paused { store.pausedPlaybackID = postID }
            }
            .onChange(of: store.isForeground) { _, foreground in
                if foreground, store.pausedPlaybackID != postID { player.play() }
            }
    }
}

// Attach the gesture to the native UIKit player rather than an overlay:
// AVPlayerViewController intercepts drags before SwiftUI's overlay sees them.
private final class FullscreenSwipeDownHandler: NSObject, UIGestureRecognizerDelegate {
    var onExit: () -> Void
    private var didExit = false
    init(onExit: @escaping () -> Void) { self.onExit = onExit }

    func install(on view: UIView, addSwipe: Bool = false) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        if addSwipe {
            // AVKit uses internal gesture recognizers and occasionally prevents
            // our pan from ending. A simultaneous downward swipe is the fallback.
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe(_:)))
            swipe.direction = .down
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = gestureRecognizer.view else { return false }
        if gestureRecognizer is UISwipeGestureRecognizer { return !(view is ComicScrollView) }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        // Do not interfere with AVKit's horizontal scrubbing or image zoom.
        // Recognize only a clearly downward, one-finger dismissal pan.
        // Videos may be dismissed from the center. A regular image uses the
        // same gesture at its minimum zoom; zoomed images must remain pannable.
        // Long comics never install this recognizer at all.
        if let scroll = view as? ComicScrollView,
           scroll.zoomScale > scroll.minimumZoomScale + 0.025 { return false }
        return velocity.y > 20
            && abs(velocity.y) > abs(velocity.x) * 1.15
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, let view = gesture.view else { return }
        let offset = gesture.translation(in: view)
        guard offset.y > 75, abs(offset.x) < offset.y * 0.72 else { return }
        exitOnce()
    }
    @objc private func didSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended else { return }
        exitOnce()
    }
    private func exitOnce() {
        guard !didExit else { return }
        didExit = true
        onExit()
    }
}

private struct FullScreenPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let onSwipeDown: () -> Void
    func makeCoordinator() -> FullscreenSwipeDownHandler { FullscreenSwipeDownHandler(onExit: onSwipeDown) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        context.coordinator.install(on: controller.view, addSwipe: true)
        if let overlay = controller.contentOverlayView { context.coordinator.install(on: overlay, addSwipe: true) }
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        context.coordinator.onExit = onSwipeDown
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: FullscreenSwipeDownHandler) {
        controller.player = nil
    }
}

private struct FullComicView: View {
    let url: String
    let previewURL: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var preview: UIImage?
    @State private var comic = false
    @State private var error: String?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ComicZoomSurface(image: image, isComic: comic, onSwipeDown: { dismiss() })
                    .ignoresSafeArea(edges: .bottom)
            } else if let preview {
                Image(uiImage: preview).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 7) { InfinityLoader(size: 25); Text("Loading full resolution").font(.caption) }
                            .padding(10).background(.black.opacity(0.65), in: Capsule())
                            .padding(.bottom, 20)
                    }
            } else if let error { Text(error).foregroundStyle(.white).padding() }
            else { VStack(spacing: 8) { InfinityLoader(size: 50); Text("Loading full image").font(.caption) }.foregroundStyle(.white) }
        }.overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }.buttonStyle(.plain).padding(12).accessibilityLabel("Close full image")
        }
        .quicktickEdgeBack { dismiss() }
        // Reuse the card's bounded decoded thumbnail from MediaImagePipeline.
        // A preview can appear immediately while the original loads separately.
        .task(id: previewURL) {
            guard !previewURL.isEmpty else { return }
            if let warm = await MediaImagePipeline.shared.cachedPreview(raw: previewURL) {
                if !Task.isCancelled, image == nil { preview = UIImage(cgImage: warm.image) }
                return
            }
            if let decoded = try? await MediaImagePipeline.shared.image(
                raw: previewURL, pixels: 1024, comicPreview: true),
               !Task.isCancelled, image == nil {
                preview = UIImage(cgImage: decoded.image)
            }
        }
        .task(id: url) {
            do {
                guard let location = (URL(string: url)?.isFileURL == true ? URL(string: url) : NativeProviderAPI.mediaURL(url)) else { throw URLError(.badURL) }
                let full = try await MediaImagePipeline.shared.fullImage(url: location)
                guard !Task.isCancelled else { return }
                comic = full.comic
                image = UIImage(cgImage: full.image)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { preview = nil; image = nil }
    }
}

private struct ComicZoomSurface: UIViewRepresentable {
    let image: UIImage
    let isComic: Bool
    let onSwipeDown: () -> Void
    func makeCoordinator() -> FullscreenSwipeDownHandler { FullscreenSwipeDownHandler(onExit: onSwipeDown) }
    func makeUIView(context: Context) -> ComicScrollView {
        let view = ComicScrollView(image: image)
        // Long comics keep their ordinary vertical scrolling gestures.
        // Regular images can be dismissed with a downward drag from the middle.
        if !isComic { context.coordinator.install(on: view) }
        return view
    }
    func updateUIView(_ view: ComicScrollView, context: Context) {
        context.coordinator.onExit = onSwipeDown
    }
}

private final class ComicScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: ComicTileView
    private let imageSize: CGSize
    private var previousSize = CGSize.zero
    init(image: UIImage) {
        imageView = ComicTileView(image: image); imageSize = image.size
        super.init(frame: .zero)
        delegate = self; backgroundColor = .black; showsHorizontalScrollIndicator = false
        imageView.frame = CGRect(origin: .zero, size: image.size); addSubview(imageView)
        contentSize = image.size; bouncesZoom = true
        accessibilityIdentifier = "full-comic-zoom"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if previousSize != bounds.size {
            previousSize = bounds.size
            // Fit to width: tall comic strips can be read immediately by scrolling.
            minimumZoomScale = min(1, bounds.width / max(1, imageSize.width))
            maximumZoomScale = max(4, minimumZoomScale * 8)
            setZoomScale(minimumZoomScale, animated: false)
        }
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

// Draw visible regions rather than putting the entire long comic in one
// backing bitmap. The original CGImage stays uncached and retains full detail.
private final class ComicTileView: UIView {
    private nonisolated let tileImage: ComicTileImage
    override class var layerClass: AnyClass { CATiledLayer.self }
    init(image: UIImage) {
        tileImage = ComicTileImage(image: image.cgImage, size: image.size, scale: image.scale)
        super.init(frame: CGRect(origin: .zero, size: image.size))
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 256, height: 256)
            tiled.levelsOfDetail = 8; tiled.levelsOfDetailBias = 3
        }
        isOpaque = true; backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    nonisolated override func draw(_ rect: CGRect) {
        // CATiledLayer invokes drawing on worker threads. Read only immutable
        // image data here; UIView geometry and SwiftUI state stay on MainActor.
        guard let context = UIGraphicsGetCurrentContext(), let full = tileImage.image else { return }
        let region = rect.intersection(CGRect(origin: .zero, size: tileImage.size))
        guard !region.isEmpty, let tile = full.cropping(to: CGRect(x: region.minX * tileImage.scale, y: region.minY * tileImage.scale, width: region.width * tileImage.scale, height: region.height * tileImage.scale)) else { return }
        context.saveGState(); context.translateBy(x: region.minX, y: region.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(tile, in: CGRect(origin: .zero, size: region.size)); context.restoreGState()
    }
}

private struct ComicTileImage: @unchecked Sendable {
    let image: CGImage?
    let size: CGSize
    let scale: CGFloat
}
