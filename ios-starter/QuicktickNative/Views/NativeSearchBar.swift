import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool
    @State private var form = SearchDraft()
    @State private var suggestions: [TagSuggestion] = []
    @State private var loaded = false
    init(immersive: Bool = false, focusRequested: Binding<Bool> = .constant(false)) {
        self.immersive = immersive; _focusRequested = focusRequested
    }
    private var tab: Int { immersive ? 1 : 0 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputRow
                    autocompleteRow
                    filterRow
                    HStack { Text("Selected tags").font(.headline); Spacer(); Button("Clear") { form.tags = []; form.text = ""; form.filters = SearchFilters() }.font(.caption) }
                    selectedTagGrid
                    Text("Tap a tag name to remove it. Tap its block icon to include or exclude it.").font(.caption).foregroundStyle(.secondary)
                    Button(action: submit) { Label("Search", systemImage: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("apply-search-filters")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).background(AppTheme.canvas.ignoresSafeArea())
                .toolbarBackground(AppTheme.canvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("close-search") } }
                .onAppear {
                    guard !loaded else { return }; loaded = true; focused = true
                    let split = SearchFilters.split(store.queryText)
                    form = store.searchDrafts[tab] ?? SearchDraft(tags: SearchTag.parse(split.tags), filters: split.filters, sort: store.feedSort)
                }
                .onDisappear { store.searchDrafts[tab] = form }
                .task(id: store.selectedProvider.rawValue + ":" + form.text) {
                    suggestions = []
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
                    #endif
                    guard store.selectedProvider == .rule34, let token = form.text.split(whereSeparator: \.isWhitespace).last else { return }
                    let query = token.hasPrefix("-") ? String(token.dropFirst()) : String(token)
                    guard query.count >= 2 else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        let values = try await store.api.suggestions(provider: .rule34, query: query)
                        guard !Task.isCancelled else { return }; suggestions = values
                    } catch { if !Task.isCancelled { suggestions = [] } }
                }
        }.background(AppTheme.canvas.ignoresSafeArea())
            .presentationBackground(AppTheme.canvas)
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(.dark)
    }
    private var inputRow: some View {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search tags", text: $form.text)
                            .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.search).onSubmit { submit() }.accessibilityIdentifier("feed-search-input")
                        Button { addTypedTags() } label: { Image(systemName: "plus.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Add tags")
                    }.padding(.horizontal, 12).background(AppTheme.surface, in: Capsule())
    }
    @ViewBuilder private var autocompleteRow: some View {
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(suggestions.prefix(6)) { item in
                                Button(item.value) { chooseSuggestion(item.value) }.buttonStyle(.bordered)
                            } }
                        }
                    }
    }
    private var filterRow: some View {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            Menu {
                                Picker("Feed order", selection: $form.sort) {
                                    Text("Recommended").tag("recommended"); Text("Created").tag("recent"); Text("Popular").tag("popular")
                                }
                                if store.selectedProvider == .rule34 {
                                    Picker("Tag order", selection: $form.filters.order) {
                                        ForEach(SearchOrder.allCases) { Text($0.title).tag($0) }
                                    }
                                }
                            } label: { filterLabel("Sorting", icon: "line.3.horizontal.decrease") }.accessibilityIdentifier("search-sort-filter")
                            if store.selectedProvider == .rule34 {
                                Menu {
                                    Picker("Rating", selection: $form.filters.rating) {
                                        Text("Any rating").tag("")
                                        ForEach(SearchFilters.ratings, id: \.self) { Text($0.capitalized).tag($0) }
                                    }
                                } label: { filterLabel(form.filters.rating.isEmpty ? "Rating" : form.filters.rating.capitalized, icon: "eye") }.accessibilityIdentifier("search-rating-filter")
                                Menu {
                                    Picker("Minimum score", selection: $form.filters.minimumScore) {
                                        Text("Any score").tag(Optional<Int>.none)
                                        ForEach(SearchFilters.scores, id: \.self) { Text("≥ \($0)").tag(Optional($0)) }
                                    }
                                } label: { filterLabel(form.filters.minimumScore.map { "≥ \($0)" } ?? "Score", icon: "star") }.accessibilityIdentifier("search-score-filter")
                            }
                        }
                    }
    }
    private var selectedTagGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
            ForEach(form.tags) { tag in tagChip(tag) }
        }
    }
    private func tagChip(_ tag: SearchTag) -> some View {
        HStack(spacing: 0) {
            Button { form.tags.removeAll { $0.id == tag.id } } label: {
                Text(tag.name.replacingOccurrences(of: "_", with: " ")).font(.caption).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44)
            }.accessibilityLabel("Remove \(tag.name)")
            Button {
                if let index = form.tags.firstIndex(where: { $0.id == tag.id }) { form.tags[index].excluded.toggle() }
            } label: { Image(systemName: tag.excluded ? "minus.circle.fill" : "nosign").frame(width: 44, height: 44) }
                .accessibilityLabel("\(tag.excluded ? "Include" : "Exclude") \(tag.name)")
        }.buttonStyle(.plain).padding(.leading, 8)
            .foregroundStyle(tag.excluded ? Color.orange : Color.white)
            .background(tag.excluded ? Color.orange.opacity(0.15) : AppTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(tag.excluded ? Color.orange.opacity(0.6) : .white.opacity(0.15)))
    }
    private func filterLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline).padding(.horizontal, 12).frame(height: 40)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
    }
    private func add(_ text: String) {
        for tag in SearchTag.parse(text) {
            if let index = form.tags.firstIndex(where: { $0.id == tag.id }) { form.tags[index].excluded = tag.excluded }
            else { form.tags.append(tag) }
        }
    }
    private func chooseSuggestion(_ value: String) {
        var parts = form.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let excluded = parts.last?.hasPrefix("-") == true
        if !parts.isEmpty { parts.removeLast() }
        parts.append((excluded ? "-" : "") + value)
        add(parts.joined(separator: " ")); form.text = ""; suggestions = []
    }
    private func addTypedTags() { add(form.text); form.text = ""; suggestions = [] }
    private func submit() {
        addTypedTags(); focused = false
        store.searchDrafts[tab] = form
        let tags = form.tags.map { ($0.excluded ? "-" : "") + $0.name }.joined(separator: " ")
        let query = form.filters.query(tags: tags, provider: store.selectedProvider)
        store.commitSearch(query: query, sort: form.sort)
        dismiss()
        Task { await store.refresh(immersive: immersive, trainSearch: true) }
    }
}
