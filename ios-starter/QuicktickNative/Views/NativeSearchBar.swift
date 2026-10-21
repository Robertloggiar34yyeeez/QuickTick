import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool

    private struct SelectedTag: Identifiable, Equatable {
        let value: String
        var excluded: Bool
        var id: String { value.lowercased() }
    }

    @State private var suggestions: [TagSuggestion] = []
    @State private var draft = ""
    @State private var selectedTags: [SelectedTag] = []
    @State private var initialized = false

    init(immersive: Bool = false, focusRequested: Binding<Bool> = .constant(false)) {
        self.immersive = immersive
        _focusRequested = focusRequested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Add tags · -tag to exclude", text: $draft)
                    .focused($focused)
                    .accessibilityIdentifier("feed-search-input")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { search() }
                Button { search() } label: {
                    Image(systemName: "arrow.right")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }

            if !selectedTags.isEmpty {
                Text("Selected tags")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(selectedTags) { tag in
                        HStack(spacing: 0) {
                            Button {
                                selectedTags.removeAll { $0.id == tag.id }
                            } label: {
                                Text(tag.value)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 10)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Remove tag \(tag.value)")
                            .accessibilityIdentifier("search-tag-\(tag.id)")
                            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 26)
                            Button {
                                guard let index = selectedTags.firstIndex(where: { $0.id == tag.id }) else { return }
                                selectedTags[index].excluded.toggle()
                            } label: {
                                Image(systemName: tag.excluded ? "checkmark.circle.fill" : "nosign")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(tag.excluded ? .orange : .white.opacity(0.8))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(tag.excluded ? "Include tag \(tag.value)" : "Exclude tag \(tag.value)")
                            .accessibilityIdentifier("search-block-\(tag.id)")
                        }
                        .buttonStyle(.plain)
                        .background(AppTheme.surface, in: Capsule())
                        .overlay(Capsule().stroke(tag.excluded ? .orange.opacity(0.7) : .white.opacity(0.18)))
                    }
                }
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions.prefix(6)) { suggestion in
                            Button(suggestion.value) {
                                let excluded = draft.split(whereSeparator: \.isWhitespace).last?.hasPrefix("-") == true
                                addTag(suggestion.value, excluded: excluded)
                                draft = ""
                                suggestions = []
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("tag-suggestion-\(suggestion.value)")
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            if !initialized {
                initialized = true
                selectedTags = tags(from: store.queryText)
            }
        }
        .onChange(of: store.queryText) { _, query in
            if initialized && serializedTags != query { selectedTags = tags(from: query); draft = "" }
        }
        .task(id: focusRequested) {
            if focusRequested { focused = true; focusRequested = false }
        }
        .task(id: store.selectedProvider.rawValue + ":" + draft) {
            suggestions = []
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            guard store.selectedProvider == .rule34,
                  let token = draft.split(whereSeparator: \.isWhitespace).last else { return }
            let query = token.hasPrefix("-") ? String(token.dropFirst()) : String(token)
            guard query.count >= 2 else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await store.api.suggestions(provider: .rule34, query: query)
                guard !Task.isCancelled else { return }
                suggestions = result
            } catch { suggestions = [] }
        }
    }

    private var serializedTags: String {
        selectedTags.map { ($0.excluded ? "-" : "") + $0.value }.joined(separator: " ")
    }

    private func tags(from text: String) -> [SelectedTag] {
        let parsed = QueryParser.parse(text)
        var result: [SelectedTag] = []
        for tag in parsed.included {
            result.append(SelectedTag(value: tag, excluded: false))
        }
        for tag in parsed.excluded {
            if let index = result.firstIndex(where: { $0.id == tag.lowercased() }) {
                result[index].excluded = true
            } else {
                result.append(SelectedTag(value: tag, excluded: true))
            }
        }
        return result
    }

    private func addTag(_ value: String, excluded: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = selectedTags.firstIndex(where: { $0.id == trimmed.lowercased() }) {
            selectedTags[index].excluded = excluded
        } else {
            selectedTags.append(SelectedTag(value: trimmed, excluded: excluded))
        }
    }

    private func search() {
        let parsed = QueryParser.parse(draft)
        for tag in parsed.included { addTag(tag, excluded: false) }
        for tag in parsed.excluded { addTag(tag, excluded: true) }
        draft = ""
        focused = false
        suggestions = []
        // Commit only on Search, not on each keystroke or chip interaction.
        store.queryText = serializedTags
        Task { await store.refresh(immersive: immersive, trainSearch: true) }
    }
}
