import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool
    @State private var suggestions: [TagSuggestion] = []
    @State private var draft = ""
    @State private var initialized = false
    @State private var filters = SearchFilters()
    @State private var filtersOpen = false
    init(immersive: Bool = false, focusRequested: Binding<Bool> = .constant(false)) {
        self.immersive = immersive; _focusRequested = focusRequested
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tags", text: $draft)
                    .focused($focused).accessibilityIdentifier("feed-search-input")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { search() }
                Button { focused = false; filtersOpen = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Search filters").accessibilityIdentifier("search-filters")
                Button { search() } label: { Image(systemName: "arrow.right").font(.headline).frame(width: 44, height: 44).background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel("Search")
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(suggestions.prefix(6)) { suggestion in
                        Button(suggestion.value) {
                            var parts = draft.split(whereSeparator: \.isWhitespace).map(String.init)
                            let negative = parts.last?.hasPrefix("-") == true
                            if !parts.isEmpty { parts.removeLast() }
                            parts.append((negative ? "-" : "") + suggestion.value)
                            draft = parts.joined(separator: " "); suggestions = []
                        }.buttonStyle(.bordered)
                    } }
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 6).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .onAppear {
                if !initialized { initialized = true; restoreQuery(store.queryText) }
            }
            .onChange(of: store.queryText) { _, query in restoreQuery(query) }
            .onChange(of: store.selectedProvider) { _, provider in
                if provider != .rule34 {
                    filters = SearchFilters()
                    store.queryText = SearchFilters.split(store.queryText).tags
                }
            }
            .sheet(isPresented: $filtersOpen) {
                SearchFiltersPanel(provider: store.selectedProvider, tags: $draft, filters: $filters,
                    previews: Array(store.posts.prefix(4)), submit: { search(); filtersOpen = false })
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .task(id: focusRequested) {
                if focusRequested { focused = true; focusRequested = false }
            }
            .task(id: store.selectedProvider.rawValue + ":" + draft) {
                suggestions = []
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
                #endif
                guard store.selectedProvider == .rule34, let token = draft.split(whereSeparator: \.isWhitespace).last else { return }
                let query = token.hasPrefix("-") ? String(token.dropFirst()) : String(token)
                guard query.count >= 2 else { return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    let result = try await store.api.suggestions(provider: .rule34, query: query)
                    guard !Task.isCancelled else { return }; suggestions = result
                } catch { suggestions = [] }
            }
    }
    private func search() {
        focused = false; suggestions = []
        // Editing is a form draft, not a new active feed. Commit once so
        // keystrokes do not remove cards and collapse the focused scroll view.
        store.queryText = filters.query(tags: draft, provider: store.selectedProvider)
        Task { await store.refresh(immersive: immersive, trainSearch: true) }
    }
    private func restoreQuery(_ query: String) {
        let state = SearchFilters.split(query)
        draft = state.tags; filters = state.filters
    }
}

