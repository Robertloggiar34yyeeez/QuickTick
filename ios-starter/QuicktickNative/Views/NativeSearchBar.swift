import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    var immersive = false
    @State private var suggestions: [TagSuggestion] = []
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search · -tag to exclude", text: $store.queryText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { search() }
                Button { search() } label: { Image(systemName: "arrow.right").font(.headline).frame(width: 44, height: 44).background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel("Search")
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(suggestions.prefix(6)) { suggestion in
                        Button(suggestion.value) {
                            var parts = store.queryText.split(whereSeparator: \.isWhitespace).map(String.init)
                            let negative = parts.last?.hasPrefix("-") == true
                            if !parts.isEmpty { parts.removeLast() }
                            parts.append((negative ? "-" : "") + suggestion.value)
                            store.queryText = parts.joined(separator: " "); suggestions = []
                        }.buttonStyle(.bordered)
                    } }
                }
            }
        }.padding(10).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .task(id: store.selectedProvider.rawValue + ":" + store.queryText) {
                suggestions = []
                guard store.selectedProvider == .rule34, let token = store.queryText.split(whereSeparator: \.isWhitespace).last else { return }
                let query = token.hasPrefix("-") ? String(token.dropFirst()) : String(token)
                guard query.count >= 2 else { return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    let result = try await store.api.suggestions(provider: .rule34, query: query)
                    guard !Task.isCancelled else { return }; suggestions = result
                } catch { suggestions = [] }
            }
    }
    private func search() { suggestions = []; Task { await store.refresh(immersive: immersive, trainSearch: true) } }
}
