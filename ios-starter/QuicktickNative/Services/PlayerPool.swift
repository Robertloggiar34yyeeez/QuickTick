import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerPool: ObservableObject {
    private var players: [String: AVPlayer] = [:]
    private var order: [String] = []
    var capacity = 4

    func player(for key: String, url: URL) -> AVPlayer {
        if let existing = players[key] { touch(key); return existing }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        players[key] = player; touch(key); trim()
        return player
    }

    func prewarm(key: String, url: URL) { _ = player(for: key, url: url) }
    func release(_ key: String) { players.removeValue(forKey: key)?.pause(); order.removeAll { $0 == key } }
    func releaseAll() { players.values.forEach { $0.pause() }; players.removeAll(); order.removeAll() }
    func retain(_ keys: Set<String>) {
        for key in Array(players.keys) where !keys.contains(key) { release(key) }
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func trim() { while order.count > capacity { release(order[0]) } }
}
