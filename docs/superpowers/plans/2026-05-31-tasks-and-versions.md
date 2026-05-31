# Tasks & Versions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the developer turn feedbacks into GitHub-backed tasks, group tasks into versions (milestones + optional releases), and email the affected users — with confirmation — when a version is released, all from a collapsible right-side inspector panel.

**Architecture:** Tasks are GitHub issues labelled `appfeedback:task` (filtered out of the feedback list); feedback links live as `Addresses: #n` references in the task body. Versions are GitHub Milestones (always) plus an optional Release, mirrored into two new CloudKit-synced SwiftData models (`ProjectVersion`, `SentReleaseNotification`). GitHub remains the source of truth; new actor clients (`GitHubIssueWriter`, `GitHubMilestoneReleaseClient`) follow the existing `GitHubCommentPoster` REST pattern. The release email reuses the existing `ComposeMailViewModel` send path. Project = repo (the multi-app-per-repo UI is removed first).

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData + CloudKit, XcodeGen, SwiftMail (SMTP), GitHub REST + GraphQL, XCTest with `MockURLProtocol`.

**Reference spec:** `docs/superpowers/specs/2026-05-31-tasks-and-versions-design.md`

---

## Conventions used throughout this plan

- **Adding a new file requires regenerating the Xcode project** (XcodeGen scans folders at generate time). After creating any new `.swift` file, run:
  ```bash
  cd /Users/amir/Developer/AppFeedback && xcodegen generate
  ```
- **Ground-truth test runs use `xcodebuild`** (the zcode `/api/test` summary can report a pass even when a test hard-crashes — see project memory). Canonical command (macOS, no simulator boot):
  ```bash
  cd /Users/amir/Developer/AppFeedback && xcodegen generate && \
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
    -only-testing:AppFeedbackTests_macOS/<TestClass> 2>&1 | tail -40
  ```
  Replace `<TestClass>` (and optionally `/<testMethod>`) per step. Drop `-only-testing:` to run the whole suite.
  > **NOTE:** xcodegen splits the `AppFeedbackTests` target per-platform, so the runtime test target is **`AppFeedbackTests_macOS`** (and `AppFeedbackTests_iOS`) — *not* `AppFeedbackTests`. Every `-only-testing:` argument below should read `AppFeedbackTests_macOS/<TestClass>`. `xcodegen` (2.45.4) is installed via brew; after adding a new file, `xcodegen generate` and **commit the regenerated `AppFeedback.xcodeproj/project.pbxproj` together with the source file.**
- **New source files** go under `AppFeedback/...` (auto-included by folder); **new tests** under `AppFeedbackTests/` (flat folder).
- **Network tests** inject `URLSession.mock` and set `MockURLProtocol.requestHandler` (see `AppFeedbackTests/MockURLProtocol.swift`).
- **Commit after every task.** Branch is `feature/tasks-and-versions` (already created).

## Shared identifiers (define once, reuse everywhere)

These names are referenced across many tasks; they are introduced in **Task 1.1** and **Task 1.3**. Keep them exact:

- Labels: `AppFeedbackLabels.task = "appfeedback:task"`, `.statusTodo = "status:todo"`, `.statusInProgress = "status:in-progress"`, `.statusDone = "status:done"`, `.priorityLow = "priority:low"`, `.priorityMed = "priority:med"`, `.priorityHigh = "priority:high"`.
- `enum TaskStatus: String { case todo, inProgress, done }` (rawValues `"todo"`, `"in-progress"`, `"done"`).
- `enum TaskPriority: String { case low, med, high }`.
- `struct TaskItem` — parsed task (number, title, body, feedbackRefs, status, priority, milestoneTitle, isClosed).
- `FeedbackTaskRefParser` — parses/formats the `Addresses: #12, #15` block in a task body.

---

# PHASE 0 — Remove multi-app-per-repo (project = repo)

Goal: every repo selects as a whole; the `.app` sidebar concept is gone. No data migration (appName is parsed, not stored structurally).

### Task 0.1: Simplify `SidebarSelection` to repo-only

**Files:**
- Modify: `AppFeedback/Models/SidebarSelection.swift`
- Test: `AppFeedbackTests/ModelsTests.swift` (add a case)

- [ ] **Step 1: Write the failing test**

Add to `AppFeedbackTests/ModelsTests.swift`:

```swift
func testSidebarSelectionExposesRepoID() {
    let id = UUID()
    let sel = SidebarSelection.allIssues(repoId: id)
    XCTAssertEqual(sel.repoId, id)
}
```

- [ ] **Step 2: Run it (compiles against current enum, should PASS already — this pins behavior before we delete `.app`)**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ModelsTests/testSidebarSelectionExposesRepoID 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 3: Remove the `.app` case**

Replace the entire contents of `AppFeedback/Models/SidebarSelection.swift` with:

```swift
import Foundation

enum SidebarSelection: Hashable, Sendable {
    case allIssues(repoId: UUID)

    var repoId: UUID {
        switch self {
        case .allIssues(let id): return id
        }
    }
}
```

- [ ] **Step 4: Build to surface every `.app` use site (compiler-driven)**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | grep -E "error:|\.app" | head -40`
Expected: errors in `RepoSectionView.swift`, `RootView.swift` (navigationTitle, updateViewModel). These are fixed in Tasks 0.2–0.3.

- [ ] **Step 5: Commit** (after 0.2 and 0.3 also done — this task does not build alone; commit at end of 0.3).

### Task 0.2: Collapse `RepoSectionView` to a single selectable repo row

**Files:**
- Modify: `AppFeedback/Views/Sidebar/RepoSectionView.swift`

- [ ] **Step 1: Replace the whole view body with a repo leaf row**

Replace the entire contents of `AppFeedback/Views/Sidebar/RepoSectionView.swift` with:

```swift
import SwiftUI

struct RepoSectionView: View {
    let repo: RepoConfig
    let issues: [FeedbackIssue]
    let allApps: [String]          // retained param (callers still pass it); unused for selection now
    @Binding var selection: SidebarSelection?
    var store: RepoStore
    @State private var showRemoveConfirmation = false

    var body: some View {
        AppRowView(
            label: repo.displayName,
            count: issues.count,
            color: .secondary,
            isSelected: selection == .allIssues(repoId: repo.id)
        )
        .tag(SidebarSelection.allIssues(repoId: repo.id))
        .contentShape(Rectangle())
        .onTapGesture { selection = .allIssues(repoId: repo.id) }
        .contextMenu {
            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label("Remove Repo", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Remove \"\(repo.displayName)\"?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if selection?.repoId == repo.id { selection = nil }
                Task { await store.remove(id: repo.id) }
            }
        } message: {
            Text("This will remove the repo from the sidebar. Your GitHub data will not be affected.")
        }
    }
}
```

Note: `AppRowView` already exists and is reused. The per-app color/hide context actions are intentionally dropped with the multi-app concept.

- [ ] **Step 2: Build** — defer to 0.3 (RootView still references `.app`).

### Task 0.3: Fix `RootView` `.app` references; make filters repo-wide

**Files:**
- Modify: `AppFeedback/App/RootView.swift`

- [ ] **Step 1: Simplify `navigationTitle(for:)`**

Replace (RootView.swift ~162-171):

```swift
    #if os(iOS)
    private func navigationTitle(for selection: SidebarSelection) -> String {
        switch selection {
        case .allIssues:
            return "All Apps"
        case .app(_, let appName):
            return appName
        }
    }
    #endif
```

with:

```swift
    #if os(iOS)
    private func navigationTitle(for selection: SidebarSelection) -> String {
        store.repos.first(where: { $0.id == selection.repoId })?.displayName ?? "Feedback"
    }
    #endif
```

- [ ] **Step 2: Simplify `updateViewModel(for:)`**

Replace the `switch selection { … }` block at the end of `updateViewModel` (RootView.swift ~188-195):

```swift
        switch selection {
        case .allIssues:
            viewModel.appFilter = []
            viewModel.allowsAppFilter = true
        case .app(_, let name):
            viewModel.appFilter = [name]
            viewModel.allowsAppFilter = false
        }
```

with:

```swift
        viewModel.appFilter = []
        viewModel.allowsAppFilter = true
```

- [ ] **Step 3: Build the whole app for both platforms**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && \
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -20
```
Expected: no `error:` lines (no remaining `.app` references). If `allApps`/`allAppsFor` are now unused and the compiler warns, leave them (warnings are fine) or delete the now-dead `navigationTitle` `.app` arm only.

