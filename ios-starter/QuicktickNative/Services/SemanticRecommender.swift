import Foundation
import CoreML
import CryptoKit

struct WordPieceTokenizer: Sendable {
    let vocabulary: [String: Int]
    func encode(_ text: String, length: Int = 96) -> (ids: [Int], mask: [Int]) {
        let cleaned = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []; var word = ""
        for scalar in cleaned.unicodeScalars {
            let chinese = (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                if !word.isEmpty { words.append(word); word = "" }
            } else if chinese || CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                if !word.isEmpty { words.append(word); word = "" }; words.append(String(scalar))
            } else { word.unicodeScalars.append(scalar) }
        }
        if !word.isEmpty { words.append(word) }
        var ids = [vocabulary["[CLS]"] ?? 101]
        for word in words {
            let characters = Array(word); var pieces: [Int] = []; var start = 0
            if characters.count > 100 { pieces = [vocabulary["[UNK]"] ?? 100] }
            else {
                while start < characters.count {
                    var end = characters.count; var found: Int?
                    while end > start {
                        let token = (start == 0 ? "" : "##") + String(characters[start..<end])
                        if let id = vocabulary[token] { found = id; break }; end -= 1
                    }
                    guard let found else { pieces = [vocabulary["[UNK]"] ?? 100]; break }
                    pieces.append(found); start = end
                }
            }
            for id in pieces where ids.count < length - 1 { ids.append(id) }
            if ids.count >= length - 1 { break }
        }
        ids.append(vocabulary["[SEP]"] ?? 102)
        let count = ids.count; ids += Array(repeating: vocabulary["[PAD]"] ?? 0, count: max(0, length - count))
        return (ids, Array(repeating: 1, count: count) + Array(repeating: 0, count: max(0, length - count)))
    }
}

struct SemanticInterest: Codable, Sendable {
    var recent: [Float] = []
    var longTerm: [Float] = []
    var negative: [Float] = []
    var creators: [String: Float] = [:]
    var updated = Date()
}
struct SemanticRankWeights: Sendable {
    var recent = 10.0, longTerm = 6.0, negative = 12.0, creator = 2.0, freshness = 1.5
    var tag = 8.0, seen = 1000.0, semanticDiversity = 10.0, nearDuplicate = 8.0, creatorRepeat = 3.0, exploration = 2.0
    var tagDiversityCap = 8.0, overlap = 0.5, immediate = 1.0
    var immediateTwo = 9.0, immediateThree = 15.0, overlapFour = 11.0, overlapSix = 18.0
}
struct SemanticScore: Sendable {
    var recent: Double = 0, longTerm: Double = 0, negative: Double = 0, creator: Double = 0, freshness: Double = 0
    var cacheHit = false
    func total(_ w: SemanticRankWeights) -> Double { recent * w.recent + longTerm * w.longTerm - negative * w.negative + creator * w.creator + freshness * w.freshness }
}
private struct SemanticDiskState: Codable {
    var version = "bge-micro-v2-3edf6d7-96-v1"
    var embeddings: [String: [Float]] = [:]
    var profiles: [String: SemanticInterest] = [:]
    var order: [String] = []
}

