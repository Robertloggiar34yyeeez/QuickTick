import SwiftUI
import AVKit
import Combine

/// In-app floating playback (not the system background PiP entitlement).
/// Its AVPlayer survives tab remounts and keeps the same time in full screen.
struct FloatingPiPView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var width: CGFloat = 244
    @State private var playing = true
    @State private var videoReady = false

    private let radius: CGFloat = 23

    private func control(_ symbol: String, name: String, prominent: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: prominent ? 38 : 32, height: prominent ? 38 : 32)
                .background(prominent ? AppTheme.accent.opacity(0.88) : .black.opacity(0.49), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    var body: some View {
        Group {
            if let player = store.pipPlayer {
                ZStack {
                    NativePlayerSurface(player: player, fill: false, ready: $videoReady,
                                        accessibilityID: "floating-pip-frame")
                        .frame(width: width, height: width * 9 / 16)
                        .background(.black)
                        .onTapGesture(count: 2) { store.pipFullscreen = true }

                    LinearGradient(colors: [.black.opacity(0.72), .clear, .black.opacity(0.73)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "pip.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                            Text("FLOATING")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.88))
                            Spacer(minLength: 0)
                            control("xmark", name: "Close floating video") { store.closeFloatingVideo() }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 5) {
                            control(playing ? "pause.fill" : "play.fill",
                                    name: playing ? "Pause floating video" : "Play floating video",
                                    prominent: true) {
                                if playing { player.pause() } else { player.play() }
                                playing.toggle()
                            }
                            Spacer(minLength: 0)
                            control("minus", name: "Shrink floating video") {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                                    width = max(220, width - 32)
                                }
                            }
                            control("plus", name: "Enlarge floating video") {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                                    width = min(340, width + 32)
                                }
                            }
                            control("arrow.up.left.and.arrow.down.right", name: "Return floating video to full screen") {
                                store.pipFullscreen = true
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(width: width, height: width * 9 / 16)
                .background(.black, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
                .shadow(color: AppTheme.accent.opacity(0.16), radius: 13, y: 1)
                .padding(14)
                .offset(offset)
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        offset = CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = offset })
                .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                    playing = status == .playing
                }
                .accessibilityIdentifier("floating-pip-video")
                .fullScreenCover(isPresented: $store.pipFullscreen) {
                    ZStack(alignment: .topTrailing) {
                        Color.black.ignoresSafeArea()
                        VideoPlayer(player: player).ignoresSafeArea(edges: .horizontal)
                        Button {
                            store.pipFullscreen = false
                        } label: {
                            Label("Return to floating window", systemImage: "pip.exit")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.22)))
                        }
                        .padding(20)
                    }
                }
            }
        }
    }
}