- [ ] **Step 4: Run the model + repo test suites**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ModelsTests -only-testing:AppFeedbackTests/RepoStoreTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/SidebarSelection.swift AppFeedback/Views/Sidebar/RepoSectionView.swift AppFeedback/App/RootView.swift AppFeedbackTests/ModelsTests.swift
git commit -m "feat(phase0): remove multi-app-per-repo; project = repo"
```

---

# PHASE 1 — GitHub backend (labels, loaders, writers, models, stores)

### Task 1.1: Label + status/priority constants and enums

**Files:**
- Create: `AppFeedback/Models/TaskMetadata.swift`
- Test: `AppFeedbackTests/TaskMetadataTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/TaskMetadataTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class TaskMetadataTests: XCTestCase {
    func testStatusFromLabels() {
        XCTAssertEqual(TaskStatus(labels: ["status:in-progress", "other"]), .inProgress)
        XCTAssertEqual(TaskStatus(labels: ["nope"]), .todo)             // default
        XCTAssertEqual(TaskStatus(labels: ["status:done"]), .done)
    }

    func testPriorityFromLabels() {
        XCTAssertEqual(TaskPriority(labels: ["priority:high"]), .high)
        XCTAssertEqual(TaskPriority(labels: []), .med)                  // default
    }

    func testLabelRoundTrip() {
        XCTAssertEqual(TaskStatus.done.label, "status:done")
        XCTAssertEqual(TaskPriority.low.label, "priority:low")
        XCTAssertEqual(AppFeedbackLabels.task, "appfeedback:task")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/TaskMetadataTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TaskStatus' in scope`.

- [ ] **Step 3: Implement**

Create `AppFeedback/Models/TaskMetadata.swift`:

```swift
import Foundation

/// Reserved GitHub label names this app reads/writes to model tasks.
enum AppFeedbackLabels {
    static let task           = "appfeedback:task"
    static let statusTodo       = "status:todo"
    static let statusInProgress = "status:in-progress"
    static let statusDone       = "status:done"
    static let priorityLow  = "priority:low"
    static let priorityMed  = "priority:med"
    static let priorityHigh = "priority:high"

    /// Every label this app manages, with the color GitHub should use when creating it.
    static let managed: [(name: String, color: String)] = [
        (task, "5319e7"),
        (statusTodo, "ededed"), (statusInProgress, "fbca04"), (statusDone, "0e8a16"),
        (priorityLow, "c2e0c6"), (priorityMed, "fef2c0"), (priorityHigh, "f9d0c4"),
    ]
}

enum TaskStatus: String, CaseIterable, Sendable {
    case todo
    case inProgress = "in-progress"
    case done

    var label: String { "status:\(rawValue)" }
    var displayName: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    /// First matching status label wins; defaults to `.todo`.
    init(labels: [String]) {
        for s in TaskStatus.allCases where labels.contains(s.label) { self = s; return }
        self = .todo
    }
}

enum TaskPriority: String, CaseIterable, Sendable {
    case low, med, high

    var label: String { "priority:\(rawValue)" }
    var sortRank: Int {                          // high first
        switch self { case .high: return 0; case .med: return 1; case .low: return 2 }
    }
    var displayName: String { rawValue.capitalized }

    /// First matching priority label wins; defaults to `.med`.
    init(labels: [String]) {
        for p in TaskPriority.allCases where labels.contains(p.label) { self = p; return }
        self = .med
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/TaskMetadata.swift AppFeedbackTests/TaskMetadataTests.swift
git commit -m "feat(tasks): add label constants + TaskStatus/TaskPriority"
```

### Task 1.2: `FeedbackTaskRefParser` — many-to-many links in the task body

**Files:**
- Create: `AppFeedback/Services/FeedbackTaskRefParser.swift`
- Test: `AppFeedbackTests/FeedbackTaskRefParserTests.swift`

The task body carries a machine-managed block:
```
<!-- appfeedback:addresses -->
Addresses: #12, #15, #20
<!-- /appfeedback:addresses -->
```

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/FeedbackTaskRefParserTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class FeedbackTaskRefParserTests: XCTestCase {
    func testParseEmptyWhenNoBlock() {
        XCTAssertEqual(FeedbackTaskRefParser.parse("Some task body, no refs."), [])
    }

    func testParseExtractsNumbersDeduplicatedSorted() {
        let body = """
        Fix the thing.

        <!-- appfeedback:addresses -->
        Addresses: #15, #12, #12, #20
        <!-- /appfeedback:addresses -->
        """
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [12, 15, 20])
    }

    func testFormatInsertsBlockWhenAbsent() {
        let out = FeedbackTaskRefParser.upsert(into: "Body text.", refs: [20, 12])
        XCTAssertEqual(FeedbackTaskRefParser.parse(out), [12, 20])
        XCTAssertTrue(out.contains("Addresses: #12, #20"))
    }

    func testUpsertReplacesExistingBlockAndPreservesProse() {
        let original = FeedbackTaskRefParser.upsert(into: "Hello.", refs: [1])
        let updated = FeedbackTaskRefParser.upsert(into: original, refs: [1, 2])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [1, 2])
        XCTAssertTrue(updated.hasPrefix("Hello."))
        // Exactly one block.
        XCTAssertEqual(updated.components(separatedBy: "appfeedback:addresses").count - 1, 2)
    }

    func testUpsertEmptyRefsRemovesBlock() {
        let withBlock = FeedbackTaskRefParser.upsert(into: "X", refs: [1])
        let cleared = FeedbackTaskRefParser.upsert(into: withBlock, refs: [])
        XCTAssertFalse(cleared.contains("appfeedback:addresses"))
        XCTAssertEqual(FeedbackTaskRefParser.parse(cleared), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/FeedbackTaskRefParserTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'FeedbackTaskRefParser'`.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/FeedbackTaskRefParser.swift`:

```swift
import Foundation

/// Reads and writes the machine-managed "Addresses: #n, #n" block that links a task
/// issue to the feedback issues it addresses. This block is the source of truth for the
/// many-to-many task↔feedback relationship; GitHub renders backlinks on each feedback.
enum FeedbackTaskRefParser {
    static let openMarker  = "<!-- appfeedback:addresses -->"
    static let closeMarker = "<!-- /appfeedback:addresses -->"

    /// Returns the addressed feedback numbers, deduplicated and ascending.
    static func parse(_ body: String) -> [Int] {
        guard let range = blockRange(in: body) else { return [] }
        let inner = String(body[range])
        let numbers = matches(of: "#([0-9]+)", in: inner).compactMap { Int($0) }
        return Array(Set(numbers)).sorted()
    }

    /// Returns `body` with the addresses block inserted/replaced (or removed when `refs` is empty).
    static func upsert(into body: String, refs: [Int]) -> String {
        let stripped = removingBlock(from: body)
        let sorted = Array(Set(refs)).sorted()
        guard !sorted.isEmpty else { return stripped.trimmingTrailingNewlines() }
        let line = "Addresses: " + sorted.map { "#\($0)" }.joined(separator: ", ")
        let block = "\(openMarker)\n\(line)\n\(closeMarker)"
        let base = stripped.trimmingTrailingNewlines()
        return base.isEmpty ? block : "\(base)\n\n\(block)"
    }

    // MARK: - Internals

    private static func blockRange(in body: String) -> Range<String.Index>? {
        guard let open = body.range(of: openMarker),
              let close = body.range(of: closeMarker),
              open.upperBound <= close.lowerBound else { return nil }
        return open.upperBound..<close.lowerBound
    }

    private static func removingBlock(from body: String) -> String {
        guard let open = body.range(of: openMarker),
              let close = body.range(of: closeMarker),
              open.lowerBound <= close.upperBound else { return body }
        var result = body
        result.removeSubrange(open.lowerBound..<close.upperBound)
        return result
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while let last = s.last, last == "\n" || last == "\r" { s.removeLast() }
        return s
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/FeedbackTaskRefParser.swift AppFeedbackTests/FeedbackTaskRefParserTests.swift
git commit -m "feat(tasks): add FeedbackTaskRefParser for many-to-many links"
```

### Task 1.3: `TaskItem` value type + parse from a loaded issue

**Files:**
- Create: `AppFeedback/Models/TaskItem.swift`
- Test: `AppFeedbackTests/TaskItemTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/TaskItemTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class TaskItemTests: XCTestCase {
    private func issue(number: Int, body: String, labels: [String], state: IssueState, milestone: String?) -> FeedbackIssue {
        FeedbackIssue(
            number: number, title: "T\(number)", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: body, labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") },
            state: state, milestoneTitle: milestone
        )
    }

    func testParsesStatusPriorityAndRefs() {
        let body = FeedbackTaskRefParser.upsert(into: "Do it", refs: [12, 15])
        let item = TaskItem(issue: issue(
            number: 99, body: body,
            labels: [AppFeedbackLabels.task, "status:in-progress", "priority:high"],
            state: .open, milestone: "1.2.0"
        ))
        XCTAssertEqual(item.number, 99)
        XCTAssertEqual(item.feedbackRefs, [12, 15])
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertEqual(item.priority, .high)
        XCTAssertEqual(item.milestoneTitle, "1.2.0")
        XCTAssertFalse(item.isClosed)
    }

    func testClosedIssueIsDoneEquivalent() {
        let item = TaskItem(issue: issue(number: 1, body: "", labels: [AppFeedbackLabels.task], state: .closed, milestone: nil))
        XCTAssertTrue(item.isClosed)
        XCTAssertTrue(item.isCompleted)   // closed OR status:done
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/TaskItemTests 2>&1 | tail -20`
Expected: FAIL — `TaskItem` not found, and `FeedbackIssue` has no `milestoneTitle` (added in Task 1.4). **If `milestoneTitle:` errors here, do Task 1.4 first, then return.** (Both are small; recommended order is 1.4 then re-run 1.3.)

- [ ] **Step 3: Implement**

Create `AppFeedback/Models/TaskItem.swift`:

```swift
import Foundation

/// In-memory projection of a GitHub issue that carries the `appfeedback:task` label.
/// Not persisted — derived from a loaded `FeedbackIssue` on every fetch.
struct TaskItem: Identifiable, Sendable, Hashable {
    let number: Int
    let title: String
    let body: String
    let feedbackRefs: [Int]
    let status: TaskStatus
    let priority: TaskPriority
    let milestoneTitle: String?
    let isClosed: Bool

    var id: Int { number }

    /// "Completed" for notification purposes: the issue is closed or explicitly status:done.
    var isCompleted: Bool { isClosed || status == .done }

    init(issue: FeedbackIssue) {
        self.number = issue.number
        self.title = issue.title
        self.body = issue.rawBody
        self.feedbackRefs = FeedbackTaskRefParser.parse(issue.rawBody)
        let labelNames = issue.labels.map(\.name)
        self.status = TaskStatus(labels: labelNames)
        self.priority = TaskPriority(labels: labelNames)
        self.milestoneTitle = issue.milestoneTitle
        self.isClosed = (issue.state == .closed)
    }

    /// True when a loaded issue should be treated as a task rather than feedback.
    static func isTask(_ issue: FeedbackIssue) -> Bool {
        issue.labels.contains { $0.name == AppFeedbackLabels.task }
    }
}
```

- [ ] **Step 4: Run to verify it passes** (after Task 1.4). Expected: PASS.

- [ ] **Step 5: Commit** (combined with 1.4).

### Task 1.4: Add `milestoneTitle` to `FeedbackIssue` and fetch it in the loader

**Files:**
- Modify: `AppFeedback/Models/FeedbackIssue.swift`
- Modify: `AppFeedback/Services/IssueLoader.swift`
- Modify: `AppFeedback/Models/CachedIssue.swift` (persist the new field)
- Test: `AppFeedbackTests/IssueLoaderTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Add to `AppFeedbackTests/IssueLoaderTests.swift` (mirror the existing GraphQL-mock tests in that file; this asserts milestone decoding):

```swift
func testDecodesMilestoneTitle() throws {
    let json = """
    {"data":{"repository":{"issues":{
      "pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":7,"title":"X","body":"b","createdAt":"2024-01-01T00:00:00Z",
        "updatedAt":"2024-01-01T00:00:00Z","state":"OPEN",
        "milestone":{"title":"1.2.0"},
        "labels":{"nodes":[{"name":"appfeedback:task","color":"5319e7"}]}}]
    }}}}
    """.data(using: .utf8)!
    let result = try IssueLoader.decodePageForTesting(data: json, owner: "o", repo: "r")
    XCTAssertEqual(result.first?.milestoneTitle, "1.2.0")
    XCTAssertTrue(result.first.map(TaskItem.isTask) ?? false)
}
```

If `IssueLoader.decodePage` is `private`, add a test shim in `IssueLoader` (Step 3) exposing `decodePageForTesting`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/IssueLoaderTests/testDecodesMilestoneTitle 2>&1 | tail -20`
Expected: FAIL (no `milestoneTitle`, no `decodePageForTesting`).

- [ ] **Step 3: Implement**

(a) In `AppFeedback/Models/FeedbackIssue.swift`, add the stored property and init parameter. Add after `var state: IssueState?` (line ~57):

```swift
    var milestoneTitle: String?
```

Add to the initializer parameter list (after `state: IssueState? = nil,`):

```swift
        milestoneTitle: String? = nil,
```

and in the init body (after `self.state = state`):

```swift
        self.milestoneTitle = milestoneTitle
```

(b) In `AppFeedback/Services/IssueLoader.swift`, extend the GraphQL query (line ~187) — add `milestone { title }` inside `nodes`:

```graphql
        number
        title
        body
        createdAt
        updatedAt
        state
        milestone { title }
        labels(first: 30) { nodes { name color } }
```

Add the decodable (near the other private structs, line ~329):

```swift
private struct Milestone: Decodable { let title: String }
```

Add `let milestone: Milestone?` to the private `Node` struct (after `let state: String`).

In `decodePage` (line ~268), pass the milestone into the `FeedbackIssue(...)` initializer (add a line after `state: IssueState(rawValue: node.state.lowercased()),`):

```swift
            milestoneTitle: node.milestone?.title,
```

Add the test shim at the end of `IssueLoader` (before the closing brace):

```swift
    #if DEBUG
    static func decodePageForTesting(data: Data, owner: String, repo: String) throws -> [FeedbackIssue] {
        try decodePage(data: data, owner: owner, repo: repo).nodes
    }
    #endif
```

(c) In `AppFeedback/Models/CachedIssue.swift`, persist the new field. `CachedIssue` encodes/decodes the full `FeedbackIssue` — locate the property list and the `from(_:)` / `toFeedbackIssue()` mapping (whatever the file uses) and add `milestoneTitle`. Add the stored property:

```swift
    var milestoneTitle: String?
```

and set it in both directions of the mapping (where other optional fields like `osVersion` are mapped). Default existing rows to `nil`.

- [ ] **Step 4: Run 1.3 + 1.4 tests**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/IssueLoaderTests -only-testing:AppFeedbackTests/TaskItemTests -only-testing:AppFeedbackTests/CachedIssueTests 2>&1 | tail -25`
Expected: PASS (including the previously-failing TaskItemTests).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/FeedbackIssue.swift AppFeedback/Services/IssueLoader.swift AppFeedback/Models/CachedIssue.swift AppFeedback/Models/TaskItem.swift AppFeedbackTests/TaskItemTests.swift AppFeedbackTests/IssueLoaderTests.swift
git commit -m "feat(tasks): fetch milestone on issues; add TaskItem projection"
```

### Task 1.5: Partition tasks out of the feedback list

The feedback list must not show task issues. `IssueListViewModel.applyLoaded(_:)` is the single funnel (called from `RootView.updateViewModel`). Filter there, and expose tasks for the panel.

**Files:**
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift`
- Test: `AppFeedbackTests/IssueListViewModelTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Add to `AppFeedbackTests/IssueListViewModelTests.swift`:

```swift
func testApplyLoadedExcludesTaskIssuesFromFeedback() {
    let vm = IssueListViewModel()
    let feedback = FeedbackIssue(number: 1, title: "fb", createdAt: Date(), rawBody: "",
        appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
        description: "", labels: [])
    let task = FeedbackIssue(number: 2, title: "task", createdAt: Date(), rawBody: "",
        appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
        description: "", labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "5319e7")])
    vm.applyLoaded([feedback, task])
    XCTAssertEqual(vm.allIssues.map(\.number), [1])
    XCTAssertEqual(vm.tasks.map(\.number), [2])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/IssueListViewModelTests/testApplyLoadedExcludesTaskIssuesFromFeedback 2>&1 | tail -20`
Expected: FAIL (`vm.tasks` not found; task issue leaks into allIssues).

- [ ] **Step 3: Implement**

In `IssueListViewModel`, add a published property near the other state:

```swift
    private(set) var tasks: [TaskItem] = []
```

At the **top** of `applyLoaded(_:)`, split the incoming issues before the existing logic runs:

```swift
    func applyLoaded(_ issues: [FeedbackIssue]) {
        let taskIssues = issues.filter(TaskItem.isTask)
        let feedbackIssues = issues.filter { !TaskItem.isTask($0) }
        tasks = taskIssues.map(TaskItem.init).sorted {
            ($0.priority.sortRank, $0.number) < ($1.priority.sortRank, $1.number)
        }
        let issues = feedbackIssues       // shadow so the rest of the method is unchanged
        // … existing body continues, now operating on the feedback-only array …
```

(Keep the remainder of the existing method as-is; it now sees only feedback issues.)

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Then run the full `IssueListViewModelTests` class to ensure no regression:
`xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/IssueListViewModelTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat(tasks): partition task issues out of the feedback list"
```

### Task 1.6: `GitHubIssueWriter` actor (create/update task issues)

**Files:**
- Create: `AppFeedback/Services/GitHubIssueWriter.swift`
- Test: `AppFeedbackTests/GitHubIssueWriterTests.swift`

Follows the `GitHubCommentPoster` pattern exactly (actor, injected `URLSession`, `Bearer` token, status check, typed error).

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/GitHubIssueWriterTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class GitHubIssueWriterTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testCreateIssuePostsLabelsAndBodyAndReturnsNumber() async throws {
        var captured: URLRequest?
        var capturedBody: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            captured = req
            if let stream = req.httpBodyStream { capturedBody = Self.readJSON(stream) }
            else if let d = req.httpBody { capturedBody = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, #"{"number":42}"#.data(using: .utf8)!)
        }
        let writer = GitHubIssueWriter(session: .mock)
        let number = try await writer.createIssue(
            owner: "o", repo: "r", title: "Fix bug",
            body: "details", labels: [AppFeedbackLabels.task, "status:todo", "priority:med"],
            milestoneNumber: 3, token: "tok"
        )
        XCTAssertEqual(number, 42)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.github.com/repos/o/r/issues")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(capturedBody?["title"] as? String, "Fix bug")
        XCTAssertEqual(capturedBody?["milestone"] as? Int, 3)
        XCTAssertEqual((capturedBody?["labels"] as? [String])?.contains(AppFeedbackLabels.task), true)
    }

    func testApiErrorThrows() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
             #"{"message":"Validation failed"}"#.data(using: .utf8)!)
        }
        let writer = GitHubIssueWriter(session: .mock)
        do {
            _ = try await writer.createIssue(owner: "o", repo: "r", title: "t", body: "b", labels: [], milestoneNumber: nil, token: "x")
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    private static func readJSON(_ stream: InputStream) -> [String: Any]? {
        stream.open(); defer { stream.close() }
        var data = Data(); let size = 4096; var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: size); if n > 0 { data.append(buf, count: n) } else { break } }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/GitHubIssueWriterTests 2>&1 | tail -20`
Expected: FAIL — `GitHubIssueWriter` not found.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/GitHubIssueWriter.swift`:

```swift
import Foundation

/// Creates and mutates GitHub issues used to model tasks. Mirrors `GitHubCommentPoster`'s
/// REST conventions: injected session, Bearer token, 2xx check, typed error.
actor GitHubIssueWriter {
    enum WriteError: LocalizedError {
        case apiError(Int, message: String?)
        var errorDescription: String? {
            switch self {
            case let .apiError(code, message?): return "GitHub API \(code): \(message)"
            case let .apiError(code, nil):      return "GitHub API \(code)"
            }
        }
    }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// Creates an issue and returns its number.
    func createIssue(owner: String, repo: String, title: String, body: String,
                     labels: [String], milestoneNumber: Int?, token: String) async throws -> Int {
        var payload: [String: Any] = ["title": title, "body": body, "labels": labels]
        if let milestoneNumber { payload["milestone"] = milestoneNumber }
        let data = try await send(
            "https://api.github.com/repos/\(owner)/\(repo)/issues",
            method: "POST", json: payload, token: token)
        guard let number = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["number"] as? Int else {
            throw WriteError.apiError(0, message: "Missing number in response")
        }
        return number
    }

    /// PATCHes any subset of issue fields. Pass `state` as "open"/"closed".
    func updateIssue(owner: String, repo: String, number: Int,
                     body: String? = nil, labels: [String]? = nil,
                     milestoneNumber: Int?? = nil, state: String? = nil, token: String) async throws {
        var payload: [String: Any] = [:]
        if let body { payload["body"] = body }
        if let labels { payload["labels"] = labels }
        if let state { payload["state"] = state }
        if let milestoneNumber {                      // double optional: .some(nil) clears it
            payload["milestone"] = milestoneNumber as Any? ?? NSNull()
        }
        _ = try await send(
            "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)",
            method: "PATCH", json: payload, token: token)
    }

    // MARK: - Shared request

    @discardableResult
    private func send(_ url: String, method: String, json: [String: Any], token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)",              forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json",  forHTTPHeaderField: "Accept")
        request.setValue("application/json",             forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WriteError.apiError(0, message: nil) }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw WriteError.apiError(http.statusCode, message: message)
        }
        return data
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/GitHubIssueWriter.swift AppFeedbackTests/GitHubIssueWriterTests.swift
git commit -m "feat(tasks): add GitHubIssueWriter (create/update task issues)"
```

### Task 1.7: `GitHubMilestoneReleaseClient` actor (milestones + releases + labels)

**Files:**
- Create: `AppFeedback/Services/GitHubMilestoneReleaseClient.swift`
- Test: `AppFeedbackTests/GitHubMilestoneReleaseClientTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/GitHubMilestoneReleaseClientTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class GitHubMilestoneReleaseClientTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testCreateMilestoneReturnsNumberAndTitle() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/o/r/milestones")
            XCTAssertEqual(req.httpMethod, "POST")
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"number":5,"title":"1.2.0","state":"open","description":"notes"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let ms = try await client.createMilestone(owner: "o", repo: "r", title: "1.2.0", description: "notes", token: "t")
        XCTAssertEqual(ms.number, 5)
        XCTAssertEqual(ms.title, "1.2.0")
        XCTAssertEqual(ms.state, "open")
    }

    func testListMilestonesParsesArray() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             #"[{"number":1,"title":"1.0","state":"closed","description":""},{"number":2,"title":"1.1","state":"open","description":"x"}]"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let all = try await client.listMilestones(owner: "o", repo: "r", token: "t")
        XCTAssertEqual(all.map(\.number), [1, 2])
    }

    func testCreateReleaseDraftThenPublishFlags() async throws {
        var capturedBody: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            if let d = req.httpBody { capturedBody = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"id":900,"tag_name":"v1.2.0","draft":false}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let rel = try await client.createRelease(owner: "o", repo: "r", tag: "v1.2.0",
            name: "1.2.0", body: "notes", draft: false, target: "main", token: "t")
        XCTAssertEqual(rel.id, 900)
        XCTAssertEqual(capturedBody?["tag_name"] as? String, "v1.2.0")
        XCTAssertEqual(capturedBody?["draft"] as? Bool, false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/GitHubMilestoneReleaseClientTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/GitHubMilestoneReleaseClient.swift`:

```swift
import Foundation

/// REST client for GitHub milestones, releases, and label bootstrap. Same conventions as
/// `GitHubIssueWriter`/`GitHubCommentPoster`.
actor GitHubMilestoneReleaseClient {
    struct Milestone: Sendable, Equatable {
        let number: Int
        let title: String
        let state: String          // "open" | "closed"
        let description: String?
    }
    struct Release: Sendable, Equatable {
        let id: Int
        let tagName: String
        let draft: Bool
    }
    enum ClientError: LocalizedError {
        case apiError(Int, message: String?)
        var errorDescription: String? {
            switch self {
            case let .apiError(c, m?): return "GitHub API \(c): \(m)"
            case let .apiError(c, nil): return "GitHub API \(c)"
            }
        }
    }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    // MARK: Milestones

    func listMilestones(owner: String, repo: String, token: String) async throws -> [Milestone] {
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/milestones?state=all&per_page=100",
                                  method: "GET", json: nil, token: token)
        let arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return arr.map(Self.milestone(from:))
    }

    func createMilestone(owner: String, repo: String, title: String, description: String, token: String) async throws -> Milestone {
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/milestones",
            method: "POST", json: ["title": title, "description": description], token: token)
        return Self.milestone(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func updateMilestone(owner: String, repo: String, number: Int,
                         title: String? = nil, description: String? = nil, state: String? = nil, token: String) async throws -> Milestone {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let description { payload["description"] = description }
        if let state { payload["state"] = state }
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/milestones/\(number)",
            method: "PATCH", json: payload, token: token)
        return Self.milestone(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    // MARK: Releases

    func createRelease(owner: String, repo: String, tag: String, name: String, body: String,
                       draft: Bool, target: String?, token: String) async throws -> Release {
        var payload: [String: Any] = ["tag_name": tag, "name": name, "body": body, "draft": draft]
        if let target { payload["target_commitish"] = target }
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/releases",
            method: "POST", json: payload, token: token)
        return Self.release(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func updateRelease(owner: String, repo: String, id: Int, body: String? = nil, draft: Bool? = nil, token: String) async throws -> Release {
        var payload: [String: Any] = [:]
        if let body { payload["body"] = body }
        if let draft { payload["draft"] = draft }
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/releases/\(id)",
            method: "PATCH", json: payload, token: token)
        return Self.release(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    // MARK: Labels (bootstrap)

    /// Idempotently creates a label; a 422 "already_exists" is treated as success.
    func ensureLabel(owner: String, repo: String, name: String, color: String, token: String) async throws {
        do {
            _ = try await send("https://api.github.com/repos/\(owner)/\(repo)/labels",
                method: "POST", json: ["name": name, "color": color], token: token)
        } catch ClientError.apiError(422, _) {
            return   // already exists
        }
    }

    // MARK: - Mapping + request

    private static func milestone(from d: [String: Any]) -> Milestone {
        Milestone(number: d["number"] as? Int ?? 0,
                  title: d["title"] as? String ?? "",
                  state: d["state"] as? String ?? "open",
                  description: d["description"] as? String)
    }
    private static func release(from d: [String: Any]) -> Release {
        Release(id: d["id"] as? Int ?? 0,
                tagName: d["tag_name"] as? String ?? "",
                draft: d["draft"] as? Bool ?? false)
    }

    @discardableResult
    private func send(_ url: String, method: String, json: [String: Any]?, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.apiError(0, message: nil) }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw ClientError.apiError(http.statusCode, message: message)
        }
        return data
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/GitHubMilestoneReleaseClient.swift AppFeedbackTests/GitHubMilestoneReleaseClientTests.swift
git commit -m "feat(versions): add GitHubMilestoneReleaseClient"
```

### Task 1.8: `ProjectVersion` + `SentReleaseNotification` models + schema registration

**Files:**
- Create: `AppFeedback/Models/ProjectVersion.swift`
- Create: `AppFeedback/Models/SentReleaseNotification.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (register in CloudKit schema + both container `for:` lists)
- Test: `AppFeedbackTests/ProjectVersionStoreTests.swift` (added in 1.9; here just a model smoke test in `ModelsTests.swift`)

CloudKit rules (per `MailThread`): every stored property has a default; no uniqueness constraints; to-many relationships optional. These models have no relationships.

- [ ] **Step 1: Write the failing test**

Add to `AppFeedbackTests/ModelsTests.swift`:

```swift
func testProjectVersionDefaultsAndDerivedState() {
    let v = ProjectVersion(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "notes")
    XCTAssertFalse(v.releasePublished)
    XCTAssertNil(v.milestoneNumber)
    XCTAssertEqual(v.derivedState(anyTaskStarted: false), .new)
    XCTAssertEqual(v.derivedState(anyTaskStarted: true), .wip)
    v.releasePublished = true
    XCTAssertEqual(v.derivedState(anyTaskStarted: true), .released)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ModelsTests/testProjectVersionDefaultsAndDerivedState 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Models/ProjectVersion.swift`:

```swift
import Foundation
import SwiftData

enum VersionState: String, Sendable { case new, wip, released }

@Model
final class ProjectVersion {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var name: String = ""                 // e.g. "1.2.0" — milestone title / release name base
    var changelog: String = ""            // canonical "what's new"
    var milestoneNumber: Int? = nil       // GitHub milestone number once created
    var releaseTag: String? = nil         // git tag once a Release is published
    var releasePublished: Bool = false
    var releasedAt: Date? = nil
    var createdAt: Date = Date()
    /// Optional per-version override of where the Release publishes (the "connected code repo").
    var connectedRepoOwner: String? = nil
    var connectedRepoName: String? = nil

    init(id: UUID = UUID(), repoOwner: String, repoName: String, name: String,
         changelog: String = "", milestoneNumber: Int? = nil, releaseTag: String? = nil,
         releasePublished: Bool = false, releasedAt: Date? = nil, createdAt: Date = Date(),
         connectedRepoOwner: String? = nil, connectedRepoName: String? = nil) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.name = name
        self.changelog = changelog
        self.milestoneNumber = milestoneNumber
        self.releaseTag = releaseTag
        self.releasePublished = releasePublished
        self.releasedAt = releasedAt
        self.createdAt = createdAt
        self.connectedRepoOwner = connectedRepoOwner
        self.connectedRepoName = connectedRepoName
    }

    func derivedState(anyTaskStarted: Bool) -> VersionState {
        if releasePublished { return .released }
        return anyTaskStarted ? .wip : .new
    }
}
```

Create `AppFeedback/Models/SentReleaseNotification.swift`:

```swift
import Foundation
import SwiftData

@Model
final class SentReleaseNotification {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var versionName: String = ""
    var recipientEmail: String = ""
    var feedbackNumbers: [Int] = []
    var threadIssueNumber: Int = 0
    var sentAt: Date = Date()
    var statusRaw: String = "sent"        // "sent" | "failed"
    var errorDetail: String? = nil

    enum Status: String, Sendable { case sent, failed }
    var status: Status {
        get { Status(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), repoOwner: String, repoName: String, versionName: String,
         recipientEmail: String, feedbackNumbers: [Int], threadIssueNumber: Int,
         sentAt: Date = Date(), status: Status = .sent, errorDetail: String? = nil) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.versionName = versionName
        self.recipientEmail = recipientEmail
        self.feedbackNumbers = feedbackNumbers
        self.threadIssueNumber = threadIssueNumber
        self.sentAt = sentAt
        self.statusRaw = status.rawValue
        self.errorDetail = errorDetail
    }
}
```

In `AppFeedback/App/AppFeedbackApp.swift`:

(a) Add to the **CloudKit schema** (line 84) — append the two models:
```swift
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self])
```

(b) Add to the **production container** `for:` list (lines 93-98) — append after `IssueTranslation.self, IssueSummaryCache.self,`:
```swift
                        ProjectVersion.self, SentReleaseNotification.self,
