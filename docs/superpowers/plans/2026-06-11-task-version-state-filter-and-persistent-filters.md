# Task version-state filter + persistent filters — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the inspector's Tasks filter by version **state** (New/WIP/Released) plus specific version names, and persist all filters per-repo with iCloud sync.

**Architecture:** The task Version filter becomes a single `VersionScope` value (`.any` / `.state` / `.versions`) with override semantics, resolved live against a `versionStates` map pushed from `RootView`. All filter selections persist via a new CloudKit-synced SwiftData `@Model` (`RepoFilterPreference`) holding JSON blobs, loaded/saved on repo switch in `RootView` (replacing today's clear-on-switch).

**Tech Stack:** Swift, SwiftUI, SwiftData (+ CloudKit private DB), XCTest.

**Build/test:** Use the **zcode skill** for build/run/test (the session mandates it). Test target is **`AppFeedbackTests_macOS`**. Per project memory, zcode's test summary can mask trap crashes — confirm green with `xcodebuild` as ground truth when a run looks suspicious.

---

## File Structure

- `AppFeedback/Models/ProjectVersion.swift` — add `Codable` to `VersionState`.
- `AppFeedback/Models/TaskMetadata.swift` — add `Codable` to `TaskStatus`, `TaskPriority`.
- `AppFeedback/Models/FeedbackIssue.swift` — add `Codable` to `IssueType`.
- `AppFeedback/ViewModels/ProjectInspectorModel.swift` — `VersionScope`, `TaskFilters` rework (+ override helpers), `versionStates`, `filteredTasks`.
- `AppFeedback/ViewModels/IssueListViewModel.swift` — feedback-filter DTO mapping.
- `AppFeedback/Views/Inspector/InspectorFilterBars.swift` — bespoke `VersionScopeFilterChip`.
- `AppFeedback/Models/RepoFilterPreference.swift` — **new** `@Model`.
- `AppFeedback/Services/FilterPreferenceStore.swift` — **new** DTOs + store.
- `AppFeedback/App/AppFeedbackApp.swift` — register model in schema + container; build `FilterPreferenceStore`; pass to `RootView`.
- `AppFeedback/App/RootView.swift` — load/save wiring; drop clear-on-switch; push `versionStates`.
- Tests: `AppFeedbackTests/VersionScopeTests.swift`, `AppFeedbackTests/TaskVersionFilterTests.swift`, `AppFeedbackTests/FilterPreferenceStoreTests.swift`.

---

### Task 1: `Codable` enums + `VersionScope`

**Files:**
- Modify: `AppFeedback/Models/ProjectVersion.swift:4`
- Modify: `AppFeedback/Models/TaskMetadata.swift:21,42`
- Modify: `AppFeedback/Models/FeedbackIssue.swift:13`
- Modify: `AppFeedback/ViewModels/ProjectInspectorModel.swift` (add `VersionScope` near `TaskFilters`, ~line 49)
- Test: `AppFeedbackTests/VersionScopeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/VersionScopeTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class VersionScopeTests: XCTestCase {
    private func roundTrip(_ scope: VersionScope) throws -> VersionScope {
        let data = try JSONEncoder().encode(scope)
        return try JSONDecoder().decode(VersionScope.self, from: data)
    }

    func test_roundTrip_any() throws {
        XCTAssertEqual(try roundTrip(.any), .any)
    }

    func test_roundTrip_state() throws {
        XCTAssertEqual(try roundTrip(.state(.released)), .state(.released))
    }

    func test_roundTrip_versions() throws {
        XCTAssertEqual(try roundTrip(.versions(["1.0", "2.0"])), .versions(["1.0", "2.0"]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Build the test target via the zcode skill.
Expected: COMPILE FAILURE — `cannot find 'VersionScope' in scope`.

- [ ] **Step 3: Add `Codable` conformances**

`AppFeedback/Models/ProjectVersion.swift:4` — change to:

```swift
enum VersionState: String, Codable, Sendable, Hashable { case new, wip, released }
```

`AppFeedback/Models/TaskMetadata.swift` — line 21 and line 42:

```swift
enum TaskStatus: String, CaseIterable, Codable, Sendable {
```
```swift
enum TaskPriority: String, CaseIterable, Codable, Sendable {
```

`AppFeedback/Models/FeedbackIssue.swift:13`:

```swift
enum IssueType: String, Codable {
```

- [ ] **Step 4: Add `VersionScope`**

In `AppFeedback/ViewModels/ProjectInspectorModel.swift`, immediately above `struct TaskFilters` (~line 50):

```swift
/// The task Version filter's value: no constraint, a single derived state (resolved live so
/// versions added later are covered), or an explicit set of milestone names. State and a fresh
/// specific-version pick replace the whole value; a second specific-version pick is additive.
enum VersionScope: Equatable, Codable {
    case any
    case state(VersionState)
    case versions(Set<String>)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Build & run `AppFeedbackTests_macOS` via the zcode skill.
Expected: PASS (all three `VersionScopeTests`). Whole suite still builds.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Models/ProjectVersion.swift AppFeedback/Models/TaskMetadata.swift AppFeedback/Models/FeedbackIssue.swift AppFeedback/ViewModels/ProjectInspectorModel.swift AppFeedbackTests/VersionScopeTests.swift
git commit -m "feat(filters): add Codable VersionScope + enum conformances"
```

---

### Task 2: `TaskFilters` rework + override helpers + `filteredTasks`

**Files:**
- Modify: `AppFeedback/ViewModels/ProjectInspectorModel.swift:52-62` (`TaskFilters`), `:77-79` (add `versionStates`), `:279-287` (`filteredTasks`)
- Test: `AppFeedbackTests/TaskVersionFilterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/TaskVersionFilterTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class TaskVersionFilterTests: XCTestCase {

    private func task(_ number: Int, milestone: String? = nil) -> TaskItem {
        TaskItem(issue: FeedbackIssue(number: number, title: "t\(number)", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")], state: .open, milestoneTitle: milestone))
    }

    // MARK: override semantics

    func test_toggleState_selectsThenClears() {
        var f = TaskFilters()
        f.toggleState(.released)
        XCTAssertEqual(f.versionScope, .state(.released))
        f.toggleState(.released)                       // re-tap clears
        XCTAssertEqual(f.versionScope, .any)
    }

    func test_toggleState_overridesAnotherState() {
        var f = TaskFilters()
        f.toggleState(.new)
        f.toggleState(.released)                       // single-select: replaces
        XCTAssertEqual(f.versionScope, .state(.released))
    }

    func test_toggleVersion_overridesState_thenIsAdditive() {
        var f = TaskFilters()
        f.toggleState(.new)
        f.toggleVersion("2.8")                          // version overrides state
        XCTAssertEqual(f.versionScope, .versions(["2.8"]))
        f.toggleVersion("2.6")                          // second version is additive
        XCTAssertEqual(f.versionScope, .versions(["2.8", "2.6"]))
        f.toggleVersion("2.8")                          // toggling off
        XCTAssertEqual(f.versionScope, .versions(["2.6"]))
        f.toggleVersion("2.6")                          // emptied → .any
        XCTAssertEqual(f.versionScope, .any)
    }

    func test_isStateSelected_and_isVersionSelected() {
        var f = TaskFilters()
        f.toggleState(.wip)
        XCTAssertTrue(f.isStateSelected(.wip))
        XCTAssertFalse(f.isStateSelected(.new))
        f.toggleVersion("1.0")
        XCTAssertTrue(f.isVersionSelected("1.0"))
        XCTAssertFalse(f.isStateSelected(.wip))
    }

    // MARK: filteredTasks

    func test_filter_byState_resolvesViaVersionStates() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: "2.0"), task(3, milestone: nil)])
        model.versionStates = ["1.0": .released, "2.0": .new]
        model.taskFilters.versionScope = .state(.new)
        XCTAssertEqual(model.filteredTasks.map(\.number), [2])   // version-less + released excluded
    }

    func test_filter_byVersions_matchesNames() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: "2.0")])
        model.taskFilters.versionScope = .versions(["2.0"])
        XCTAssertEqual(model.filteredTasks.map(\.number), [2])
    }

    func test_filter_any_returnsAll() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: nil)])
        XCTAssertEqual(model.filteredTasks.count, 2)
    }

    func test_isActive_reflectsVersionScope() {
        var f = TaskFilters()
        XCTAssertFalse(f.isActive)
        f.toggleState(.released)
        XCTAssertTrue(f.isActive)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Build the test target via the zcode skill.
Expected: COMPILE FAILURE — `value of type 'TaskFilters' has no member 'toggleState'` / `versionScope`.

- [ ] **Step 3: Rework `TaskFilters`**

Replace `struct TaskFilters` (`ProjectInspectorModel.swift:52-62`) with:

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

    func isStateSelected(_ s: VersionState) -> Bool { versionScope == .state(s) }

    func isVersionSelected(_ name: String) -> Bool {
        if case .versions(let names) = versionScope { return names.contains(name) }
        return false
    }

    /// Selecting a state replaces the whole scope; re-selecting the active state clears to `.any`.
    mutating func toggleState(_ s: VersionState) {
        versionScope = (versionScope == .state(s)) ? .any : .state(s)
    }

    /// A specific-version pick overrides a state/`.any`; a second pick is additive. Emptying → `.any`.
    mutating func toggleVersion(_ name: String) {
        if case .versions(var names) = versionScope {
            if names.contains(name) { names.remove(name) } else { names.insert(name) }
            versionScope = names.isEmpty ? .any : .versions(names)
        } else {
            versionScope = .versions([name])
        }
    }
}
```

- [ ] **Step 4: Add `versionStates` + rework `filteredTasks`**

In `ProjectInspectorModel`, add after `var versionFilters = VersionFilters()` (~line 79):

```swift
    /// Derived state per version name, pushed from `RootView`. Drives `.state` version filtering.
    var versionStates: [String: VersionState] = [:]
