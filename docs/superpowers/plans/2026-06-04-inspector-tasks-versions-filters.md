# Tasks & Versions Inspector Filters/Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-section filtering and an expandable search field to the right-sidebar Tasks & Versions inspector panel — Tasks filter by multi-select status/priority/version, Versions filter by status + name search.

**Architecture:** Filter state lives in the existing `@Observable ProjectInspectorModel` (testable, matching the current `filteredTasks` precedent). The polished chip UI is extracted out of `FilterBarView` into a shared `FilterChipKit` and reused by both the feedback filter bar and two new inspector filter bars. The panel renders a filter row under each section header.

**Tech Stack:** Swift 5.9, SwiftUI, `@Observable` (Observation), XCTest. xcodegen-generated project (`project.yml`, folder-glob sources). macOS test target: `AppFeedbackTests_macOS`.

---

## Conventions for every task

- **Build/test:** Use the **zcode skill** for all build/test operations (per project setup). The macOS unit-test target is `AppFeedbackTests_macOS`.
- **Ground-truth tests:** zcode's test summary can mask trap crashes. After any logic task, also confirm with xcodebuild (verify the scheme name first with `xcodebuild -list -project AppFeedback.xcodeproj`):
  ```bash
  xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS \
    -destination 'platform=macOS' \
    -only-testing:AppFeedbackTests_macOS/ProjectInspectorModelTests 2>&1 | tail -30
  ```
- **New files:** This project's `.xcodeproj` is generated from `project.yml` with folder-glob sources. After creating ANY new `.swift` file, run `xcodegen generate` **before** building, or the file won't be compiled:
  ```bash
  xcodegen generate
  ```
- **Commits:** Commit after each task. Work is on branch `inspector-filters`.

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `AppFeedback/Models/TaskItem.swift` | Task projection | Add `displayStatus`, `matchesSearch(_:)` |
| `AppFeedback/Models/ProjectVersion.swift` | Version model + `VersionState` | Make `VersionState: Hashable` |
| `AppFeedback/ViewModels/ProjectInspectorModel.swift` | Inspector state + filtering | Replace `statusFilter` with `TaskFilters`/`VersionFilters`; generalize `filteredTasks`; add `versionMatches`, `uniqueTaskVersions`, clear methods |
| `AppFeedback/Views/Filters/FilterChipKit.swift` | Reusable chip + search components | **Create** |
| `AppFeedback/Views/Issues/FilterBarView.swift` | Feedback filter bar | Refactor onto the kit |
| `AppFeedback/Views/Inspector/InspectorFilterBars.swift` | Task & version filter bars | **Create** |
| `AppFeedback/Views/Inspector/InspectorDesign.swift` | Inspector card/empty-state components | Add `PanelFilteredEmptyState` |
| `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift` | The panel | Insert filter rows; filtered versions; tailored empty states |
| `AppFeedback/App/RootView.swift` | Hosts the panel | Reset filters on repo change |
| `AppFeedbackTests/TaskItemTests.swift` | TaskItem tests | Add tests |
| `AppFeedbackTests/ProjectInspectorModelTests.swift` | Model tests | Add tests |

---

## Task 1: `TaskItem.displayStatus` + `matchesSearch`

**Files:**
- Modify: `AppFeedback/Models/TaskItem.swift`
- Test: `AppFeedbackTests/TaskItemTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AppFeedbackTests/TaskItemTests.swift` inside the `TaskItemTests` class (the file already has an `issue(number:body:labels:state:milestone:)` helper):

