import SwiftUI

enum AppTheme {
    static let background = Color.black
    static let surface = Color(white: 0.055)
    static let elevatedSurface = Color(red: 0.09, green: 0.09, blue: 0.13)
    static let border = Color.white.opacity(0.12)
    static let secondaryLabel = Color.white.opacity(0.58)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let accent = Color(red: 0.60, green: 0.43, blue: 1)
    static let gradient = LinearGradient(colors: [accent, Color(red: 0.25, green: 0.62, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvas = Color.black
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

// Only full-screen viewers presented by standard feeds use this gesture.
// A small lower-edge activation area avoids stealing vertical comic zoom,
// scrub controls, and Immersive's native vertical pager.
struct QuicktickSwipeUpExit: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onExit: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Color.clear
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 22).onEnded { gesture in
                        guard gesture.translation.height < -90,
                              abs(gesture.translation.width) < -gesture.translation.height * 0.65 else { return }
                        onExit()
                    }
                )
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func quicktickSwipeUpExit(_ action: @escaping () -> Void) -> some View {
        modifier(QuicktickSwipeUpExit(onExit: action))
    }
}

struct ActionIcon: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(selected ? AppTheme.accent : .white)
                .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(QuicktickPressStyle()).accessibilityLabel(title)
    }
}

struct PostTagsView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(Array(Set(post.tags)).sorted(), id: \.self) { tag in
                        Menu {
                            Button("Add to search") { store.includeTag(tag) }
                            Button("Exclude from search") { store.excludeTag(tag) }
                        } label: {
                            Text("#\(tag)").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.horizontal, 8).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
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
