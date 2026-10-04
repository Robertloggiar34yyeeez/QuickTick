import SwiftUI

struct CommentsView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @State private var page: CommentPage?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.orange) }
                else if let page {
                    if !page.available { Text(page.message ?? "Comments are unavailable for this provider.") }
                    ForEach(page.items) { comment in
                        VStack(alignment: .leading) { Text(comment.author).font(.headline); Text(comment.body); Text(comment.createdAt).font(.caption).foregroundStyle(.secondary) }
                    }
                    if page.available && page.items.isEmpty { Text("No comments.") }
                } else { ProgressView() }
            }.navigationTitle("Comments")
        }.task {
            do { page = try await store.api.comments(post) } catch { self.error = error.localizedDescription }
        }
    }
}

struct TasteOnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var into = Set<String>()
    @State private var notInto = Set<String>()
    var body: some View {
        NavigationStack {
            List {
                Text("Choose interests for \(store.selectedProvider.displayName). Not Into filters Recommended posts.")
                ForEach(Array(Set(store.posts.flatMap { $0.tags.prefix(6) })).sorted().prefix(24), id: \.self) { tag in
                    HStack {
                        if let post = store.posts.first(where: { $0.tags.contains(tag) }) {
                            PosterView(url: post.thumbUrl).frame(width: 72, height: 72).clipped()
                        }
                        Text(tag)
                        Spacer()
                        Button(into.contains(tag) ? "✓ Into" : "Into") { notInto.remove(tag); if !into.insert(tag).inserted { into.remove(tag) } }
                        Button(notInto.contains(tag) ? "✓ Not Into" : "Not Into") { into.remove(tag); if !notInto.insert(tag).inserted { notInto.remove(tag) } }
                    }.buttonStyle(.bordered)
                }
            }.navigationTitle("Your interests")
                .toolbar { Button("Done") { store.setTaste(into: into.sorted(), notInto: notInto.sorted()); dismiss() } }
        }.interactiveDismissDisabled()
            .onAppear { let taste = store.tasteChoice(for: store.selectedProvider); into = Set(taste.into); notInto = Set(taste.notInto) }
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        ScrollView { LazyVStack { ForEach(store.favorites.values.sorted { $0.stableID < $1.stableID }, id: \.stableID) { PostCardView(post: $0) } }.padding() }
            .navigationTitle("Favorites")
    }
}