```

Replace `var filteredTasks` (`:279-287`) with:

```swift
    /// Tasks passing all active filters (status, priority, version scope, search) — empty
    /// dimensions impose no constraint, and the dimensions combine with AND.
    var filteredTasks: [TaskItem] {
        tasks.filter { t in
            (taskFilters.statuses.isEmpty   || taskFilters.statuses.contains(t.displayStatus)) &&
            (taskFilters.priorities.isEmpty || taskFilters.priorities.contains(t.priority)) &&
            versionScopeMatches(t) &&
            t.matchesSearch(taskFilters.search)
        }
    }

    /// Resolves the task against the active `VersionScope`. `.state` looks the task's milestone up
    /// in `versionStates`; version-less tasks match neither `.state` nor `.versions`.
    private func versionScopeMatches(_ t: TaskItem) -> Bool {
        switch taskFilters.versionScope {
        case .any:                 return true
        case .state(let s):        return (t.milestoneTitle.flatMap { versionStates[$0] }) == s
        case .versions(let names): return names.contains(t.milestoneTitle ?? "")
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Build & run `AppFeedbackTests_macOS` via the zcode skill.
Expected: PASS (all `TaskVersionFilterTests`). Existing `ProjectInspectorModelTests` still pass.

> Note: the old version `MultiSelectFilterChip` in `InspectorFilterBars.swift` still references `taskFilters.versions` and will now fail to compile — Task 3 fixes the UI. If you build the **app** target before Task 3 it will error there; the **test** target compiles `ProjectInspectorModel` fine. Run Task 3 before building the app.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/ViewModels/ProjectInspectorModel.swift AppFeedbackTests/TaskVersionFilterTests.swift
git commit -m "feat(filters): VersionScope task filtering with live state resolution"
```

---

### Task 3: `VersionScopeFilterChip` UI

**Files:**
- Modify: `AppFeedback/Views/Inspector/InspectorFilterBars.swift:27-33` (replace the Version chip) + append the new component

- [ ] **Step 1: Replace the Version chip in `TaskFilterBar`**

In `InspectorFilterBars.swift`, replace the `MultiSelectFilterChip(label: "Version", …)` block (`:27-33`) with:

```swift
                VersionScopeFilterChip(filters: $inspector.taskFilters,
                                       versions: inspector.uniqueTaskVersions,
                                       accent: accent)
```

- [ ] **Step 2: Add the component**

Append to `InspectorFilterBars.swift`:

```swift
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
                    Button("Clear Version") { filters.versionScope = .any }
                    Divider()
                }
                ForEach([VersionState.new, .wip, .released], id: \.self) { state in
                    Button {
                        filters.toggleState(state)
                    } label: {
                        Label(state.title, systemImage: filters.isStateSelected(state) ? "checkmark" : state.symbol)
                    }
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
                SubPill(text: s.title, leadingSymbol: s.symbol, accent: accent) { filters.versionScope = .any }
            case .versions(let names):
                ForEach(names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }, id: \.self) { name in
                    SubPill(text: name, accent: accent) { filters.toggleVersion(name) }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build the app target**

Build the macOS app via the zcode skill.
Expected: BUILD SUCCEEDS, no remaining references to `taskFilters.versions`.

- [ ] **Step 4: Run the full suite**

Run `AppFeedbackTests_macOS` via the zcode skill.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Inspector/InspectorFilterBars.swift
git commit -m "feat(filters): version state + names menu chip for tasks"
```

---

### Task 4: `RepoFilterPreference` model + schema registration

**Files:**
- Create: `AppFeedback/Models/RepoFilterPreference.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift:78-87` (test container), `:90` (cloudSchema), `:99-108` (prod container)

- [ ] **Step 1: Create the model**

Create `AppFeedback/Models/RepoFilterPreference.swift`:

```swift
import Foundation
import SwiftData

/// Per-repo persisted filter selections (Tasks, Versions, and feedback-list filters), stored as
/// JSON blobs so the model stays CloudKit-compatible (all properties optional/defaulted, no unique
/// constraints). Lives in the CloudKit-synced schema so selections follow the user to iOS.
@Model
final class RepoFilterPreference {
    var repoOwner = ""
    var repoName = ""
    var taskFiltersData: Data? = nil       // PersistedTaskFilters (no search)
    var versionFiltersData: Data? = nil    // PersistedVersionFilters (no search)
    var feedbackFiltersData: Data? = nil   // PersistedFeedbackFilters (no search)
    var updatedAt = Date.distantPast

    init(repoOwner: String, repoName: String) {
        self.repoOwner = repoOwner
        self.repoName = repoName
    }
}
```

- [ ] **Step 2: Register in the cloud schema**

`AppFeedbackApp.swift:90` — append `RepoFilterPreference.self` to the `cloudSchema` array:

```swift
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self, RepoFilterPreference.self])
```

- [ ] **Step 3: Register in both `ModelContainer(for:)` lists**

In the **test** container (`:78-87`) and the **prod** container (`:99-108`), add `RepoFilterPreference.self` to the `for:` type list (e.g. on the `ReplyTemplate.self,` line, append `RepoFilterPreference.self,`). Both lists must include it so the model is known in tests and production.

- [ ] **Step 4: Build**

Build the macOS app via the zcode skill.
Expected: BUILD SUCCEEDS (schema/container compile with the new model).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/RepoFilterPreference.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(filters): RepoFilterPreference model + schema registration"
```

