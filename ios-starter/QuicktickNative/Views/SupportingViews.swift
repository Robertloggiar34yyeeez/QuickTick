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
            }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Comments")
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
    @State private var positiveDraft = ""
    @State private var negativeDraft = ""
    var body: some View {
        NavigationStack {
            List {
                Section("What would you like more of?") {
                    Text("Add your own topics, tags or phrases. Separate multiple interests with commas.").font(.caption).foregroundStyle(.secondary)
                    TextField("Topics or keywords", text: $positiveDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("positive-interest-input")
                    Button("Add interests") { addDraft(positive: true) }.disabled(positiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(into.sorted(), id: \.self) { term in
                        HStack { Text(term); Spacer(); Button("Remove") { into.remove(term) } }
                    }
                }
                Section("What would you rather avoid?") {
                    TextField("Unwanted topics or keywords", text: $negativeDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add exclusions") { addDraft(positive: false) }.disabled(negativeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(notInto.sorted(), id: \.self) { term in
                        HStack { Text(term); Spacer(); Button("Remove") { notInto.remove(term) } }
                    }
                }
                Section("Which of these appeal to you?") {
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
                }
            }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Your interests")
                .toolbar { Button("Done") { addDraft(positive: true); addDraft(positive: false); store.setTaste(into: into.sorted(), notInto: notInto.sorted()); dismiss() } }
        }.interactiveDismissDisabled()
            .onAppear { let taste = store.tasteChoice(for: store.selectedProvider); into = Set(taste.into); notInto = Set(taste.notInto) }
    }
    private func addDraft(positive: Bool) {
        let draft = positive ? positiveDraft : negativeDraft
        let terms = TasteChoice.normalized(draft.components(separatedBy: CharacterSet(charactersIn: ",\n;")))
        for term in terms {
            if positive { notInto.remove(term); into.insert(term) }
            else { into.remove(term); notInto.insert(term) }
        }
        if positive { positiveDraft = "" } else { negativeDraft = "" }
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        ScrollView { LazyVStack { ForEach(store.favorites.values.sorted { $0.stableID < $1.stableID }, id: \.stableID) { PostCardView(post: $0, playbackTab: 2) } }.padding() }
            .scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Favorites")
    }
}
