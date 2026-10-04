import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case rule34, redgifs, pornhub, eporner, hanime
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .rule34: "Rule34"
        case .redgifs: "RedGIFs"
        case .pornhub: "Pornhub"
        case .eporner: "Eporner"
        case .hanime: "Hanime"
        }
    }
}