```

(c) Add to the **test container** `for:` list (lines 75-80) — same insertion after `IssueTranslation.self, IssueSummaryCache.self,`:
```swift
                        ProjectVersion.self, SentReleaseNotification.self,
```

(Do **not** add them to `localSchema` — they are CloudKit-synced.)

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2, then a full build to confirm the container compiles:
`xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | grep -E "error:" | head`
Expected: model test PASS, no build errors.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/ProjectVersion.swift AppFeedback/Models/SentReleaseNotification.swift AppFeedback/App/AppFeedbackApp.swift AppFeedbackTests/ModelsTests.swift
git commit -m "feat(versions): add ProjectVersion + SentReleaseNotification models"
```

### Task 1.9: `VersionStore` + `SentNotificationStore` (@Observable @MainActor)

**Files:**
- Create: `AppFeedback/Services/VersionStore.swift`
- Test: `AppFeedbackTests/VersionStoreTests.swift`

Follows the `RepoStore` pattern (ModelContext + reload on didSave/remoteChange/cloudKitImport).

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/VersionStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class VersionStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ProjectVersion.self, SentReleaseNotification.self, configurations: config)
        return ModelContext(container)
    }

    func testAddAndFetchScopedToRepo() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "first")
        store.create(repoOwner: "o", repoName: "other", name: "9.9", changelog: "")
        let forRepo = store.versions(owner: "o", repo: "r")
        XCTAssertEqual(forRepo.map(\.name), ["1.0.0"])
        XCTAssertEqual(v.changelog, "first")
    }

    func testRecordSentNotification() throws {
        let store = VersionStore(context: try makeContext())
        store.recordSent(repoOwner: "o", repoName: "r", versionName: "1.0.0",
                         recipientEmail: "a@b.com", feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        let already = store.alreadyNotifiedEmails(owner: "o", repo: "r", versionName: "1.0.0")
        XCTAssertTrue(already.contains("a@b.com"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/VersionStoreTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/VersionStore.swift`:

```swift
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class VersionStore {
    private(set) var versionsAll: [ProjectVersion] = []
    private(set) var sentAll: [SentReleaseNotification] = []

    private let context: ModelContext
    private var didSaveTask: Task<Void, Never>?
    private var remoteChangeTask: Task<Void, Never>?
    private var cloudKitImportTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        reload()

        let ownContext = ObjectIdentifier(context)
        let didSaves = NotificationCenter.default.notifications(named: ModelContext.didSave)
            .compactMap { @Sendable note -> Bool? in
                let senderID = (note.object as? ModelContext).map(ObjectIdentifier.init)
                return senderID == ownContext ? nil : true
            }
        didSaveTask = Task { @MainActor [weak self] in
            for await _ in didSaves { self?.reload() }
        }
        remoteChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) { self?.reload() }
        }
        cloudKitImportTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.cloudKitImportSucceeded { self?.reload() }
        }
    }

    isolated deinit {
        didSaveTask?.cancel(); remoteChangeTask?.cancel(); cloudKitImportTask?.cancel()
    }

    // MARK: Queries

    func versions(owner: String, repo: String) -> [ProjectVersion] {
        versionsAll
            .filter { $0.repoOwner == owner && $0.repoName == repo }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func alreadyNotifiedEmails(owner: String, repo: String, versionName: String) -> Set<String> {
        Set(sentAll
            .filter { $0.repoOwner == owner && $0.repoName == repo && $0.versionName == versionName && $0.status == .sent }
            .map(\.recipientEmail))
    }

    func sentNotifications(owner: String, repo: String, versionName: String) -> [SentReleaseNotification] {
        sentAll
            .filter { $0.repoOwner == owner && $0.repoName == repo && $0.versionName == versionName }
            .sorted { $0.sentAt > $1.sentAt }
    }

    // MARK: Mutations

    @discardableResult
    func create(repoOwner: String, repoName: String, name: String, changelog: String) -> ProjectVersion {
        let v = ProjectVersion(repoOwner: repoOwner, repoName: repoName, name: name, changelog: changelog)
        context.insert(v); save(); reload(); return v
    }

    func save() { try? context.save() }   // call after mutating a ProjectVersion in place, then reload()
    func saveAndReload() { save(); reload() }

    func recordSent(repoOwner: String, repoName: String, versionName: String, recipientEmail: String,
                    feedbackNumbers: [Int], threadIssueNumber: Int, status: SentReleaseNotification.Status,
                    errorDetail: String? = nil) {
        let row = SentReleaseNotification(repoOwner: repoOwner, repoName: repoName, versionName: versionName,
            recipientEmail: recipientEmail, feedbackNumbers: feedbackNumbers, threadIssueNumber: threadIssueNumber,
            status: status, errorDetail: errorDetail)
        context.insert(row); save(); reload()
    }

    func delete(_ version: ProjectVersion) { context.delete(version); save(); reload() }

    // MARK: Internal

    private func reload() {
        versionsAll = (try? context.fetch(FetchDescriptor<ProjectVersion>())) ?? []
        sentAll = (try? context.fetch(FetchDescriptor<SentReleaseNotification>())) ?? []
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/VersionStore.swift AppFeedbackTests/VersionStoreTests.swift
git commit -m "feat(versions): add VersionStore (versions + sent notifications)"
```

### Task 1.10: `TaskService` + `VersionService` (online orchestration)

These @MainActor services resolve the token (`KeychainService.loadSync`) and drive the actors + stores. They are thin; the heavy logic/tests live in the actors. Unit-test the token-resolution + label-assembly helpers (pure), and smoke-test happy paths against `MockURLProtocol` by injecting clients built on `URLSession.mock`.

**Files:**
- Create: `AppFeedback/Services/TaskService.swift`
- Create: `AppFeedback/Services/VersionService.swift`
- Test: `AppFeedbackTests/TaskServiceTests.swift`

- [ ] **Step 1: Write the failing test (label assembly is pure + deterministic)**

Create `AppFeedbackTests/TaskServiceTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class TaskServiceTests: XCTestCase {
    func testLabelAssembly() {
        let labels = TaskService.labels(status: .inProgress, priority: .high)
        XCTAssertTrue(labels.contains(AppFeedbackLabels.task))
        XCTAssertTrue(labels.contains("status:in-progress"))
        XCTAssertTrue(labels.contains("priority:high"))
        XCTAssertEqual(labels.count, 3)
    }

    func testBodyWithRefs() {
        let body = TaskService.body(prose: "Fix it", feedbackRefs: [15, 12])
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [12, 15])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/TaskServiceTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/TaskService.swift`:

```swift
import Foundation

/// Orchestrates task-issue writes: resolves the GitHub token for a repo, ensures labels exist,
/// and delegates to `GitHubIssueWriter`. @MainActor because it reads `RepoConfig` from the UI layer.
@MainActor
final class TaskService {
    enum ServiceError: LocalizedError {
        case noToken
        var errorDescription: String? { "No GitHub token for this repo. Re-authenticate in Settings." }
    }

    private let writer: GitHubIssueWriter
    private let labelClient: GitHubMilestoneReleaseClient

    init(writer: GitHubIssueWriter = GitHubIssueWriter(),
         labelClient: GitHubMilestoneReleaseClient = GitHubMilestoneReleaseClient()) {
        self.writer = writer
        self.labelClient = labelClient
    }

    static func labels(status: TaskStatus, priority: TaskPriority) -> [String] {
        [AppFeedbackLabels.task, status.label, priority.label]
    }
    static func body(prose: String, feedbackRefs: [Int]) -> String {
        FeedbackTaskRefParser.upsert(into: prose, refs: feedbackRefs)
    }

    /// Creates a task issue. Returns its number. Requires online.
    func createTask(repo: RepoConfig, title: String, prose: String, feedbackRefs: [Int],
                    status: TaskStatus, priority: TaskPriority, milestoneNumber: Int?) async throws -> Int {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await ensureLabels(repo: repo, token: token)
        return try await writer.createIssue(
            owner: repo.owner, repo: repo.repo, title: title,
            body: Self.body(prose: prose, feedbackRefs: feedbackRefs),
            labels: Self.labels(status: status, priority: priority),
            milestoneNumber: milestoneNumber, token: token)
    }

    func setStatus(repo: RepoConfig, task: TaskItem, status: TaskStatus) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let labels = [AppFeedbackLabels.task, status.label, task.priority.label]
        // status:done also closes the issue; reopening on any other status.
        let state = (status == .done) ? "closed" : "open"
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            labels: labels, state: state, token: token)
    }

    func setPriority(repo: RepoConfig, task: TaskItem, priority: TaskPriority) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            labels: [AppFeedbackLabels.task, task.status.label, priority.label], token: token)
    }

    func setFeedbackRefs(repo: RepoConfig, task: TaskItem, refs: [Int]) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let newBody = FeedbackTaskRefParser.upsert(into: bodyWithoutBlock(task.body), refs: refs)
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number, body: newBody, token: token)
    }

    func assignVersion(repo: RepoConfig, task: TaskItem, milestoneNumber: Int?) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            milestoneNumber: .some(milestoneNumber), token: token)
    }

    private func bodyWithoutBlock(_ body: String) -> String {
        // upsert handles replacement; pass the raw body, upsert strips the old block first.
        body
    }

    private func ensureLabels(repo: RepoConfig, token: String) async throws {
        for label in AppFeedbackLabels.managed {
            try await labelClient.ensureLabel(owner: repo.owner, repo: repo.repo, name: label.name, color: label.color, token: token)
        }
    }
}
```

Create `AppFeedback/Services/VersionService.swift`:

```swift
import Foundation