```swift
    // MARK: - displayStatus

    func testDisplayStatusReflectsRawStatusWhenOpen() {
        let todo = TaskItem(issue: issue(number: 1, body: "", labels: [AppFeedbackLabels.task], state: .open, milestone: nil))
        XCTAssertEqual(todo.displayStatus, .todo)
        let wip = TaskItem(issue: issue(number: 2, body: "", labels: [AppFeedbackLabels.task, "status:in-progress"], state: .open, milestone: nil))
        XCTAssertEqual(wip.displayStatus, .inProgress)
    }

    func testDisplayStatusIsDoneWhenClosedEvenIfLabeledTodo() {
        // A closed issue still carries its old status:todo label, but reads as Done.
        let item = TaskItem(issue: issue(number: 1, body: "", labels: [AppFeedbackLabels.task, "status:todo"], state: .closed, milestone: nil))
        XCTAssertEqual(item.status, .todo)
        XCTAssertEqual(item.displayStatus, .done)
    }

    // MARK: - matchesSearch

    func testMatchesSearchTitleNumberAndProse() {
        let body = FeedbackTaskRefParser.upsert(into: "investigate the crash log", refs: [7])
        let item = TaskItem(issue: issue(number: 42, body: body, labels: [AppFeedbackLabels.task], state: .open, milestone: nil))
        XCTAssertTrue(item.matchesSearch("T42"))          // title is "T42"
        XCTAssertTrue(item.matchesSearch("#42"))          // issue number
        XCTAssertTrue(item.matchesSearch("CRASH"))        // prose, case-insensitive
    }

    func testMatchesSearchIgnoresRefBlockAndBlankQuery() {
        let body = FeedbackTaskRefParser.upsert(into: "notes", refs: [55])
        let item = TaskItem(issue: issue(number: 1, body: body, labels: [AppFeedbackLabels.task], state: .open, milestone: nil))
        XCTAssertFalse(item.matchesSearch("Addresses"))   // lives only in the stripped ref block
        XCTAssertFalse(item.matchesSearch("#55"))         // ref number is in the block, not prose; not this task's number
        XCTAssertTrue(item.matchesSearch("   "))          // blank query matches everything
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the `TaskItemTests` suite via the zcode skill (macOS).
Expected: FAIL — `value of type 'TaskItem' has no member 'displayStatus'` / `... 'matchesSearch'`.

- [ ] **Step 3: Implement the helpers**

In `AppFeedback/Models/TaskItem.swift`, add inside `struct TaskItem` (e.g. just after `var isCompleted: Bool { ... }`):

```swift
    /// The status to display/filter by: a completed task (closed, or `status:done`) reads as
    /// `.done` regardless of its raw status label, so a closed issue still appears under a
    /// "Done" filter and never under "To Do" / "In Progress".
    var displayStatus: TaskStatus { isCompleted ? .done : status }

    /// Case-insensitive match of `query` against the task's number ("#42"), title, and prose
    /// (the body with the machine-managed feedback-ref block stripped, so refs don't pollute
    /// matches). A blank/whitespace query matches everything.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if "#\(number)".localizedCaseInsensitiveContains(q) { return true }
        if title.localizedCaseInsensitiveContains(q) { return true }
        return FeedbackTaskRefParser.prose(of: body).localizedCaseInsensitiveContains(q)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run `TaskItemTests` via the zcode skill (macOS).
Expected: PASS (all four new tests + the two existing ones).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/TaskItem.swift AppFeedbackTests/TaskItemTests.swift
git commit -m "feat(tasks): TaskItem.displayStatus + matchesSearch for filtering"
```

---

## Task 2: Filter state + logic in `ProjectInspectorModel`

**Files:**
- Modify: `AppFeedback/Models/ProjectVersion.swift` (one line)
- Modify: `AppFeedback/ViewModels/ProjectInspectorModel.swift`
- Test: `AppFeedbackTests/ProjectInspectorModelTests.swift`

- [ ] **Step 1: Make `VersionState` Hashable**

In `AppFeedback/Models/ProjectVersion.swift`, change:

```swift
enum VersionState: String, Sendable { case new, wip, released }
```
to:
```swift
enum VersionState: String, Sendable, Hashable { case new, wip, released }
```

- [ ] **Step 2: Write the failing tests**

Add to `AppFeedbackTests/ProjectInspectorModelTests.swift` inside the class. First add a builder helper near the existing `todoTask` helper:

```swift
    private func makeTask(_ n: Int, status: TaskStatus = .todo, priority: TaskPriority = .med,
                          milestone: String? = nil, closed: Bool = false,
                          title: String? = nil, body: String = "") -> TaskItem {
        var labels = [AppFeedbackLabels.task]
        if status != .todo { labels.append(status.label) }      // .todo is the parsed default
        if priority != .med { labels.append(priority.label) }   // .med is the parsed default
        return TaskItem(issue: FeedbackIssue(
            number: n, title: title ?? "t\(n)", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: body,
            labels: labels.map { IssueLabel(name: $0, colorHex: "x") },
            state: closed ? .closed : .open, milestoneTitle: milestone))
    }
