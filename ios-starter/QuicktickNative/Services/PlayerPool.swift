import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerPool: ObservableObject {
    private var players: [String: AVPlayer] = [:]
    private var warmObservers: [String: NSKeyValueObservation] = [:]
    private var order: [String] = []
    var capacity = 5

    func player(for key: String, url: URL) -> AVPlayer {
        if let existing = players[key] { touch(key); return existing }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        players[key] = player; touch(key); trim()
        return player
    }

    func prewarm(key: String, url: URL) {
        let p = player(for: key, url: url)
        guard p.rate == 0 else { return }
        // AVPlayerItem creation alone does not prime the decode pipeline.
        if p.currentItem?.status == .readyToPlay { p.preroll(atRate: 1) { _ in }; return }
        warmObservers[key] = p.currentItem?.observe(\.status, options: [.new]) { [weak self, weak p] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self, let p, self.players[key] === p else { return }
                self.warmObservers.removeValue(forKey: key)
                if p.rate == 0 { p.preroll(atRate: 1) { _ in } }
            }
        }
    }
    func release(_ key: String) { warmObservers.removeValue(forKey: key); players.removeValue(forKey: key)?.pause(); order.removeAll { $0 == key } }
    func releaseAll() { warmObservers.removeAll(); players.values.forEach { $0.pause() }; players.removeAll(); order.removeAll() }
    func retain(_ keys: Set<String>) {
        for key in Array(players.keys) where !keys.contains(key) { release(key) }
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func trim() { while order.count > capacity { release(order[0]) } }
}