/// Orchestrates version writes: creates the GitHub milestone (and optional draft release) for a
/// new `ProjectVersion`, edits the changelog, and performs the release (close milestone + publish
/// release). Keeps the local `ProjectVersion` in sync via `VersionStore`. Requires online.
@MainActor
final class VersionService {
    enum ServiceError: LocalizedError {
        case noToken
        case noCommitForRelease
        var errorDescription: String? {
            switch self {
            case .noToken: return "No GitHub token for this repo. Re-authenticate in Settings."
            case .noCommitForRelease: return "The target repo has no commit to tag. The version was released as a milestone only."
            }
        }
    }

    private let client: GitHubMilestoneReleaseClient
    private let store: VersionStore

    init(store: VersionStore, client: GitHubMilestoneReleaseClient = GitHubMilestoneReleaseClient()) {
        self.store = store
        self.client = client
    }

    /// Creates a milestone for `version` and stores its number. Call right after `store.create`.
    func provisionMilestone(repo: RepoConfig, version: ProjectVersion) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let ms = try await client.createMilestone(owner: repo.owner, repo: repo.repo,
            title: version.name, description: version.changelog, token: token)
        version.milestoneNumber = ms.number
        store.saveAndReload()
    }

    func updateChangelog(repo: RepoConfig, version: ProjectVersion, changelog: String) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        version.changelog = changelog
        store.saveAndReload()
        if let number = version.milestoneNumber {
            _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number,
                description: changelog, token: token)
        }
    }

    /// Closes the milestone and (best-effort) publishes a GitHub Release. Marks the local version
    /// released even if the Release step fails for lack of a commit (milestone-only release).
    /// Returns whether a Release object was created.
    @discardableResult
    func release(repo: RepoConfig, version: ProjectVersion, tag: String, target: String?, publishRelease: Bool, now: Date) async throws -> Bool {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        if let number = version.milestoneNumber {
            _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number, state: "closed", token: token)
        }
        var createdRelease = false
        if publishRelease {
            let owner = version.connectedRepoOwner ?? repo.owner
            let name = version.connectedRepoName ?? repo.repo
            do {
                _ = try await client.createRelease(owner: owner, repo: name, tag: tag, name: version.name,
                    body: version.changelog, draft: false, target: target, token: token)
                version.releaseTag = tag
                createdRelease = true
            } catch GitHubMilestoneReleaseClient.ClientError.apiError(422, _) {
                // No commit to tag → milestone-only release. Surfaced to the UI by the caller.
            }
        }
        version.releasePublished = true
        version.releasedAt = now
        store.saveAndReload()
        return createdRelease
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS (label/body assembly). Build to confirm services compile.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/TaskService.swift AppFeedback/Services/VersionService.swift AppFeedbackTests/TaskServiceTests.swift
git commit -m "feat(tasks,versions): add TaskService + VersionService orchestration"
```

---

# PHASE 2 — Inspector panel UI

### Task 2.1: `connectedRepo` fields on the project model

**Files:**
- Modify: `AppFeedback/Models/RepoConfig.swift`, `AppFeedback/Models/Repo.swift`, `AppFeedback/Services/RepoStore.swift`
- Test: `AppFeedbackTests/RepoStoreTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Add to `AppFeedbackTests/RepoStoreTests.swift` (match the existing in-memory context setup in that file):

