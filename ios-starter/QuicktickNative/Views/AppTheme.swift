import SwiftUI

enum AppTheme {
    enum AccentPalette: String, CaseIterable, Identifiable {
        case violet, ocean, sunset, mint, rose, cobalt, amber, cherry, teal, lime, indigo, coral, galaxy
        case darkCosmos, auroraNight, solarEclipse
        var id: String { rawValue }
        var name: String {
            switch self {
            case .darkCosmos: "Dark Cosmos"
            case .auroraNight: "Aurora Night"
            case .solarEclipse: "Solar Eclipse"
            default: rawValue.capitalized
            }
        }
        var primary: Color {
            switch self {
            case .violet: Color(red: 0.60, green: 0.43, blue: 1.00)
            case .ocean: Color(red: 0.20, green: 0.65, blue: 1.00)
            case .sunset: Color(red: 1.00, green: 0.46, blue: 0.30)
            case .mint: Color(red: 0.21, green: 0.83, blue: 0.65)
            case .rose: Color(red: 0.98, green: 0.39, blue: 0.69)
            case .cobalt: Color(red: 0.27, green: 0.43, blue: 1.00)
            case .amber: Color(red: 1.00, green: 0.68, blue: 0.20)
            case .cherry: Color(red: 0.93, green: 0.25, blue: 0.43)
            case .teal: Color(red: 0.05, green: 0.76, blue: 0.74)
            case .lime: Color(red: 0.63, green: 0.84, blue: 0.28)
            case .indigo: Color(red: 0.44, green: 0.38, blue: 0.94)
            case .coral: Color(red: 0.99, green: 0.40, blue: 0.42)
            case .galaxy: Color(red: 0.75, green: 0.43, blue: 1.00)
            case .darkCosmos: Color(red: 0.52, green: 0.48, blue: 1.00)
            case .auroraNight: Color(red: 0.22, green: 0.91, blue: 0.73)
            case .solarEclipse: Color(red: 1.00, green: 0.47, blue: 0.28)
            }
        }
        var secondary: Color {
            switch self {
            case .violet: Color(red: 0.25, green: 0.62, blue: 0.95)
            case .ocean: Color(red: 0.10, green: 0.84, blue: 0.83)
            case .sunset: Color(red: 1.00, green: 0.72, blue: 0.36)
            case .mint: Color(red: 0.20, green: 0.60, blue: 0.98)
            case .rose: Color(red: 0.65, green: 0.38, blue: 0.98)
            case .cobalt: Color(red: 0.44, green: 0.77, blue: 1.00)
            case .amber: Color(red: 1.00, green: 0.36, blue: 0.31)
            case .cherry: Color(red: 0.83, green: 0.31, blue: 0.74)
            case .teal: Color(red: 0.26, green: 0.55, blue: 0.99)
            case .lime: Color(red: 0.10, green: 0.74, blue: 0.59)
            case .indigo: Color(red: 0.77, green: 0.40, blue: 1.00)
            case .coral: Color(red: 1.00, green: 0.66, blue: 0.36)
            case .galaxy: Color(red: 0.23, green: 0.79, blue: 1.00)
            case .darkCosmos: Color(red: 0.22, green: 0.56, blue: 0.95)
            case .auroraNight: Color(red: 0.29, green: 0.48, blue: 0.98)
            case .solarEclipse: Color(red: 0.77, green: 0.29, blue: 0.72)
            }
        }
        var gradientColors: [Color] {
            switch self {
            case .galaxy:
                [Color(red: 0.95, green: 0.35, blue: 0.82), primary, secondary]
            case .darkCosmos:
                [Color(red: 0.13, green: 0.10, blue: 0.36), primary, secondary]
            case .auroraNight:
                [Color(red: 0.08, green: 0.32, blue: 0.43), primary, secondary]
            case .solarEclipse:
                [Color(red: 0.21, green: 0.06, blue: 0.17), primary, secondary]
            default: [primary, secondary]
            }
        }
    }
    static var palette: AccentPalette {
        AccentPalette(rawValue: UserDefaults.standard.string(forKey: "quicktick-accent-palette-v1") ?? "violet") ?? .violet
    }
    static var modernUI: Bool { (UserDefaults.standard.object(forKey: "quicktick-modern-ui-v1") as? Bool) ?? true }
    static var isGalaxy: Bool { palette == .galaxy }
    static var isCosmic: Bool {
        switch palette {
        case .galaxy, .darkCosmos, .auroraNight, .solarEclipse: return true
        default: return false
        }
    }
    // Galaxy changes the actual surfaces across menus, not just button tint.
    // Fixed colors avoid animated shaders or heavy effects on feed scrolling.
    static var background: Color {
        switch palette {
        case .galaxy: return Color(red: 0.020, green: 0.021, blue: 0.074)
        case .darkCosmos: return Color(red: 0.009, green: 0.012, blue: 0.036)
        case .auroraNight: return Color(red: 0.009, green: 0.043, blue: 0.052)
        case .solarEclipse: return Color(red: 0.048, green: 0.014, blue: 0.031)
        default: break
        }
        return modernUI ? Color(red: 0.035, green: 0.035, blue: 0.065) : .black
    }
    static var surface: Color {
        switch palette {
        case .galaxy: return Color(red: 0.065, green: 0.052, blue: 0.143)
        case .darkCosmos: return Color(red: 0.035, green: 0.041, blue: 0.093)
        case .auroraNight: return Color(red: 0.028, green: 0.092, blue: 0.103)
        case .solarEclipse: return Color(red: 0.107, green: 0.043, blue: 0.065)
        default: break
        }
        return modernUI ? Color(red: 0.073, green: 0.073, blue: 0.11) : Color(white: 0.055)
    }
    static var elevatedSurface: Color {
        switch palette {
        case .galaxy: return Color(red: 0.110, green: 0.078, blue: 0.212)
        case .darkCosmos: return Color(red: 0.067, green: 0.067, blue: 0.160)
        case .auroraNight: return Color(red: 0.053, green: 0.145, blue: 0.146)
        case .solarEclipse: return Color(red: 0.171, green: 0.077, blue: 0.115)
        default: break
        }
        return modernUI ? Color(red: 0.10, green: 0.095, blue: 0.15) : Color(red: 0.09, green: 0.09, blue: 0.13)
    }
    static var navigationSurface: Color {
        switch palette {
        case .galaxy: Color(red: 0.040, green: 0.031, blue: 0.114)
        case .darkCosmos: Color(red: 0.020, green: 0.025, blue: 0.061)
        case .auroraNight: Color(red: 0.015, green: 0.069, blue: 0.077)
        case .solarEclipse: Color(red: 0.078, green: 0.026, blue: 0.047)
        default: Color(red: 0.045, green: 0.04, blue: 0.075)
        }
    }
    static var border: Color {
        isCosmic ? palette.primary.opacity(0.30) : Color.white.opacity(0.12)
    }
    static var secondaryLabel: Color { Color.white.opacity(isCosmic ? 0.72 : 0.58) }
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static var accent: Color { palette.primary }
    static var gradient: LinearGradient {
        LinearGradient(colors: palette.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var canvas: Color { background }
    static let small: CGFloat = 8
    static let contentMargin: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let controlHeight: CGFloat = 44
    static let controlRadius: CGFloat = 14
    static let cardRadius: CGFloat = 22
    static let feedWidth: CGFloat = 680
}

// Native SwiftUI interpretation of beUI's spring-press interaction.
// No React Native runtime or JavaScript dependency is required.
struct QuicktickPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.955 : 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// Keep native vertical paging, AVPlayer controls and comic zoom gestures intact:
// only an intentional rightward swipe from the extreme left edge exits.
struct QuicktickEdgeBack: ViewModifier {
    let onBack: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Color.clear
                .frame(width: 32)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 24).onEnded { gesture in
                        let dx = gesture.translation.width
                        let dy = gesture.translation.height
                        guard dx > 80, abs(dy) < min(70, dx * 0.65) else { return }
                        onBack()
                    }
                )
                .padding(.top, 64)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func quicktickEdgeBack(_ onBack: @escaping () -> Void) -> some View {
        modifier(QuicktickEdgeBack(onBack: onBack))
    }
}