```

Then add the test methods:

```swift
    // MARK: - Task filtering

    func testFilteredTasksNoFiltersReturnsAll() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1), makeTask(2, status: .inProgress)])
        XCTAssertEqual(m.filteredTasks.map(\.number), [1, 2])
    }

    func testFilterByMultipleStatuses() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, status: .todo), makeTask(2, status: .inProgress), makeTask(3, status: .done)])
        m.taskFilters.statuses = [.todo, .inProgress]
        XCTAssertEqual(Set(m.filteredTasks.map(\.number)), [1, 2])
    }

    func testClosedTaskMatchesDoneNotTodo() {
        let m = ProjectInspectorModel()
        // A closed task reads as Done via displayStatus regardless of its raw status. (The
        // explicit status:todo-label variant is proven at the TaskItem layer in Task 1.)
        m.setTasks([makeTask(1, status: .todo, closed: true)])
        m.taskFilters.statuses = [.done]
        XCTAssertEqual(m.filteredTasks.map(\.number), [1], "closed task should match a Done filter")
        m.taskFilters.statuses = [.todo]
        XCTAssertTrue(m.filteredTasks.isEmpty, "closed task should not match a To Do filter")
    }

    func testFilterByPriority() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, priority: .high), makeTask(2, priority: .low)])
        m.taskFilters.priorities = [.high]
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
    }

    func testFilterByVersion() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, milestone: "1.0"), makeTask(2, milestone: "2.0"), makeTask(3, milestone: nil)])
        m.taskFilters.versions = ["1.0"]
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
    }

    func testFilterDimensionsCombineWithAnd() {
        let m = ProjectInspectorModel()
        m.setTasks([
            makeTask(1, status: .inProgress, priority: .high, milestone: "1.0"),
            makeTask(2, status: .inProgress, priority: .low,  milestone: "1.0"),
            makeTask(3, status: .todo,       priority: .high, milestone: "1.0"),
        ])
        m.taskFilters.statuses = [.inProgress]
        m.taskFilters.priorities = [.high]
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
    }

    func testFilterBySearch() {
        let m = ProjectInspectorModel()
        m.setTasks([
            makeTask(1, title: "Fix login bug"),
            makeTask(2, title: "Polish onboarding"),
        ])
        m.taskFilters.search = "login"
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
        m.taskFilters.search = "  "          // blank → no constraint
        XCTAssertEqual(m.filteredTasks.count, 2)
    }

    func testUniqueTaskVersionsDistinctSortedExcludingNil() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, milestone: "2.0"), makeTask(2, milestone: "1.0"),
                    makeTask(3, milestone: "2.0"), makeTask(4, milestone: nil)])
        XCTAssertEqual(m.uniqueTaskVersions, ["1.0", "2.0"])
    }

    // MARK: - Version filtering

    func testVersionMatchesByState() {
        let m = ProjectInspectorModel()
        XCTAssertTrue(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .new))  // no filters → all
        m.versionFilters.states = [.released]
        XCTAssertFalse(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .new))
        XCTAssertTrue(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .released))
    }

    func testVersionMatchesBySearchOnNameOrTitle() {
        let m = ProjectInspectorModel()
        m.versionFilters.search = "pol"
        XCTAssertTrue(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .new))   // title
        XCTAssertFalse(m.versionMatches(name: "1.0.0", releaseTitle: "Speed", state: .new))
        m.versionFilters.search = "1.3"
        XCTAssertTrue(m.versionMatches(name: "1.3.0", releaseTitle: "x", state: .new))         // name
        XCTAssertFalse(m.versionMatches(name: "2.0.0", releaseTitle: "x", state: .new))
    }

    // MARK: - Clearing

    func testClearFiltersResetsEverything() {
        let m = ProjectInspectorModel()
        m.taskFilters.statuses = [.done]
        m.taskFilters.search = "x"
        m.versionFilters.states = [.released]
        m.versionFilters.search = "y"
        m.clearFilters()
        XCTAssertFalse(m.taskFilters.isActive)
        XCTAssertFalse(m.versionFilters.isActive)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run `ProjectInspectorModelTests` via the zcode skill (macOS).
Expected: FAIL — `value of type 'ProjectInspectorModel' has no member 'taskFilters'` etc.

- [ ] **Step 4: Implement the filter state + logic**

In `AppFeedback/ViewModels/ProjectInspectorModel.swift`:

(a) Add the filter types near the top of the file (after the existing `TaskCreation` struct, before `@Observable @MainActor final class ProjectInspectorModel`):

```swift
/// Active filters for the inspector's Tasks section. An empty set on a dimension means "no
/// constraint"; dimensions combine with AND. `search` is matched by `TaskItem.matchesSearch`.
struct TaskFilters: Equatable {
    var statuses:   Set<TaskStatus>   = []
    var priorities: Set<TaskPriority> = []
    var versions:   Set<String>       = []     // milestoneTitle values
    var search:     String            = ""

    var isActive: Bool {
        !statuses.isEmpty || !priorities.isEmpty || !versions.isEmpty
            || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Active filters for the inspector's Versions section: by derived `VersionState` and a name/
/// title search. Empty `states` means "no constraint".
struct VersionFilters: Equatable {
    var states: Set<VersionState> = []
    var search: String            = ""

    var isActive: Bool {
        !states.isEmpty || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

(b) In the class, **replace** the line:

```swift
    var statusFilter: TaskStatus? = nil
```
with:
```swift
    var taskFilters    = TaskFilters()
    var versionFilters = VersionFilters()
```

(c) **Replace** the existing `filteredTasks` computed property:

```swift
    var filteredTasks: [TaskItem] {
        guard let statusFilter else { return tasks }
        return tasks.filter { ($0.status == statusFilter && !$0.isClosed) || (statusFilter == .done && $0.isCompleted) }
    }
```
with:
```swift
    /// Tasks passing all active filters (status, priority, version, search) — empty dimensions
    /// impose no constraint, and the dimensions combine with AND.
    var filteredTasks: [TaskItem] {
        tasks.filter { t in
            (taskFilters.statuses.isEmpty   || taskFilters.statuses.contains(t.displayStatus)) &&
            (taskFilters.priorities.isEmpty || taskFilters.priorities.contains(t.priority)) &&
            (taskFilters.versions.isEmpty   || taskFilters.versions.contains(t.milestoneTitle ?? "")) &&
            t.matchesSearch(taskFilters.search)
        }
    }

    /// Distinct, sorted version names present among the loaded tasks (drives the Version filter
    /// menu). Excludes tasks with no version.
    var uniqueTaskVersions: [String] {
        Array(Set(tasks.compactMap(\.milestoneTitle))).sorted()
    }

    /// Pure predicate for the Versions section filter; the panel supplies each version's derived
    /// `state`. No filters → matches everything.
    func versionMatches(name: String, releaseTitle: String, state: VersionState) -> Bool {
        let stateOK = versionFilters.states.isEmpty || versionFilters.states.contains(state)
        let q = versionFilters.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchOK = q.isEmpty
            || name.localizedCaseInsensitiveContains(q)
            || releaseTitle.localizedCaseInsensitiveContains(q)
        return stateOK && searchOK
    }

    func clearTaskFilters()    { taskFilters = TaskFilters() }
    func clearVersionFilters() { versionFilters = VersionFilters() }
    func clearFilters()        { clearTaskFilters(); clearVersionFilters() }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `ProjectInspectorModelTests` via the zcode skill (macOS), then confirm with the xcodebuild ground-truth command from "Conventions".
Expected: PASS (new tests + all pre-existing tests in the file).

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Models/ProjectVersion.swift AppFeedback/ViewModels/ProjectInspectorModel.swift AppFeedbackTests/ProjectInspectorModelTests.swift
git commit -m "feat(inspector): multi-select task/version filter state + logic"
```

---

## Task 3: Shared `FilterChipKit` + refactor `FilterBarView`

This task creates the reusable kit and migrates the existing feedback filter bar onto it in one step, so the module always compiles (the primitives can't live in two files under the same names).

**Files:**
- Create: `AppFeedback/Views/Filters/FilterChipKit.swift`
- Modify: `AppFeedback/Views/Issues/FilterBarView.swift`

- [ ] **Step 1: Create the kit**

Create `AppFeedback/Views/Filters/FilterChipKit.swift`:

```swift
import SwiftUI

// MARK: - Generic multi-select filter chip

/// A reusable multi-select filter chip: a menu trigger ("Label : All ▾") plus inline removable
/// sub-pills for each selected value. Renders nothing when `values` is empty. Used by both the
/// feedback filter bar and the inspector's task/version filter bars.
struct MultiSelectFilterChip<Value: Hashable>: View {
    let label: String
    let values: [Value]
    @Binding var selection: Set<Value>
    var display: (Value) -> String
    /// Optional SF Symbol per value; when present the menu shows it (or a checkmark when selected)
    /// and the sub-pill carries it as a leading glyph.
    var symbol: ((Value) -> String?)? = nil
    var accent: Color = .accentColor

    var body: some View {
        if !values.isEmpty {
            FilterChipContainer(isActive: !selection.isEmpty, accent: accent) {
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
                            let isSelected = selection.contains(value)
                            if let sym = symbol?(value) {
                                Label(display(value), systemImage: isSelected ? "checkmark" : sym)
                            } else if isSelected {
                                Label(display(value), systemImage: "checkmark")
                            } else {
                                Text(display(value))
                            }
                        }
                    }
                } label: {
                    FilterTitleSegment(label: label, showsAll: selection.isEmpty)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                ForEach(selection.sorted { display($0) < display($1) }, id: \.self) { value in
                    SubPill(text: display(value), leadingSymbol: symbol?(value), accent: accent) {
                        selection.remove(value)
                    }
                }
            }
        }
    }
}

