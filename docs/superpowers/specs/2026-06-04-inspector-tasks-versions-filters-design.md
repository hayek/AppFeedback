# Filters & search for the Tasks & Versions inspector panel

**Date:** 2026-06-04
**Status:** Approved (design)

## Problem

The right-sidebar inspector (`ProjectInspectorPanel`) lists a project's **Tasks** and
**Versions** with no way to narrow them. As a project accumulates tasks and releases, the
two sections become long and hard to scan. Users want to filter each section and search
within it.

## Goals

- **Tasks section:** filter by **status**, **priority**, and **release version**
  (the task's milestone), plus a search field.
- **Versions section:** filter by **status** (New / In Progress / Released), plus a search
  field that matches the version number/title.
- A **search button** per section that, when tapped, expands into a search text field.
- Multi-select for the task filter dimensions (pick several statuses/priorities/versions
  at once), matching the existing feedback `FilterBarView` behavior.
- Visual and code consistency with the existing feedback filter bar.

## Non-goals

- No persistence of filter state across app launches (session-only).
- No "No Version" pseudo-option in the task Version filter for v1 (cheap future add).
- No changes to the version-detail sheet's task list.
- No filtering of the left sidebar (repo list) — this is strictly the right inspector panel.

## Current state (as explored)

- `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift` renders a `List` with two
  sections: **Tasks** (from `inspector.filteredTasks`, sorted by priority) and **Versions**
  (from `versionStore.versions(owner:repo:)`). Section headers come from `PanelSectionHeader`.
- `AppFeedback/ViewModels/ProjectInspectorModel.swift` (`@Observable @MainActor`) owns the
  tasks array and an **unused** `statusFilter: TaskStatus?` with a computed `filteredTasks`.
  `statusFilter` has no external consumers; `filteredTasks` is consumed only by the panel.
- Models: `TaskItem` (`status: TaskStatus` = todo/inProgress/done, `priority: TaskPriority`
  = low/med/high, `milestoneTitle: String?`, `isClosed`, `isCompleted`). `ProjectVersion`
  (`name`, `releaseTitle`) with `derivedState(anyTaskStarted:) -> VersionState`
  (new/wip/released).
- `AppFeedback/Views/Issues/FilterBarView.swift` has a mature chip pattern (menu + removable
  sub-pills): `FilterChip` (string-valued), `IssueTypeFilterChip` (enum-valued), and shared
  primitives `FilterChipContainer`, `FilterTitleSegment`, `SubPill` — all currently `private`.
  Used by exactly one view, `IssueListView`.
- Search precedent: `IssueListViewModel.searchQuery` + `.searchable`, and
  `AccountRepoPicker` (TextField + `localizedCaseInsensitiveContains`).

## Approach (chosen: A)

**A — Extend `ProjectInspectorModel` + a shared chip kit.** Filter state lives in the existing
observable model (matching the `statusFilter`/`filteredTasks` precedent, keeping the logic
unit-testable). Extract the polished chip primitives out of `FilterBarView` into a shared
`FilterChipKit`, then build the two section filter bars on them. Reuses the exact look of the
feedback filter bar with no duplication.

*Alternatives considered:* **B** — inspector-only chips, leave `FilterBarView` untouched
(zero risk to the issues UI, but duplicates the chip code and risks drift). **C** — local
`@State` in the panel (smallest change, but not unit-testable and inconsistent with the
existing model-owned filtering). A chosen for testability + consistency + no duplication.

## UX / interaction

A compact filter row sits directly under each section header as its own `List` row (like the
headers themselves), horizontally scrollable to fit the 260pt-min sidebar.

- **Tasks:** `[🔍] Status▾ Priority▾ Version▾` + trailing **Clear** (shown only when any
  task filter is active).
- **Versions:** `[🔍] Status▾` + trailing **Clear**.
- **🔍** is an `ExpandableSearchField`: collapsed it is a magnifier icon button; tapped it
  animates open into an inline text field (~150pt) with a leading magnifier and a trailing
  **✕** that clears the text and collapses the field. While it holds text it stays expanded.
- Status / Priority / Version chips are **multi-select** menus that render removable sub-pills,
  identical in look/behavior to the feedback filter bar.
- **Empty states:** when a filter hides everything, show "No tasks match your filters" /
  "No versions match" with an inline Clear, instead of the existing "No tasks yet." /
  "No versions yet." (which remain for the genuinely-empty case).
- **Counts:** the Tasks header count already reflects the visible count (`taskRowItems.count`).
  The Versions header count is changed to the filtered count for consistency.

### Layout sketch

```
TASKS · 12          + New Task
🔍  Status▾ Priority▾ Version▾
────────────────────────────────
 #42 Fix crash on launch
 #41 Tighten onboarding copy

VERSIONS · 3       + New Version
🔍  Status▾
────────────────────────────────
 1.3.0   In Progress
 1.2.0   Released
```

Search expanded (Tasks):
```
TASKS · 12          + New Task
🔍 fix crash______ ✕   Status▾ Priority▾ …
```

## Data model (`ProjectInspectorModel`)

Replaces the unused `statusFilter`:

```swift
struct TaskFilters: Equatable {
    var statuses:   Set<TaskStatus>   = []
    var priorities: Set<TaskPriority> = []
    var versions:   Set<String>       = []   // milestoneTitle values
    var search:     String            = ""
    var isActive: Bool {
        !statuses.isEmpty || !priorities.isEmpty || !versions.isEmpty
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct VersionFilters: Equatable {
    var states: Set<VersionState> = []
    var search: String            = ""
    var isActive: Bool {
        !states.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

var taskFilters    = TaskFilters()
var versionFilters = VersionFilters()
```

`VersionState` must become `Hashable` (currently `String, Sendable`) so it can live in a `Set`.

## Filtering logic

**Tasks** — `filteredTasks` becomes the conjunction of all active dimensions; an empty set
means "no constraint":

```swift
var filteredTasks: [TaskItem] {
    let q = taskFilters.search.trimmingCharacters(in: .whitespaces)
    return tasks.filter { t in
        (taskFilters.statuses.isEmpty   || taskFilters.statuses.contains(t.displayStatus)) &&
        (taskFilters.priorities.isEmpty || taskFilters.priorities.contains(t.priority)) &&
        (taskFilters.versions.isEmpty   || taskFilters.versions.contains(t.milestoneTitle ?? "")) &&
        (q.isEmpty || t.matchesSearch(q))
    }
}
```

- `displayStatus` is a new `TaskItem` computed property: `isCompleted ? .done : status`. This
  preserves today's behavior (a closed issue counts as Done) while making multi-select clean.
  It replaces the current special-cased predicate
  `($0.status == statusFilter && !$0.isClosed) || (statusFilter == .done && $0.isCompleted)`.
- `matchesSearch(_:)` is a new `TaskItem` helper: case-insensitive match over `"#\(number)"`,
  `title`, and the body **prose** (`FeedbackTaskRefParser.prose(of: body)`, so the hidden ref
  block doesn't pollute matches).

**Versions** — a pure predicate on the model so it is testable without the store:

```swift
func versionMatches(name: String, releaseTitle: String, state: VersionState) -> Bool {
    let q = versionFilters.search.trimmingCharacters(in: .whitespaces)
    let stateOK = versionFilters.states.isEmpty || versionFilters.states.contains(state)
    let searchOK = q.isEmpty
        || name.localizedCaseInsensitiveContains(q)
        || releaseTitle.localizedCaseInsensitiveContains(q)
    return stateOK && searchOK
}
```

The panel maps `versionStore.versions(...)` through this, supplying `state` from the existing
`version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed:))`.

**Available filter values** (for the menus):

- Task **Version** menu: distinct non-nil `milestoneTitle`s present among `tasks`, sorted.
  (Exposed as `uniqueTaskVersions: [String]`.)
- Task **Status** / **Priority** menus: `TaskStatus.allCases` / `TaskPriority.allCases`.
- Version **Status** menu: the three `VersionState` cases (new/wip/released).

**Clearing:**

```swift
func clearTaskFilters()    { taskFilters = TaskFilters() }
func clearVersionFilters() { versionFilters = VersionFilters() }
func clearFilters()        { clearTaskFilters(); clearVersionFilters() }
```

**Reset on repo switch:** `RootView.updateViewModel(for:)` calls `inspector.clearFilters()`
(mirroring how it already calls `viewModel.clearFilters()` for the feedback list), so filters
don't carry across projects.

## Components & files

**New** `AppFeedback/Views/Filters/FilterChipKit.swift`
- Extract `FilterChipContainer`, `FilterTitleSegment`, `SubPill` from `FilterBarView` (made
  non-private / internal).
- `MultiSelectFilterChip<Value: Hashable>` — generic chip: `label`, `values: [Value]`,
  `selection: Binding<Set<Value>>`, `display: (Value) -> String`, optional
  `symbol: (Value) -> String?`, `accent`. Unifies the current `FilterChip` (string) and
  `IssueTypeFilterChip` (enum) shapes.
- `ExpandableSearchField` — `text: Binding<String>`, `prompt: String`, `accent`. Collapsed =
  magnifier button; expanded = magnifier + `TextField` + clear/collapse ✕. Uses
  `@FocusState` and a `withAnimation` toggle. Stays expanded while text is non-empty.

**Refactor** `AppFeedback/Views/Issues/FilterBarView.swift`
- Rebuild its chips on `MultiSelectFilterChip` and the shared primitives. Behavior unchanged
  (App / Type / Version / Device / OS multi-select + Clear All). Verified by the existing
  issues UI and smoke tests.

**New** `AppFeedback/Views/Inspector/InspectorFilterBars.swift`
- `TaskFilterBar(inspector:accent:)` — search + Status + Priority + Version + Clear, bound to
  `inspector.taskFilters`, values from `inspector.uniqueTaskVersions` etc.
- `VersionFilterBar(inspector:accent:)` — search + Status + Clear, bound to
  `inspector.versionFilters`.

**Edit** `AppFeedback/ViewModels/ProjectInspectorModel.swift`
- Add `TaskFilters`/`VersionFilters`, replace `statusFilter`, generalize `filteredTasks`,
  add `versionMatches`, `uniqueTaskVersions`, and the clear methods.

**Edit** `AppFeedback/Models/TaskItem.swift`
- Add `displayStatus` and `matchesSearch(_:)`.

**Edit** `AppFeedback/Models/ProjectVersion.swift`
- Make `VersionState` `Hashable`.

**Edit** `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`
- Insert `TaskFilterBar` / `VersionFilterBar` rows under each header; map versions through
  `versionMatches`; tailored empty states; Versions header count = filtered count.

**Edit** `AppFeedback/App/RootView.swift`
- `updateViewModel(for:)` calls `inspector.clearFilters()`.

## Testing (TDD)

Extend `AppFeedbackTests/ProjectInspectorModelTests.swift`:
- `filteredTasks` with single and multi-select status; multi-select priority; version filter;
  combined dimensions (AND semantics).
- The done-vs-closed nuance: a closed task with a `status:todo` label is matched by a `.done`
  status filter and **not** by a `.todo` filter (`displayStatus`).
- Search: matches title, `#number`, and body prose; ignores the ref block; case-insensitive;
  blank/whitespace search is a no-op.
- `versionMatches`: state filter, name/title search, empty filters pass everything.
- `uniqueTaskVersions`: distinct, sorted, excludes nil.
- `clearTaskFilters` / `clearVersionFilters` / `clearFilters` reset to empty.

The existing `TasksSectionSmokeTests` continue to cover panel rendering. Test target is
`AppFeedbackTests_macOS` (per project conventions).

## Risks & mitigations

- **Refactoring `FilterBarView`** could regress the feedback filter bar. Mitigation: it has a
  single consumer; keep behavior identical; rely on the issues smoke tests + manual check.
- **`VersionState: Hashable`** is additive and low-risk.
- **Narrow sidebar width**: the filter row is horizontally scrollable (matches the existing
  `FilterBarView` `ScrollView(.horizontal)` approach), so chips never clip.
