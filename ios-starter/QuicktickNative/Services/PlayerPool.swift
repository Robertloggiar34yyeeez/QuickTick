import Foundation
import AVFoundation
import Combine

enum VideoIntroPolicy {
    static let hanimeSettingKey = "quicktick-skip-hanime-intros-v1"
    static func hanimeEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hanimeSettingKey) as? Bool ?? true
    }

    static func isPornhub(_ provider: String) -> Bool {
        provider.lowercased() == "pornhub"
    }

    static func isHanime(_ provider: String) -> Bool {
        provider.lowercased() == "hanime"
    }

    static func isHaven(_ provider: String) -> Bool {
        ["hhaven", "hentai haven", "hentaihaven"].contains(provider.lowercased())
    }

    static func enabled(provider: String, pornhub: Bool, haven: Bool,
                        hanime: Bool = false) -> Bool {
        isHaven(provider) ? haven : (isHanime(provider) ? hanime : (isPornhub(provider) && pornhub))
    }

    static func startTime(duration: Double, enabled: Bool, provider: String) -> Double {
        guard enabled, duration.isFinite, duration > 12 else { return 0 }
        if isHanime(provider) { return min(60, max(0, duration - 8)) }
        return isPornhub(provider) || isHaven(provider) ? 10 : 0
    }

    static func bufferedFrom(_ start: Double, ranges: [CMTimeRange], requiredSeconds: Double = 0.7) -> Bool {
        ranges.contains { range in
            let first = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            return first.isFinite && end.isFinite && first <= start + 0.2 && end >= start + requiredSeconds
        }
    }
}

enum VideoPlaybackPreferences {
    static let autoplayKey = "quicktick-video-autoplay-v1"
    // Existing installations must keep their current autoplay behaviour
    // unless the user explicitly disables it.
    static func autoplayEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoplayKey) as? Bool ?? true
    }

    // The Home-only autoplay preference must not disable the swipe-through
    // Immersive player or prevent it resuming after a brief app interruption.
    static func shouldResume(owner: String, defaults: UserDefaults = .standard) -> Bool {
        owner == "immersive" || owner.hasSuffix("-immersive") || autoplayEnabled(defaults)
    }
}

/// Full-screen video navigation shares one persisted interval across providers.
/// A double tap never seeks past the last playable fraction of a second.
enum FullscreenSeekPolicy {
    static let settingKey = "quicktick-fullscreen-double-tap-seconds-v1"
    static func target(current: Double, duration: Double, forward: Bool, interval: Int) -> Double? {
        guard current.isFinite else { return nil }
        let step = Double(min(60, max(1, interval)))
        let proposed = current + (forward ? step : -step)
        let upper = duration.isFinite && duration > 0 ? max(0, duration - 0.2) : Double.greatestFiniteMagnitude
        return max(0, min(upper, proposed))
    }
}

@MainActor
final class PlayerPool: ObservableObject {
    private var players: [String: AVPlayer] = [:]
    private var warmObservers: [String: NSKeyValueObservation] = [:]
    private var introObservers: [String: NSKeyValueObservation] = [:]
    private var introAttempts: [String: UUID] = [:]
    private var introSkipped = Set<String>()
    private var order: [String] = []
    private var urls: [String: URL] = [:]
    private var warming = Set<String>()
    private var warmAttempts: [String: UUID] = [:]
    private var prerollStarted = Set<String>()
    private var suspendedPlayback: (key: String, owner: String)?
    private(set) var activeKey: String?
    private(set) var activeOwner: String?
    var suspendedOwner: String? { suspendedPlayback?.owner }
    var capacity = 3
    var feedVolumeScale: Float = 1 {
        didSet { players.values.forEach { $0.volume = feedVolumeScale } }
    }
    var onPlaybackStart: (() -> Void)?
    func isPreparing(_ key: String) -> Bool { warming.contains(key) }
    func preparedURL(for key: String) -> URL? {
        guard let player = players[key], player.status != .failed,
              player.currentItem?.status != .failed else { return nil }
        return urls[key]
    }
    func transitionVisiblePost() {
        suspendedPlayback = nil
        if let activeKey {
            introAttempts.removeValue(forKey: activeKey)
            introObservers.removeValue(forKey: activeKey)
            players[activeKey]?.pause()
        }
        activeKey = nil; activeOwner = nil
    }

