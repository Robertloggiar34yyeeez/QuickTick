import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case rule34, redgifs, pornhub, eporner, hanime
    var id: String { rawValue }
    /// Older imports and restored downloads may use website names instead of
    /// the canonical provider ID. Restrict aliases to known sources rather
    /// than guessing from arbitrary CDN hosts.
    static func identify(_ source: String) -> Provider? {
        let lowered = source.lowercased()
        if let exact = Provider(rawValue: lowered) { return exact }
        let compact = lowered.filter { $0.isLetter || $0.isNumber }
        switch compact {
        case "rule34", "rule34xxx": .rule34
        case "redgifs", "redgifscom": .redgifs
        case "pornhub", "pornhubcom": .pornhub
        case "eporner", "epornercom": .eporner
        case "hanime", "hanimetv": .hanime
        default: nil
        }
    }

    static func identifyPage(_ raw: String) -> Provider? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        for (domain, source) in [("rule34.xxx", Provider.rule34), ("redgifs.com", .redgifs),
                                  ("pornhub.com", .pornhub), ("eporner.com", .eporner),
                                  ("hanime.tv", .hanime)] {
            if host == domain || host.hasSuffix("." + domain) { return source }
        }
        return nil
    }
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