// MARK: - Expandable search field

/// A magnifier button that expands into an inline text field with a clear/collapse control.
/// Stays expanded while it holds text; collapses when emptied and unfocused.
struct ExpandableSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var accent: Color = .accentColor
    @State private var expanded = false
    @FocusState private var focused: Bool

    private var isOpen: Bool { expanded || !text.isEmpty }

    var body: some View {
        Group {
            if isOpen {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($focused)
                        .frame(width: 150)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                    Button {
                        text = ""
                        focused = false
                        withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                .overlay(Capsule().stroke(accent.opacity(text.isEmpty ? 0 : 0.28), lineWidth: 1))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                    DispatchQueue.main.async { focused = true }   // focus after the field exists
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Search")
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && text.isEmpty {
                withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
            }
        }
    }
}

// MARK: - Clear button

/// The trailing "clear filters" pill shown when any filter is active.
struct ClearFiltersButton: View {
    var title: String = "Clear All"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help("Clear all filters")
    }
}

// MARK: - Shared chip pieces

/// Outer rounded capsule that contains the title segment + sub-pills as one unit.
struct FilterChipContainer<Content: View>: View {
    let isActive: Bool
    var accent: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            isActive ? accent.opacity(0.08) : Color.secondary.opacity(0.06),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                isActive ? accent.opacity(0.28) : Color.secondary.opacity(0.18),
                lineWidth: 1
            )
        )
    }
}

