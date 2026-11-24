import SwiftUI
import UIKit

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var form = SearchDraft()
    @State private var suggestions: [TagSuggestion] = []
    @State private var pornhubCategories = PornhubSearchFilters.commonCategories
    @State private var suggestionsLoading = false
    @State private var suggestionsUnavailable = false
    @State private var loaded = false
    @State private var showRedgifsNiches = false
    init(immersive: Bool = false, focusRequested: Binding<Bool> = .constant(false)) {
        self.immersive = immersive; _focusRequested = focusRequested
    }
    private var tab: Int { immersive ? 1 : 0 }
    private var isArchive: Bool { store.selectedProvider == .kemono || store.selectedProvider == .coomer }
    var body: some View {
        NavigationStack {
            searchScrollView
        }.background(AppTheme.canvas.ignoresSafeArea())
            .presentationBackground(AppTheme.canvas)
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(.dark)
    }

    private var searchScrollView: some View {
        ScrollView { searchForm }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.canvas.ignoresSafeArea())
            .toolbarBackground(AppTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("close-search")
                }
            }
            .onAppear(perform: restoreSearchDraft)
            .onDisappear(perform: persistSearchDraft)
            .task(id: "artist-index-" + store.selectedProvider.rawValue) { await prefetchArtists() }
            .task(id: "pornhub-categories-" + store.selectedProvider.rawValue) { await loadPornhubCategories() }
            .task(id: store.selectedProvider.rawValue + ":" + form.text) { await updateSuggestions() }
    }

    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            inputRow
            if store.selectedProvider == .rule34 || isArchive { autocompleteRow }
            filterRow
            if store.selectedProvider == .redgifs {
                redgifsNicheControl
            }
            if store.selectedProvider == .pornhub {
                PornhubFilterPanel(filters: $form.pornhub, categories: pornhubCategories)
            }
            queryEditingControls
            submitButton
        }.padding(20)
            .sheet(isPresented: $showRedgifsNiches) {
                RedgifsSearchNichePicker(selection: $form.redgifsNiche)
                    .environmentObject(store)
            }
    }

    private var redgifsNicheControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Niche").font(.headline)
            HStack {
                Button { focused = false; showRedgifsNiches = true } label: {
                    HStack {
                        Label(form.redgifsNiche?.replacingOccurrences(of: "-", with: " ").capitalized ?? "All niches",
                              systemImage: "square.grid.2x2")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("redgifs-niche-filter")
                if form.redgifsNiche != nil {
                    Button { form.redgifsNiche = nil } label: {
                        Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Clear niche")
                }
            }
            Text("Choose a niche, then enter optional keywords to search within it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var queryEditingControls: some View {
        if store.selectedProvider == .rule34 {
            HStack {
                Text("Selected tags").font(.headline)
                Spacer()
                Button("Clear") { form.tags = []; form.text = ""; form.filters = SearchFilters() }.font(.caption)
            }
            selectedTagGrid
            Text("Tap a tag name to remove it. Tap its block icon to include or exclude it.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(isArchive ? "Search post titles or select an artist suggestion to see that creator's posts." :
                (store.selectedProvider == .hanime
                 ? "Search by title keywords or tags (for example fantasy, ahegao, or \"dark skin\"). Use -\"tag\" to exclude a tag."
                 : "Search titles and keywords. Use quotes for phrases (\"red hair\") and -\"phrase\" to exclude them."))
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Clear keywords") {
                form.text = ""; form.archiveCreatorReference = nil; form.archiveCreatorLabel = nil
            }.font(.caption).disabled(form.text.isEmpty)
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Label("Search", systemImage: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("apply-search-filters")
    }

    private func restoreSearchDraft() {
        guard !loaded else { return }
        loaded = true; focused = true
        let split = SearchFilters.split(store.queryText)
        let parsed = QueryParser.parse(split.tags)
        let keywords = ProviderSearchCategories.split(parsed, provider: store.selectedProvider).keywords
        let plainQuery = store.selectedProvider == .hhaven || store.selectedProvider == .pornhub
            ? QueryParser.formatted(ParsedQuery(included: keywords, excluded: parsed.excluded))
            : split.tags
        var pornhubFilters = PornhubSearchFilters.decode(store.queryText)
        if store.selectedProvider == .pornhub, pornhubFilters.includedCategory == nil, pornhubFilters.includedEthnicity == nil,
           let selectedCategory = ProviderSearchCategories.split(parsed, provider: .pornhub).category {
            pornhubFilters.includedCategory = String(selectedCategory.dropFirst("category:".count))
        }
        pornhubFilters = pornhubFilters.normalized
        if let saved = store.searchDrafts[tab], saved.provider == store.selectedProvider {
            form = saved
        } else {
            form = SearchDraft(text: store.selectedProvider == .rule34 ? "" : plainQuery,
                               tags: store.selectedProvider == .rule34 ? SearchTag.parse(split.tags) : [],
                               filters: split.filters, pornhub: pornhubFilters, sort: store.feedSort,
                               provider: store.selectedProvider)
        }
        if store.selectedProvider == .pornhub { form.pornhub = form.pornhub.normalized }
        if store.selectedProvider == .redgifs {
            let draft = QueryParser.parse(form.text)
            form.redgifsNiche = NativeProviderAPI.redgifsSelectedNiche(parsed)
                ?? NativeProviderAPI.redgifsSelectedNiche(draft) ?? form.redgifsNiche
            form.text = QueryParser.formatted(ParsedQuery(
                included: draft.included.filter { !$0.hasPrefix("niche:") },
                excluded: draft.excluded))
        }
    }

    private func persistSearchDraft() {
        form.provider = store.selectedProvider
        store.searchDrafts[tab] = form
    }

    private func prefetchArtists() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        if isArchive { await store.api.prefetchArchiveCreators(for: store.selectedProvider) }
    }

    private func loadPornhubCategories() async {
        guard store.selectedProvider == .pornhub else { return }
        if let categories = try? await store.api.pornhubCategories(), !categories.isEmpty {
            pornhubCategories = categories
        }
    }

    private func updateSuggestions() async {
        suggestions = []; suggestionsLoading = false; suggestionsUnavailable = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        let provider = store.selectedProvider
        guard provider == .rule34 || provider == .kemono || provider == .coomer,
              form.archiveCreatorReference == nil else { return }
        let query: String
        if provider == .rule34 {
            guard let token = form.text.split(whereSeparator: \.isWhitespace).last else { return }
            query = token.hasPrefix("-") ? String(token.dropFirst()) : String(token)
        } else { query = form.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard query.count >= 2 else { return }
        do {
            try await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            suggestionsLoading = true
            let values = try await store.api.suggestions(provider: provider, query: query)
            guard !Task.isCancelled else { return }
            suggestions = values; suggestionsLoading = false
        } catch {
            if !Task.isCancelled {
                suggestions = []; suggestionsLoading = false
                suggestionsUnavailable = isArchive
            }
        }
    }
    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(focused ? AppTheme.accent : AppTheme.secondaryLabel)
                .frame(width: 26)
            TextField(store.selectedProvider == .rule34 ? "Search tags" : (isArchive ? "Search artists or posts" : "Search titles and keywords"), text: $form.text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { submit() }
                .onChange(of: form.text) { _, value in
                    if form.archiveCreatorReference != nil, value != form.archiveCreatorLabel {
                        form.archiveCreatorReference = nil
                        form.archiveCreatorLabel = nil
                    }
                }
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
                                Button(item.label) { chooseSuggestion(item) }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(AppTheme.accent.opacity(0.13), in: Capsule())
                                    .overlay(Capsule().stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                                    .buttonStyle(QuicktickPressStyle())
                            } }
                        }
                    } else if isArchive && suggestionsLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finding artists…").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("archive-artist-loading")
                    } else if isArchive && suggestionsUnavailable {
                        Text("Artist suggestions are temporarily unavailable. Post search still works.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
    }
    private var filterRow: some View {
                    Group { if store.selectedProvider != .pornhub {
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
                    } }
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
            .contextMenu {
                Button { UIPasteboard.general.string = tag.name } label: {
                    Label("Copy tag", systemImage: "doc.on.doc")
                }
            }
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
    private func chooseSuggestion(_ suggestion: TagSuggestion) {
        if isArchive {
            form.archiveCreatorReference = suggestion.value
            form.archiveCreatorLabel = suggestion.label
            form.text = suggestion.label
            suggestions = []
            return
        }
        var parts = form.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let excluded = parts.last?.hasPrefix("-") == true
        if !parts.isEmpty { parts.removeLast() }
        parts.append((excluded ? "-" : "") + suggestion.value)
        add(parts.joined(separator: " ")); form.text = ""; suggestions = []
    }
    private func addTypedTags() { add(form.text); form.text = ""; suggestions = [] }
    private func submit() {
        let isTagProvider = store.selectedProvider == .rule34
        if isTagProvider { addTypedTags() }
        focused = false
        form.provider = store.selectedProvider
        let query: String
        if isTagProvider {
            let tags = form.tags.map { ($0.excluded ? "-" : "") + $0.name }.joined(separator: " ")
            query = form.filters.query(tags: tags, provider: store.selectedProvider)
        } else if store.selectedProvider == .pornhub {
            query = form.pornhub.encodedQuery(form.text)
            form.sort = form.pornhub.order.feedSort
        } else if store.selectedProvider == .redgifs {
            var parsed = QueryParser.parse(form.text)
            if let niche = form.redgifsNiche {
                parsed.included.removeAll { $0.hasPrefix("niche:") }
                parsed.included.insert("niche:" + niche, at: 0)
            }
            query = QueryParser.formatted(parsed)
        } else {
            query = (isArchive ? form.archiveCreatorReference : nil)
                ?? form.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        store.searchDrafts[tab] = form
        store.commitSearch(query: query, sort: form.sort)
        dismiss()
        Task { await store.refresh(immersive: immersive, trainSearch: true) }
    }
}


/// A lightweight directory for search; artwork is not required for a valid
/// niche and the next page remains reachable even if the current filter is empty.
private struct RedgifsSearchNichePicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    @State private var niches: [RedgifsNiche] = []
    @State private var search = ""
    @State private var nextPage = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    private var visible: [RedgifsNiche] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return niches.filter {
            needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) ||
                $0.id.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = nil; dismiss()
                } label: {
                    HStack {
                        Text("All niches")
                        Spacer()
                        if selection == nil { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                ForEach(visible) { niche in
                    Button {
                        selection = niche.id; dismiss()
                    } label: {
                        HStack {
                            Text(niche.name)
                            Spacer()
                            if selection == niche.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .accessibilityIdentifier("redgifs-niche-\(niche.id)")
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if loading {
                    HStack { ProgressView(); Text("Loading niches…") }
                } else if hasMore {
                    Button(error == nil ? "Load more niches" : "Retry") {
                        Task { await loadNextPage() }
                    }
                    .accessibilityIdentifier("redgifs-load-more-niches")
                } else if visible.isEmpty {
                    Text("No matching niches").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, prompt: "Find a niche")
            .navigationTitle("Choose a niche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { if niches.isEmpty { await loadNextPage() } }
        }
        .preferredColorScheme(.dark)
    }

    @MainActor private func loadNextPage() async {
        guard !loading, hasMore else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await store.api.redgifsNichesPage(page: nextPage, limit: 24, includeArtwork: false)
            try Task.checkCancellation()
            var known = Set(niches.map(\.id))
            niches.append(contentsOf: result.items.filter { known.insert($0.id).inserted })
            hasMore = result.hasMore
            nextPage += 1
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
