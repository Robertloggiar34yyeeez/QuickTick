import SwiftUI

struct NativeSearchBar: View {
    @EnvironmentObject private var store: AppStore
    var immersive = false
    @Binding var focusRequested: Bool
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestions: [TagSuggestion] = []
    @State private var draft = ""
    @State private var initialized = false
    init(immersive: Bool = false, focusRequested: Binding<Bool> = .constant(false)) {
        self.immersive = immersive; _focusRequested = focusRequested
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(focused ? AppTheme.accent : AppTheme.secondaryLabel)
                    .frame(width: 26)
                TextField("Search · -tag to exclude", text: $draft)
                    .focused($focused).accessibilityIdentifier("feed-search-input")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { search() }
                    .tint(AppTheme.accent)
                if !draft.isEmpty {
                    Button {
                        draft = ""
                        suggestions = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(AppTheme.secondaryLabel)
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityLabel("Clear search text")
                }
                Button { search() } label: {
                    Image(systemName: "arrow.right")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Search")
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions.prefix(6)) { suggestion in
                            Button(suggestion.value) {
                                var parts = draft.split(whereSeparator: \.isWhitespace).map(String.init)
                                let negative = parts.last?.hasPrefix("-") == true
                                if !parts.isEmpty { parts.removeLast() }
                                parts.append((negative ? "-" : "") + suggestion.value)
                                draft = parts.joined(separator: " "); suggestions = []
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(AppTheme.accent.opacity(0.13), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                            .buttonStyle(QuicktickPressStyle())
                        }
                    }
                }
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
            .onAppear {
                if !initialized { initialized = true; draft = store.queryText }
            }
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