    /// Playback and downloads use the same public origin for official
    /// Pornhub CDN media. No account cookies or third-party proxy are used.
    private static func pornhubPlaybackHeaders(for url: URL) -> [String: String] {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "phncdn.com" || host.hasSuffix(".phncdn.com") ||
              host == "pornhub.com" || host.hasSuffix(".pornhub.com") else { return [:] }
        return ["Referer": "https://www.pornhub.com/",
                "User-Agent": NativeProviderAPI.userAgent]
    }

    func player(for key: String, url: URL) -> AVPlayer {
        if let existing = players[key], urls[key] == url,
           existing.status != .failed, existing.currentItem?.status != .failed { touch(key); return existing }
        release(key)
        let mediaHeaders = HanimeGeneratedAPI.mediaHeaders(for: url)
            .merging(EromeGeneratedAPI.mediaHeaders(for: url)) { _, new in new }
            .merging(Self.pornhubPlaybackHeaders(for: url)) { _, new in new }
        var assetOptions: [String: Any] = [:]
        if !mediaHeaders.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = mediaHeaders
        }
        if HanimeGeneratedAPI.permittedStreamURL(url) {
            // HLS variant playlists, segments and keys may be requested from
            // different first-party hosts. AVFoundation documents explicitly
            // supplementing cookies for these subrequests when necessary.
            // Never attach unrelated provider or third-party session cookies.
            let firstPartyCookies = (HTTPCookieStorage.shared.cookies ?? []).filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return domain == "hanime.tv" || domain.hasSuffix(".hanime.tv")
            }
            if !firstPartyCookies.isEmpty {
                assetOptions[AVURLAssetHTTPCookiesKey] = firstPartyCookies
            }
        }
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.volume = feedVolumeScale
        // Start explicitly below, but let AVFoundation resume after a network stall.
        player.automaticallyWaitsToMinimizeStalling = true
        players[key] = player; urls[key] = url; touch(key); trim()
        return player
    }

    func activate(key: String, url: URL, muted: Bool, owner: String = "home",
                  autoplay: Bool = true, onIntroReady: (@MainActor () -> Void)? = nil) -> AVPlayer {
        onPlaybackStart?()
        suspendedPlayback = nil
        // Feed transitions must preserve the next clips' pending prerolls.
        // pauseAll is reserved for tab/background transitions.
        for (otherKey, other) in players where otherKey != key && other.rate != 0 { other.pause() }
        activeKey = nil; activeOwner = nil
        let p = player(for: key, url: url)
        warmObservers.removeValue(forKey: key)
        introObservers.removeValue(forKey: key)
        introAttempts.removeValue(forKey: key)
        warmAttempts.removeValue(forKey: key); prerollStarted.remove(key)
        warming.remove(key)
        p.cancelPendingPrerolls()
        p.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        // Favor first frame latency for swipe-through playback. Longer
        // buffering remains AVFoundation's responsibility after startup.
        p.currentItem?.preferredForwardBufferDuration = url.isFileURL ? 0 : 1.5
        activeKey = key; activeOwner = owner; p.isMuted = muted
        p.volume = feedVolumeScale
        let provider = String(key.split(separator: ":", maxSplits: 1).first ?? "")
        let skipIntro = VideoIntroPolicy.enabled(provider: provider,
            pornhub: UserDefaults.standard.bool(forKey: "quicktick-skip-video-intros-v1"),
            haven: UserDefaults.standard.object(forKey: "quicktick-skip-hhaven-intros-v1") as? Bool ?? true,
            hanime: VideoIntroPolicy.hanimeEnabled())
        if skipIntro, !introSkipped.contains(key),
           p.currentItem != nil {
            // Crucially: never decode 0:00 and seek a playing video afterward.
            // Keep the poster visible while metadata, the seek, and the first
            // post-seek playable frame become ready.
            p.pause()
            scheduleIntroSkip(key: key, provider: provider, player: p,
                              autoplay: autoplay, onIntroReady: onIntroReady)
        } else {
            if autoplay { p.play() } else { p.pause() }
            onIntroReady?()
        }
        return p
    }
    private func scheduleIntroSkip(key: String, provider: String, player: AVPlayer, autoplay: Bool,
                                   onIntroReady: (@MainActor () -> Void)?) {
        guard let item = player.currentItem else { onIntroReady?(); return }
        let attempt = UUID()
        introAttempts[key] = attempt
        introObservers[key] = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            Task { @MainActor in
                guard let self, let player, self.players[key] === player,
                      self.activeKey == key, player.currentItem === item,
                      self.introAttempts[key] == attempt, item.status == .readyToPlay else { return }
                self.introObservers.removeValue(forKey: key)
                let loadedDuration = (try? await item.asset.load(.duration))?.seconds ?? 0
                // A VOD HLS playlist can initially report an indefinite
                // asset duration. Its seekable range still gives the intro
                // skip a safe end bound once AVPlayerItem is ready.
                let seekableEnd = item.seekableTimeRanges.map {
                    CMTimeRangeGetEnd($0.timeRangeValue).seconds
                }.filter { $0.isFinite && $0 > 0 }.max() ?? 0
                let duration = loadedDuration.isFinite && loadedDuration > 0
                    ? loadedDuration : seekableEnd
                let current = player.currentTime().seconds
                guard self.players[key] === player, self.activeKey == key,
                      self.introAttempts[key] == attempt else { return }
                let start = VideoIntroPolicy.startTime(duration: duration, enabled: true, provider: provider)
                if current.isFinite, current < 9.5, start > 0 {
                    let seeked = await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                            toleranceBefore: CMTime(seconds: 0.15, preferredTimescale: 600),
                            toleranceAfter: CMTime(seconds: 0.15, preferredTimescale: 600))
                    guard self.players[key] === player, self.activeKey == key,
                          self.introAttempts[key] == attempt else { return }
                    guard seeked else {
                        // A provider rejecting a timed intro seek must not
                        // leave autoplay permanently paused. Resume from its
                        // playable beginning and let the normal video layer
                        // report readiness.
                        self.introAttempts.removeValue(forKey: key)
                        if autoplay { player.play() }
                        onIntroReady?()
                        return
                    }
                    self.introSkipped.insert(key)
                    // Seeking a network URL is not the same as buffering the
                    // target segment. Let AVFoundation fill a short window
                    // while the poster stays on screen; cap the wait for
                    // servers that do not report meaningful time ranges.
                    if let url = self.urls[key], !url.isFileURL {
                        let deadline = Date().addingTimeInterval(5)
                        while self.players[key] === player, self.activeKey == key,
                              self.introAttempts[key] == attempt, Date() < deadline,
                              !VideoIntroPolicy.bufferedFrom(start,
                                  ranges: item.loadedTimeRanges.map(\.timeRangeValue)) {
                            do { try await Task.sleep(for: .milliseconds(120)) }
                            catch { return }
                        }
                    }
                }
                guard self.players[key] === player, self.activeKey == key,
                      self.introAttempts[key] == attempt else { return }
                if autoplay { player.play() }
                else { self.introAttempts.removeValue(forKey: key); onIntroReady?(); return }
                if start == 0 || !current.isFinite || current >= 9.5 {
                    self.introAttempts.removeValue(forKey: key)
                    onIntroReady?()
                    return
                }
                // Waiting for .readyToPlay or seek completion alone can still
                // expose the old 0:00 frame. Only reveal once playback advances
                // from the target time; the loop exits when the post deactivates.
                let revealDeadline = Date().addingTimeInterval(8)
                while self.players[key] === player, self.activeKey == key,
                      self.introAttempts[key] == attempt, Date() < revealDeadline {
                    let seconds = player.currentTime().seconds
                    if seconds.isFinite, seconds >= start - 0.2,
                       player.timeControlStatus == .playing {
                        self.introAttempts.removeValue(forKey: key)
                        onIntroReady?()
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                }
                if self.players[key] === player, self.activeKey == key,
                   self.introAttempts[key] == attempt {
                    // Some CDNs never update loadedTimeRanges reliably. The
                    // player may still buffer; don't keep the UI's intro
                    // gate closed indefinitely after starting playback.
                    self.introAttempts.removeValue(forKey: key)
                    onIntroReady?()
                }
            }
        }
    }
    func pauseAll() { suspendedPlayback = nil; introAttempts.removeAll(); introObservers.removeAll(); warmAttempts.removeAll(); prerollStarted.removeAll(); players.values.forEach { $0.pause(); $0.cancelPendingPrerolls() }; warming.removeAll(); warmObservers.removeAll(); activeKey = nil; activeOwner = nil }
    func suspendActivePlayback() {
        let saved: (key: String, owner: String)?
        if let key = activeKey, let owner = activeOwner, let player = players[key],
           player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { saved = (key, owner) }
        else { saved = nil }
        pauseAll()
        suspendedPlayback = saved
    }
    func resumeSuspendedPlayback(allowed: Set<String>, owner: String, muted: Bool, pausedKey: String?) {
        let saved = suspendedPlayback; suspendedPlayback = nil
        guard let saved, saved.owner == owner, allowed.contains(saved.key), saved.key != pausedKey,
              let player = players[saved.key], player.currentItem?.status != .failed, let url = urls[saved.key] else { return }
        guard VideoPlaybackPreferences.shouldResume(owner: owner) else { return }
        _ = activate(key: saved.key, url: url, muted: muted, owner: owner)
    }
    func pause(_ key: String, owner: String? = nil) { guard owner == nil || activeOwner == owner else { return }; introAttempts.removeValue(forKey: key); introObservers.removeValue(forKey: key); players[key]?.pause(); if activeKey == key { activeKey = nil; activeOwner = nil } }
    var count: Int { players.count }
    func prewarm(key: String, url: URL) {
        let p = player(for: key, url: url)
        guard p.rate == 0, activeKey != key, warming.insert(key).inserted else { return }
        let attempt = UUID(); warmAttempts[key] = attempt
        p.isMuted = true
        p.currentItem?.preferredForwardBufferDuration = 2
        // Preroll requires the PLAYER to be ready; item readiness can arrive first.
        // Always cross to the main actor before consuming readiness/ownership.
        warmObservers[key] = p.observe(\.status, options: [.initial, .new]) { [weak self, weak p] _, _ in
            Task { @MainActor in
                guard let self, let p, self.players[key] === p,
                      self.warming.contains(key), self.warmAttempts[key] == attempt, self.activeKey != key,
                      !self.prerollStarted.contains(key) else { return }
                guard p.status != .unknown else { return }
                self.warmObservers.removeValue(forKey: key)
                guard p.status == .readyToPlay, p.rate == 0 else { self.warming.remove(key); return }
                self.prerollStarted.insert(key)
                // Preroll is unsupported with automatic waiting enabled. It does
                // not play or advance the offscreen clip.
                p.automaticallyWaitsToMinimizeStalling = false
                p.preroll(atRate: 1) { [weak self, weak p] success in
                    Task { @MainActor in
                        guard let self, let p, self.players[key] === p, self.warmAttempts[key] == attempt, self.activeKey != key else { return }
                        if !success { self.warming.remove(key); self.prerollStarted.remove(key) }
                    }
                }
            }
        }
    }
    func release(_ key: String) { introAttempts.removeValue(forKey: key); introObservers.removeValue(forKey: key); introSkipped.remove(key); warmAttempts.removeValue(forKey: key); prerollStarted.remove(key); players[key]?.cancelPendingPrerolls(); if suspendedPlayback?.key == key { suspendedPlayback = nil }; if activeKey == key { activeKey = nil; activeOwner = nil }; warming.remove(key); urls.removeValue(forKey: key); warmObservers.removeValue(forKey: key); players.removeValue(forKey: key)?.pause(); order.removeAll { $0 == key } }
    func releaseAll() { pauseAll(); introAttempts.removeAll(); introObservers.removeAll(); introSkipped.removeAll(); urls.removeAll(); players.removeAll(); order.removeAll() }
    func retain(_ keys: Set<String>) {
        for key in Array(players.keys) where !keys.contains(key) {
            warmAttempts.removeValue(forKey: key); prerollStarted.remove(key); players[key]?.cancelPendingPrerolls(); release(key)
        }
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func trim() { while order.count > capacity { guard let key = order.first(where: { $0 != activeKey }) else { break }; release(key) } }
}
