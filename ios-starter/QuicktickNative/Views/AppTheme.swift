import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.085)
    static let surface = Color(red: 0.085, green: 0.10, blue: 0.16)
    static let accent = Color(red: 0.60, green: 0.43, blue: 1)
    static let gradient = LinearGradient(colors: [accent, Color(red: 0.25, green: 0.62, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvas = LinearGradient(colors: [Color(red: 0.12, green: 0.08, blue: 0.22), background, Color(red: 0.04, green: 0.10, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
