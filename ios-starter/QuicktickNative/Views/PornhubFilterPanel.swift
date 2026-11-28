import SwiftUI

/// Provider-specific controls: nothing in this panel is used by Rule34 or any
/// other keyword provider.
struct PornhubFilterPanel: View {
    @Binding var filters: PornhubSearchFilters
    let categories: [String]
    @State private var categoryPicker: CategoryPicker?

    private enum CategoryPicker: String, Identifiable {
        case included, ethnicity, excluded
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

            Label("Categories", systemImage: "tag").font(.headline)
            categoryButton(title: "Topic",
                           detail: filters.includedCategory ?? "Any topic",
                           subtitle: "Choose one topic") { categoryPicker = .included }
                .accessibilityIdentifier("pornhub-included-category")
            categoryButton(title: "Ethnicity",
                           detail: filters.includedEthnicity ?? "Any ethnicity",
                           subtitle: "Provider category") { categoryPicker = .ethnicity }
                .accessibilityIdentifier("pornhub-ethnicity-category")
            Text("Both selections must match when combined. Categories are supplied by the provider.")
                .font(.caption).foregroundStyle(.secondary)
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
                                  excluding: picker == .excluded, ethnicity: picker == .ethnicity)
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
    let ethnicity: Bool
    @State private var search = ""

    private var visible: [String] {
        categories.filter {
            (excluding || PornhubSearchFilters.isEthnicityCategory($0) == ethnicity) &&
                (search.isEmpty || $0.localizedCaseInsensitiveContains(search))
        }
    }

    private var selectedCategory: String? {
        ethnicity ? filters.includedEthnicity : filters.includedCategory
    }

    private func choose(_ value: String?) {
        if ethnicity { filters.includedEthnicity = value }
        else { filters.includedCategory = value }
        filters = filters.normalized
    }

    private var title: String {
        if excluding { return "Exclude categories (\(filters.excludedCategories.count)/10)" }
        return ethnicity ? "Ethnicity" : "Topic"
    }

    var body: some View {
        NavigationStack {
            List {
                if !excluding {
                    categoryRow(ethnicity ? "Any ethnicity" : "Any topic", selected: selectedCategory == nil,
                                disabled: false) { choose(nil) }
                }
                ForEach(visible, id: \.self) { category in
                    let selected = excluding
                        ? filters.excludedCategories.contains(category)
                        : selectedCategory == category
                    categoryRow(category, selected: selected,
                                disabled: excluding && !selected && filters.excludedCategories.count >= 10) {
                        if excluding {
                            if selected { filters.excludedCategories.removeAll { $0 == category } }
                            else if filters.excludedCategories.count < 10 {
                                filters.excludedCategories.append(category)
                                if filters.includedCategory == category { filters.includedCategory = nil }
                                if filters.includedEthnicity == category { filters.includedEthnicity = nil }
                            }
                        } else {
                            choose(selected ? nil : category)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find category")
            .navigationTitle(title)
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
