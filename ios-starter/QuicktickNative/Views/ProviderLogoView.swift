import SwiftUI

// Local source marks, not remote favicons or official trademarks.
struct ProviderLogoView: View {
    let provider: Provider
    static func symbol(for provider: Provider) -> String {
        switch provider {
        case .rule34: "number"
        case .redgifs: "play.rectangle.fill"
        case .pornhub: "play.fill"
        case .eporner: "film"
        case .erome: "photo.on.rectangle"
        case .hanime: "tv"
        case .hhaven: "play.tv"
        case .coomer: "waveform"
        case .kemono: "photo.stack"
        case .nhentai: "book"
        }
    }
    private var tint: Color {
        switch provider {
        case .rule34: .green
        case .redgifs: .red
        case .pornhub: .orange
        case .eporner: .blue
        case .erome: .teal
        case .hanime: .pink
        case .hhaven: .indigo
        case .coomer: .cyan
        case .kemono: .purple
        case .nhentai: .red
        }
    }
    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: Self.symbol(for: provider)).font(.system(size: 13, weight: .bold))
            Text(provider.monogram).font(.system(size: 8, weight: .black, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(tint.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.24)))
        .accessibilityHidden(true)
    }
}
