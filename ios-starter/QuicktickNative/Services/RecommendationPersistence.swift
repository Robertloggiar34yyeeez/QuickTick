import Foundation

actor RecommendationPersistence {
    private let url: URL
    private var blockedWrite = false
    private(set) var lastError: String?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("Quicktick", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("recommendations-v3.json")
    }

    func load() -> RecommendationState? {
        var source = url
        if !FileManager.default.fileExists(atPath: source.path) {
            for version in [2, 1] {
                let legacy = url.deletingLastPathComponent().appendingPathComponent("recommendations-v\(version).json")
                if FileManager.default.fileExists(atPath: legacy.path) { source = legacy; break }
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        do {
            let state = try JSONDecoder().decode(RecommendationState.self, from: Data(contentsOf: source))
            guard state.version <= 3 else { throw APIError.server("Unsupported recommendation state version") }
            return state
        } catch {
            blockedWrite = true; lastError = "Recommendation storage could not be read. The original file is preserved."
            return nil
        }
    }

    @discardableResult func save(_ state: RecommendationState) -> Bool {
        guard !blockedWrite else { return false }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    func clear() {
        for version in [1, 2, 3] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("recommendations-v\(version).json")) }
        blockedWrite = false; lastError = nil
    }
}
