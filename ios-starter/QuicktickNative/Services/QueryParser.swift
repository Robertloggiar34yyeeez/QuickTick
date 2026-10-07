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