private struct SearchFiltersPanel: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingTags: Bool
    let provider: Provider
    @Binding var tags: String
    @Binding var filters: SearchFilters
    let previews: [Post]
    let submit: () -> Void
    private var tokens: [String] {
        let parsed = QueryParser.parse(tags)
        return parsed.included + parsed.excluded.map { "-" + $0 }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search tags · -tag to exclude", text: $tags)
                            .focused($editingTags)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                            .onSubmit(submit).accessibilityIdentifier("search-filter-input")
                    }.padding(12).background(AppTheme.surface, in: Capsule())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Menu {
                                Picker("Sort", selection: $filters.order) {
                                    ForEach(SearchOrder.allCases) { Text($0.title).tag($0) }
                                }
                            } label: { filterLabel(filters.order.title, icon: "line.3.horizontal.decrease") }
                                .accessibilityIdentifier("search-sort-filter")
                            Menu {
                                Picker("Rating", selection: $filters.rating) {
                                    Text("Any rating").tag("")
                                    ForEach(SearchFilters.ratings, id: \.self) { Text($0.capitalized).tag($0) }
                                }
                            } label: { filterLabel(filters.rating.isEmpty ? "Rating" : filters.rating.capitalized, icon: "eye") }
                                .accessibilityIdentifier("search-rating-filter")
                            Menu {
                                Picker("Minimum score", selection: $filters.minimumScore) {
                                    Text("Any score").tag(Optional<Int>.none)
                                    ForEach(SearchFilters.scores, id: \.self) { Text("≥ \($0)").tag(Optional($0)) }
                                }
                            } label: { filterLabel(filters.minimumScore.map { "≥ \($0)" } ?? "Score", icon: "star") }
                                .accessibilityIdentifier("search-score-filter")
                        }.disabled(provider != .rule34)
                    }
                    if provider != .rule34 {
                        Text("Rating, score and random order are available for Rule34. Other sources keep their native feed sorting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Selected tags").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Clear") { tags = ""; filters = SearchFilters() }.font(.caption)
                    }
                    if tokens.isEmpty { Text("Add tags above or choose a preview below.").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(tokens, id: \.self) { token in
                            HStack(spacing: 2) {
                                Button { remove(token) } label: {
                                    Text(token.replacingOccurrences(of: "_", with: " ")).font(.caption).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                }.accessibilityLabel("Remove \(token)")
                                Button { toggleExcluded(token) } label: {
                                    Image(systemName: token.hasPrefix("-") ? "minus.circle.fill" : "nosign").frame(width: 36, height: 36)
                                }.accessibilityLabel(token.hasPrefix("-") ? "Include \(token.dropFirst())" : "Exclude \(token)")
                            }.buttonStyle(.plain).padding(.horizontal, 8)
                                .background(token.hasPrefix("-") ? Color.orange.opacity(0.15) : AppTheme.surface, in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.1)))
                        }
                    }
                    if !previews.isEmpty {
                        Text("From your feed").font(.subheadline.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(previews, id: \.stableID) { post in
                                    if let tag = post.tags.first(where: { !$0.contains(":") }) {
                                        Button { add(tag) } label: {
                                            VStack(spacing: 5) {
                                                SearchPreviewTile(post: post).frame(width: 76, height: 76).clipped()
                                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                                Text(tag.replacingOccurrences(of: "_", with: " ")).font(.caption2).lineLimit(1).frame(width: 76)
                                            }
                                        }.buttonStyle(.plain).accessibilityLabel("Add tag \(tag)")
                                    }
                                }
                            }
                        }
                    }
                    Text("Tap a tag to remove it. Use the block icon to exclude it.").font(.caption).foregroundStyle(.secondary)
                    Button(action: submit) { Label("Search", systemImage: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("apply-search-filters")
                }.padding(16)
            }.scrollDismissesKeyboard(.interactively).background(AppTheme.canvas).navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { editingTags = false }.accessibilityIdentifier("search-keyboard-done")
                    }
                }
        }
    }
    private func filterLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(height: 38)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18)))
    }
    private func remove(_ token: String) { tags = tokens.filter { $0 != token }.joined(separator: " ") }
    private func add(_ tag: String) {
        var list = tokens.filter { $0 != tag && $0 != "-" + tag }; list.append(tag); tags = list.joined(separator: " ")
    }
    private func toggleExcluded(_ token: String) {
        let replacement = token.hasPrefix("-") ? String(token.dropFirst()) : "-" + token
        tags = tokens.map { $0 == token ? replacement : $0 }.joined(separator: " ")
    }
}

private struct SearchPreviewTile: View {
    let post: Post
    @State private var decoded: DecodedMediaImage?
    var body: some View {
        Group {
            if let decoded { Image(decorative: decoded.image, scale: 1).resizable().scaledToFill() }
            else { AppTheme.surface.overlay { Image(systemName: post.isImmersiveMedia ? "play.rectangle" : "photo").foregroundStyle(AppTheme.accent) } }
        }.task(id: post.stableID) {
            // Visual hints reuse cached pixels; opening search never starts media requests.
            decoded = await MediaImagePipeline.shared.cachedAnalysisImage(raw: post.cardPreviewURL)
        }
    }
}
