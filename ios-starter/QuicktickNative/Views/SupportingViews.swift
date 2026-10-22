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
                    Text("Guide your existing learned profile with topics, tags or phrases. Separate interests with commas. Your history is kept.").font(.caption).foregroundStyle(.secondary)
                    TextField("Topics or keywords", text: $positiveDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("positive-interest-input")
                    Button("Add interests") { addDraft(positive: true) }.disabled(positiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(into.sorted(), id: \.self) { term in
                        HStack { Text(term); Spacer(); Button("Remove") { into.remove(term) } }
                    }
                }
                Section("What would you rather avoid?") {
                    Text("Reduces unwanted recommendations while keeping your other learned interests. Exact unwanted tags are excluded.").font(.caption).foregroundStyle(.secondary)
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
    @State private var immersive = false
    @State private var activeID: String?
    @State private var shuffleLikes = false
    @State private var randomizedIDs: [String] = []
    private var orderedLikes: [Post] { store.favorites.values.sorted { $0.stableID < $1.stableID } }
    private var saved: [Post] {
        guard shuffleLikes else { return orderedLikes }
        let byID = Dictionary(uniqueKeysWithValues: orderedLikes.map { ($0.stableID, $0) })
        let shuffled = randomizedIDs.compactMap { byID[$0] }
        let inserted = orderedLikes.filter { !randomizedIDs.contains($0.stableID) }
        return shuffled + inserted
    }
    private func shuffleFavorites() {
        randomizedIDs = orderedLikes.map(\.stableID).shuffled()
        shuffleLikes = true
        activeID = nil
    }
    var body: some View {
        Group {
            if immersive {
                ImmersiveFeedView(posts: saved, offline: false, activePostID: $activeID,
                                  onClose: { immersive = false }, collectionTab: 2)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(saved, id: \.stableID) { post in
                                PostCardView(post: post, available: CGSize(width: min(680, geometry.size.width), height: geometry.size.height), playbackTab: 2)
                            }
                        }.frame(maxWidth: .infinity).padding(.bottom, 18)
                    }.coordinateSpace(name: "home-viewport")
                        .onPreferenceChange(HomeVisibleFrames.self) { frames in
                            guard store.activeTab == 2, store.isForeground, !immersive else { return }
                            store.noteFeedMotion()
                            let bounds = CGRect(origin: .zero, size: geometry.size)
                            for (id, frame) in frames {
                                if let post = store.favorites[id], frame.height > 0,
                                   frame.intersection(bounds).height >= min(frame.height * 0.5, bounds.height * 0.5) {
                                    store.recordImpression(post)
                                }
                            }
                            if store.fullScreenPlaybackID == nil {
                                let playable = Set(frames.keys.filter { store.favorites[$0]?.isImmersiveMedia == true })
                                let key = VisiblePostSelector.select(frames: frames, viewport: bounds, current: store.inlinePlaybackID, eligible: playable)
                                if key != store.inlinePlaybackID { store.inlinePlaybackID = key }
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvas)
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Shuffle likes", systemImage: "shuffle") { shuffleFavorites() }
                    Button("Original order", systemImage: "list.bullet") {
                        shuffleLikes = false
                        activeID = nil
                    }
                    .disabled(!shuffleLikes)
                } label: {
                    Image(systemName: shuffleLikes ? "shuffle.circle.fill" : "shuffle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(orderedLikes.isEmpty)
                .accessibilityLabel("Browse likes randomly")
                .accessibilityIdentifier("favorites-shuffle")
                Button(immersive ? "Feed" : "Immersive") {
                    activeID = nil
                    immersive.toggle()
                }
                .disabled(saved.isEmpty)
                .accessibilityIdentifier("favorites-immersive")
            }
        }
    }
}
