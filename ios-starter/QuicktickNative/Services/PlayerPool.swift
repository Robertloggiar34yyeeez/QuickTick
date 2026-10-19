import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerPool: ObservableObject {
    private var players: [String: AVPlayer] = [:]
    private var warmObservers: [String: NSKeyValueObservation] = [:]
    private var order: [String] = []
    private var urls: [String: URL] = [:]
    private var warming = Set<String>()
    private var suspendedPlayback: (key: String, owner: String)?
    private(set) var activeKey: String?
    private(set) var activeOwner: String?
    var capacity = 3

    func player(for key: String, url: URL) -> AVPlayer {
        if let existing = players[key], urls[key] == url { touch(key); return existing }
        release(key)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        // Start explicitly below, but let AVFoundation resume after a network stall.
        player.automaticallyWaitsToMinimizeStalling = true
        players[key] = player; urls[key] = url; touch(key); trim()
        return player
    }

    func activate(key: String, url: URL, muted: Bool, owner: String = "home") -> AVPlayer {
        suspendedPlayback = nil
        // Feed transitions must preserve the next clips' pending prerolls.
        // pauseAll is reserved for tab/background transitions.
        for (otherKey, other) in players where otherKey != key && other.rate != 0 { other.pause() }
        activeKey = nil; activeOwner = nil
        let p = player(for: key, url: url)
        warmObservers.removeValue(forKey: key)
        warming.remove(key)
        p.cancelPendingPrerolls()
        p.automaticallyWaitsToMinimizeStalling = true
        p.currentItem?.preferredForwardBufferDuration = 6
        activeKey = key; activeOwner = owner; p.isMuted = muted
        p.playImmediately(atRate: 1)
        return p
    }
    func pauseAll() { suspendedPlayback = nil; players.values.forEach { $0.pause(); $0.cancelPendingPrerolls() }; warming.removeAll(); warmObservers.removeAll(); activeKey = nil; activeOwner = nil }
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
        _ = activate(key: saved.key, url: url, muted: muted, owner: owner)
    }
    func pause(_ key: String, owner: String? = nil) { guard owner == nil || activeOwner == owner else { return }; players[key]?.pause(); if activeKey == key { activeKey = nil; activeOwner = nil } }
    var count: Int { players.count }
    func prewarm(key: String, url: URL) {
        let p = player(for: key, url: url)
        guard p.rate == 0, activeKey != key, warming.insert(key).inserted else { return }
        p.isMuted = true
        p.currentItem?.preferredForwardBufferDuration = 2
        // Preroll requires the PLAYER to be ready; item readiness can arrive first.
        // Always cross to the main actor before consuming readiness/ownership.
        warmObservers[key] = p.observe(\.status, options: [.initial, .new]) { [weak self, weak p] _, _ in
            Task { @MainActor in
                guard let self, let p, self.players[key] === p,
                      self.warming.contains(key), self.activeKey != key else { return }
                guard p.status != .unknown else { return }
                self.warmObservers.removeValue(forKey: key)
                guard p.status == .readyToPlay, p.rate == 0 else { self.warming.remove(key); return }
                // Preroll is unsupported with automatic waiting enabled. It does
                // not play or advance the offscreen clip.
                p.automaticallyWaitsToMinimizeStalling = false
                p.preroll(atRate: 1) { [weak self, weak p] success in
                    Task { @MainActor in
                        guard let self, let p, self.players[key] === p, self.activeKey != key else { return }
                        if !success { self.warming.remove(key) }
                    }
                }
            }
        }
    }
    func release(_ key: String) { if suspendedPlayback?.key == key { suspendedPlayback = nil }; if activeKey == key { activeKey = nil; activeOwner = nil }; warming.remove(key); urls.removeValue(forKey: key); warmObservers.removeValue(forKey: key); players.removeValue(forKey: key)?.pause(); order.removeAll { $0 == key } }
    func releaseAll() { suspendedPlayback = nil; activeKey = nil; activeOwner = nil; warming.removeAll(); urls.removeAll(); warmObservers.removeAll(); players.values.forEach { $0.pause() }; players.removeAll(); order.removeAll() }
    func retain(_ keys: Set<String>) {
        for key in Array(players.keys) where !keys.contains(key) { release(key) }
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func trim() { while order.count > capacity { guard let key = order.first(where: { $0 != activeKey }) else { break }; release(key) } }
}
