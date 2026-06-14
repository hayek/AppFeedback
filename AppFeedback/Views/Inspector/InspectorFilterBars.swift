import SwiftUI

/// Filter + search row for the inspector's **Tasks** section: status, priority, and version
/// multi-selects plus an expandable search field. Bound to `inspector.taskFilters`.
struct TaskFilterBar: View {
    @Bindable var inspector: ProjectInspectorModel
    var accent: Color = .accentColor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ExpandableSearchField(text: $inspector.taskFilters.search, prompt: "Search tasks", accent: accent)
                MultiSelectFilterChip(
                    label: "Status",
                    values: TaskStatus.allCases,
                    selection: $inspector.taskFilters.statuses,
                    display: { $0.displayName },
                    accent: accent
                )
                MultiSelectFilterChip(
                    label: "Priority",
                    values: TaskPriority.allCases,
                    selection: $inspector.taskFilters.priorities,
                    display: { $0.displayName },
                    accent: accent
                )
                VersionScopeFilterChip(filters: $inspector.taskFilters,
                                       versions: inspector.uniqueTaskVersions,
                                       accent: accent)
                if inspector.taskFilters.isActive {
                    ClearFiltersButton(title: "Clear") {
                        withAnimation(.easeInOut(duration: 0.18)) { inspector.clearTaskFilters() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}

/// Filter + search row for the inspector's **Versions** section: a state multi-select plus an
/// expandable search field matching version name/title. Bound to `inspector.versionFilters`.
struct VersionFilterBar: View {
    @Bindable var inspector: ProjectInspectorModel
    var accent: Color = .accentColor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ExpandableSearchField(text: $inspector.versionFilters.search, prompt: "Search versions", accent: accent)
                MultiSelectFilterChip(
                    label: "Status",
                    values: [VersionState.new, .wip, .released],
                    selection: $inspector.versionFilters.states,
                    display: { $0.title },
                    symbol: { $0.symbol },
                    accent: accent
                )
                if inspector.versionFilters.isActive {
                    ClearFiltersButton(title: "Clear") {
                        withAnimation(.easeInOut(duration: 0.18)) { inspector.clearVersionFilters() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}

/// The task **Version** filter: single-select state chips (New / In Progress / Released) plus a
/// "Version" submenu of specific milestone names. Selection follows `TaskFilters`' override rules.
struct VersionScopeFilterChip: View {
    @Binding var filters: TaskFilters
    let versions: [String]
    var accent: Color = .accentColor

    private var isActive: Bool { filters.versionScope != .any }

    var body: some View {
        FilterChipContainer(isActive: isActive, accent: accent) {
            Menu {
                if isActive {
                    Button("Clear Version") { filters.clearVersionScope() }
                    Divider()
                }
                ForEach([VersionState.new, .wip, .released], id: \.self) { state in
                    Button {
                        filters.toggleState(state)
                    } label: {
                        Label(state.title, systemImage: filters.isStateSelected(state) ? "checkmark" : state.symbol)
                    }
                }
                Button {
                    filters.toggleUnassigned()
                } label: {
                    Label("Unassigned", systemImage: filters.isUnassignedSelected ? "checkmark" : "tray")
                }
                if !versions.isEmpty {
                    Divider()
                    Menu("Version") {
                        ForEach(versions, id: \.self) { name in
                            Button {
                                filters.toggleVersion(name)
                            } label: {
                                if filters.isVersionSelected(name) {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                }
            } label: {
                FilterTitleSegment(label: "Version", showsAll: !isActive)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            // Active-selection sub-pills (state → one pill; versions → one pill per name).
            switch filters.versionScope {
            case .any:
                EmptyView()
            case .state(let s):
                SubPill(text: s.title, leadingSymbol: s.symbol, accent: accent) { filters.clearVersionScope() }
            case .unassigned:
                SubPill(text: "Unassigned", leadingSymbol: "tray", accent: accent) { filters.clearVersionScope() }
            case .versions(let names):
                ForEach(names.sorted { $0.compare($1, options: .numeric) == .orderedAscending }, id: \.self) { name in
                    SubPill(text: name, accent: accent) { filters.toggleVersion(name) }
                }
            }
        }
    }
}