/// Serial utility work, CPU/Neural Engine only: never uses the GPU competing with AV playback.
actor SemanticRecommender {
    let weights: SemanticRankWeights
    private var disk = SemanticDiskState()
    private var restored = false
    private var model: MLModel?
    private var tokenizer: WordPieceTokenizer?
    private var unavailable = false
    private var changes = 0
    private(set) var modelLoadMs = 0.0
    private(set) var embeddingMs = 0.0
    private(set) var cacheHits = 0
    private(set) var cacheMisses = 0
    private let directory: URL
    init(directory: URL? = nil, weights: SemanticRankWeights = SemanticRankWeights(), enabled: Bool = true) {
        self.weights = weights; self.unavailable = !enabled
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuicktickSemantic", isDirectory: true)
    }
    nonisolated static func text(for post: Post) -> String {
        [post.caption ?? "", post.category ?? "", post.tags.prefix(36).joined(separator: ", ")]
            .joined(separator: ". ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased().prefix(1800).description
    }
    private func key(_ post: Post) -> String { SHA256.hash(data: Data(Self.text(for: post).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func restore() {
        guard !restored else { return }; restored = true
        if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")), let saved = try? JSONDecoder().decode(SemanticDiskState.self, from: data), saved.version == disk.version { disk = saved }
    }
    private func loadModel() throws {
        guard model == nil else { return }
        guard !unavailable, let path = Bundle.main.url(forResource: "BGEMicro", withExtension: "mlmodelc"), let vocab = Bundle.main.url(forResource: "bge-vocab", withExtension: "txt") else { unavailable = true; throw CocoaError(.fileNoSuchFile) }
        let start = Date()
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        do {
            model = try MLModel(contentsOf: path, configuration: config)
            let words = try String(contentsOf: vocab, encoding: .utf8).components(separatedBy: .newlines)
            tokenizer = WordPieceTokenizer(vocabulary: Dictionary(words.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first }))
            modelLoadMs = Date().timeIntervalSince(start) * 1000
        } catch { unavailable = true; throw error }
    }
    func embed(_ post: Post) throws -> [Float] {
        restore(); let key = key(post)
        if let vector = disk.embeddings[key] { cacheHits += 1; return vector }
        guard !Self.text(for: post).trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty else { return [] }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled, ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { throw CancellationError() }
        try loadModel(); guard let model, let tokenizer else { return [] }
        let input = tokenizer.encode(Self.text(for: post)); let start = Date()
        let ids = try MLMultiArray(shape: [1,96], dataType: .int32); let mask = try MLMultiArray(shape: [1,96], dataType: .int32)
        for i in 0..<96 { ids[i] = NSNumber(value: input.ids[i]); mask[i] = NSNumber(value: input.mask[i]) }
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        guard let output = try model.prediction(from: features).featureValue(for: "embedding")?.multiArrayValue else { throw CocoaError(.coderInvalidValue) }
        let vector = (0..<output.count).map { output[$0].floatValue }
        guard vector.count == 384, vector.allSatisfy({ $0.isFinite }) else { throw CocoaError(.coderInvalidValue) }
        embeddingMs = Date().timeIntervalSince(start) * 1000; cacheMisses += 1
        disk.embeddings[key] = vector; disk.order.removeAll { $0 == key }; disk.order.append(key)
        while disk.order.count > 800 { disk.embeddings.removeValue(forKey: disk.order.removeFirst()) }
        changes += 1
        return vector
    }
    func prepare(_ posts: [Post]) async {
        restore()
        for post in posts.prefix(24) {
            guard !Task.isCancelled else { break }
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled, ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { break }
            _ = try? embed(post)
            // Give cooperative executor work a turn; no per-swipe inference.
            await Task.yield()
        }
        persist()
    }
    func record(_ event: RecommendationEvent, post: Post) {
        restore()
        let weight: Float
        switch event {
        case .like: weight = 4
        case .download: weight = 6
        case .less: weight = -5
        case .unlike: weight = -2
        case .quickSkip: weight = -0.4
        case .replay: weight = 2
        case .complete: weight = 2
        case let .watched(seconds, completion): weight = completion >= 0.8 ? 2 : (seconds >= 8 ? 0.6 : (completion > 0 && completion < 0.15 ? -0.3 : 0))
        case .impression: weight = 0
        }
        guard weight != 0, let vector = try? embed(post), !vector.isEmpty else { return }
        var profile = disk.profiles[post.provider.lowercased()] ?? SemanticInterest()
        let decay = Float(pow(0.5, Date().timeIntervalSince(profile.updated) / (30 * 86400)))
        profile.recent = profile.recent.map { $0 * decay }; profile.longTerm = profile.longTerm.map { $0 * decay }; profile.negative = profile.negative.map { $0 * decay }
        if weight > 0 {
            profile.recent = Self.blend(profile.recent, vector, alpha: min(0.65, weight * 0.1))
            profile.longTerm = Self.blend(profile.longTerm, vector, alpha: min(0.2, weight * 0.025))
        } else { profile.negative = Self.blend(profile.negative, vector, alpha: min(0.6, abs(weight) * 0.1)) }
        if let creator = post.creator, !creator.isEmpty {
            profile.creators[creator] = max(-1, min(1, (profile.creators[creator] ?? 0) * 0.95 + weight * 0.1))
            profile.creators = Dictionary(profile.creators.sorted { abs($0.value) > abs($1.value) }.prefix(48).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        profile.updated = Date(); disk.profiles[post.provider.lowercased()] = profile; persist()
    }
    func scores(_ posts: [Post]) -> [String: SemanticScore] {
        restore(); var result: [String: SemanticScore] = [:]
        for post in posts {
            guard let vector = disk.embeddings[key(post)] else { continue }
            let profile = disk.profiles[post.provider.lowercased()] ?? SemanticInterest()
            let recentDecay = exp(-max(0, Date().timeIntervalSince(profile.updated)) / (7 * 86400))
            let longDecay = exp(-max(0, Date().timeIntervalSince(profile.updated)) / (30 * 86400))
            let age = post.createdAt.map { max(0, Date().timeIntervalSince1970 - $0) }
            result[post.stableID] = SemanticScore(recent: max(0, Self.cosine(vector, profile.recent)) * recentDecay, longTerm: max(0, Self.cosine(vector, profile.longTerm)) * longDecay, negative: max(0, Self.cosine(vector, profile.negative)) * longDecay, creator: Double(profile.creators[post.creator ?? ""] ?? 0), freshness: age.map { exp(-$0 / (7 * 86400)) } ?? 0, cacheHit: true)
        }
        return result
    }
    func diversityVectors(_ posts: [Post]) -> [String: [Float]] {
        restore(); return Dictionary(posts.compactMap { post in disk.embeddings[key(post)].map { (post.stableID, $0) } }, uniquingKeysWith: { first, _ in first })
    }
    func similarity(_ a: Post, _ b: Post) -> Double {
        guard let first = disk.embeddings[key(a)], let second = disk.embeddings[key(b)] else { return 0 }; return Self.cosine(first, second)
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let dot = zip(a,b).reduce(Float(0)) { $0 + $1.0 * $1.1 }; let aa = a.reduce(Float(0)) { $0 + $1 * $1 }; let bb = b.reduce(Float(0)) { $0 + $1 * $1 }
        return aa > 0 && bb > 0 ? Double(dot / sqrt(aa * bb)) : 0
    }
    static func blend(_ old: [Float], _ new: [Float], alpha: Float) -> [Float] {
        guard old.count == new.count else { return new }; return zip(old,new).map { $0 * (1-alpha) + $1 * alpha }
    }
    func releaseModel() { model = nil; tokenizer = nil }
    func reset() { disk = SemanticDiskState(); restored = true; persist() }
    private func persist() {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let data = try JSONEncoder().encode(disk); try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic); changes = 0 }
        catch { /* Local tag ranking remains available if private cache persistence fails. */ }
    }
}
