import SwiftUI

/// Provider-specific controls: nothing in this panel is used by Rule34 or any
/// other keyword provider.
struct PornhubFilterPanel: View {
    @Binding var filters: PornhubSearchFilters
    let categories: [String]
    @State private var categoryPicker: CategoryPicker?

    private enum CategoryPicker: String, Identifiable {
        case included, excluded
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sort by", systemImage: "arrow.up.arrow.down")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(PornhubSearchOrder.allCases) { option in
                    chip(option.title, selected: filters.order == option) { filters.order = option }
                        .accessibilityIdentifier("pornhub-sort-\(option.rawValue)")
                }
            }

            Divider().padding(.vertical, 5)
            Label("Filters", systemImage: "slider.horizontal.3").font(.headline)
            Text("Production").font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                ForEach(PornhubProduction.allCases) { option in
                    chip(option.title, selected: filters.production == option) { filters.production = option }
                        .accessibilityIdentifier("pornhub-production-\(option.rawValue)")
                }
            }

            Text("Duration (minutes)").font(.subheadline.weight(.medium)).padding(.top, 5)
            HStack {
                Text("Minimum").foregroundStyle(.secondary)
                Spacer()
                Text("\(filters.minimumMinutes) min").monospacedDigit()
            }.font(.caption)
            Slider(value: Binding(get: { Double(filters.minimumMinutes) }, set: {
                filters.minimumMinutes = min(filters.maximumMinutes, Int($0))
            }), in: 0...40, step: 5)
                .tint(AppTheme.accent)
                .accessibilityIdentifier("pornhub-duration-min")

            HStack {
                Text("Maximum").foregroundStyle(.secondary)
                Spacer()
                Text(filters.maximumMinutes == 40 ? "40+ min" : "\(filters.maximumMinutes) min").monospacedDigit()
            }.font(.caption)
            Slider(value: Binding(get: { Double(filters.maximumMinutes) }, set: {
                filters.maximumMinutes = max(filters.minimumMinutes, Int($0))
            }), in: 0...40, step: 5)
                .tint(AppTheme.accent)
                .accessibilityIdentifier("pornhub-duration-max")

            categoryButton(title: "Included category",
                           detail: filters.includedCategory ?? "All categories",
                           subtitle: "Choose up to 1 category") { categoryPicker = .included }
                .accessibilityIdentifier("pornhub-included-category")
            categoryButton(title: "Excluded categories",
                           detail: filters.excludedCategories.isEmpty ? "None" : "\(filters.excludedCategories.count) selected",
                           subtitle: "Exclude up to 10 categories") { categoryPicker = .excluded }
                .accessibilityIdentifier("pornhub-excluded-categories")

            Button {
                filters = PornhubSearchFilters()
            } label: {
                Label("Reset Pornhub filters", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("pornhub-reset-filters")
        }
        .sheet(item: $categoryPicker) { picker in
            PornhubCategoryPicker(filters: $filters, categories: categories,
                                  excluding: picker == .excluded)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 46)
                .padding(.horizontal, 4)
                .background(selected ? AppTheme.accent.opacity(0.17) : AppTheme.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? AppTheme.accent : AppTheme.border, lineWidth: selected ? 1.5 : 1))
        }.buttonStyle(.plain)
    }

    private func categoryButton(title: String, detail: String, subtitle: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct PornhubCategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: PornhubSearchFilters
    let categories: [String]
    let excluding: Bool
    @State private var search = ""

    private var visible: [String] {
        categories.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !excluding {
                    categoryRow("All categories", selected: filters.includedCategory == nil,
                                disabled: false) { filters.includedCategory = nil }
                }
                ForEach(visible, id: \.self) { category in
                    let selected = excluding
                        ? filters.excludedCategories.contains(category)
                        : filters.includedCategory == category
                    categoryRow(category, selected: selected,
                                disabled: excluding && !selected && filters.excludedCategories.count >= 10) {
                        if excluding {
                            if selected { filters.excludedCategories.removeAll { $0 == category } }
                            else if filters.excludedCategories.count < 10 {
                                filters.excludedCategories.append(category)
                                if filters.includedCategory == category { filters.includedCategory = nil }
                            }
                        } else {
                            filters.includedCategory = selected ? nil : category
                            filters.excludedCategories.removeAll { $0 == category }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find category")
            .navigationTitle(excluding ? "Exclude categories (\(filters.excludedCategories.count)/10)" : "Included category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func categoryRow(_ name: String, selected: Bool, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent) }
            }
        }
        .disabled(disabled)
        .foregroundStyle(disabled ? .secondary : .primary)
    }
}