```swift
func testConnectedRepoRoundTrips() throws {
    let store = makeStore()            // existing helper in this test file
    var cfg = RepoConfig(displayName: "P", owner: "o", repo: "r")
    cfg.connectedRepoOwner = "o2"; cfg.connectedRepoName = "code"
    store.add(cfg)
    let reloaded = store.repos.first { $0.owner == "o" }
    XCTAssertEqual(reloaded?.connectedRepoOwner, "o2")
    XCTAssertEqual(reloaded?.connectedRepoName, "code")
}
```

If `RepoStoreTests` has no `makeStore()` helper, instantiate `RepoStore(context:)` with an in-memory `ModelContainer(for: Repo.self, …)` as the other tests in the file do.

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/RepoStoreTests/testConnectedRepoRoundTrips 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

(a) `RepoConfig.swift` — add two properties + init params (with defaults, so existing call-sites compile):

```swift
    var connectedRepoOwner: String?
    var connectedRepoName: String?
```
Add to init signature (with `= nil` defaults) and assign in the body, mirroring `redactEmailAddresses`.

(b) `Repo.swift` — add stored properties with defaults:

```swift
    var connectedRepoOwner: String? = nil
    var connectedRepoName: String? = nil
```
Add matching init params (`= nil`) and assignments.

(c) `RepoStore.swift` — thread the fields through `add`, `update`, `remove` (the `RepoConfig(…)` reconstruction), and `reload`'s `RepoConfig(…)` mapping. In `add`:
```swift
        let model = Repo(
            id: repo.id, displayName: repo.displayName, owner: repo.owner, repo: repo.repo,
            mirrorEmailsToGitHub: repo.mirrorEmailsToGitHub, redactEmailAddresses: repo.redactEmailAddresses,
            connectedRepoOwner: repo.connectedRepoOwner, connectedRepoName: repo.connectedRepoName
        )
```
In `update`, set `model.connectedRepoOwner = repo.connectedRepoOwner` and `model.connectedRepoName = repo.connectedRepoName`. In `reload` and `remove`, add the two args to the `RepoConfig(…)` initializers.

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2, then full `RepoStoreTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/RepoConfig.swift AppFeedback/Models/Repo.swift AppFeedback/Services/RepoStore.swift AppFeedbackTests/RepoStoreTests.swift
git commit -m "feat(versions): add optional connected code repo to project config"
```

### Task 2.2: `ProjectInspectorModel` — selected-project tasks + versions

A small `@Observable @MainActor` view model the panel reads from. It exposes the current repo's `TaskItem`s (from the loader/viewModel) and `ProjectVersion`s (from `VersionStore`), and computes per-version `anyTaskStarted` for the derived state.

**Files:**
- Create: `AppFeedback/ViewModels/ProjectInspectorModel.swift`
- Test: `AppFeedbackTests/ProjectInspectorModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/ProjectInspectorModelTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class ProjectInspectorModelTests: XCTestCase {
    func testTasksForVersionAndStartedFlag() {
        let model = ProjectInspectorModel()
        let t1 = TaskItem(issue: FeedbackIssue(number: 1, title: "a", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x"), IssueLabel(name: "status:in-progress", colorHex: "x")],
            state: .open, milestoneTitle: "1.0.0"))
        let t2 = TaskItem(issue: FeedbackIssue(number: 2, title: "b", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")],
            state: .open, milestoneTitle: nil))
        model.setTasks([t1, t2])
        XCTAssertEqual(model.tasks(forVersionNamed: "1.0.0").map(\.number), [1])
        XCTAssertTrue(model.anyTaskStarted(versionNamed: "1.0.0"))
        XCTAssertFalse(model.anyTaskStarted(versionNamed: "2.0.0"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ProjectInspectorModelTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/ViewModels/ProjectInspectorModel.swift`:

```swift
import Foundation
import Observation

@Observable @MainActor
final class ProjectInspectorModel {
    private(set) var tasks: [TaskItem] = []
    var statusFilter: TaskStatus? = nil

    func setTasks(_ tasks: [TaskItem]) { self.tasks = tasks }

    var filteredTasks: [TaskItem] {
        guard let statusFilter else { return tasks }
        return tasks.filter { $0.status == statusFilter && !$0.isClosed || (statusFilter == .done && $0.isCompleted) }
    }

    func tasks(forVersionNamed name: String) -> [TaskItem] {
        tasks.filter { $0.milestoneTitle == name }
    }

    /// A version is "started" (→ wip) when any of its tasks is in progress or completed.
    func anyTaskStarted(versionNamed name: String) -> Bool {
        tasks(forVersionNamed: name).contains { $0.status == .inProgress || $0.isCompleted }
    }

    /// Completed feedback numbers for a version (drives recipient computation).
    func completedFeedbackNumbers(versionNamed name: String) -> [Int] {
        let refs = tasks(forVersionNamed: name).filter(\.isCompleted).flatMap(\.feedbackRefs)
        return Array(Set(refs)).sorted()
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/ViewModels/ProjectInspectorModel.swift AppFeedbackTests/ProjectInspectorModelTests.swift
git commit -m "feat(panel): add ProjectInspectorModel"
```

### Task 2.3: Inspector scaffold + toolbar toggle, wired in `RootView`

**Files:**
- Create: `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`
- Modify: `AppFeedback/App/RootView.swift` (own the panel state, inject stores, attach `.inspector`)
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (construct `VersionStore`, inject into `RootView`)

- [ ] **Step 1: Construct + inject `VersionStore`**

In `AppFeedbackApp.swift`, add a `@State private var versionStore: VersionStore` (near the other stores, line ~46), initialize it in `init()` next to the other stores:
```swift
        _versionStore = State(initialValue: VersionStore(context: ModelContext(container)))
```
Pass it into `RootView` wherever `RootView` is instantiated in `body` (add `versionStore: versionStore`).

- [ ] **Step 2: Add the panel scaffold**

Create `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`:

```swift
import SwiftUI

struct ProjectInspectorPanel: View {
    let repo: RepoConfig?
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        Group {
            if let repo {
                List {
                    Section("Tasks") {
                        TasksSectionView(repo: repo, inspector: inspector)
                    }
                    Section("Versions") {
                        VersionsSectionView(
                            repo: repo, inspector: inspector, versionStore: versionStore,
                            onCreateVersion: onCreateVersion, onOpenVersion: onOpenVersion)
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #else
                .listStyle(.insetGrouped)
                #endif
            } else {
                ContentUnavailableView("No project selected", systemImage: "sidebar.right")
            }
        }
        .navigationTitle("Tasks & Versions")
    }
}
```

(Stub `TasksSectionView`/`VersionsSectionView` minimally here so it compiles; they are fleshed out in 2.4/2.6. Add temporary stubs returning `Text("…")` if executing strictly task-by-task.)

- [ ] **Step 3: Attach `.inspector` in `RootView`**

In `RootView`, add state:
```swift
    @State private var showInspector = true
    @State private var inspector = ProjectInspectorModel()
    @State private var versionToOpen: ProjectVersion?
    @State private var showCreateVersion = false
    var versionStore: VersionStore     // injected (add to the stored properties + the call site)
```
Attach the inspector to the `detail:` content. Wrap the `IssueListView` (inside `if let summaryVM`) — add after its modifiers (after the `#if os(iOS)` title block, before the `else`):
```swift
                    .inspector(isPresented: $showInspector) {
                        ProjectInspectorPanel(
                            repo: store.repos.first(where: { $0.id == selection.repoId }),
                            inspector: inspector,
                            versionStore: versionStore,
                            onCreateVersion: { showCreateVersion = true },
                            onOpenVersion: { versionToOpen = $0 }
                        )
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                    }
```
Add a toolbar toggle on the detail (inside the existing `detail:` toolbar, or add one). Add to RootView's outer `.toolbar` (create one on the NavigationSplitView if needed):
```swift
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .help("Toggle Tasks & Versions")
            }
        }
```
Feed tasks into the inspector model — in `updateViewModel(for:)` (after `viewModel.applyLoaded(issues)`), add:
```swift
        inspector.setTasks(viewModel.tasks)
```
and also in the `selectedLoadedSignature` onChange path (it already calls `updateViewModel`).

- [ ] **Step 4: Build both platforms**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && \
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | grep -E "error:" | head
xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS' 2>&1 | grep -E "error:" | head
```
Expected: no errors. (`.inspector` is available on iOS 17 / macOS 14 — deployment targets are 17.0/15.0, OK.)

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Inspector/ProjectInspectorPanel.swift AppFeedback/App/RootView.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(panel): add collapsible inspector scaffold + toolbar toggle"
```

### Task 2.4: Tasks section — list, status/priority controls

**Files:**
- Create: `AppFeedback/Views/Inspector/TasksSectionView.swift` (replace stub)
- Test: smoke test `AppFeedbackTests/TasksSectionSmokeTests.swift` (mirror `AttachmentStripViewSmokeTests`)

