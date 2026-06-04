import SwiftUI

struct FilterBarView: View {
    @Bindable var viewModel: IssueListViewModel
    var accent: Color = .accentColor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if viewModel.allowsAppFilter {
                    MultiSelectFilterChip(
                        label: "App",
                        values: viewModel.uniqueAppNames,
                        selection: $viewModel.appFilter,
                        display: { $0 },
                        accent: accent
                    )
                }
                MultiSelectFilterChip(
                    label: "Type",
                    values: viewModel.uniqueIssueTypes,
                    selection: Binding(
                        get: { viewModel.filters.issueType },
                        set: { viewModel.filters.issueType = $0 }
                    ),
                    display: { $0.displayName },
                    symbol: { $0.systemImage },
                    accent: accent
                )
                MultiSelectFilterChip(
                    label: "Version",
                    values: viewModel.uniqueValues(for: \.appVersion),
                    selection: binding(for: \.appVersion),
                    display: { $0 },
                    accent: accent
                )
                MultiSelectFilterChip(
                    label: "Device",
                    values: viewModel.uniqueValues(for: \.device),
                    selection: binding(for: \.device),
                    display: DeviceName.friendly,
                    accent: accent
                )
                MultiSelectFilterChip(
                    label: "OS",
                    values: viewModel.uniqueValues(for: \.osVersion),
                    selection: binding(for: \.osVersion),
                    display: OSVersionFormat.display,
                    accent: accent
                )

                if hasAnyActiveFilter {
                    ClearFiltersButton(title: "Clear All", action: clearAll)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
    }

    private var hasAnyActiveFilter: Bool {
        !viewModel.appFilter.isEmpty || !viewModel.filters.isEmpty
    }

    private func clearAll() {
        withAnimation(.easeInOut(duration: 0.18)) {
            viewModel.appFilter = []
            viewModel.clearFilters()
        }
    }

    private func binding(for keyPath: WritableKeyPath<IssueListViewModel.ActiveFilters, Set<String>>) -> Binding<Set<String>> {
        Binding(
            get: { viewModel.filters[keyPath: keyPath] },
            set: { viewModel.filters[keyPath: keyPath] = $0 }
        )
    }
}
