import SwiftUI

enum AppTheme {
    static let background = Color.black
    static let surface = Color(white: 0.055)
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
                let query = QueryParser.parse(store.queryText)
                let included = Set(query.included.map { $0.lowercased() })
                let excluded = Set(query.excluded.map { $0.lowercased() })
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(Array(Set(post.tags)).sorted(), id: \.self) { tag in
                        let isSelected = included.contains(tag.lowercased()) || excluded.contains(tag.lowercased())
                        let isExcluded = excluded.contains(tag.lowercased())
                        HStack(spacing: 0) {
                            Button {
                                if isSelected { store.removeTag(tag) }
                                else { store.includeTag(tag) }
                            } label: {
                                Text("#\(tag)").font(.subheadline).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                                    .padding(.leading, 10)
                            }
                            .accessibilityLabel("#\(tag)")
                            .accessibilityHint(isSelected ? "Remove from search" : "Add to search")
                            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 26)
                            Button {
                                if isExcluded { store.includeTag(tag) }
                                else { store.excludeTag(tag) }
                            } label: {
                                Image(systemName: "nosign")
                                    .foregroundStyle(isExcluded ? .orange : .white.opacity(0.8))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(isExcluded ? "Include #\(tag)" : "Exclude #\(tag)")
                        }
                        .buttonStyle(.plain)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isExcluded ? .orange.opacity(0.7) : .white.opacity(0.12)))
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