- [ ] **Step 1: Write a smoke test**

Create `AppFeedbackTests/TasksSectionSmokeTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import AppFeedback

@MainActor
final class TasksSectionSmokeTests: XCTestCase {
    func testRendersWithoutCrash() {
        let inspector = ProjectInspectorModel()
        inspector.setTasks([TaskItem(issue: FeedbackIssue(number: 1, title: "t", createdAt: Date(),
            rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")]))])
        let view = TasksSectionView(repo: RepoConfig(displayName: "P", owner: "o", repo: "r"), inspector: inspector)
        _ = view.body   // force view-tree construction
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/TasksSectionSmokeTests 2>&1 | tail -20`
Expected: FAIL (real `TasksSectionView` not implemented / stub has different init).

- [ ] **Step 3: Implement**

Create/replace `AppFeedback/Views/Inspector/TasksSectionView.swift`:

```swift
import SwiftUI

struct TasksSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    @State private var working = false
    @State private var errorMessage: String?
    private let service = TaskService()

    var body: some View {
        if inspector.filteredTasks.isEmpty {
            Text("No tasks yet. Select feedbacks and choose “Create Task.”")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(inspector.filteredTasks) { task in
                TaskRow(task: task,
                        onStatus: { newStatus in update { try await service.setStatus(repo: repo, task: task, status: newStatus) } },
                        onPriority: { newPriority in update { try await service.setPriority(repo: repo, task: task, priority: newPriority) } })
            }
        }
        if let errorMessage {
            Text(errorMessage).font(.footnote).foregroundStyle(.red)
        }
    }

    private func update(_ work: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; errorMessage = nil
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
            working = false
            // The next GitHub refresh re-derives tasks; optionally trigger a refresh here.
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    var onStatus: (TaskStatus) -> Void
    var onPriority: (TaskPriority) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(task.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(task.title).font(.callout).lineLimit(2)
            }
            HStack(spacing: 8) {
                Menu(task.status.displayName) {
                    ForEach(TaskStatus.allCases, id: \.self) { s in Button(s.displayName) { onStatus(s) } }
                }.font(.caption)
                Menu(task.priority.displayName) {
                    ForEach(TaskPriority.allCases, id: \.self) { p in Button(p.displayName) { onPriority(p) } }
                }.font(.caption)
                if !task.feedbackRefs.isEmpty {
                    Text(task.feedbackRefs.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Inspector/TasksSectionView.swift AppFeedbackTests/TasksSectionSmokeTests.swift
git commit -m "feat(panel): tasks section with status/priority controls"
```

### Task 2.5: Multi-select feedbacks + “Create Task” sheet

**Files:**
- Create: `AppFeedback/Views/Inspector/CreateTaskSheet.swift`
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift` (selection set)
- Modify: `AppFeedback/Views/Issues/IssueListView.swift` (selection toggles on cards + toolbar action)
- Modify: `AppFeedback/App/RootView.swift` (present the sheet)

- [ ] **Step 1: Add selection state to the view model (+ test)**

Add to `IssueListViewModel`:
```swift
    var selectedFeedbackNumbers: Set<Int> = []
    var isSelecting: Bool = false
    func toggleSelection(_ number: Int) {
        if selectedFeedbackNumbers.contains(number) { selectedFeedbackNumbers.remove(number) }
        else { selectedFeedbackNumbers.insert(number) }
    }
    func clearSelection() { selectedFeedbackNumbers = []; isSelecting = false }
```
Add to `AppFeedbackTests/IssueListViewModelTests.swift`:
```swift
func testToggleSelection() {
    let vm = IssueListViewModel()
    vm.toggleSelection(5); vm.toggleSelection(7); vm.toggleSelection(5)
    XCTAssertEqual(vm.selectedFeedbackNumbers, [7])
}
```

- [ ] **Step 2: Run to verify it fails, then passes**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/IssueListViewModelTests/testToggleSelection 2>&1 | tail -20`
First FAIL, then implement the model code above and re-run → PASS.

- [ ] **Step 3: Implement the sheet + list wiring**

Create `AppFeedback/Views/Inspector/CreateTaskSheet.swift`:

```swift
import SwiftUI

struct CreateTaskSheet: View {
    let repo: RepoConfig
    let feedbackNumbers: [Int]
    let versions: [ProjectVersion]
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prose = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .med
    @State private var selectedVersionID: UUID?
    @State private var working = false
    @State private var errorMessage: String?
    private let service = TaskService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                    TextField("Notes", text: $prose, axis: .vertical).lineLimit(3...8)
                }
                Section("Metadata") {
                    Picker("Status", selection: $status) { ForEach(TaskStatus.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    Picker("Priority", selection: $priority) { ForEach(TaskPriority.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    Picker("Version", selection: $selectedVersionID) {
                        Text("None").tag(UUID?.none)
                        ForEach(versions) { v in Text(v.name).tag(Optional(v.id)) }
                    }
                }
                Section("Addresses feedback") {
                    Text(feedbackNumbers.map { "#\($0)" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(title.isEmpty || working)
                }
            }
        }
    }

    private func create() {
        working = true; errorMessage = nil
        let milestone = versions.first { $0.id == selectedVersionID }?.milestoneNumber
        Task {
            do {
                _ = try await service.createTask(repo: repo, title: title, prose: prose,
                    feedbackRefs: feedbackNumbers, status: status, priority: priority, milestoneNumber: milestone)
                onCreated(); dismiss()
            } catch { errorMessage = error.localizedDescription; working = false }
        }
    }
}
```

In `IssueListView`: add a multi-select toolbar button (works on both platforms — move the existing macOS-only `.toolbar` to cross-platform or add a second `ToolbarItem`). Add to the toolbar:
```swift
                ToolbarItem(placement: .primaryAction) {
                    if viewModel.isSelecting {
                        Button("Create Task (\(viewModel.selectedFeedbackNumbers.count))") {
                            viewModel.requestCreateTask = true       // RootView observes this
                        }
                        .disabled(viewModel.selectedFeedbackNumbers.isEmpty)
                    } else {
                        Button("Select") { viewModel.isSelecting = true }
                    }
                }
```
Add `var requestCreateTask = false` to `IssueListViewModel`. In `issueCard(for:)` add a leading selection toggle when `viewModel.isSelecting` (a `Button`/`Image(systemName: selected ? "checkmark.circle.fill" : "circle")` that calls `viewModel.toggleSelection(issue.number)`).

In `RootView`, present the sheet:
```swift
        .onChange(of: viewModel.requestCreateTask) { _, want in
            guard want else { return }
            viewModel.requestCreateTask = false
            showCreateTask = true
        }
        .sheet(isPresented: $showCreateTask) {
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                CreateTaskSheet(repo: repo,
                    feedbackNumbers: Array(viewModel.selectedFeedbackNumbers).sorted(),
                    versions: versionStore.versions(owner: repo.owner, repo: repo.repo),
                    onCreated: {
                        viewModel.clearSelection()
                        Task { await refreshSelectedRepo() }   // re-fetch so the new task appears
                    })
            }
        }
```
Add `@State private var showCreateTask = false` and a `refreshSelectedRepo()` helper that reuses the existing `onRefresh` logic (load token + `loaders[repoId]?.load(token:)`).

- [ ] **Step 4: Build both platforms**

Run the two `xcodebuild build` commands from Task 2.3 Step 4. Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Inspector/CreateTaskSheet.swift AppFeedback/ViewModels/IssueListViewModel.swift AppFeedback/Views/Issues/IssueListView.swift AppFeedback/App/RootView.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat(panel): multi-select feedbacks + Create Task sheet"
```

### Task 2.6: Versions section + New Version sheet + changelog

**Files:**
- Create: `AppFeedback/Views/Inspector/VersionsSectionView.swift` (replace stub)
- Create: `AppFeedback/Views/Inspector/NewVersionSheet.swift`
- Modify: `AppFeedback/App/RootView.swift` (present New Version sheet)

- [ ] **Step 1: Implement VersionsSectionView**

Create/replace `AppFeedback/Views/Inspector/VersionsSectionView.swift`:

```swift
import SwiftUI

struct VersionsSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        Button { onCreateVersion() } label: { Label("New Version", systemImage: "plus") }
        ForEach(versionStore.versions(owner: repo.owner, repo: repo.repo)) { version in
            Button { onOpenVersion(version) } label: {
                VersionRow(version: version,
                           state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                           taskCount: inspector.tasks(forVersionNamed: version.name).count)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct VersionRow: View {
    let version: ProjectVersion
    let state: VersionState
    let taskCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.name).font(.callout.weight(.medium))
                Text("\(taskCount) task\(taskCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(badgeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(badgeColor)
        }
    }
    private var badge: String { switch state { case .new: "NEW"; case .wip: "WIP"; case .released: "RELEASED" } }
    private var badgeColor: Color { switch state { case .new: .secondary; case .wip: .orange; case .released: .green } }
}
```

Create `AppFeedback/Views/Inspector/NewVersionSheet.swift`:

```swift
import SwiftUI

struct NewVersionSheet: View {
    let repo: RepoConfig
    var versionStore: VersionStore
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var changelog = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Version") { TextField("Name (e.g. 1.2.0)", text: $name) }
                Section("What's new") { TextField("Changelog", text: $changelog, axis: .vertical).lineLimit(4...12) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New Version")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(name.isEmpty || working)
                }
            }
        }
    }

    private func create() {
        working = true; errorMessage = nil
        let version = versionStore.create(repoOwner: repo.owner, repoName: repo.repo, name: name, changelog: changelog)
        let service = VersionService(store: versionStore)
        Task {
            do { try await service.provisionMilestone(repo: repo, version: version); onCreated(); dismiss() }
            catch {
                // Milestone creation failed → roll back the local row to avoid an orphan.
                versionStore.delete(version)
                errorMessage = error.localizedDescription; working = false
            }
        }
    }
}
```

In `RootView`, present it:
```swift
        .sheet(isPresented: $showCreateVersion) {
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                NewVersionSheet(repo: repo, versionStore: versionStore, onCreated: {})
            }
        }
```

- [ ] **Step 2: Build both platforms** (commands from 2.3 Step 4). Expected: no errors.

- [ ] **Step 3: Smoke test the rows**

Add `AppFeedbackTests/VersionsSectionSmokeTests.swift` mirroring 2.4's smoke test (construct `VersionsSectionView` with an in-memory `VersionStore` and force `.body`). Run it; expect PASS.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Inspector/VersionsSectionView.swift AppFeedback/Views/Inspector/NewVersionSheet.swift AppFeedback/App/RootView.swift AppFeedbackTests/VersionsSectionSmokeTests.swift
git commit -m "feat(panel): versions section + New Version sheet (milestone + draft)"
```

### Task 2.7: Version detail (tasks, changelog editor, Release button, sent-replies list)

**Files:**
- Create: `AppFeedback/Views/Inspector/VersionDetailView.swift`
- Modify: `AppFeedback/App/RootView.swift` (present via `versionToOpen` sheet/navigation)

- [ ] **Step 1: Implement the detail view (Release wired in Phase 3, Task 3.4)**

Create `AppFeedback/Views/Inspector/VersionDetailView.swift`:

```swift
import SwiftUI

struct VersionDetailView: View {
    let repo: RepoConfig
    @Bindable var version: ProjectVersion
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onRelease: () -> Void                 // opens the recipients sheet (Phase 3)

    @State private var changelog: String = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("What's new") {
                TextField("Changelog", text: $changelog, axis: .vertical).lineLimit(4...16)
                Button("Save changelog") { saveChangelog() }.disabled(working)
            }
            Section("Tasks in this version") {
                let tasks = inspector.tasks(forVersionNamed: version.name)
                if tasks.isEmpty { Text("No tasks assigned.").foregroundStyle(.secondary) }
                ForEach(tasks) { t in
                    HStack {
                        Image(systemName: t.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(t.isCompleted ? .green : .secondary)
                        Text("#\(t.number) \(t.title)").lineLimit(1)
                    }
                }
            }
            Section {
                if version.releasePublished {
                    Label("Released\(version.releasedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")",
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button { onRelease() } label: { Label("Release…", systemImage: "paperplane.fill") }
                        .disabled(working)
                }
            }
            Section("Sent release emails") {
                let sent = versionStore.sentNotifications(owner: repo.owner, repo: repo.repo, versionName: version.name)
                if sent.isEmpty { Text("None sent yet.").foregroundStyle(.secondary) }
                ForEach(sent) { row in
                    HStack {
                        Image(systemName: row.status == .sent ? "envelope.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(row.status == .sent ? .secondary : .red)
                        VStack(alignment: .leading) {
                            Text(row.recipientEmail).font(.callout)
                            Text(row.feedbackNumbers.map { "#\($0)" }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.sentAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle(version.name)
        .onAppear { changelog = version.changelog }
    }

    private func saveChangelog() {
        working = true; errorMessage = nil
        let service = VersionService(store: versionStore)
        Task {
            do { try await service.updateChangelog(repo: repo, version: version, changelog: changelog) }
            catch { errorMessage = error.localizedDescription }
            working = false
        }
    }
}
```