/// The "Title :" / "Title : All" portion that opens the menu.
struct FilterTitleSegment: View {
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
struct SubPill: View {
    let text: String
    var leadingSymbol: String? = nil
    var accent: Color = .accentColor
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
                    .foregroundStyle(accent.opacity(0.7))
            }
            .foregroundStyle(accent)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
            .background(accent.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(text)")
    }
}
```

- [ ] **Step 2: Refactor `FilterBarView` onto the kit**

Replace the entire contents of `AppFeedback/Views/Issues/FilterBarView.swift` with:

```swift
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
```

(The previous `FilterChip`, `IssueTypeFilterChip`, `FilterChipContainer`, `FilterTitleSegment`, and `SubPill` private structs are intentionally gone — they now live in `FilterChipKit.swift`.)

- [ ] **Step 3: Regenerate the project and build**

```bash
xcodegen generate
```
Then build both schemes (iOS + macOS) via the zcode skill.
Expected: BUILD SUCCEEDED. (`DeviceName.friendly` and `OSVersionFormat.display` are `(String) -> String` statics, so they satisfy `display:`.)

- [ ] **Step 4: Verify the feedback filter bar still works**

Run the full existing test suite via the zcode skill (macOS) — nothing should regress. Then, via the run/zcode skill, launch the app and confirm the feedback list's filter bar (App / Type / Version / Device / OS chips + Clear All) still opens menus, shows sub-pills, and clears.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Filters/FilterChipKit.swift AppFeedback/Views/Issues/FilterBarView.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "refactor(filters): extract shared FilterChipKit; FilterBarView uses it"
```

