import SwiftUI
import AVKit

/// In-app floating playback (not the system background PiP entitlement).
/// Its AVPlayer survives tab remounts and keeps the same time in full screen.
struct FloatingPiPView: View {
    @EnvironmentObject private var store: AppStore
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var width: CGFloat = 230
    @State private var playing = true

    var body: some View {
        Group {
            if let player = store.pipPlayer {
                VStack(spacing: 0) {
                    VideoPlayer(player: player)
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                        .onTapGesture(count: 2) { store.pipFullscreen = true }
                    HStack(spacing: 3) {
                        Button {
                            if playing { player.pause() } else { player.play() }
                            playing.toggle()
                        } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                            .accessibilityLabel(playing ? "Pause floating video" : "Play floating video")
                        Spacer(minLength: 0)
                        Button { width = max(170, width - 35) } label: { Image(systemName: "minus.magnifyingglass") }
                            .accessibilityLabel("Shrink floating video")
                        Button { width = min(340, width + 35) } label: { Image(systemName: "plus.magnifyingglass") }
                            .accessibilityLabel("Enlarge floating video")
                        Button { store.pipFullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityLabel("Return floating video to full screen")
                        Button { store.closeFloatingVideo() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close floating video")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(AppTheme.navigationSurface)
                }
                .frame(width: width)
                .background(.black, in: RoundedRectangle(cornerRadius: 15))
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppTheme.accent.opacity(0.65)))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 7)
                .padding(12)
                .offset(offset)
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        offset = CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = offset })
                .accessibilityIdentifier("floating-pip-video")
                .fullScreenCover(isPresented: $store.pipFullscreen) {
                    ZStack(alignment: .topTrailing) {
                        Color.black.ignoresSafeArea()
                        VideoPlayer(player: player).ignoresSafeArea(edges: .horizontal)
                        Button {
                            store.pipFullscreen = false
                        } label: {
                            Label("Return to floating window", systemImage: "pip.exit")
                                .padding(12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(20)
                    }
                }
            }
        }
    }
}
