import Foundation

struct TagSuggestion: Decodable, Identifiable, Sendable {
    var id: String { value }
    let value: String
    let label: String
    let count: Int
}

/// Home-feed category chips are provider-scoped structured filters, not
/// ordinary title keywords or Search-sheet autocomplete suggestions.
enum ProviderSearchCategories {
    private static let havenSections: [(String, String)] = [
        ("trending_month", "Trending"), ("last", "Latest"),
        ("yuri", "Yuri"), ("ecchi", "Ecchi"),
        ("incest", "Incest"), ("tentacle", "Tentacle"),
        ("uncensored", "Uncensored")
    ]
    private static let pornhubCategories: [(String, String)] = [
        ("amateur", "Amateur"), ("hentai", "Hentai"),
        ("animation", "Animation"), ("asian", "Asian"),
        ("big-ass", "Big Ass"), ("big-tits", "Big Tits"),
        ("cosplay", "Cosplay"), ("milf", "MILF"),
        ("pov", "POV"), ("solo", "Solo"),
        ("vintage", "Vintage")
    ]
    static func suggestions(provider: Provider, matching query: String = "") -> [TagSuggestion] {
        let values: [TagSuggestion]
        switch provider {
        case .hhaven:
            values = havenSections.map { TagSuggestion(value: "category:section:" + $0.0, label: $0.1, count: 0) }
        case .pornhub:
            values = pornhubCategories.map { TagSuggestion(value: "category:" + $0.0, label: $0.1, count: 0) }
        default: return []
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty ? values : values.filter { $0.label.lowercased().contains(needle) }
    }

    static func valid(_ token: String, provider: Provider) -> Bool {
        guard token.hasPrefix("category:") else { return false }
        let value = String(token.dropFirst("category:".count))
        switch provider {
        case .hhaven:
            if value.hasPrefix("genre:") {
                let id = String(value.dropFirst("genre:".count))
                return !id.isEmpty && id.count <= 8 && id.allSatisfy(\.isNumber)
            }
            return havenSections.contains { value == "section:" + $0.0 }
        case .pornhub:
            return !value.isEmpty && value.count <= 60 &&
                value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        default: return false
        }
    }

    static func split(_ query: ParsedQuery, provider: Provider) -> (category: String?, keywords: [String]) {
        let category = query.included.first { valid($0, provider: provider) }
        return (category, query.included.filter { $0 != category })
    }
}

struct ParsedQuery: Equatable, Sendable {
    var included: [String]
    var excluded: [String]
    var pornhub: PornhubSearchFilters? = nil
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
            else if !lower.hasPrefix(PornhubSearchFilters.tokenPrefix) { tags.append(token) }
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

enum PornhubSearchOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case relevance, newest, mostViewed, topRated, longest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relevance: "Most relevant"
        case .newest: "Newest"
        case .mostViewed: "Most viewed"
        case .topRated: "Top rated"
        case .longest: "Longest"
        }
    }
    var ordering: String {
        switch self {
        case .relevance: "featured"
        case .newest: "newest"
        case .mostViewed: "mostviewed"
        case .topRated: "rating"
        case .longest: "longest"
        }
    }
    var feedSort: String {
        switch self {
        case .relevance: "recommended"
        case .newest: "recent"
        default: "popular"
        }
    }
}

enum PornhubProduction: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, professional, homemade
    var id: String { rawValue }
    var title: String { switch self { case .all: "All"; case .professional: "Professional"; case .homemade: "Amateur" } }
}

