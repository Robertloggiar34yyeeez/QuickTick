import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case rule34, redgifs, pornhub, eporner, hhaven, coomer, kemono, nhentai
    // Keep recognizing historical downloads, but don't offer new Hanime feeds.
    case hanime
    static var allCases: [Provider] { [.rule34, .redgifs, .pornhub, .eporner, .hhaven, .coomer, .kemono, .nhentai] }
    var id: String { rawValue }
    /// Older imports and restored downloads may use website names instead of
    /// the canonical provider ID. Restrict aliases to known sources rather
    /// than guessing from arbitrary CDN hosts.
    static func identify(_ source: String) -> Provider? {
        let lowered = source.lowercased()
        if let exact = Provider(rawValue: lowered) { return exact }
        let compact = lowered.filter { $0.isLetter || $0.isNumber }
        switch compact {
        case "rule34", "rule34xxx": return .rule34
        case "redgifs", "redgifscom": return .redgifs
        case "pornhub", "pornhubcom": return .pornhub
        case "eporner", "epornercom": return .eporner
        case "hanime", "hanimetv": return .hanime
        case "hhaven", "hentaihaven", "hentaihavenapp", "hentaihavenxxx": return .hhaven
        case "coomer", "coomerst": return .coomer
        case "kemono", "kemonocr": return .kemono
        case "nhentai", "nhentainet": return .nhentai
        default: return nil
        }
    }

    static func identifyPage(_ raw: String) -> Provider? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        for (domain, source) in [("rule34.xxx", Provider.rule34), ("redgifs.com", .redgifs),
                                  ("pornhub.com", .pornhub), ("eporner.com", .eporner),
                                  ("hanime.tv", .hanime), ("hentaihaven.xxx", .hhaven),
                                  ("hentaihaven.app", .hhaven), ("coomer.st", .coomer),
                                  ("kemono.cr", .kemono), ("nhentai.net", .nhentai)] {
            if host == domain || host.hasSuffix("." + domain) { return source }
        }
        return nil
    }
    var monogram: String {
        switch self {
        case .rule34: "34"
        case .redgifs: "RG"
        case .pornhub: "PH"
        case .eporner: "EP"
        case .hanime: "HA"
        case .hhaven: "HH"
        case .coomer: "CO"
        case .kemono: "KE"
        case .nhentai: "NH"
        }
    }
    var displayName: String {
        switch self {
        case .rule34: "Rule34"
        case .redgifs: "RedGIFs"
        case .pornhub: "Pornhub"
        case .eporner: "Eporner"
        case .hanime: "Hanime"
        case .hhaven: "Hentai Haven"
        case .coomer: "Coomer"
        case .kemono: "Kemono"
        case .nhentai: "NHentai"
        }
    }
}
