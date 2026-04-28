import SwiftUI

struct FilterBarView: View {
    @Bindable var viewModel: IssueListViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if viewModel.allowsAppFilter {
                    FilterChip(
                        label: "App",
                        values: viewModel.uniqueAppNames,
                        selection: $viewModel.appFilter
                    )
                }
                IssueTypeFilterChip(
                    types: viewModel.uniqueIssueTypes,
                    selection: Binding(
                        get: { viewModel.filters.issueType },
                        set: { viewModel.filters.issueType = $0 }
                    )
                )
                FilterChip(
                    label: "Version",
                    values: viewModel.uniqueValues(for: \.appVersion),
                    selection: binding(for: \.appVersion)
                )
                FilterChip(
                    label: "Device",
                    values: viewModel.uniqueValues(for: \.device),
                    selection: binding(for: \.device),
                    display: DeviceName.friendly
                )
                FilterChip(
                    label: "OS",
                    values: viewModel.uniqueValues(for: \.osVersion),
                    selection: binding(for: \.osVersion),
                    display: OSVersionFormat.display
                )

                if hasAnyActiveFilter {
                    Button(action: clearAll) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Clear All")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all filters")
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

// MARK: - Generic string-valued filter chip

private struct FilterChip: View {
    let label: String
    let values: [String]
    @Binding var selection: Set<String>
    var display: ((String) -> String)? = nil

    var body: some View {
        if !values.isEmpty {
            FilterChipContainer(isActive: !selection.isEmpty) {
                Menu {
                    if !selection.isEmpty {
                        Button("Clear \(label)") { selection = [] }
                        Divider()
                    }
                    ForEach(values, id: \.self) { value in
                        Button {
                            if selection.contains(value) { selection.remove(value) }
                            else { selection.insert(value) }
                        } label: {
                            if selection.contains(value) {
                                Label(display?(value) ?? value, systemImage: "checkmark")
                            } else {
                                Text(display?(value) ?? value)
                            }
                        }
                    }
                } label: {
                    FilterTitleSegment(
                        label: label,
                        showsAll: selection.isEmpty
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                ForEach(Array(selection).sorted(), id: \.self) { value in
                    SubPill(text: display?(value) ?? value) {
                        selection.remove(value)
                    }
                }
            }
        }
    }
}

// MARK: - IssueType-valued filter chip

private struct IssueTypeFilterChip: View {
    let types: [IssueType]
    @Binding var selection: Set<IssueType>

    var body: some View {
        if !types.isEmpty {
            FilterChipContainer(isActive: !selection.isEmpty) {
                Menu {
                    if !selection.isEmpty {
                        Button("Clear Type") { selection = [] }
                        Divider()
                    }
                    ForEach(types, id: \.self) { type in
                        Button {
                            if selection.contains(type) { selection.remove(type) }
                            else { selection.insert(type) }
                        } label: {
                            let isSelected = selection.contains(type)
                            Label {
                                Text(type.displayName)
                            } icon: {
                                Image(systemName: isSelected ? "checkmark" : type.systemImage)
                            }
                        }
                    }
                } label: {
                    FilterTitleSegment(label: "Type", showsAll: selection.isEmpty)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                ForEach(Array(selection).sorted(by: { $0.displayName < $1.displayName }), id: \.self) { type in
                    SubPill(text: type.displayName, leadingSymbol: type.systemImage) {
                        selection.remove(type)
                    }
                }
            }
        }
    }
}

// MARK: - Shared chip pieces

/// Outer rounded capsule that contains the title segment + sub-pills as one unit.
private struct FilterChipContainer<Content: View>: View {
    let isActive: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            isActive ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                isActive ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.18),
                lineWidth: 1
            )
        )
    }
}

/// The "Title:" / "Title : All" portion that opens the menu.
private struct FilterTitleSegment: View {
    let label: String
    let showsAll: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(":")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            if showsAll {
                Text("All")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, showsAll ? 8 : 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Removable sub-pill rendered inline inside the outer chip.
private struct SubPill: View {
    let text: String
    var leadingSymbol: String? = nil
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 3) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(text)")
    }
}