---

## Task 4: Inspector filter bars

**Files:**
- Create: `AppFeedback/Views/Inspector/InspectorFilterBars.swift`

- [ ] **Step 1: Create the filter bars**

Create `AppFeedback/Views/Inspector/InspectorFilterBars.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
```
Build iOS + macOS via the zcode skill.
Expected: BUILD SUCCEEDED. (`VersionState.title`/`.symbol` come from `InspectorDesign.swift`; `@Bindable` lets `$inspector.taskFilters.statuses` bind into the nested struct.)

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Inspector/InspectorFilterBars.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(inspector): TaskFilterBar + VersionFilterBar views"
```

---

## Task 5: Wire filter bars into `ProjectInspectorPanel`

**Files:**
- Modify: `AppFeedback/Views/Inspector/InspectorDesign.swift` (add `PanelFilteredEmptyState`)
- Modify: `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`

- [ ] **Step 1: Add the filtered-empty-state component**

In `AppFeedback/Views/Inspector/InspectorDesign.swift`, add after the existing `PanelEmptyState` struct:

```swift
/// Empty state shown when active filters hide every row in a section (distinct from the
/// genuinely-empty "No tasks yet." state); offers an inline Clear.
struct PanelFilteredEmptyState: View {
    let message: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Clear", action: clear)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
        .padding(.leading, 2)
    }
}
```

- [ ] **Step 2: Insert filter rows + a per-repo accent in the panel**

In `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`, in `body`, replace ONLY the `List { ... }` braces (current lines 34–42). **Do NOT** touch the explanatory comment above it (lines 30–33) or the trailing modifier chain attached to the `List` (`.listStyle(.plain)`, `.scrollContentBackground`, `.refreshable`, the `.sheet(...)`s and `.confirmationDialog(...)`s, etc.) — those stay exactly as they are, now attached to the new `List`.

Replace this exact block:

```swift
                List {
                    header(title: "Tasks", count: taskRowItems.count,
                           addLabel: "New Task", add: onCreateTask, topPad: 4)
                    taskRows(repo: repo)

                    header(title: "Versions", count: versionStore.versions(owner: repo.owner, repo: repo.repo).count,
                           addLabel: "New Version", add: onCreateVersion, topPad: 22)
                    versionRows(repo: repo)
                }
