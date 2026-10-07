import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool
    @State private var suggestions: [TagSuggestion] = []
    @State private var draft = ""
    init(immersive: Bool = false, focusRequested: Binding<Bool> = .constant(false)) {
        self.immersive = immersive; _focusRequested = focusRequested
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search · -tag to exclude", text: $draft)
                    .focused($focused).accessibilityIdentifier("feed-search-input")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { search() }
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
        }.padding(10).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .onAppear { draft = store.queryText }
            .onChange(of: store.queryText) { _, query in if draft != query { draft = query } }
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
        store.queryText = draft
        Task { await store.refresh(immersive: immersive, trainSearch: true) }
    }
}
