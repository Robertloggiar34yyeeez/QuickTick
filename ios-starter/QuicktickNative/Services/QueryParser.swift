import Foundation

struct TagSuggestion: Decodable, Identifiable, Sendable {
    var id: String { value }
    let value: String
    let label: String
    let count: Int
}

struct ParsedQuery: Equatable, Sendable {
    var included: [String]
    var excluded: [String]
}

enum SearchOrder: String, CaseIterable, Identifiable, Sendable {
    case source, score, created, random
    var id: String { rawValue }
    var title: String { switch self { case .source: "Source order"; case .score: "Score"; case .created: "Created"; case .random: "Random" } }
    var token: String? { switch self { case .source: nil; case .score: "sort:score:desc"; case .created: "sort:id:desc"; case .random: "sort:random" } }
}

struct SearchFilters: Equatable, Sendable {
    var order: SearchOrder = .source
    var rating = ""
    var minimumScore: Int?
    static let scores = [0, 5, 10, 25, 50, 75, 100, 200, 300]
    static let ratings = ["general", "safe", "questionable", "explicit"]
    static func split(_ query: String) -> (tags: String, filters: Self) {
        var filters = Self(), tags: [String] = []
        for token in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = token.lowercased()
            if lower == "sort:score" || lower == "sort:score:desc" { filters.order = .score }
            else if lower == "sort:id:desc" { filters.order = .created }
            else if lower == "sort:random" { filters.order = .random }
            else if lower.hasPrefix("rating:"), ratings.contains(String(lower.dropFirst(7))) { filters.rating = String(lower.dropFirst(7)) }
            else if lower.hasPrefix("score:>="), let score = Int(lower.dropFirst(8)), score >= 0 { filters.minimumScore = score }
            else { tags.append(token) }
        }
        return (tags.joined(separator: " "), filters)
    }
    func query(tags: String, provider: Provider) -> String {
        let parsed = QueryParser.parse(tags)
        var tokens = parsed.included + parsed.excluded.map { "-" + $0 }
        if provider == .rule34 {
            if let token = order.token { tokens.insert(token, at: 0) }
            if Self.ratings.contains(rating) { tokens.append("rating:" + rating) }
            if let minimumScore { tokens.append("score:>=\(max(0, minimumScore))") }
        }
        return tokens.joined(separator: " ")
    }
}

enum QueryParser {
    static func parse(_ text: String) -> ParsedQuery {
        var included: [String] = [], excluded: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("-") && t.count > 1 { excluded.append(String(t.dropFirst())) }
            else { included.append(t) }
        }
        return ParsedQuery(included: uniqued(included), excluded: uniqued(excluded))
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