```
with (note the new `let accent:` line sits just above `List {`):
```swift
                let accent: Color = repo.colorHex.map(Color.init(hex:)) ?? .accentColor
                List {
                    header(title: "Tasks", count: taskRowItems.count,
                           addLabel: "New Task", add: onCreateTask, topPad: 4)
                    filterRow { TaskFilterBar(inspector: inspector, accent: accent) }
                    taskRows(repo: repo)

                    header(title: "Versions", count: filteredVersions(repo: repo).count,
                           addLabel: "New Version", add: onCreateVersion, topPad: 22)
                    filterRow { VersionFilterBar(inspector: inspector, accent: accent) }
                    versionRows(repo: repo)
                }
```
(`if let repo { let accent = ...; List { ... }.listStyle(...)... }` is well-formed ViewBuilder content — the `let` in statement position before the returned `List` is valid.)

- [ ] **Step 3: Add the `filterRow` row helper**

In the same file, add next to the existing `header(...)` helper:

```swift
    @ViewBuilder
    private func filterRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
    }
```

- [ ] **Step 4: Tailored empty state for the Tasks section**

In `taskRows(repo:)`, replace:

```swift
        if rows.isEmpty {
            PanelEmptyState(icon: "checklist", message: "No tasks yet.").cardRow()
        }
```
with:
```swift
        if rows.isEmpty {
            if inspector.taskFilters.isActive && !inspector.tasks.isEmpty {
                PanelFilteredEmptyState(message: "No tasks match") { inspector.clearTaskFilters() }.cardRow()
            } else {
                PanelEmptyState(icon: "checklist", message: "No tasks yet.").cardRow()
            }
        }
