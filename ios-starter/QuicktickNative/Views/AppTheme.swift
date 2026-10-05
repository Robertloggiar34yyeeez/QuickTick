import SwiftUI

enum AppTheme {
    static let background = Color.black
    static let surface = Color(white: 0.055)
    static let accent = Color(red: 0.60, green: 0.43, blue: 1)
    static let gradient = LinearGradient(colors: [accent, Color(red: 0.25, green: 0.62, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvas = Color.black
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
        }.buttonStyle(.plain).accessibilityLabel(title)
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
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("Settings").accessibilityIdentifier("open-settings")
    }
}