---

### Task 5: Persisted DTOs + `FilterPreferenceStore` + live mapping

**Files:**
- Create: `AppFeedback/Services/FilterPreferenceStore.swift`
- Modify: `AppFeedback/ViewModels/ProjectInspectorModel.swift` (TaskFilters/VersionFilters ↔ DTO)
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift` (feedback ↔ DTO)
- Test: `AppFeedbackTests/FilterPreferenceStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/FilterPreferenceStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class FilterPreferenceStoreTests: XCTestCase {
    private func makeStore() throws -> FilterPreferenceStore {
        let schema = Schema([RepoFilterPreference.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return FilterPreferenceStore(context: ModelContext(container))
    }

    func test_load_emptyReturnsDefaults() throws {
        let store = try makeStore()
        let bundle = store.load(owner: "o", repo: "r")
        XCTAssertEqual(bundle, PersistedFilterBundle())
        XCTAssertEqual(bundle.task.versionScope, .any)
    }

    func test_saveThenLoad_roundTrips() throws {
        let store = try makeStore()
        var bundle = PersistedFilterBundle()
        bundle.task.versionScope = .state(.released)
        bundle.task.statuses = [.inProgress]
        bundle.version.states = [.new]
        bundle.feedback.appVersion = ["2.8"]
        bundle.feedback.appFilter = ["MyApp"]
        store.save(owner: "o", repo: "r", bundle: bundle)

        let loaded = store.load(owner: "o", repo: "r")
        XCTAssertEqual(loaded, bundle)
    }

    func test_isolatedByRepo() throws {
        let store = try makeStore()
        var a = PersistedFilterBundle(); a.task.versionScope = .state(.new)
        store.save(owner: "o", repo: "r1", bundle: a)
        XCTAssertEqual(store.load(owner: "o", repo: "r2"), PersistedFilterBundle())
    }

    func test_save_upsertsSingleRow() throws {
        let store = try makeStore()
        store.save(owner: "o", repo: "r", bundle: PersistedFilterBundle())
        var b = PersistedFilterBundle(); b.task.versionScope = .state(.wip)
        store.save(owner: "o", repo: "r", bundle: b)
        XCTAssertEqual(store.load(owner: "o", repo: "r").task.versionScope, .state(.wip))
    }

    func test_taskFiltersMapping_dropsSearch() {
        var live = TaskFilters()
        live.toggleState(.released)
        live.search = "ignore me"
        let dto = live.persisted
        var restored = TaskFilters()
        restored.apply(dto)
        XCTAssertEqual(restored.versionScope, .state(.released))
        XCTAssertEqual(restored.search, "")          // search not persisted
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Build the test target via the zcode skill.
Expected: COMPILE FAILURE — `cannot find 'FilterPreferenceStore'` / `PersistedFilterBundle`.

- [ ] **Step 3: Create DTOs + store**

Create `AppFeedback/Services/FilterPreferenceStore.swift`:

```swift
import Foundation
import SwiftData

// MARK: - Persisted DTOs (no `search` — live search is intentionally not persisted)

struct PersistedTaskFilters: Codable, Equatable {
    var statuses: Set<TaskStatus> = []
    var priorities: Set<TaskPriority> = []
    var versionScope: VersionScope = .any
}

struct PersistedVersionFilters: Codable, Equatable {
    var states: Set<VersionState> = []
}

struct PersistedFeedbackFilters: Codable, Equatable {
    var appVersion: Set<String> = []
    var device: Set<String> = []
    var osVersion: Set<String> = []
    var issueType: Set<IssueType> = []
    var appFilter: Set<String> = []
}

struct PersistedFilterBundle: Codable, Equatable {
    var task = PersistedTaskFilters()
    var version = PersistedVersionFilters()
    var feedback = PersistedFeedbackFilters()
}

// MARK: - Store

@MainActor
final class FilterPreferenceStore {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func load(owner: String, repo: String) -> PersistedFilterBundle {
        guard let row = row(owner: owner, repo: repo) else { return PersistedFilterBundle() }
        return PersistedFilterBundle(
            task: decode(row.taskFiltersData) ?? PersistedTaskFilters(),
            version: decode(row.versionFiltersData) ?? PersistedVersionFilters(),
            feedback: decode(row.feedbackFiltersData) ?? PersistedFeedbackFilters()
        )
    }

    func save(owner: String, repo: String, bundle: PersistedFilterBundle) {
        let row = row(owner: owner, repo: repo) ?? {
            let created = RepoFilterPreference(repoOwner: owner, repoName: repo)
            context.insert(created)
            return created
        }()
        row.taskFiltersData = encode(bundle.task)
        row.versionFiltersData = encode(bundle.version)
        row.feedbackFiltersData = encode(bundle.feedback)
        row.updatedAt = Date()
        try? context.save()
    }

    private func row(owner: String, repo: String) -> RepoFilterPreference? {
        let predicate = #Predicate<RepoFilterPreference> { $0.repoOwner == owner && $0.repoName == repo }
        var descriptor = FetchDescriptor<RepoFilterPreference>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    private func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
```

- [ ] **Step 4: Add live ↔ DTO mapping**

In `ProjectInspectorModel.swift`, after the `TaskFilters` struct, add:

```swift
extension TaskFilters {
    var persisted: PersistedTaskFilters {
        PersistedTaskFilters(statuses: statuses, priorities: priorities, versionScope: versionScope)
    }
    /// Applies persisted selections, leaving `search` untouched (it is never persisted).
    mutating func apply(_ dto: PersistedTaskFilters) {
        statuses = dto.statuses
        priorities = dto.priorities
        versionScope = dto.versionScope
    }
}

extension VersionFilters {
    var persisted: PersistedVersionFilters { PersistedVersionFilters(states: states) }
    mutating func apply(_ dto: PersistedVersionFilters) { states = dto.states }
}
```

In `IssueListViewModel.swift`, add inside the class (e.g. after `clearFilters()`):

```swift
    /// Feedback-list filter selections for persistence (structured chips only — not `searchQuery`).
    var persistedFeedbackFilters: PersistedFeedbackFilters {
        PersistedFeedbackFilters(appVersion: filters.appVersion, device: filters.device,
                                 osVersion: filters.osVersion, issueType: filters.issueType,
                                 appFilter: appFilter)
    }

    func applyFeedbackFilters(_ dto: PersistedFeedbackFilters) {
        filters.appVersion = dto.appVersion
        filters.device = dto.device
        filters.osVersion = dto.osVersion
        filters.issueType = dto.issueType
        appFilter = dto.appFilter
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Build & run `AppFeedbackTests_macOS` via the zcode skill.
Expected: PASS (all `FilterPreferenceStoreTests`).

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/FilterPreferenceStore.swift AppFeedback/ViewModels/ProjectInspectorModel.swift AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/FilterPreferenceStoreTests.swift
git commit -m "feat(filters): persisted filter DTOs + FilterPreferenceStore"
```

---

### Task 6: Wire load/save into `AppFeedbackApp` + `RootView`

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (build store, pass to `RootView`)
- Modify: `AppFeedback/App/RootView.swift` (property + init; drop clear-on-switch; load in `updateViewModel`; push `versionStates`; save on change)

- [ ] **Step 1: Build the store in the App and pass it down**

`AppFeedbackApp.swift` — add a `@State` near the other store decls (after `versionStore`, ~line 38):

```swift
    @State private var filterStore: FilterPreferenceStore
```

In `init()`, after `_versionStore = State(...)` (~line 137):

```swift
        _filterStore = State(initialValue: FilterPreferenceStore(context: ModelContext(container)))
```

At the `RootView(...)` call site (`:277`):

```swift
            RootView(store: store, seenStore: seenStore, cacheContext: cacheContext, versionStore: versionStore, filterStore: filterStore)
```

- [ ] **Step 2: Add the property + init param to `RootView`**

`RootView.swift` — add to the stored properties (after `var versionStore: VersionStore`, `:9`):

```swift
    var filterStore: FilterPreferenceStore
```

Update `init` (`:11-18`) to accept and assign it:

```swift
    init(store: RepoStore, seenStore: SeenIssueStore, cacheContext: ModelContext, versionStore: VersionStore, filterStore: FilterPreferenceStore) {
        self.store = store
        self.seenStore = seenStore
        self.cacheContext = cacheContext
        self.versionStore = versionStore
        self.filterStore = filterStore
        _selection = State(initialValue: store.repos.first.map { SidebarSelection.allIssues(repoId: $0.id) })
    }
```

- [ ] **Step 3: Add a load/save helper + owner/repo lookup**

Add these helpers to `RootView` (near `updateViewModel`):

```swift
    private func ownerRepo(for repoId: UUID) -> (owner: String, repo: String)? {
        guard let cfg = store.repos.first(where: { $0.id == repoId }) else { return nil }
        return (cfg.owner, cfg.repo)
    }

    /// Loads this repo's persisted filters into the view models. Falls back to cleared filters.
    private func loadPersistedFilters(repoId: UUID) {
        guard let (owner, repo) = ownerRepo(for: repoId) else {
            inspector.clearFilters(); viewModel.clearFilters(); viewModel.appFilter = []
            return
        }
        let bundle = filterStore.load(owner: owner, repo: repo)
        inspector.taskFilters.apply(bundle.task)
        inspector.versionFilters.apply(bundle.version)
        viewModel.applyFeedbackFilters(bundle.feedback)
    }

    /// Persists the current repo's filter selections (structured chips only).
    private func savePersistedFilters() {
        guard let repoId = selection?.repoId, let (owner, repo) = ownerRepo(for: repoId) else { return }
        let bundle = PersistedFilterBundle(task: inspector.taskFilters.persisted,
                                           version: inspector.versionFilters.persisted,
                                           feedback: viewModel.persistedFeedbackFilters)
        filterStore.save(owner: owner, repo: repo, bundle: bundle)
    }
```

- [ ] **Step 4: Replace clear-on-switch with load + push `versionStates`**

`RootView.swift:199-203` — remove the `inspector.clearFilters()` line from the `onChange(of: selection)` body (keep `clearCreations()` and `versionCreations.clearAll()`):

```swift
            if oldValue?.repoId != newValue?.repoId {
                inspector.clearCreations()
                versionCreations.clearAll()
            }
```

In `updateViewModel(for:)` (`:314-318`), replace the `inspector.setTasks(...)` / `viewModel.clearFilters()` / `viewModel.appFilter = []` block with:

```swift
        inspector.setTasks(viewModel.tasks)
        inspector.versionStates = versionStates(owner: owner, repo: repoName)
        loadPersistedFilters(repoId: selection.repoId)
        viewModel.allowsAppFilter = true
```

(Keep the surrounding lines — `viewModel.hiddenApps`, `attachSeenStore`, `applyLoaded` — as they were. Remove the now-duplicated `viewModel.allowsAppFilter = true` if it appears twice.)

- [ ] **Step 5: Add save-on-change modifiers**

Add to the modifier chain on the same view that holds the other `.onChange` handlers (near `:195-216`):

```swift
        .onChange(of: inspector.taskFilters) { _, _ in savePersistedFilters() }
        .onChange(of: inspector.versionFilters) { _, _ in savePersistedFilters() }
        .onChange(of: viewModel.filters) { _, _ in savePersistedFilters() }
        .onChange(of: viewModel.appFilter) { _, _ in savePersistedFilters() }
```

> `viewModel.filters` is `ActiveFilters` (already `Equatable`); `inspector.taskFilters`/`versionFilters` are `Equatable`. `.onChange` requires `Equatable` — all satisfied. Saving identical values on load is harmless (idempotent upsert).

- [ ] **Step 6: Reload filters on CloudKit import**

`RootView.swift:263` already has a `for await _ in NotificationCenter.cloudKitImportSucceeded` loop. Inside that loop body, add a reload of the current repo's filters so an iOS edit appears here:

```swift
                if let repoId = selection?.repoId { loadPersistedFilters(repoId: repoId) }
```

- [ ] **Step 7: Build + run the suite**

Build the macOS app and run `AppFeedbackTests_macOS` via the zcode skill.
Expected: BUILD SUCCEEDS; all tests PASS.

- [ ] **Step 8: Manual smoke (zcode run)**

Launch the app via the zcode skill. Verify:
1. In Tasks, open **Version ▾** → pick **Released**; only released-version tasks show; a "Released" sub-pill appears.
2. Open the **Version** submenu, tick a specific version → the state pill is replaced by that version's pill; tick a second version → both show (additive).
3. Set some task + feedback filters, switch repos and back → selections restored (not cleared).
4. Relaunch the app → selections still present.

- [ ] **Step 9: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift AppFeedback/App/RootView.swift
git commit -m "feat(filters): persist per-repo filters + push version states to inspector"
```

---

## Self-Review notes

- **Spec coverage:** VersionScope + live `.state` resolution (Tasks 1–2); two-section Version menu with names submenu (Task 3); CloudKit-synced model (Task 4); store + search-excluded DTOs (Task 5); per-repo load/save replacing clear-on-switch + CloudKit reload (Task 6). All spec sections mapped.
- **Type consistency:** `VersionScope`, `TaskFilters.toggleState/toggleVersion/isStateSelected/isVersionSelected/persisted/apply`, `versionStates`, `PersistedTaskFilters/PersistedVersionFilters/PersistedFeedbackFilters/PersistedFilterBundle`, `FilterPreferenceStore.load/save`, `RepoFilterPreference`, `IssueListViewModel.persistedFeedbackFilters/applyFeedbackFilters` are used consistently across tasks.
- **Known consequence (accepted in spec):** single-select states — no one-tap "all non-released".
