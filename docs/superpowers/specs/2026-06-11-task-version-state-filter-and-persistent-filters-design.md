# Task version-state filter + persistent filters

**Date:** 2026-06-11
**Status:** Approved (design)

## Problem

In the inspector's **Tasks** section, the user wants to filter out tasks whose
version has already been released, so the list stays focused on upcoming work.
Today the task Version filter is a flat multi-select of every milestone name
(`uniqueTaskVersions`), which (a) has no notion of release state and (b) grows
unwieldy as versions accumulate.

Separately, **all** filters currently reset on every repo switch
(`inspector.clearFilters()` / `viewModel.clearFilters()` in `RootView`) and are
in-memory only. The user wants every filter to persist across launches — and to
sync to the iOS app via iCloud.

## Goals

1. Fold release-state awareness into the task Version filter: filter tasks by
   their version's derived **state** (New / WIP / Released), resolved live so
   versions added later are covered automatically.
2. Keep the ability to filter by one or more **specific** version names, tucked
   into a submenu so the long list never dominates.
3. Persist all filters (task, version-section, and feedback-list) **per repo**,
   surviving relaunch and syncing to iOS via the existing CloudKit-backed
   SwiftData container.

## Non-goals

- No "Unreleased" (New ∪ WIP) convenience chip. The user chose New/WIP/Released
  as single-select states plus a Version submenu instead. Consequence: "hide
  released" is expressed by selecting **New** or **WIP** (one state at a time),
  or by picking specific versions — there is no single-tap "everything except
  released." Accepted; an Unreleased chip can be added later if missed.
- The live **search** text is not persisted (a stale persisted query is
  surprising on relaunch). Only the structured filter chips persist.

## Design

### 1. `VersionScope` — the task Version filter value

Replace `TaskFilters.versions: Set<String>` with a single either/or value that
directly encodes the override rules the user specified:

```swift
enum VersionScope: Equatable, Codable {
    case any                      // no version constraint
    case state(VersionState)      // all versions currently in this derived state
    case versions(Set<String>)    // specific milestone names
}
```

`TaskFilters` becomes:

```swift
struct TaskFilters: Equatable {
    var statuses:   Set<TaskStatus>   = []
    var priorities: Set<TaskPriority> = []
    var versionScope: VersionScope    = .any
    var search:     String            = ""

    var isActive: Bool {
        !statuses.isEmpty || !priorities.isEmpty || versionScope != .any
            || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

**Selection / override behavior** (driven by the menu in §2):

- Tap a **state** chip (New/WIP/Released) → `versionScope = .state(that)`,
  replacing whatever was selected. Tap the already-selected state → `.any`.
- Pick a **specific version** while scope is `.any` or `.state(…)` →
  `versionScope = .versions([that])`, replacing the state.
- Pick another **specific version** while already `.versions(set)` → toggle that
  name into/out of the set (the *only* additive case). Emptied → `.any`.

So the filter is **either** one state **or** a set of specific names — never
both. This matches: "selecting new/released/a specific version overrides the
selection; the only thing that doesn't override is selecting a second specific
version after a first."

### 2. The Version chip menu

A bespoke SwiftUI `Menu` in `TaskFilterBar` (the generic `MultiSelectFilterChip`
is a flat list and cannot express the two-section / override logic):

```
 Version ▾
   ● New          ┐  single-select; picking one overrides everything,
   ○ WIP          │  shown with a checkmark on the active state
   ○ Released     ┘
   Version ▸  →  ☑ 2.8   ☐ 2.6 (80)   ☐ 1.6  …   ← nested Menu, multi-select names
```

- The three state rows are buttons that set `.state(x)` (or clear to `.any` when
  re-tapped), with a checkmark on the active one.
- The nested `Menu("Version")` lists `inspector.uniqueTaskVersions` as toggle
  rows that drive the `.versions(…)` set per the override rules above. A
  checkmark marks each selected name.
- The chip reads as "active" (accent/filled) whenever `versionScope != .any`.

### 3. Resolving a version's state

`filteredTasks` needs each task's version state for the `.state` case. Reuse the
map `RootView` already computes:

```swift
// ProjectInspectorModel
var versionStates: [String: VersionState] = [:]
```

`RootView` pushes it (e.g. `inspector.versionStates = versionStates(owner:repo:)`)
at the same place it already calls `inspector.setTasks(viewModel.tasks)`, and on
the events that change derived state (task reloads, version release). No new
derivation — `versionStates(owner:repo:)` already exists (`RootView.swift:394`).

`filteredTasks` predicate:

```swift
var filteredTasks: [TaskItem] {
    tasks.filter { t in
        (taskFilters.statuses.isEmpty   || taskFilters.statuses.contains(t.displayStatus)) &&
        (taskFilters.priorities.isEmpty || taskFilters.priorities.contains(t.priority)) &&
        versionScopeMatches(t) &&
        t.matchesSearch(taskFilters.search)
    }
}