In `RootView`, present it (sheet driven by `versionToOpen`):
```swift
        .sheet(item: $versionToOpen) { version in
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                NavigationStack {
                    VersionDetailView(repo: repo, version: version, inspector: inspector,
                        versionStore: versionStore, onRelease: { versionToRelease = version })
                }
            }
        }
```
(`ProjectVersion` must be `Identifiable` for `.sheet(item:)` — it has `id: UUID`; add `Identifiable` conformance to the `@Model` declaration: `final class ProjectVersion: Identifiable` is implicit via `id`, but add explicit `: Identifiable` to be safe.) Add `@State private var versionToRelease: ProjectVersion?` (used in Phase 3).

- [ ] **Step 2: Build both platforms.** Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Inspector/VersionDetailView.swift AppFeedback/App/RootView.swift AppFeedback/Models/ProjectVersion.swift
git commit -m "feat(panel): version detail with changelog, tasks, sent-emails list"
```

---

# PHASE 3 — Release flow + email notifications

### Task 3.1: Recipient computation (completed tasks → feedbacks → emails, deduped)

**Files:**
- Create: `AppFeedback/Services/ReleaseRecipientCalculator.swift`
- Test: `AppFeedbackTests/ReleaseRecipientCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/ReleaseRecipientCalculatorTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class ReleaseRecipientCalculatorTests: XCTestCase {
    private func fb(_ n: Int, _ email: String?) -> FeedbackIssue {
        FeedbackIssue(number: n, title: "f\(n)", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: email,
            description: "", labels: [])
    }
    private func task(_ n: Int, refs: [Int], completed: Bool, version: String) -> TaskItem {
        let labels = [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")]
        let body = FeedbackTaskRefParser.upsert(into: "", refs: refs)
        return TaskItem(issue: FeedbackIssue(number: n, title: "t\(n)", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: labels, state: completed ? .closed : .open, milestoneTitle: version))
    }

    func testDedupesByEmailAndOnlyCompletedTasks() {
        let tasks = [
            task(100, refs: [1, 2], completed: true, version: "1.2"),
            task(101, refs: [3],    completed: false, version: "1.2"),   // not completed → excluded
            task(102, refs: [2],    completed: true, version: "1.2"),
        ]
        let feedback = [fb(1, "alice@x.com"), fb(2, "alice@x.com"), fb(3, "bob@x.com"), fb(99, nil)]
        let recipients = ReleaseRecipientCalculator.recipients(versionNamed: "1.2", tasks: tasks, feedback: feedback)
        XCTAssertEqual(recipients.count, 1)                          // only alice; bob's task incomplete
        XCTAssertEqual(recipients.first?.email, "alice@x.com")
        XCTAssertEqual(recipients.first?.feedbackNumbers, [1, 2])    // deduped + sorted across her tasks
    }

    func testHidesFeedbackWithoutEmail() {
        let tasks = [task(100, refs: [99], completed: true, version: "1.2")]
        let recipients = ReleaseRecipientCalculator.recipients(versionNamed: "1.2", tasks: tasks, feedback: [fb(99, nil)])
        XCTAssertTrue(recipients.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ReleaseRecipientCalculatorTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/ReleaseRecipientCalculator.swift`:

```swift
import Foundation

struct ReleaseRecipient: Identifiable, Sendable, Hashable {
    let email: String
    let feedbackNumbers: [Int]    // this person's addressed feedbacks in the version, deduped+sorted
    var id: String { email }
}

enum ReleaseRecipientCalculator {
    /// Recipients = end-users whose feedback is addressed by a *completed* task in the version.
    /// Deduped by email; feedbacks without an email are dropped. Each recipient lists all of
    /// their addressed feedbacks across the version's completed tasks.
    static func recipients(versionNamed name: String, tasks: [TaskItem], feedback: [FeedbackIssue]) -> [ReleaseRecipient] {
        let emailByNumber: [Int: String] = feedback.reduce(into: [:]) { acc, f in
            if let e = f.email, !e.isEmpty { acc[f.number] = e }
        }
        let completedRefs = tasks
            .filter { $0.milestoneTitle == name && $0.isCompleted }
            .flatMap(\.feedbackRefs)

        var numbersByEmail: [String: Set<Int>] = [:]
        for number in completedRefs {
            guard let email = emailByNumber[number] else { continue }
            numbersByEmail[email, default: []].insert(number)
        }
        return numbersByEmail
            .map { ReleaseRecipient(email: $0.key, feedbackNumbers: $0.value.sorted()) }
            .sorted { $0.email < $1.email }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/ReleaseRecipientCalculator.swift AppFeedbackTests/ReleaseRecipientCalculatorTests.swift
git commit -m "feat(release): recipient computation (completed tasks, deduped)"
```

### Task 3.2: Email template model + per-recipient rendering

**Files:**
- Create: `AppFeedback/Services/ReleaseEmailTemplate.swift`
- Test: `AppFeedbackTests/ReleaseEmailTemplateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/ReleaseEmailTemplateTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class ReleaseEmailTemplateTests: XCTestCase {
    func testRendersPlaceholders() {
        let t = ReleaseEmailTemplate(
            subject: "{appName} {version} is out",
            body: "Hi! {whatsNew}\n\nYour reports: {theirFeedbacks}")
        let r = t.render(appName: "Feedbeek", version: "1.2.0", whatsNew: "Bug fixes",
                         feedbackNumbers: [12, 15])
        XCTAssertEqual(r.subject, "Feedbeek 1.2.0 is out")
        XCTAssertTrue(r.body.contains("Bug fixes"))
        XCTAssertTrue(r.body.contains("#12, #15"))
    }

    func testDefaultTemplateMentionsVersion() {
        let t = ReleaseEmailTemplate.default(appName: "Feedbeek", version: "1.2.0", whatsNew: "Notes")
        let r = t.render(appName: "Feedbeek", version: "1.2.0", whatsNew: "Notes", feedbackNumbers: [3])
        XCTAssertTrue(r.subject.contains("1.2.0"))
        XCTAssertFalse(r.body.contains("{"))   // no stray placeholders
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ReleaseEmailTemplateTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/ReleaseEmailTemplate.swift`:

```swift
import Foundation

/// An editable subject/body template with `{placeholder}` tokens, rendered per recipient.
struct ReleaseEmailTemplate: Sendable {
    var subject: String
    var body: String

    struct Rendered: Sendable { let subject: String; let body: String }

    func render(appName: String, version: String, whatsNew: String, feedbackNumbers: [Int]) -> Rendered {
        let theirFeedbacks = feedbackNumbers.map { "#\($0)" }.joined(separator: ", ")
        func fill(_ s: String) -> String {
            s.replacingOccurrences(of: "{appName}", with: appName)
             .replacingOccurrences(of: "{version}", with: version)
             .replacingOccurrences(of: "{whatsNew}", with: whatsNew)
             .replacingOccurrences(of: "{theirFeedbacks}", with: theirFeedbacks)
        }
        return Rendered(subject: fill(subject), body: fill(body))
    }

    static func `default`(appName: String, version: String, whatsNew: String) -> ReleaseEmailTemplate {
        ReleaseEmailTemplate(
            subject: "{appName} {version} is out",
            body: """
            Hi,

            {appName} {version} is now available. Here's what's new:

            {whatsNew}

            This update addresses your feedback: {theirFeedbacks}

            Thanks for helping improve {appName}!
            """)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/ReleaseEmailTemplate.swift AppFeedbackTests/ReleaseEmailTemplateTests.swift
git commit -m "feat(release): editable email template + rendering"
```

### Task 3.3: `ReleaseNotificationService` — send per recipient via the existing mail path

Reuses `ComposeMailViewModel` per recipient: it already does `recordOutbound` → SMTP send → GitHub mirror → failure tracking. We pick the recipient's most-recently-active thread for the addressed feedback (or the lowest feedback number if no thread exists yet), set subject/body from the rendered template, and call `send()`. Then record a `SentReleaseNotification`.

**Files:**
- Create: `AppFeedback/Services/ReleaseNotificationService.swift`
- Test: `AppFeedbackTests/ReleaseNotificationServiceTests.swift` (tests the pure pieces: thread selection + which feedback is chosen)

- [ ] **Step 1: Write the failing test (thread/feedback selection is pure)**

Create `AppFeedbackTests/ReleaseNotificationServiceTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class ReleaseNotificationServiceTests: XCTestCase {
    func testChoosesMostRecentThreadFeedback() {
        // Two candidate feedbacks; #15 has the more recent thread → chosen.
        let threads: [Int: Date] = [12: Date(timeIntervalSince1970: 100), 15: Date(timeIntervalSince1970: 200)]
        let chosen = ReleaseNotificationService.chooseFeedbackNumber(
            candidates: [12, 15], lastActivityByFeedback: threads)
        XCTAssertEqual(chosen, 15)
    }

    func testFallsBackToLowestWhenNoThreads() {
        let chosen = ReleaseNotificationService.chooseFeedbackNumber(candidates: [20, 12, 15], lastActivityByFeedback: [:])
        XCTAssertEqual(chosen, 12)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests/ReleaseNotificationServiceTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/ReleaseNotificationService.swift`:

```swift
import Foundation

/// Sends release-notification emails for a version's selected recipients, one message per person
/// into one of their feedback threads, and records each send in `VersionStore`. Reuses the existing
/// `ComposeMailViewModel` send path (SMTP + GitHub mirror + failure tracking).
@MainActor
final class ReleaseNotificationService {
    struct Dependencies {
        let accountStore: MailAccountStore
        let settingsStore: MailSettingsStore
        let threadStore: MailThreadStore
        let outboundTracker: OutboundSendTracker
        let outboundFailures: OutboundFailureStore
        let sender: any MailSending
        let activityLog: ActivityLog
        let mirror: MailToGitHubMirror?
        let passwordLoader: @Sendable (UUID) async -> String?
    }

    private let versionStore: VersionStore
    private let deps: Dependencies
    init(versionStore: VersionStore, deps: Dependencies) { self.versionStore = versionStore; self.deps = deps }

    var hasSendingAccount: Bool { deps.accountStore.defaultSender != nil }

    /// Pure helper: pick the feedback whose thread is most recently active, else the lowest number.
    static func chooseFeedbackNumber(candidates: [Int], lastActivityByFeedback: [Int: Date]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if let best = candidates
            .compactMap({ n in lastActivityByFeedback[n].map { (n, $0) } })
            .max(by: { $0.1 < $1.1 }) { return best.0 }
        return candidates.min()
    }

    /// Sends to each selected recipient sequentially; isolated failures are recorded, not fatal.
    /// `onProgress` reports (completed, total) for the UI.
    func send(repo: RepoConfig, version: ProjectVersion, recipients: [ReleaseRecipient],
              feedback: [FeedbackIssue], template: ReleaseEmailTemplate, appName: String,
              onProgress: @escaping (Int, Int) -> Void) async {
        guard let account = deps.accountStore.defaultSender else { return }
        let feedbackByNumber = Dictionary(uniqueKeysWithValues: feedback.map { ($0.number, $0) })

        var done = 0
        for recipient in recipients {
            defer { done += 1; onProgress(done, recipients.count) }

            // Choose the thread/feedback to reply into.
            let lastActivity = recipient.feedbackNumbers.reduce(into: [Int: Date]()) { acc, n in
                let threads = deps.threadStore.threads(forIssue:
                    (owner: repo.owner, repo: repo.repo, number: n, title: feedbackByNumber[n]?.title ?? ""))
                if let latest = threads.map(\.lastMessageAt).max() { acc[n] = latest }
            }
            guard let chosen = Self.chooseFeedbackNumber(candidates: recipient.feedbackNumbers, lastActivityByFeedback: lastActivity),
                  let chosenFeedback = feedbackByNumber[chosen] else {
                versionStore.recordSent(repoOwner: repo.owner, repoName: repo.repo, versionName: version.name,
                    recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                    threadIssueNumber: 0, status: .failed, errorDetail: "No feedback to thread into")
                continue
            }

            let rendered = template.render(appName: appName, version: version.name,
                whatsNew: version.changelog, feedbackNumbers: recipient.feedbackNumbers)

            // Reuse the proven send path. inReplyTo derived from the chosen thread's last message, if any.
            let inReplyTo = latestHeaders(repo: repo, feedbackNumber: chosen, title: chosenFeedback.title)
            let vm = ComposeMailViewModel(
                recipient: recipient.email, issue: chosenFeedback,
                repoOwner: repo.owner, repoName: repo.repo,
                senderAccountID: account.id, inReplyTo: inReplyTo,
                store: deps.accountStore, settingsStore: deps.settingsStore, threadStore: deps.threadStore,
                tracker: deps.outboundTracker, failureStore: deps.outboundFailures, sender: deps.sender,
                activityLog: deps.activityLog, mirror: deps.mirror, passwordLoader: deps.passwordLoader)
            vm.subject = rendered.subject
            vm.body = NSAttributedString(string: rendered.body)
            await vm.send()

            versionStore.recordSent(repoOwner: repo.owner, repoName: repo.repo, versionName: version.name,
                recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                threadIssueNumber: chosen, status: .sent)
        }
    }

    private func latestHeaders(repo: RepoConfig, feedbackNumber: Int, title: String) -> MailMessageHeaders? {
        let threads = deps.threadStore.threads(forIssue: (owner: repo.owner, repo: repo.repo, number: feedbackNumber, title: title))
        guard let thread = threads.max(by: { $0.lastMessageAt < $1.lastMessageAt }),
              let last = thread.sortedDedupedMessages.last else { return nil }
        return MailMessageHeaders(messageID: last.messageID, references: [])   // adapt to the real MailMessageHeaders initializer
    }
}
```

> **Implementation note for the engineer:** verify the exact initializer of `ComposeMailViewModel` (parameter order/labels) in `AppFeedback/ViewModels/ComposeMailViewModel.swift` and of `MailMessageHeaders`; adjust the two call sites above to match. The `send()` method, `subject`, and `body` properties are confirmed to exist. If constructing `ComposeMailViewModel` directly proves awkward, extract its body into a `MailReplySender` helper and call that from both `ComposeMailViewModel.send()` and here — keep behavior identical and re-run `ComposeMailViewModelTests`.

- [ ] **Step 4: Run to verify it passes**

Run: same as Step 2 (the pure `chooseFeedbackNumber` tests). Then build both platforms. Expected: PASS + no build errors.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/ReleaseNotificationService.swift AppFeedbackTests/ReleaseNotificationServiceTests.swift
git commit -m "feat(release): ReleaseNotificationService (send + record)"
```

### Task 3.4: Recipients sheet (checklist, select-all, already-sent, template editor) + Release wiring

**Files:**
- Create: `AppFeedback/Views/Inspector/ReleaseRecipientsSheet.swift`
- Modify: `AppFeedback/App/RootView.swift` (present via `versionToRelease`; inject mail deps)
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (pass mail stores/sender to RootView if not already in scope)

- [ ] **Step 1: Implement the sheet**

Create `AppFeedback/Views/Inspector/ReleaseRecipientsSheet.swift`:

```swift
import SwiftUI

struct ReleaseRecipientsSheet: View {
    let repo: RepoConfig
    @Bindable var version: ProjectVersion
    let recipients: [ReleaseRecipient]
    let alreadySent: Set<String>
    let appName: String
    var makeService: () -> ReleaseNotificationService
    var feedback: [FeedbackIssue]
    var onPublish: () async -> Void           // closes milestone + publishes release (VersionService.release)

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var template: ReleaseEmailTemplate = .init(subject: "", body: "")
    @State private var progress: (Int, Int)? = nil
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What's new") {
                    TextField("Subject", text: $template.subject)
                    TextField("Body", text: $template.body, axis: .vertical).lineLimit(6...18)
                    Text("Placeholders: {appName} {version} {whatsNew} {theirFeedbacks}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Select all") { selected = Set(recipients.map(\.email)) }
                        Button("Deselect all") { selected = [] }
                    }
                    ForEach(recipients) { r in
                        Toggle(isOn: Binding(
                            get: { selected.contains(r.email) },
                            set: { on in if on { selected.insert(r.email) } else { selected.remove(r.email) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(r.email)
                                Text(r.feedbackNumbers.map { "#\($0)" }.joined(separator: " "))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if alreadySent.contains(r.email) {
                                    Text("Already emailed").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: { Text("Recipients (\(selected.count) selected)") }
                if let progress { Section { ProgressView(value: Double(progress.0), total: Double(progress.1)) {
                    Text("Sending \(progress.0)/\(progress.1)") } } }
            }
            .navigationTitle("Release \(version.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send & Release") { run() }.disabled(sending)
                }
            }
            .onAppear {
                template = .default(appName: appName, version: version.name, whatsNew: version.changelog)
                // Pre-check all except already-sent.
                selected = Set(recipients.map(\.email)).subtracting(alreadySent)
            }
        }
    }

    private func run() {
        sending = true
        let chosen = recipients.filter { selected.contains($0.email) }
        let service = makeService()
        Task {
            await service.send(repo: repo, version: version, recipients: chosen, feedback: feedback,
                template: template, appName: appName, onProgress: { progress = ($0, $1) })
            await onPublish()
            sending = false
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Wire the Release action in `RootView`**

Add `@State private var versionToRelease: ProjectVersion?` (if not added in 2.7). Present:
```swift
        .sheet(item: $versionToRelease) { version in
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                let recipients = ReleaseRecipientCalculator.recipients(
                    versionNamed: version.name, tasks: viewModel.tasks, feedback: viewModel.allIssues)
                ReleaseRecipientsSheet(
                    repo: repo, version: version, recipients: recipients,
                    alreadySent: versionStore.alreadyNotifiedEmails(owner: repo.owner, repo: repo.repo, versionName: version.name),
                    appName: repo.displayName,
                    makeService: { ReleaseNotificationService(versionStore: versionStore, deps: releaseDeps()) },
                    feedback: viewModel.allIssues,
                    onPublish: {
                        let service = VersionService(store: versionStore)
                        let tag = version.releaseTag ?? "v\(version.name)"
                        _ = try? await service.release(repo: repo, version: version, tag: tag, target: nil,
                            publishRelease: true, now: Date())
                    })
            }
        }
```
Add a `releaseDeps()` helper on `RootView` that builds `ReleaseNotificationService.Dependencies` from the environment-injected mail stores/sender/mirror (these already exist in `AppFeedbackApp` — inject the needed ones into `RootView` the same way `seenStore` is). The `passwordLoader` is `{ await KeychainService.loadSMTPPassword(for: $0) }`.

> **Engineer note:** `RootView` currently receives `store`, `seenStore`, `cacheContext`. Add the mail-related stores (`mailAccountStore`, `mailSettingsStore`, `threadStore`, `outboundTracker`, `outboundFailures`, the `MailSending` instance, `activityLog` (already in environment), and `mirrorHolder`) as parameters from `AppFeedbackApp`, matching how they're already created there. Use `Date()` directly (the app is not under the workflow scripting constraint).

- [ ] **Step 3: Build both platforms.** Expected: no errors.

- [ ] **Step 4: Manual smoke (optional, real device/sim with a configured mail account):** create a task addressing a feedback that has an email, assign it to a version, mark it done, release the version, confirm the recipients sheet pre-checks the user, send, and verify a `SentReleaseNotification` row appears in the version detail. Document the result.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Inspector/ReleaseRecipientsSheet.swift AppFeedback/App/RootView.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(release): recipients sheet + Release wiring (send + publish)"
```

### Task 3.5: Guard the Release action when no mail account is configured

**Files:**
- Modify: `AppFeedback/Views/Inspector/VersionDetailView.swift` (disable/explain Release when `accountStore.defaultSender == nil`)

- [ ] **Step 1: Pass a `canEmail: Bool` into `VersionDetailView`** from `RootView` (`versionStore`-adjacent), computed as `mailAccountStore.defaultSender != nil`.

- [ ] **Step 2: In `VersionDetailView`**, when `!canEmail`, replace the Release button with:
```swift
                    Label("Add a mail account in Settings to send release emails", systemImage: "envelope.badge")
                        .font(.footnote).foregroundStyle(.secondary)
```
(Still allow milestone-only "release" — show a secondary `Button("Mark released (no email)")` that calls `VersionService.release(..., publishRelease: false, ...)`.)

- [ ] **Step 3: Build both platforms.** Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Inspector/VersionDetailView.swift AppFeedback/App/RootView.swift
git commit -m "feat(release): guard release email when no mail account configured"
```

### Task 3.6: Full regression + finish

- [ ] **Step 1: Run the entire test suite (ground truth)**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && \
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: all tests pass; confirm the **"Test Suite … passed"** line and a non-crash exit (per project memory, do not trust a summary line alone — check there is no `** TEST FAILED **` and no signal/crash in the tail).

- [ ] **Step 2: Build iOS too**

Run: `xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS' 2>&1 | grep -E "error:" | head`
Expected: no errors.

- [ ] **Step 3: Update the spec status**

Edit `docs/superpowers/specs/2026-05-31-tasks-and-versions-design.md` header `Status:` → `Implemented`.

- [ ] **Step 4: Commit + finish the branch**

```bash
git add -A && git commit -m "test(tasks-versions): full regression green"
```
Then use the `superpowers:finishing-a-development-branch` skill to choose merge/PR.

---

## Self-Review (run before handing off)

**Spec coverage check (spec §→task):**
- §3#1 Milestone+Release → Tasks 1.7, 1.10 (VersionService.release), 3.4. ✔
- §3#2 refs in task body → 1.2, 1.3, 1.10. ✔
- §3#3 one repo per project → Phase 0. ✔
- §3#4 dedicated label → 1.1, 1.5. ✔
- §3#5 editable template → 3.2, 3.4. ✔
- §3#6 one reply per person, most-recent thread, lists all → 3.3 (`chooseFeedbackNumber`), 3.1 (feedbackNumbers). ✔
- §3#7 all pre-checked, dedup, hide no-email → 3.1, 3.4 (`onAppear` selection). ✔
- §3#8 track sent; already-sent unchecked → 1.9 (`alreadyNotifiedEmails`/`recordSent`), 3.4. ✔
- §3#9 status+priority labels → 1.1, 2.4, 1.10. ✔
- §3#10 in-app, manual changelog → 2.6, 2.7. ✔
- §3#11 remove multi-app → Phase 0. ✔
- §3#12 inspector → 2.3. ✔
- §3#13 multi-select → Create Task → 2.5. ✔
- §3#14 derived state + manual Release → 1.8 (`derivedState`), 2.2 (`anyTaskStarted`), 3.4. ✔
- §3#15 require online, clear errors → all services throw `ServiceError`; UI shows `errorMessage`. ✔
- §3#16 milestone always, release optional, connected repo → 1.10, 2.1, 3.4 (422 fallback). ✔
- §3#17 only completed tasks → 3.1. ✔
- §3#18 no opt-out handling → no opt-out line/list anywhere; manual uncheck + `alreadyNotifiedEmails`. ✔
- §8 mail account dependency → 3.5. ✔  | §11.3 no-thread fallback → 3.3 (`min()`). ✔  | §11.8 milestone-only release → 1.10 (422), 3.5. ✔

**Placeholder scan:** no "TBD/TODO"; the two `> Engineer note` blocks point at concrete files to verify exact initializer labels — not deferred work, but adapters to confirm against ground truth.

**Type consistency:** `TaskStatus`/`TaskPriority` (1.1) used identically in 1.3/1.10/2.4; `AppFeedbackLabels.task` everywhere; `ProjectVersion.derivedState(anyTaskStarted:)` matches `ProjectInspectorModel.anyTaskStarted` (1.8/2.2); `VersionStore.alreadyNotifiedEmails`/`recordSent`/`sentNotifications` consistent across 1.9/2.7/3.4; `ReleaseRecipient.feedbackNumbers` consistent (3.1/3.3/3.4); `FeedbackTaskRefParser.upsert/parse` consistent (1.2/1.3/1.10).
