import SwiftUI
import AVKit
import ImageIO
import QuartzCore
import Combine

struct PostCardView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    var available = CGSize(width: 400, height: 800)
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
    private var mediaSize: CGSize { MediaSizing.size(native: nativeSize ?? post.nativeSize, aspect: (post.nativeSize.map { post.type.lowercased() == "image" && $0.height > $0.width * 4 ? 2 / 3 : $0.width / $0.height }) ?? mediaAspect, available: available) }
    var body: some View {
        VStack(spacing: 0) {
            media.frame(width: mediaSize.width, height: mediaSize.height).clipped()
            if let playbackError { Text(playbackError).font(.caption).foregroundStyle(.orange).padding(8) }
            VStack(spacing: 8) {
                HStack {
                    Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button("View tags") { tags = true }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
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
            .sheet(isPresented: $comments) { CommentsView(post: post) }
            .sheet(isPresented: $tags) { PostTagsView(post: post) }
            .fullScreenCover(isPresented: $fullImage) { FullComicView(url: post.mediaUrl.isEmpty ? post.cardPreviewURL : post.mediaUrl) }
            .task(id: "\(store.inlinePlaybackID ?? ""): \(store.pausedPlaybackID ?? ""): \(store.isForeground): \(store.activeTab): \(store.feedRevision)") {
                guard store.inlinePlaybackID == post.stableID, store.activeTab == 0, store.isForeground else { stopPlayback(); return }
                await preparePlayback()
            }
            .onDisappear { stopPlayback(); if store.inlinePlaybackID == post.stableID { store.inlinePlaybackID = nil } }
            .onReceive((player?.publisher(for: \.timeControlStatus).eraseToAnyPublisher()) ?? Just(AVPlayer.TimeControlStatus.paused).eraseToAnyPublisher()) { playing = $0 == .playing }
            .onReceive((player?.currentItem?.publisher(for: \.status).eraseToAnyPublisher()) ?? Just(AVPlayerItem.Status.unknown).eraseToAnyPublisher()) { status in
                if status == .failed { playbackError = player?.currentItem?.error?.localizedDescription ?? "Video unavailable. Tap Play to retry."; playing = false; store.players.release(post.stableID) }
            }
            .onChange(of: comments) { _, shown in if shown { store.pausedPlaybackID = post.stableID; store.players.pause(post.stableID) } }
            .onChange(of: fullImage) { _, shown in if shown { store.players.pauseAll() } }
            .onChange(of: store.muted) { _, value in player?.isMuted = value }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
                guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
                player?.seek(to: .zero); if playing { player?.play() }
            }
    }

    @ViewBuilder private var media: some View {
        Group {
            if let player {
                ZStack {
                    PosterView(url: post.cardPreviewURL)
                    NativePlayerSurface(player: player, fill: false, ready: $ready).opacity(ready ? 1 : 0)
                }.aspectRatio(mediaAspect, contentMode: .fit)
            } else if let gifURL {
                AnimatedGIFSurface(url: gifURL, playing: playing, naturalAspect: true)
            } else if post.type.lowercased() == "image" {
                CachedMediaImage(url: post.cardPreviewURL, pixels: Int(mediaSize.width * 3), comic: true) { decoded in nativeSize = decoded.nativeSize; mediaAspect = CGFloat(decoded.image.width) / CGFloat(decoded.image.height) }
            } else { PosterView(url: post.cardPreviewURL) }
        }
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
                    }.font(.subheadline.weight(.semibold)).padding(12).background(.ultraThinMaterial, in: Capsule())
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
        defer { preparing = false }
        do {
            let resolved = try await store.resolver.resolve(post)
            guard !Task.isCancelled, store.inlinePlaybackID == post.stableID, let url = URL(string: resolved.mediaUrl) else { return }
            if post.type.lowercased() == "gif" { gifURL = url; playing = store.pausedPlaybackID != post.stableID; return }
            let p: AVPlayer
            if store.pausedPlaybackID == post.stableID { p = store.players.player(for: post.stableID, url: url); p.pause() }
            else { p = store.players.activate(key: post.stableID, url: url, muted: store.muted) }
            player = p; preparing = false
            // Start playback first; size discovery adjusts the card independently.
            if let asset = p.currentItem?.asset, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let display = size.applying(transform)
                if !Task.isCancelled, store.inlinePlaybackID == post.stableID, abs(display.height) > 0 { nativeSize = CGSize(width: abs(display.width), height: abs(display.height)); mediaAspect = abs(display.width / display.height) }
            }
        } catch { if !Task.isCancelled { playbackError = error.localizedDescription; playing = false } }
    }
    private func stopPlayback() { store.players.pause(post.stableID); player?.pause(); player = nil; gifURL = nil; ready = false; playing = false }
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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 1500)).image { context in
                        UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 1500))
                    }
                    return
                }
                #endif
                guard let location = URL(string: url, relativeTo: QuicktickAPIClient.configuredBaseURL())?.absoluteURL else { throw URLError(.badURL) }
                let data: Data
                if location.isFileURL { data = try Data(contentsOf: location) }
                else {
                    let (body, response) = try await URLSession.shared.data(from: location)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                    data = body
                }
                guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let full = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw APIError.server("Full image could not be decoded.") }
                image = UIImage(cgImage: full)
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
