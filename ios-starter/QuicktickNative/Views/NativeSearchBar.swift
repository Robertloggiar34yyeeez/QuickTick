import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    if store.selectedProvider == .rule34 {
                        autocompleteRow
                    }
                    filterRow
                    if store.selectedProvider == .rule34 {
                        HStack { Text("Selected tags").font(.headline); Spacer(); Button("Clear") { form.tags = []; form.text = ""; form.filters = SearchFilters() }.font(.caption) }
                        selectedTagGrid
                        Text("Tap a tag name to remove it. Tap its block icon to include or exclude it.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Search titles and keywords. Use quotes for phrases (\"red hair\") and -\"phrase\" to exclude them. Providers use free-text search, not Rule34 tags.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Clear keywords") { form.text = "" }
                            .font(.caption).disabled(form.text.isEmpty)
                    }
                    Button(action: submit) {
                        Label("Search", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityIdentifier("apply-search-filters")
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
                    if let saved = store.searchDrafts[tab], saved.provider == store.selectedProvider {
                        form = saved
                    } else {
                        form = SearchDraft(
                            text: store.selectedProvider == .rule34 ? "" : split.tags,
                            tags: store.selectedProvider == .rule34 ? SearchTag.parse(split.tags) : [],
                            filters: split.filters, sort: store.feedSort,
                            provider: store.selectedProvider)
                    }
                }
                .onDisappear {
                    form.provider = store.selectedProvider
                    store.searchDrafts[tab] = form
                }
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
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(focused ? AppTheme.accent : AppTheme.secondaryLabel)
                .frame(width: 26)
            TextField(store.selectedProvider == .rule34 ? "Search tags" : "Search titles and keywords", text: $form.text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { submit() }
                .tint(AppTheme.accent)
                .accessibilityIdentifier("feed-search-input")
            if !form.text.isEmpty {
                Button {
                    form.text = ""
                    suggestions = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondaryLabel)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Clear search text")
            }
            if store.selectedProvider == .rule34 {
                Button { addTypedTags() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Add tags")
            }
        }
        .padding(10)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(focused ? AppTheme.accent.opacity(0.7) : AppTheme.border, lineWidth: focused ? 1.5 : 1)
        }
        .shadow(color: focused ? AppTheme.accent.opacity(0.14) : .clear, radius: 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
    @ViewBuilder private var autocompleteRow: some View {
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(suggestions.prefix(6)) { item in
                                Button(item.value) { chooseSuggestion(item.value) }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(AppTheme.accent.opacity(0.13), in: Capsule())
                                    .overlay(Capsule().stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                                    .buttonStyle(QuicktickPressStyle())
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
            .background(tag.excluded ? Color.orange.opacity(0.15) : AppTheme.elevatedSurface, in: Capsule())
            .overlay(Capsule().stroke(tag.excluded ? Color.orange.opacity(0.6) : .white.opacity(0.15)))
    }
    private func filterLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline).padding(.horizontal, 12).frame(height: 40)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border))
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
        let isTagProvider = store.selectedProvider == .rule34
        if isTagProvider { addTypedTags() }
        focused = false
        form.provider = store.selectedProvider
        store.searchDrafts[tab] = form
        let query: String
        if isTagProvider {
            let tags = form.tags.map { ($0.excluded ? "-" : "") + $0.name }.joined(separator: " ")
            query = form.filters.query(tags: tags, provider: store.selectedProvider)
        } else {
            query = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        store.commitSearch(query: query, sort: form.sort)
        dismiss()
        Task { await store.refresh(immersive: immersive, trainSearch: true) }
    }
}
