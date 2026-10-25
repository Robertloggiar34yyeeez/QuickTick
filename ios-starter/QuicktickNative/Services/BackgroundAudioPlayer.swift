import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

/// Independent of the video pool: audio persists when the feed changes or
/// iOS backgrounds the app. A single shared instance owns the current track.
@MainActor final class BackgroundAudioPlayer: ObservableObject {
    @Published private(set) var currentPost: Post?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    private var player: AVPlayer?
    private var observer: Any?
    private var remoteInstalled = false

    func toggle(_ post: Post) {
        guard post.isAudio else { return }
        if currentPost?.stableID == post.stableID {
            isPlaying ? pause() : resume()
            return
        }
        stop()
        guard let url = URL(string: post.mediaUrl),
              url.isFileURL || url.scheme?.lowercased() == "https",
              !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            error = "Audio file is not accessible."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            installRemoteCommands()
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            currentPost = post
            error = nil
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                       queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, let current = self.player else { return }
                    if time.seconds.isFinite { self.elapsed = max(0, time.seconds) }
                    let length = current.currentItem?.duration.seconds ?? 0
                    if length.isFinite && length > 0 { self.duration = length }
                    self.updateNowPlaying()
                }
            }
            resume()
        } catch { self.error = error.localizedDescription; stop(clearError: false) }
    }

    func resume() { player?.play(); isPlaying = player != nil; updateNowPlaying() }
    func pause() { player?.pause(); isPlaying = false; updateNowPlaying() }
    func skip(_ seconds: Double) { seek(to: elapsed + seconds) }
    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        elapsed = target; updateNowPlaying()
    }
    func stop(clearError: Bool = true) {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause(); player = nil
        currentPost = nil; isPlaying = false; elapsed = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if clearError { error = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func installRemoteCommands() {
        guard !remoteInstalled else { return }
        remoteInstalled = true
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }; return .success
        }
        remote.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }; return .success
        }
        remote.skipForwardCommand.preferredIntervals = [15]
        remote.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(15) }; return .success
        }
        remote.skipBackwardCommand.preferredIntervals = [15]
        remote.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(-15) }; return .success
        }
    }
    private func updateNowPlaying() {
        guard let post = currentPost else { return }
        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: post.caption?.isEmpty == false ? (post.caption ?? "Audio") : "Audio · \(post.provider)",
            MPMediaItemPropertyArtist: post.creator ?? post.provider,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if duration > 0 { metadata[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = metadata
    }
}

struct AudioPostPlayButton: View {
    @ObservedObject var audio: BackgroundAudioPlayer
    let post: Post
    private var active: Bool { audio.currentPost?.stableID == post.stableID }
    var body: some View {
        Button { audio.toggle(post) } label: {
            Image(systemName: active && audio.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 50, height: 50)
                .foregroundStyle(.white)
                .background(AppTheme.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active && audio.isPlaying ? "Pause audio" : "Play audio")
        .accessibilityIdentifier("audio-play-\(post.stableID)")
    }
}

struct BackgroundAudioMiniPlayer: View {
    @ObservedObject var audio: BackgroundAudioPlayer
    var body: some View {
        if let post = audio.currentPost {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.caption?.isEmpty == false ? (post.caption ?? "Audio") : "Audio")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Text(post.creator ?? post.provider)
                            .font(.system(size: 10)).foregroundStyle(AppTheme.secondaryLabel).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button { audio.skip(-15) } label: { Image(systemName: "gobackward.15") }
                        .accessibilityLabel("Back 15 seconds")
                    Button { audio.isPlaying ? audio.pause() : audio.resume() } label: {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").frame(width: 35, height: 35)
                    }.accessibilityLabel(audio.isPlaying ? "Pause audio" : "Play audio")
                    Button { audio.stop() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .accessibilityLabel("Close audio player")
                }
                .buttonStyle(.plain)
                if audio.duration > 0 {
                    Slider(value: Binding(get: { audio.elapsed }, set: { audio.seek(to: $0) }),
                           in: 0...max(0.1, audio.duration))
                        .tint(AppTheme.accent).accessibilityLabel("Audio progress")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(AppTheme.navigationSurface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.border))
            .accessibilityIdentifier("background-audio-controls")
        }
    }
}
