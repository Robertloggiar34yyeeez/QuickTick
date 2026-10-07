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
    @State private var nativeSize: CGSize?
    @State private var comments = false
    @State private var tags = false
    @State private var fullImage = false
    @State private var player: AVPlayer?
    @State private var gifURL: URL?
    @State private var ready = false
    @State private var playing = false
    @State private var preparing = false
    @State private var mediaAspect: CGFloat = 4 / 3
    @State private var playbackError: String?
    @State private var watchSeconds = 0.0
    @State private var completion = 0.0
    private var playbackOwner: String { playbackTab == 2 ? "favorites" : "home" }
    private var mediaSize: CGSize { MediaSizing.size(native: nativeSize ?? post.nativeSize, aspect: (post.nativeSize.map { post.type.lowercased() == "image" && $0.height > $0.width * 4 ? 2 / 3 : $0.width / $0.height }) ?? mediaAspect, available: available) }
    var body: some View {
        VStack(spacing: 0) {
            media.frame(width: mediaSize.width, height: mediaSize.height).clipped()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("post-media-\(post.stableID)")
            if let playbackError { Text(playbackError).font(.caption).foregroundStyle(.orange).padding(8) }
            VStack(spacing: 8) {
                HStack {
                    Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button("View tags") { tags = true }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        .frame(minHeight: 44)
                }
                HStack(spacing: 0) {
                    ActionIcon(title: "Like", symbol: store.favorites[post.stableID] == nil ? "heart" : "heart.fill", selected: store.favorites[post.stableID] != nil) { store.toggleFavorite(post) }
                    ActionIcon(title: "Less", symbol: "hand.thumbsdown") { store.less(post) }
                    ActionIcon(title: "Download", symbol: "arrow.down.to.line") { store.download(post) }
                    ActionIcon(title: "Comments", symbol: "bubble.left") { comments = true }
                }
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
        }.frame(width: mediaSize.width).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07), lineWidth: 1))
            .sensoryFeedback(.selection, trigger: store.favorites[post.stableID] != nil)
            .sheet(isPresented: $comments) { CommentsView(post: post) }
            .sheet(isPresented: $tags) { PostTagsView(post: post) }
            .fullScreenCover(isPresented: $fullImage) { FullComicView(url: post.mediaUrl.isEmpty ? post.cardPreviewURL : post.mediaUrl) }
            .task(id: "\(store.inlinePlaybackID ?? ""): \(store.pausedPlaybackID ?? ""): \(store.isForeground): \(store.activeTab): \(store.feedRevision)") {
                guard !Task.isCancelled else { return }
                guard store.inlinePlaybackID == post.stableID, store.activeTab == playbackTab, store.isForeground else { stopPlayback(); return }
                await preparePlayback()
            }
            .onDisappear {
                // Home visibility owns the active ID. A delayed disappearance
                // from the outgoing tab must not clear a reactivated Home post.
                if playbackTab != 0 || store.activeTab != playbackTab || store.inlinePlaybackID != post.stableID { stopPlayback() }
            }
            .onReceive((player?.publisher(for: \.timeControlStatus).eraseToAnyPublisher()) ?? Just(AVPlayer.TimeControlStatus.paused).eraseToAnyPublisher()) { if player != nil { playing = $0 == .playing } }
            .onReceive((player?.currentItem?.publisher(for: \.status).eraseToAnyPublisher()) ?? Just(AVPlayerItem.Status.unknown).eraseToAnyPublisher()) { status in
                if status == .failed { playbackError = player?.currentItem?.error?.localizedDescription ?? "Video unavailable. Tap Play to retry."; playing = false; store.players.release(post.stableID) }
            }
            .onChange(of: comments) { _, shown in if shown { store.pausedPlaybackID = post.stableID; store.players.pause(post.stableID) } }
            .onChange(of: fullImage) { _, shown in if shown { store.players.pauseAll() } }
            .onChange(of: store.muted) { _, value in player?.isMuted = value }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
                guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
                if store.inlinePlaybackID == post.stableID, store.activeTab == 0, store.isForeground { store.recordComplete(post); store.recordReplay(post); player?.seek(to: .zero); if store.pausedPlaybackID != post.stableID { player?.play() } }
            }
    }

    @ViewBuilder private var media: some View {
        Group {
            if let player {
                ZStack {
                    PosterView(url: post.cardPreviewURL)
                    NativePlayerSurface(player: player, fill: false, ready: $ready)
                        .frame(width: mediaSize.width, height: mediaSize.height)
                        .opacity(ready ? 1 : 0)
                }.aspectRatio(mediaSize.width / max(1,mediaSize.height), contentMode: .fit)
            } else if let gifURL {
                AnimatedGIFSurface(url: gifURL, playing: playing, naturalAspect: true, onSize: { nativeSize = $0; mediaAspect = $0.width / max(1,$0.height) })
            } else if post.type.lowercased() == "image" {
                CachedMediaImage(url: post.cardPreviewURL, pixels: Int(mediaSize.width * 3), comic: true) { decoded in nativeSize = decoded.nativeSize; mediaAspect = CGFloat(decoded.image.width) / CGFloat(decoded.image.height) }
            } else { PosterView(url: post.cardPreviewURL) }
        }
        .frame(width: mediaSize.width, height: mediaSize.height)
        .overlay(alignment: .bottomTrailing) {
            if post.isImmersiveMedia {
                Button {
                    if store.inlinePlaybackID == post.stableID {
                        store.pausedPlaybackID = store.pausedPlaybackID == post.stableID ? nil : post.stableID
                    } else { store.inlinePlaybackID = post.stableID }
                } label: {
                    HStack(spacing: 8) {
                        if preparing { ProgressView() } else { Image(systemName: playing ? "pause.fill" : "play.fill") }
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
        .onTapGesture { if !post.isImmersiveMedia { fullImage = true } }
    }
    private func preparePlayback() async {
        preparing = true; playbackError = nil; playing = false
        defer { preparing = false; reportWatch() }
        do {
            let resolved = try await store.resolver.resolve(post)
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

private struct FullComicView: View {
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image { ComicZoomSurface(image: image).ignoresSafeArea(edges: .bottom) }
            else if let error { Text(error).foregroundStyle(.white).padding() }
            else { ProgressView("Loading full image").tint(.white) }
        }.overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }.buttonStyle(.plain).padding(12).accessibilityLabel("Close full image")
        }.task {
            do {
                guard let location = URL(string: url, relativeTo: QuicktickAPIClient.configuredBaseURL())?.absoluteURL else { throw URLError(.badURL) }
                let full = try await MediaImagePipeline.shared.fullImage(url: location)
                guard !Task.isCancelled else { return }
                image = UIImage(cgImage: full.image)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct ComicZoomSurface: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ComicScrollView { ComicScrollView(image: image) }
    func updateUIView(_ view: ComicScrollView, context: Context) {}
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
