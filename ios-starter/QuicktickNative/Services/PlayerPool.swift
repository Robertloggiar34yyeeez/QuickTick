import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerPool: ObservableObject {
    private var players: [String: AVPlayer] = [:]
    private var warmObservers: [String: NSKeyValueObservation] = [:]
    private var order: [String] = []
    private var urls: [String: URL] = [:]
    private(set) var activeKey: String?
    private(set) var activeOwner: String?
    var capacity = 3

    func player(for key: String, url: URL) -> AVPlayer {
        if let existing = players[key], urls[key] == url { touch(key); return existing }
        release(key)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        players[key] = player; urls[key] = url; touch(key); trim()
        return player
    }

    func activate(key: String, url: URL, muted: Bool, owner: String = "home") -> AVPlayer {
        pauseAll()
        let p = player(for: key, url: url)
        activeKey = key; activeOwner = owner; p.isMuted = muted; p.play()
        return p
    }
    func pauseAll() { players.values.forEach { $0.pause(); $0.cancelPendingPrerolls() }; activeKey = nil; activeOwner = nil }
    func pause(_ key: String, owner: String? = nil) { guard owner == nil || activeOwner == owner else { return }; players[key]?.pause(); if activeKey == key { activeKey = nil; activeOwner = nil } }
    var count: Int { players.count }
    func prewarm(key: String, url: URL) {
        let p = player(for: key, url: url)
        guard p.rate == 0 else { return }
        // AVPlayerItem creation alone does not prime the decode pipeline.
        if p.currentItem?.status == .readyToPlay, activeKey != key { p.preroll(atRate: 1) { _ in }; return }
        warmObservers[key] = p.currentItem?.observe(\.status, options: [.new]) { [weak self, weak p] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self, let p, self.players[key] === p else { return }
                self.warmObservers.removeValue(forKey: key)
                if p.rate == 0, self.activeKey != key { p.preroll(atRate: 1) { _ in } }
            }
        }
    }
    func release(_ key: String) { if activeKey == key { activeKey = nil; activeOwner = nil }; urls.removeValue(forKey: key); warmObservers.removeValue(forKey: key); players.removeValue(forKey: key)?.pause(); order.removeAll { $0 == key } }
    func releaseAll() { activeKey = nil; activeOwner = nil; urls.removeAll(); warmObservers.removeAll(); players.values.forEach { $0.pause() }; players.removeAll(); order.removeAll() }
    func retain(_ keys: Set<String>) {
        for key in Array(players.keys) where !keys.contains(key) { release(key) }
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func trim() { while order.count > capacity { guard let key = order.first(where: { $0 != activeKey }) else { break }; release(key) } }
}