struct ActionIcon: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(selected ? AppTheme.accent : .white.opacity(0.83))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityLabel(title)
    }
}

struct PostTagsView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                let actions = ActionSemantics.facets(post.tags).sorted()
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recognized actions", systemImage: "figure.stand")
                            .font(.subheadline.weight(.semibold))
                        Text(actions.map { $0.replacingOccurrences(of: ":", with: " · ").replacingOccurrences(of: "_", with: " ") }
                            .joined(separator: "   •   "))
                            .font(.caption).foregroundStyle(AppTheme.accent)
                        Text("Based on provider tags; visual checking happens separately when enabled.")
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(Array(Set(post.tags)).sorted(), id: \.self) { tag in
                        let blocked = store.exclusions.map(RecommendationTagRules.canonical)
                            .contains(RecommendationTagRules.canonical(tag))
                        Menu {
                            Button("Add to search") { store.includeTag(tag) }
                            Button("Exclude from search") { store.excludeTag(tag) }
                            Button(blocked ? "Remove persistent block" : "Block in all feeds", role: blocked ? .cancel : .destructive) {
                                let key = RecommendationTagRules.canonical(tag)
                                let result = blocked
                                    ? store.exclusions.filter { RecommendationTagRules.canonical($0) != key }
                                    : store.exclusions + [key]
                                store.setExclusions(Array(Set(result)).sorted())
                                Task { await store.refresh(immersive: store.activeTab == 1) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: blocked ? "nosign" : "number")
                                    .font(.caption)
                                Text(tag.replacingOccurrences(of: "_", with: " "))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .font(.subheadline)
                            .foregroundStyle(blocked ? Color.orange : .white.opacity(0.84))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 8)
                            .background(blocked ? Color.orange.opacity(0.15) : AppTheme.elevatedSurface, in: Capsule())
                            .overlay(Capsule().stroke(blocked ? Color.orange.opacity(0.5) : AppTheme.border))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("#\(tag)")
                    }
                }.padding()
                if post.tags.isEmpty { Text("No tags available").foregroundStyle(.secondary).padding() }
            }.background(AppTheme.canvas).navigationTitle("Tags")
                .toolbar { Button("Done") { dismiss() } }
        }.tint(AppTheme.accent)
    }
}

struct SettingsLauncher: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white).frame(width: 44, height: 44)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.border, lineWidth: 1))
        }.buttonStyle(QuicktickPressStyle()).accessibilityLabel("Settings").accessibilityIdentifier("open-settings")
    }
}