private func versionScopeMatches(_ t: TaskItem) -> Bool {
    switch taskFilters.versionScope {
    case .any:                return true
    case .state(let s):       return (t.milestoneTitle.flatMap { versionStates[$0] }) == s
    case .versions(let names): return names.contains(t.milestoneTitle ?? "")
    }
}
```

Version-less tasks (`milestoneTitle == nil`) match neither a `.state` nor a
`.versions` constraint — consistent with today's behavior where `""` is never in
`uniqueTaskVersions`.

### 4. Persistence — CloudKit-synced SwiftData

A new model added to the existing **`cloudSchema`** (`AppFeedbackApp.swift:90`,
`cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")`) so it syncs to
iOS. CloudKit requires every property to be optional or defaulted, so the filter
selections are stored as encoded JSON blobs (the blob's internal shape is opaque
to CloudKit):

```swift
@Model
final class RepoFilterPreference {
    var repoOwner = ""
    var repoName = ""
    var taskFiltersData: Data? = nil       // PersistedTaskFilters: statuses, priorities, versionScope (no search)
    var versionFiltersData: Data? = nil    // version-section states (no search)
    var feedbackFiltersData: Data? = nil   // appVersion/device/osVersion/issueType + appFilter (no search)
    var updatedAt = Date.distantPast
    init(repoOwner: String, repoName: String) { self.repoOwner = repoOwner; self.repoName = repoName }
}
```

A `FilterPreferenceStore` mirrors `HiddenAppStore`: fetch-by-`(owner, repo)`,
upsert, and a CloudKit-import reload hook using the existing
`NotificationCenter.cloudKitImportSucceeded` stream.

**Codable DTOs** (separate from the live structs so search is never persisted
and persistence is decoupled from UI state):

- `PersistedTaskFilters { statuses, priorities, versionScope }`
- `PersistedVersionFilters { states }`
- `PersistedFeedbackFilters { appVersion, device, osVersion, issueType, appFilter }`

The live `TaskFilters` / `VersionFilters` / `IssueListViewModel.ActiveFilters`
gain mapping to/from these DTOs (or `Codable` with `search` omitted from
`CodingKeys`).

### 5. Load / save wiring (`RootView`)

- **Repo switch** (`onChange(of: selection)`, currently `inspector.clearFilters()`
  at `RootView.swift:202`, and `viewModel.clearFilters()` at `:318`): replace
  with `load(forRepo:)` that reads `RepoFilterPreference` for the new
  `(owner, repo)` and applies it to `inspector.taskFilters`,
  `inspector.versionFilters`, and the `viewModel` feedback filters. Falls back to
  cleared filters when no row exists.
- **Save:** `.onChange` of the persisted filter values (task, version, feedback),
  keyed to the current repo, writes through `FilterPreferenceStore` (upsert,
  bump `updatedAt`). Search changes do not trigger a save.
- **CloudKit import:** on `cloudKitImportSucceeded`, reload the current repo's
  prefs so an edit made on iOS appears on macOS (and vice versa).

## Files touched

- `AppFeedback/Models/RepoFilterPreference.swift` — **new** `@Model`.
- `AppFeedback/Services/FilterPreferenceStore.swift` — **new** store.
- `AppFeedback/ViewModels/ProjectInspectorModel.swift` — `VersionScope`,
  `TaskFilters` change, `versionStates`, `filteredTasks`, `isActive`, persisted
  DTOs / Codable.
- `AppFeedback/ViewModels/IssueListViewModel.swift` — Codable feedback filters /
  DTO mapping.
- `AppFeedback/Views/Inspector/InspectorFilterBars.swift` — bespoke Version
  `Menu` replacing the version `MultiSelectFilterChip`.
- `AppFeedback/App/AppFeedbackApp.swift` — add `RepoFilterPreference` to
  `cloudSchema`.
- `AppFeedback/App/RootView.swift` — load/save wiring; drop clear-on-switch;
  push `versionStates` to the inspector.

## Testing

- `ProjectInspectorModel` unit tests: `versionScopeMatches` for `.any`,
  `.state(...)` (including version-less tasks and unknown version names), and
  `.versions(...)`; override transitions (state → version replaces; version →
  second version is additive; re-tapping a state clears to `.any`).
- `FilterPreferenceStore`: round-trip encode/decode of each DTO; upsert keyed by
  `(owner, repo)`; missing-row returns defaults.
- Persistence-with-search: confirm `search` is excluded from saved data.
- Existing build/test workflow: `AppFeedbackTests_macOS` via xcodebuild (per
  project memory; the in-process test host uses an in-memory, CloudKit-`.none`
  config, so `RepoFilterPreference` persists locally in tests without CloudKit).

## Open risks

- Single-select state means no one-tap "all non-released" view (see Non-goals).
- The bespoke Version `Menu` is new UI; ensure it matches existing chip styling
  (accent, active state) for visual consistency with the other filter chips.