```

- [ ] **Step 5: Filter the Versions section**

In the same file, replace the entire `versionRows(repo:)` function:

```swift
    @ViewBuilder private func versionRows(repo: RepoConfig) -> some View {
        let versions = versionStore.versions(owner: repo.owner, repo: repo.repo)
        ForEach(versions) { version in
            VersionCard(
                name: version.name,
                state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                taskCount: inspector.tasks(forVersionNamed: version.name).count,
                creationBadge: versionCreations.status(version.id),
                onRetry: { onRetryVersion(version.id) },
                onDismiss: { onDismissVersion(version.id) },
                action: { versionToOpen = version }
            )
            .cardRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { versionToDelete = version } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        if versions.isEmpty {
            PanelEmptyState(icon: "shippingbox", message: "No versions yet.").cardRow()
        }
    }
```
with:
```swift
    /// All versions for the repo, narrowed by the active version filters.
    private func filteredVersions(repo: RepoConfig) -> [ProjectVersion] {
        versionStore.versions(owner: repo.owner, repo: repo.repo).filter { version in
            inspector.versionMatches(
                name: version.name,
                releaseTitle: version.releaseTitle,
                state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name))
            )
        }
    }

    @ViewBuilder private func versionRows(repo: RepoConfig) -> some View {
        let total = versionStore.versions(owner: repo.owner, repo: repo.repo).count
        let versions = filteredVersions(repo: repo)
        ForEach(versions) { version in
            VersionCard(
                name: version.name,
                state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                taskCount: inspector.tasks(forVersionNamed: version.name).count,
                creationBadge: versionCreations.status(version.id),
                onRetry: { onRetryVersion(version.id) },
                onDismiss: { onDismissVersion(version.id) },
                action: { versionToOpen = version }
            )
            .cardRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { versionToDelete = version } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        if versions.isEmpty {
            if inspector.versionFilters.isActive && total > 0 {
                PanelFilteredEmptyState(message: "No versions match") { inspector.clearVersionFilters() }.cardRow()
            } else {
                PanelEmptyState(icon: "shippingbox", message: "No versions yet.").cardRow()
            }
        }
    }
```

- [ ] **Step 6: Build and run the smoke tests**

```bash
xcodegen generate    # only needed if a new file was added; safe to run regardless
```
Build iOS + macOS via the zcode skill, then run the full macOS test suite (includes `TasksSectionSmokeTests`).
Expected: BUILD SUCCEEDED, tests PASS.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Views/Inspector/InspectorDesign.swift AppFeedback/Views/Inspector/ProjectInspectorPanel.swift
git commit -m "feat(inspector): render task/version filter bars + filtered empty states"
```

---

## Task 6: Reset filters on repo change

Filters are session state that should not leak between projects, but must survive a same-repo refresh. `updateViewModel` runs on every reload, so the reset goes in the repo-change branch of the selection `onChange`.

**Files:**
- Modify: `AppFeedback/App/RootView.swift`

- [ ] **Step 1: Clear inspector filters when the repo changes**

In `AppFeedback/App/RootView.swift`, find the `.onChange(of: selection)` block:

```swift
            if oldValue?.repoId != newValue?.repoId {
                inspector.clearCreations()
                versionCreations.clearAll()
            }
```
and add `inspector.clearFilters()`:
```swift
            if oldValue?.repoId != newValue?.repoId {
                inspector.clearCreations()
                versionCreations.clearAll()
                inspector.clearFilters()
            }
```

- [ ] **Step 2: Build**

Build iOS + macOS via the zcode skill.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/App/RootView.swift
git commit -m "feat(inspector): reset task/version filters on repo switch"
```

---

## Task 7: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full clean build + test (ground truth)**

```bash
xcodegen generate
xcodebuild -list -project AppFeedback.xcodeproj   # confirm scheme/target names
xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS \
  -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: `** TEST SUCCEEDED **`. (Cross-check, since zcode's summary can hide trap crashes.)

- [ ] **Step 2: Manual verification (run the app via the run/zcode skill)**

Confirm, with a repo that has several tasks and versions selected and the right inspector open:
- Tasks section shows a row under its header with a 🔍 button + Status / Priority / Version chips.
- Tapping 🔍 expands a text field, focuses it, and filters tasks live; the ✕ clears and collapses it.
- Each chip multi-selects (sub-pills appear), and combining dimensions narrows with AND.
- A closed task appears under a "Done" status filter and not under "To Do".
- Versions section shows 🔍 + a Status chip; status + name search both narrow the list.
- When filters hide everything, the "No tasks match" / "No versions match" row appears with a working Clear.
- Switching to another repo resets all filters; pulling to refresh the same repo keeps them.
- The feedback list's filter bar (left/main area) is visually unchanged and still works.

- [ ] **Step 3: Update memory (optional)**

If anything about the build/test workflow proved different than documented, update the relevant memory file.

---

## Self-review notes

- **Spec coverage:** Tasks status/priority/version filters → Tasks 2/4/5. Task search → Tasks 1/2/4. Versions status + name search → Tasks 2/4/5. Expandable search button → Task 3 (`ExpandableSearchField`). Multi-select → `MultiSelectFilterChip` (Task 3) + `Set` filter state (Task 2). Per-section bars → Task 5. Shared kit / `FilterBarView` refactor → Task 3. Reset on repo switch → Task 6. Tailored empty states & version count → Task 5. Tests → Tasks 1, 2.
- **Type consistency:** `taskFilters`/`versionFilters` (Task 2) are referenced identically in Tasks 4–6; `clearTaskFilters`/`clearVersionFilters`/`clearFilters`, `uniqueTaskVersions`, `versionMatches`, `displayStatus`, `matchesSearch`, `MultiSelectFilterChip`, `ExpandableSearchField`, `ClearFiltersButton`, `FilterChipContainer`, `FilterTitleSegment`, `SubPill`, `PanelFilteredEmptyState` all defined before first use.
- **Deviation from spec:** spec said reset "mirroring how it already clears the feedback filters" in `updateViewModel`; the plan instead resets in the repo-change branch so a same-repo refresh doesn't wipe filters (a cleaner behavior than the feedback bar's current reset-on-every-reload).
- **No "No Version" option** in the task Version filter (v1 scope), per spec.