/// Only Pornhub search reads these options. The single opaque query token keeps
/// Home/Immersive pagination and saved-tab searches in sync without adding
/// provider-specific state to every other feed and recommendation API.
struct PornhubSearchFilters: Codable, Equatable, Sendable {
    static let tokenPrefix = "qtph:"
    static let commonCategories = ["Amateur", "Anal", "Asian", "Babe", "Big Ass", "Big Tits", "Blonde",
                                   "Brunette", "Cosplay", "Couples", "Ebony", "Fetish", "Hentai",
                                   "Interracial", "Latina", "Lesbian", "Mature", "MILF", "POV",
                                   "Romantic", "Solo", "VR", "Vintage"]
    var order: PornhubSearchOrder = .relevance
    var production: PornhubProduction = .all
    var minimumMinutes = 0
    var maximumMinutes = 40 // 40 means 40+ / no upper bound.
    var includedCategory: String? = nil
    var excludedCategories: [String] = []

    var normalized: Self {
        var value = self
        value.minimumMinutes = min(40, max(0, minimumMinutes))
        value.maximumMinutes = max(value.minimumMinutes, min(40, max(0, maximumMinutes)))
        value.includedCategory = includedCategory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.includedCategory?.isEmpty == true { value.includedCategory = nil }
        let includedKey = value.includedCategory?.lowercased()
        var seen = Set<String>()
        value.excludedCategories = excludedCategories.filter {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && key != includedKey && seen.insert(key).inserted
        }.prefix(10).map { $0 }
        return value
    }

    static func decode(_ query: String) -> Self {
        guard let token = query.split(whereSeparator: \.isWhitespace).first(where: { $0.lowercased().hasPrefix(tokenPrefix) }) else { return Self() }
        let payload = String(token.dropFirst(tokenPrefix.count))
        let base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64.padding(toLength: ((base64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded), data.count < 4096,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded.normalized
    }

    func encodedQuery(_ keywords: String) -> String {
        let text = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized
        guard value != Self(), let data = try? JSONEncoder().encode(value) else { return text }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return [text, Self.tokenPrefix + encoded].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum QueryParser {
    /// Preserve literal multiword keywords when a post tag is added from its
    /// action menu. Without quotes, searching for `red hair` becomes two
    /// unrelated provider terms on a later parse.
    static func formatted(_ query: ParsedQuery) -> String {
        func token(_ text: String) -> String {
            let clean = text.replacingOccurrences(of: "\"", with: "")
            return clean.contains(where: \.isWhitespace) ? "\"\(clean)\"" : clean
        }
        return (query.included.map(token) + query.excluded.map { "-" + token($0) })
            .joined(separator: " ")
    }

    static func parse(_ text: String) -> ParsedQuery {
        var included: [String] = [], excluded: [String] = []
        for raw in tokens(text) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.lowercased().hasPrefix(PornhubSearchFilters.tokenPrefix) { continue }
            if t.hasPrefix("-") && t.count > 1 { excluded.append(String(t.dropFirst())) }
            else { included.append(t) }
        }
        let blocked = Set(excluded.map { $0.lowercased() })
        return ParsedQuery(included: uniqued(included).filter { !blocked.contains($0.lowercased()) }, excluded: uniqued(excluded),
                           pornhub: text.contains(PornhubSearchFilters.tokenPrefix) ? PornhubSearchFilters.decode(text) : nil)
    }

    /// Keep quoted phrases intact for free-text providers, including `-"phrase"`
    /// exclusions. An unclosed quote still produces a usable final term.
    private static func tokens(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { parts.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

struct SearchTag: Identifiable, Equatable, Sendable {
    let name: String
    var excluded: Bool
    var id: String { name.lowercased() }
    static func parse(_ query: String) -> [Self] {
        let value = QueryParser.parse(query)
        return value.included.map { Self(name: $0.lowercased(), excluded: false) } + value.excluded.map { Self(name: $0.lowercased(), excluded: true) }
    }
}
struct SearchDraft: Sendable {
    var text = ""
    var archiveCreatorReference: String? = nil
    var archiveCreatorLabel: String? = nil
    var tags: [SearchTag] = []
    var filters = SearchFilters()
    var pornhub = PornhubSearchFilters()
    var sort = "recommended"
    // Do not reuse a tag-based draft after switching to a keyword provider.
    var provider: Provider? = nil
}
