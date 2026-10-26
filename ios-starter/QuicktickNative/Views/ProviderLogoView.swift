import SwiftUI

/// Replaces toolbar provider names with compact icon marks. Load each site's
/// own favicon when compatible; fall back to an immediate recognizable glyph.
struct ProviderLogoView: View {
    let provider: Provider
    private var symbol: String {
        switch provider {
        case .rule34: "number.square.fill"
        case .redgifs: "play.square.stack.fill"
        case .pornhub: "play.rectangle.fill"
        case .eporner: "play.square.fill"
        case .hanime: "sparkles.tv.fill"
        case .hhaven: "play.tv.fill"
        case .coomer: "waveform.path"
        case .kemono: "photo.stack.fill"
        case .nhentai: "books.vertical.fill"
        }
    }
    private var favicon: URL? {
        let domain: String
        switch provider {
        case .rule34: domain = "rule34.xxx"
        case .redgifs: domain = "redgifs.com"
        case .pornhub: domain = "pornhub.com"
        case .eporner: domain = "eporner.com"
        case .hanime: domain = "hanime.tv"
        case .hhaven: domain = "hentaihaven.xxx"
        case .coomer: domain = "coomer.st"
        case .kemono: domain = "kemono.cr"
        case .nhentai: domain = "nhentai.net"
        }
        return URL(string: "https://" + domain + "/favicon.ico")
    }
    var body: some View {
        AsyncImage(url: favicon) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}
