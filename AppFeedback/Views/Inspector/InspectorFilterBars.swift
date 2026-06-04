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
                MultiSelectFilterChip(
                    label: "Version",
                    values: inspector.uniqueTaskVersions,
                    selection: $inspector.taskFilters.versions,
                    display: { $0 },
                    accent: accent
                )
                if inspector.taskFilters.isActive {
                    ClearFiltersButton(title: "Clear") { inspector.clearTaskFilters() }
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
                    ClearFiltersButton(title: "Clear") { inspector.clearVersionFilters() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}
