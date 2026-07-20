# AI Feedback Triage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When new feedback arrives, on-device AI classifies it and either assigns it to an existing task or creates a new one — automatically or as a one-tap suggestion, per a user setting.

**Architecture:** Two-stage FoundationModels pipeline (classify worthiness → match-or-create against a roster of open task titles) orchestrated by a serial `FeedbackTriageCoordinator` hooked into `IssueLoaderRegistry.refreshTick()`. Verdicts persist in a local-only SwiftData store; GitHub is only touched through the existing `TaskService` paths when a task is actually created or assigned.

**Tech Stack:** Swift / SwiftUI, FoundationModels (`@Generable`, macOS 26 / iOS 26 gated), SwiftData (local, non-CloudKit schema), existing `TaskService` + `GitHubIssueWriter`.

**Spec:** `docs/superpowers/specs/2026-07-20-ai-feedback-triage-design.md`

## Global Constraints

- FoundationModels code must be fenced `#if canImport(FoundationModels)` + `@available(macOS 26, iOS 26, *)`; plain-Swift DTO mirrors for everything views/tests touch (pattern: `IssueSummary` / `IssueSummaryDTO`).
- ~4096-token session ceiling (TN3193): every prompt uses a shrinking config ladder; one `LanguageModelSession` per attempt.
- `TriageVerdictRecord` goes in the **local** SwiftData schema (`cloudKitDatabase: .none`) — AI verdicts never sync. CloudKit-compatible defaults on all properties anyway (the test container mixes schemas).
- Test target is `AppFeedbackTests_macOS`. Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/<ClassName> 2>&1 | tail -20` (or the zcode skill; xcodebuild is ground truth). ~11 pre-existing Keychain-related failures (`KeychainServicePerAccountTests`, `GitHubAccountStoreTests`) are NOT regressions.
- After creating new source files, run `xcodegen generate` before building. FIRST check `git status`: xcodegen silently discards uncommitted `.xcscheme` hand-edits and globs any untracked files into the project — the working tree often holds the user's unrelated WIP.
- Commits: stage ONLY the files you created/modified (never `git add -A`). End commit messages with the Claude Code co-author trailer.
- New task defaults when the AI creates one: `status: .todo`, `priority: .med`, no milestone.

---

### Task 1: Triage models & DTOs

**Files:**
- Create: `AppFeedback/Services/Intelligence/TriageModels.swift`
- Test: `AppFeedbackTests/TriageModelsTests.swift`

**Interfaces:**
- Produces: `TriageKind` (`bug`/`featureRequest`/`usability`, `init?(modelOutput:)`), `TriageClassificationDTO {isActionable: Bool, kind: TriageKind?, signal: String}`, `TriageDecisionDTO` (`.assign(taskNumber:)` / `.createNew(title:summary:)`) with `validated(againstRoster:fallbackTitle:fallbackSummary:)`, `TriageTaskRosterEntry {number: Int, title: String}`, and the FoundationModels-fenced `@Generable` mirrors `TriageClassification`, `TriageMatchDecision` with DTO conversion inits.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AppFeedback

struct TriageModelsTests {
    @Test func kindParsesLenientModelOutput() {
        #expect(TriageKind(modelOutput: "bug") == .bug)
        #expect(TriageKind(modelOutput: "Bug Report") == .bug)
        #expect(TriageKind(modelOutput: "feature request") == .featureRequest)
        #expect(TriageKind(modelOutput: "featureRequest") == .featureRequest)
        #expect(TriageKind(modelOutput: "usability complaint") == .usability)
        #expect(TriageKind(modelOutput: "none") == nil)
        #expect(TriageKind(modelOutput: "praise") == nil)
    }

    @Test func validatedKeepsAssignWhenNumberInRoster() {
        let d = TriageDecisionDTO.assign(taskNumber: 42)
        #expect(d.validated(againstRoster: [7, 42], fallbackTitle: "t", fallbackSummary: "s") == d)
    }

    @Test func validatedDemotesHallucinatedAssignToCreate() {
        let d = TriageDecisionDTO.assign(taskNumber: 99)
        let v = d.validated(againstRoster: [7, 42], fallbackTitle: "Fix crash", fallbackSummary: "Crash on export")
        #expect(v == .createNew(title: "Fix crash", summary: "Crash on export"))
    }

    @Test func validatedLeavesCreateAlone() {
        let d = TriageDecisionDTO.createNew(title: "a", summary: "b")
        #expect(d.validated(againstRoster: [], fallbackTitle: "t", fallbackSummary: "s") == d)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/TriageModelsTests 2>&1 | tail -20` (after `xcodegen generate`; check `git status` first per Global Constraints)
Expected: BUILD FAILURE — `TriageKind` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What kind of actionable feedback this is. Praise, content-free negativity,
/// and questions/support requests are not task-worthy and have no kind.
enum TriageKind: String, Sendable, CaseIterable {
    case bug
    case featureRequest
    case usability

    /// Lenient parse of free-form model output ("Bug Report", "feature request", …).
    init?(modelOutput: String) {
        let folded = modelOutput.lowercased().filter(\.isLetter)
        switch folded {
        case "bug", "bugreport", "crash", "regression": self = .bug
        case "featurerequest", "feature": self = .featureRequest
        case "usability", "usabilitycomplaint", "friction": self = .usability
        default: return nil
        }
    }
}

/// Plain-Swift stage-1 verdict mirror (views/tests don't need FoundationModels).
struct TriageClassificationDTO: Equatable, Sendable {
    var isActionable: Bool
    var kind: TriageKind?
    var signal: String
}

/// A candidate task the stage-2 matcher may assign feedback to.
struct TriageTaskRosterEntry: Equatable, Sendable {
    let number: Int
    let title: String
}

/// Plain-Swift stage-2 decision mirror.
enum TriageDecisionDTO: Equatable, Sendable {
    case assign(taskNumber: Int)
    case createNew(title: String, summary: String)

    /// Hallucination guard: an `assign` whose number was not in the roster actually
    /// sent to the model demotes to `createNew` with the fallback content.
    func validated(againstRoster rosterNumbers: Set<Int>,
                   fallbackTitle: String, fallbackSummary: String) -> TriageDecisionDTO {
        guard case .assign(let number) = self, !rosterNumbers.contains(number) else { return self }
        return .createNew(title: fallbackTitle, summary: fallbackSummary)
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct TriageClassification: Equatable, Sendable {
    @Guide(description: "true only when the feedback describes something a developer can act on: a bug, crash, or regression; a concrete feature request; or a usability complaint (confusing, hard to find, too many steps). false for praise, content-free negativity ('don't like it'), and questions or support requests.")
    var isActionable: Bool

    @Guide(description: "Exactly one of: bug, featureRequest, usability. Use none when not actionable.")
    var kind: String

    @Guide(description: "One short sentence naming the actionable signal — what is broken or wanted, plus platform/version when stated. Empty when not actionable.")
    var signal: String
}

@available(macOS 26, iOS 26, *)
extension TriageClassificationDTO {
    init(_ c: TriageClassification) {
        let kind = TriageKind(modelOutput: c.kind)
        // An "actionable" verdict without a recognizable kind is demoted — garbage
        // kinds must not produce tasks.
        self.isActionable = c.isActionable && kind != nil
        self.kind = c.isActionable ? kind : nil
        self.signal = c.signal
    }
}

@available(macOS 26, iOS 26, *)
@Generable
struct TriageMatchDecision: Equatable, Sendable {
    @Guide(description: "The number of the existing task that covers the same underlying problem or request, or 0 when none of the listed tasks match and a new task is needed.")
    var taskNumber: Int

    @Guide(description: "When taskNumber is 0: a short imperative task title, e.g. 'Fix crash when exporting on iPad'. Empty otherwise.")
    var newTaskTitle: String

    @Guide(description: "When taskNumber is 0: one or two plain sentences describing the task, grounded in the feedback. Empty otherwise.")
    var newTaskSummary: String
}

@available(macOS 26, iOS 26, *)
extension TriageDecisionDTO {
    init(_ d: TriageMatchDecision, fallbackTitle: String, fallbackSummary: String) {
        if d.taskNumber > 0 {
            self = .assign(taskNumber: d.taskNumber)
        } else {
            let title = d.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = d.newTaskSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .createNew(title: title.isEmpty ? fallbackTitle : title,
                              summary: summary.isEmpty ? fallbackSummary : summary)
        }
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Same command. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/TriageModels.swift AppFeedbackTests/TriageModelsTests.swift AppFeedback.xcodeproj
git commit -m "feat(triage): add triage models, DTOs, and hallucination guard"
```

---

### Task 2: TriagePromptBuilder

**Files:**
- Create: `AppFeedback/Services/Intelligence/TriagePromptBuilder.swift`
- Test: `AppFeedbackTests/TriagePromptBuilderTests.swift`

**Interfaces:**
- Consumes: `TriageKind`, `TriageTaskRosterEntry` (Task 1); `SummaryPromptBuilder.stripCodeBlocks(_:)`; `FeedbackIssue` fields `title`, `description`, `appName`, `appVersion`, `osVersion`, `rating`, `source`.
- Produces: `TriagePromptBuilder.classifyConfigs() -> [Int]` (bodyCharCaps), `matchConfigs() -> [Int]` (rosterCaps), `buildClassifyPrompt(issue:bodyCharCap:) -> String`, `buildMatchPrompt(signal:kind:roster:rosterCap:) -> (prompt: String, includedNumbers: Set<Int>)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AppFeedback

struct TriagePromptBuilderTests {
    private func issue(number: Int = 1, title: String = "Crash", body: String = "It crashes") -> FeedbackIssue {
        // Use the same fixture helper style as SummaryPromptBuilderTests; if a shared
        // fixture exists in Fakes/, reuse it instead of this local builder.
        FeedbackIssue(number: number, title: title, createdAt: .now, rawBody: body,
                      appName: "MyApp", appVersion: "2.3", device: nil, osVersion: "iOS 26",
                      email: nil, description: body, labels: [], updatedAt: nil, state: .open,
                      milestoneTitle: nil, detectedLanguageCode: nil,
                      attachments: [], source: .appStore, rating: 2)
    }

    @Test func classifyPromptTruncatesBodyAndIncludesMetadata() {
        let long = String(repeating: "x", count: 2_000)
        let p = TriagePromptBuilder.buildClassifyPrompt(issue: issue(body: long), bodyCharCap: 300)
        #expect(!p.contains(String(repeating: "x", count: 301)))
        #expect(p.contains("MyApp"))
        #expect(p.contains("2.3"))
    }

    @Test func matchPromptCapsRosterAndReportsIncludedNumbers() {
        let roster = (1...50).map { TriageTaskRosterEntry(number: $0, title: "Task \($0)") }
        let (prompt, included) = TriagePromptBuilder.buildMatchPrompt(
            signal: "Crash when exporting", kind: .bug, roster: roster, rosterCap: 10)
        #expect(included.count == 10)
        #expect(included.contains(1) && included.contains(10) && !included.contains(11))
        #expect(prompt.contains("#10 Task 10"))
        #expect(!prompt.contains("#11 Task 11"))
        #expect(prompt.contains("Crash when exporting"))
    }

    @Test func matchPromptHandlesEmptyRoster() {
        let (prompt, included) = TriagePromptBuilder.buildMatchPrompt(
            signal: "Dark mode wanted", kind: .featureRequest, roster: [], rosterCap: 10)
        #expect(included.isEmpty)
        #expect(prompt.contains("no existing tasks"))
    }

    @Test func configLaddersShrink() {
        let c = TriagePromptBuilder.classifyConfigs()
        let m = TriagePromptBuilder.matchConfigs()
        #expect(c == c.sorted(by: >) && !c.isEmpty)
        #expect(m == m.sorted(by: >) && !m.isEmpty)
    }
}
```

Note: adjust the `FeedbackIssue` initializer call to the real memberwise/custom init if it differs — check `AppFeedback/Models/FeedbackIssue.swift` and existing fixtures under `AppFeedbackTests/Fakes/` first, and reuse a fixture helper if one exists.

- [ ] **Step 2: Run test to verify it fails**

Run the Task 1 command with `-only-testing:AppFeedbackTests_macOS/TriagePromptBuilderTests`.
Expected: BUILD FAILURE — `TriagePromptBuilder` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Prompts for the two triage stages, with shrinking-size ladders for the
/// 4096-token session ceiling (TN3193). Stage 2 returns the set of task numbers
/// actually embedded so the caller can validate the model's answer against
/// exactly what it saw.
enum TriagePromptBuilder {
    /// Stage-1 body-char caps, largest first.
    static func classifyConfigs() -> [Int] { [1_200, 600, 300] }
    /// Stage-2 roster caps, largest first.
    static func matchConfigs() -> [Int] { [60, 30, 12] }

    static func buildClassifyPrompt(issue: FeedbackIssue, bodyCharCap: Int) -> String {
        let body = String(SummaryPromptBuilder.stripCodeBlocks(issue.description).prefix(max(bodyCharCap, 40)))
        var meta: [String] = []
        if let app = issue.appName { meta.append("app: \(app)") }
        if let version = issue.appVersion { meta.append("version: \(version)") }
        if let os = issue.osVersion { meta.append("os: \(os)") }
        if let rating = issue.rating { meta.append("rating: \(rating)/5") }
        let metaLine = meta.isEmpty ? "" : " (\(meta.joined(separator: ", ")))"
        return """
        Classify this single piece of user feedback\(metaLine):

        Title: \(issue.title)
        Body: \(body)

        Decide whether a developer can act on it (bug/crash/regression, concrete \
        feature request, or usability complaint) or not (praise, vague negativity, \
        question/support request).
        """
    }

    static func buildMatchPrompt(
        signal: String, kind: TriageKind,
        roster: [TriageTaskRosterEntry], rosterCap: Int
    ) -> (prompt: String, includedNumbers: Set<Int>) {
        let included = Array(roster.prefix(max(rosterCap, 0)))
        var lines: [String] = []
        lines.append("A new \(kindNoun(kind)) came in from user feedback:")
        lines.append("  \(signal)")
        lines.append("")
        if included.isEmpty {
            lines.append("There are no existing tasks. Propose a new task (taskNumber 0).")
        } else {
            lines.append("Existing open tasks:")
            for entry in included {
                lines.append("- #\(entry.number) \(entry.title)")
            }
            lines.append("")
            lines.append("""
            If one of these tasks covers the same underlying problem or request, answer \
            with its number. Otherwise answer taskNumber 0 and propose a new task title \
            and summary.
            """)
        }
        return (lines.joined(separator: "\n"), Set(included.map(\.number)))
    }

    private static func kindNoun(_ kind: TriageKind) -> String {
        switch kind {
        case .bug: return "bug report"
        case .featureRequest: return "feature request"
        case .usability: return "usability complaint"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — same command, expected PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/TriagePromptBuilder.swift AppFeedbackTests/TriagePromptBuilderTests.swift AppFeedback.xcodeproj
git commit -m "feat(triage): add two-stage prompt builder with token-budget ladders"
```

---

### Task 3: TriageVerdictRecord + TriageVerdictStore

**Files:**
- Create: `AppFeedback/Models/TriageVerdictRecord.swift`
- Create: `AppFeedback/Services/TriageVerdictStore.swift`
- Test: `AppFeedbackTests/TriageVerdictStoreTests.swift`

**Interfaces:**
- Produces: `TriageState` (String-raw enum: `preexisting`, `notActionable`, `pending`, `accepted`, `dismissed`, `autoApplied`, `skipped`), `@Model TriageVerdictRecord` (fields below), `@MainActor TriageVerdictStore` with `record(owner:repo:number:)`, `hasRecord(owner:repo:number:)`, `pendingSuggestions(owner:repo:)`, `aiCreatedTaskNumbers(owner:repo:)`, `upsert(owner:repo:number:mutate:)`, `snapshotPreexisting(owner:repo:numbers:)`, `setState(_:_:)`.
- Schema registration happens in Task 7 (app container); tests use their own in-memory container.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import AppFeedback

@MainActor
struct TriageVerdictStoreTests {
    private func makeStore() throws -> TriageVerdictStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TriageVerdictRecord.self, configurations: config)
        return TriageVerdictStore(context: ModelContext(container))
    }

    @Test func upsertCreatesThenUpdates() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 5) { $0.state = TriageState.pending.rawValue }
        #expect(store.hasRecord(owner: "o", repo: "r", number: 5))
        store.upsert(owner: "o", repo: "r", number: 5) { $0.state = TriageState.accepted.rawValue }
        #expect(store.record(owner: "o", repo: "r", number: 5)?.state == TriageState.accepted.rawValue)
        // Still exactly one record.
        #expect(store.pendingSuggestions(owner: "o", repo: "r").isEmpty)
    }

    @Test func pendingSuggestionsFiltersByStateAndRepo() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.notActionable.rawValue }
        store.upsert(owner: "o", repo: "other", number: 3) { $0.state = TriageState.pending.rawValue }
        let pending = store.pendingSuggestions(owner: "o", repo: "r")
        #expect(pending.map(\.feedbackNumber) == [1])
    }

    @Test func snapshotPreexistingOnlyInsertsMissing() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.snapshotPreexisting(owner: "o", repo: "r", numbers: [1, 2, 3])
        #expect(store.record(owner: "o", repo: "r", number: 1)?.state == TriageState.pending.rawValue)
        #expect(store.record(owner: "o", repo: "r", number: 2)?.state == TriageState.preexisting.rawValue)
        #expect(store.record(owner: "o", repo: "r", number: 3)?.state == TriageState.preexisting.rawValue)
    }

    @Test func aiCreatedTaskNumbersCollectsCreatedTasks() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.autoApplied.rawValue
            $0.createdTaskNumber = 90
        }
        store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.accepted.rawValue }
        #expect(store.aiCreatedTaskNumbers(owner: "o", repo: "r") == [90])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:AppFeedbackTests_macOS/TriageVerdictStoreTests`, expected BUILD FAILURE.

- [ ] **Step 3: Write the implementation**

`AppFeedback/Models/TriageVerdictRecord.swift`:

```swift
import Foundation
import SwiftData

/// Lifecycle of an AI triage verdict for one feedback issue.
enum TriageState: String, Sendable, CaseIterable {
    /// Present before triage was first enabled for its repo; only manual backfill touches it.
    case preexisting
    /// Classified as praise / vague negativity / question — no task warranted.
    case notActionable
    /// Suggestion awaiting user accept/dismiss.
    case pending
    case accepted
    case dismissed
    /// Applied without confirmation (hybrid assign or full-auto).
    case autoApplied
    /// Guardrail block or repeated context/transport failure; backfill may retry.
    case skipped
}

/// Local-only AI triage verdict for one feedback issue. Lives in the local
/// (non-CloudKit) schema — AI output never syncs or touches GitHub.
@Model
final class TriageVerdictRecord {
    var repoOwner: String = ""
    var repoName: String = ""
    var feedbackNumber: Int = 0
    /// Raw `TriageState`.
    var state: String = ""
    var isActionable: Bool = false
    /// Raw `TriageKind`; nil when not actionable.
    var kind: String?
    var signal: String = ""
    /// Pending/applied outcome: the existing task to assign to…
    var suggestedTaskNumber: Int?
    /// …or the new task to create.
    var suggestedTitle: String?
    var suggestedSummary: String?
    /// Task number an accepted/auto-applied create produced — drives the local "AI" badge.
    var createdTaskNumber: Int?
    var updatedAt: Date = Date()

    init(repoOwner: String, repoName: String, feedbackNumber: Int, state: String) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.feedbackNumber = feedbackNumber
        self.state = state
    }
}
```

`AppFeedback/Services/TriageVerdictStore.swift`:

```swift
import Foundation
import SwiftData

/// Fetch/upsert layer over `TriageVerdictRecord`. @MainActor like the other
/// SwiftData-backed stores; the coordinator is the only writer.
@MainActor
final class TriageVerdictStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(owner: String, repo: String, number: Int) -> TriageVerdictRecord? {
        var descriptor = FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.feedbackNumber == number
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func hasRecord(owner: String, repo: String, number: Int) -> Bool {
        record(owner: owner, repo: repo, number: number) != nil
    }

    func pendingSuggestions(owner: String, repo: String) -> [TriageVerdictRecord] {
        let raw = TriageState.pending.rawValue
        let descriptor = FetchDescriptor<TriageVerdictRecord>(
            predicate: #Predicate { $0.repoOwner == owner && $0.repoName == repo && $0.state == raw },
            sortBy: [SortDescriptor(\.feedbackNumber)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Numbers of tasks that were created by AI (accepted or auto-applied creates).
    func aiCreatedTaskNumbers(owner: String, repo: String) -> Set<Int> {
        let descriptor = FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.createdTaskNumber != nil
        })
        return Set(((try? context.fetch(descriptor)) ?? []).compactMap(\.createdTaskNumber))
    }

    @discardableResult
    func upsert(owner: String, repo: String, number: Int,
                mutate: (TriageVerdictRecord) -> Void) -> TriageVerdictRecord {
        let rec = record(owner: owner, repo: repo, number: number)
            ?? {
                let fresh = TriageVerdictRecord(repoOwner: owner, repoName: repo,
                                                feedbackNumber: number,
                                                state: TriageState.pending.rawValue)
                context.insert(fresh)
                return fresh
            }()
        mutate(rec)
        rec.updatedAt = Date()
        try? context.save()
        return rec
    }

    /// Marks feedback that predates triage as `.preexisting` — insert-if-missing only,
    /// so real verdicts are never downgraded (mirrors NotificationService.snapshotExistingIssues).
    func snapshotPreexisting(owner: String, repo: String, numbers: [Int]) {
        for number in numbers where !hasRecord(owner: owner, repo: repo, number: number) {
            context.insert(TriageVerdictRecord(repoOwner: owner, repoName: repo,
                                               feedbackNumber: number,
                                               state: TriageState.preexisting.rawValue))
        }
        try? context.save()
    }

    func setState(_ record: TriageVerdictRecord, _ state: TriageState) {
        record.state = state.rawValue
        record.updatedAt = Date()
        try? context.save()
    }
}
```

- [ ] **Step 4: Run to verify pass** — same command, expected PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/TriageVerdictRecord.swift AppFeedback/Services/TriageVerdictStore.swift AppFeedbackTests/TriageVerdictStoreTests.swift AppFeedback.xcodeproj
git commit -m "feat(triage): add local-only verdict record and store"
```

---

### Task 4: TriageSettings

**Files:**
- Create: `AppFeedback/Services/Intelligence/TriageSettings.swift`
- Test: `AppFeedbackTests/TriageSettingsTests.swift`

**Interfaces:**
- Produces: `TriageMode` (`off`/`suggest`/`hybrid`/`fullAuto`, `displayName`), `@Observable @MainActor TriageSettings` with `var mode: TriageMode`, `hasSnapshotted(owner:repo:)`, `markSnapshotted(owner:repo:)`, `init(defaults: UserDefaults = .standard)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AppFeedback

@MainActor
struct TriageSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "triage-tests-\(UUID().uuidString)")!
    }

    @Test func defaultsToOffAndPersistsMode() {
        let defaults = makeDefaults()
        let s1 = TriageSettings(defaults: defaults)
        #expect(s1.mode == .off)
        s1.mode = .hybrid
        let s2 = TriageSettings(defaults: defaults)
        #expect(s2.mode == .hybrid)
    }

    @Test func snapshotMarkerIsPerRepo() {
        let s = TriageSettings(defaults: makeDefaults())
        #expect(!s.hasSnapshotted(owner: "o", repo: "r"))
        s.markSnapshotted(owner: "o", repo: "r")
        #expect(s.hasSnapshotted(owner: "o", repo: "r"))
        #expect(!s.hasSnapshotted(owner: "o", repo: "other"))
    }
}
```

- [ ] **Step 2: Run to verify failure** — expected BUILD FAILURE.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Observation

/// How autonomously AI triage acts on new feedback.
enum TriageMode: String, CaseIterable, Sendable {
    case off
    /// Everything becomes a suggestion the user accepts or dismisses.
    case suggest
    /// Assigns to existing tasks auto-apply; new-task creates need confirmation.
    case hybrid
    /// Assigns and creates both auto-apply.
    case fullAuto

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .suggest: return "Suggest only"
        case .hybrid: return "Auto-assign, confirm new tasks"
        case .fullAuto: return "Fully automatic"
        }
    }
}

@Observable @MainActor
final class TriageSettings {
    private let defaults: UserDefaults
    private static let modeKey = "triage.mode"
    private static let snapshotKeyPrefix = "triage.snapshotted."

    var mode: TriageMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = defaults.string(forKey: Self.modeKey).flatMap(TriageMode.init(rawValue:)) ?? .off
    }

    /// Per-repo first-sighting marker: the first time triage sees a repo's loaded
    /// feedback, the existing backlog is snapshotted as preexisting instead of triaged.
    func hasSnapshotted(owner: String, repo: String) -> Bool {
        defaults.bool(forKey: Self.snapshotKeyPrefix + "\(owner)/\(repo)")
    }

    func markSnapshotted(owner: String, repo: String) {
        defaults.set(true, forKey: Self.snapshotKeyPrefix + "\(owner)/\(repo)")
    }
}
```

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/TriageSettings.swift AppFeedbackTests/TriageSettingsTests.swift AppFeedback.xcodeproj
git commit -m "feat(triage): add triage mode settings with per-repo snapshot markers"
```

---

### Task 5: IntelligenceProvider triage methods

**Files:**
- Modify: `AppFeedback/Services/Intelligence/IntelligenceProvider.swift`
- Modify: `AppFeedback/Services/Intelligence/IntelligenceService.swift`
- Modify: `AppFeedbackTests/MockIntelligenceProvider.swift`
- Test: `AppFeedbackTests/IntelligenceServiceTriageTests.swift`

**Interfaces:**
- Consumes: `TriageClassificationDTO`, `TriageDecisionDTO`, `TriageKind`, `TriageTaskRosterEntry`, `TriagePromptBuilder`, `TriageClassification`, `TriageMatchDecision` (Tasks 1–2).
- Produces: protocol methods `triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO` and `triageMatch(signal: String, kind: TriageKind, roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO`; new `IntelligenceError.guardrailBlocked`. **Contract:** `triageMatch`'s returned `.assign` numbers are always ⊆ the roster passed in (the service validates against the numbers actually embedded in the prompt); guardrail hits throw `.guardrailBlocked` (no silent fallback — the coordinator marks the item skipped).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AppFeedback

@MainActor
struct IntelligenceServiceTriageTests {
    @Test func triageThrowsUnavailableWhenModelNotReady() async {
        let service = IntelligenceService()   // availability defaults to .osTooOld until recomputed
        let issue = FeedbackIssue.triageTestFixture(number: 1, title: "t", body: "b")
        await #expect(throws: IntelligenceError.unavailable) {
            _ = try await service.triageClassify(issue: issue)
        }
        await #expect(throws: IntelligenceError.unavailable) {
            _ = try await service.triageMatch(signal: "s", kind: .bug, roster: [])
        }
    }
}
```

Add a shared fixture helper `FeedbackIssue.triageTestFixture(number:title:body:)` in `AppFeedbackTests/Fakes/` (or reuse an existing FeedbackIssue fixture if one is already there — check first; Task 2's local builder should also migrate to it).

- [ ] **Step 2: Run to verify failure** — `-only-testing:AppFeedbackTests_macOS/IntelligenceServiceTriageTests`, BUILD FAILURE (no such protocol methods).

- [ ] **Step 3: Implement**

In `IntelligenceProvider.swift`, extend the protocol:

```swift
protocol IntelligenceProvider: AnyObject, Sendable {
    @MainActor var availability: IntelligenceAvailability { get }
    func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO
    /// Stage 1: is this single feedback item task-worthy, and what's the signal?
    func triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO
    /// Stage 2: assign to one of `roster` or propose a new task. Returned `.assign`
    /// numbers are guaranteed to be members of `roster`.
    func triageMatch(signal: String, kind: TriageKind,
                     roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO
}
```

In `IntelligenceService.swift`: add `case guardrailBlocked` to `IntelligenceError` (make it `Equatable` if it isn't for the test's `#expect(throws:)`), instruction constants, the public methods (same availability-gate shape as `summarize`), and the FoundationModels extension:

```swift
    private let triageClassifyInstructions = """
    You triage a single piece of app-user feedback for a developer.
    Actionable means a developer could work on it: a bug, crash, or regression; a \
    concrete feature request; or a usability complaint (confusing, hard to find, \
    too many steps).
    Not actionable: praise ("the app works great"), content-free negativity \
    ("don't like it"), and questions or support requests.
    kind must be exactly one of: bug, featureRequest, usability, none.
    signal: one short factual sentence naming what is broken or wanted; empty when \
    not actionable. No markdown.
    """
    private let triageMatchInstructions = """
    You match an actionable piece of user feedback against a list of existing \
    development tasks. Choose an existing task ONLY when it covers the same \
    underlying problem or request — do not stretch. Otherwise answer taskNumber 0 \
    with a short imperative newTaskTitle and a 1-2 sentence newTaskSummary grounded \
    in the feedback. No markdown.
    """

    nonisolated func triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runTriageClassify(issue: issue)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    nonisolated func triageMatch(signal: String, kind: TriageKind,
                                 roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runTriageMatch(signal: signal, kind: kind, roster: roster)
        }
        #endif
        throw IntelligenceError.unavailable
    }
```

FoundationModels extension (append to the existing `@available(macOS 26, iOS 26, *)` extension in the same file):

```swift
    fileprivate func runTriageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO {
        let instructions = await MainActor.run { triageClassifyInstructions }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        var lastBudgetError: Error?
        for bodyCharCap in TriagePromptBuilder.classifyConfigs() {
            let prompt = TriagePromptBuilder.buildClassifyPrompt(issue: issue, bodyCharCap: bodyCharCap)
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: TriageClassification.self)
                return TriageClassificationDTO(response.content)
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { throw IntelligenceError.guardrailBlocked }
                if case .exceededContextWindowSize = error { lastBudgetError = error; continue }
                throw error
            }
        }
        throw lastBudgetError ?? IntelligenceError.unavailable
    }

    fileprivate func runTriageMatch(signal: String, kind: TriageKind,
                                    roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        let instructions = await MainActor.run { triageMatchInstructions }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let fallbackTitle = String(signal.prefix(72))
        var lastBudgetError: Error?
        for rosterCap in TriagePromptBuilder.matchConfigs() {
            let (prompt, includedNumbers) = TriagePromptBuilder.buildMatchPrompt(
                signal: signal, kind: kind, roster: roster, rosterCap: rosterCap)
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: TriageMatchDecision.self)
                return TriageDecisionDTO(response.content, fallbackTitle: fallbackTitle, fallbackSummary: signal)
                    .validated(againstRoster: includedNumbers,
                               fallbackTitle: fallbackTitle, fallbackSummary: signal)
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { throw IntelligenceError.guardrailBlocked }
                if case .exceededContextWindowSize = error { lastBudgetError = error; continue }
                throw error
            }
        }
        throw lastBudgetError ?? IntelligenceError.unavailable
    }
```

Extend `MockIntelligenceProvider` (keeps every existing test compiling and gives Task 6 its seam):

```swift
    var triageClassifyHandler: (FeedbackIssue) async throws -> TriageClassificationDTO = { _ in
        TriageClassificationDTO(isActionable: false, kind: nil, signal: "")
    }
    var triageMatchHandler: (String, TriageKind, [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO = { signal, _, _ in
        .createNew(title: String(signal.prefix(72)), summary: signal)
    }
    private(set) var triageClassifyCalls: [FeedbackIssue] = []
    private(set) var triageMatchCalls: [(signal: String, kind: TriageKind, roster: [TriageTaskRosterEntry])] = []

    func triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO {
        await MainActor.run { self.triageClassifyCalls.append(issue) }
        return try await triageClassifyHandler(issue)
    }

    func triageMatch(signal: String, kind: TriageKind,
                     roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        await MainActor.run { self.triageMatchCalls.append((signal, kind, roster)) }
        return try await triageMatchHandler(signal, kind, roster)
    }
```

- [ ] **Step 4: Run to verify pass** — run the new class AND the full `AppFeedbackTests_macOS` suite once (protocol change touches existing mocks): expect no new failures beyond the ~11 known Keychain ones.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceProvider.swift AppFeedback/Services/Intelligence/IntelligenceService.swift AppFeedbackTests/MockIntelligenceProvider.swift AppFeedbackTests/IntelligenceServiceTriageTests.swift AppFeedbackTests/Fakes AppFeedback.xcodeproj
git commit -m "feat(triage): add two-stage triage methods to IntelligenceProvider"
```

---

### Task 6: FeedbackTriageCoordinator

**Files:**
- Create: `AppFeedback/Services/FeedbackTriageCoordinator.swift`
- Test: `AppFeedbackTests/FeedbackTriageCoordinatorTests.swift` (+ `AppFeedbackTests/Fakes/MockTriageApplier.swift`)

**Interfaces:**
- Consumes: everything from Tasks 1–5; `TaskItem.isTask(_:)`, `TaskItem(issue:)`, `TaskItem.withFeedbackRefs(_:)`, `TaskItem.isCompleted`; `TaskService.setFeedbackRefs(repo:task:refs:)` and `createTask(repo:title:prose:feedbackRefs:status:priority:milestoneNumber:)`.
- Produces:
  - `@MainActor protocol TriageTaskApplying: AnyObject` with `assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws` and `createTask(in repo: ProductConfig, title: String, summary: String, feedbackNumber: Int) async throws -> Int`.
  - `TaskServiceTriageApplier` (production conformance over `TaskService`).
  - `@Observable @MainActor FeedbackTriageCoordinator` with `init(provider:store:settings:applier:)`, `processLoaded(_ groups: [(repo: ProductConfig, issues: [FeedbackIssue])]) async`, `runBackfill(repo:issues:rerunSettled:) async`, `accept(record:repo:issues:) async throws`, `dismiss(record:)`, `pendingSuggestion(owner:repo:number:) -> TriageVerdictRecord?`, `aiCreatedTaskNumbers(owner:repo:) -> Set<Int>`, observable `isProcessing: Bool` and `progress: (done: Int, total: Int)?`.

- [ ] **Step 1: Write the failing tests**

`AppFeedbackTests/Fakes/MockTriageApplier.swift`:

```swift
import Foundation
@testable import AppFeedback

@MainActor
final class MockTriageApplier: TriageTaskApplying {
    private(set) var assigns: [(feedback: Int, task: Int)] = []
    private(set) var creates: [(title: String, summary: String, feedback: Int)] = []
    var errorToThrow: Error?
    var nextCreatedNumber = 900

    func assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws {
        if let errorToThrow { throw errorToThrow }
        assigns.append((feedbackNumber, task.number))
    }

    func createTask(in repo: ProductConfig, title: String, summary: String,
                    feedbackNumber: Int) async throws -> Int {
        if let errorToThrow { throw errorToThrow }
        creates.append((title, summary, feedbackNumber))
        nextCreatedNumber += 1
        return nextCreatedNumber
    }
}
```

`AppFeedbackTests/FeedbackTriageCoordinatorTests.swift` — the harness plus the behaviors below. Fixture notes: build feedback with `FeedbackIssue.triageTestFixture` (Task 5); build task issues as fixtures carrying the `appfeedback:task` label with body text produced by `FeedbackTaskRefParser.upsert(into:refs:)` so `TaskItem(issue:)` parses refs.

```swift
import Testing
import Foundation
import SwiftData
@testable import AppFeedback

@MainActor
struct FeedbackTriageCoordinatorTests {
    struct Harness {
        let provider = MockIntelligenceProvider()
        let applier = MockTriageApplier()
        let store: TriageVerdictStore
        let settings: TriageSettings
        let coordinator: FeedbackTriageCoordinator
        let repo = ProductConfig(displayName: "P", owner: "o", repo: "r")

        init(mode: TriageMode) throws {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: TriageVerdictRecord.self, configurations: config)
            store = TriageVerdictStore(context: ModelContext(container))
            settings = TriageSettings(defaults: UserDefaults(suiteName: "triage-co-\(UUID())")!)
            settings.mode = mode
            coordinator = FeedbackTriageCoordinator(
                provider: provider, store: store, settings: settings, applier: applier)
        }

        /// Skips the first-sighting snapshot so tests exercise triage directly.
        func markSnapshotted() { settings.markSnapshotted(owner: "o", repo: "r") }
    }

    // Behaviors to cover (one @Test each):
    // 1. offModeDoesNothing — mode .off: no AI calls, no records.
    // 2. firstSightingSnapshotsBacklogWithoutAI — unsnapshotted repo: all unlinked
    //    feedback becomes .preexisting, zero triageClassifyCalls.
    // 3. notActionableStoresVerdict — classify returns isActionable false →
    //    record .notActionable, no stage-2 call, no applier calls.
    // 4. suggestModeStoresPendingForAssignAndCreate — actionable + match .assign(42)
    //    (roster contains open task 42) → record .pending with suggestedTaskNumber 42,
    //    applier untouched. Same for .createNew → pending with title/summary.
    // 5. hybridAppliesAssignImmediately — match .assign(42) → applier.assigns == [(n, 42)],
    //    record .autoApplied.
    // 6. hybridLeavesCreateAsPending.
    // 7. fullAutoCreatesAndGrowsRoster — two feedback items; classify actionable for
    //    both; matchHandler returns .createNew for the first, then asserts the roster
    //    it receives for the SECOND contains the first's created number (901) and
    //    returns .assign(taskNumber: 901). Expect creates.count == 1, assigns == [(f2, 901)].
    // 8. guardrailMarksSkipped — classifyHandler throws IntelligenceError.guardrailBlocked
    //    → record .skipped, no crash, processing continues to next item.
    // 9. applyFailureDemotesToPending — fullAuto, applier.errorToThrow set → record
    //    .pending with suggestion payload preserved.
    // 10. alreadyLinkedAndAlreadyRecordedAreSkipped — feedback in a task's
    //     feedbackRefs, or with an existing record → zero AI calls for those.
    // 11. backfillProcessesPreexistingAndSkipped — records in .preexisting/.skipped
    //     get triaged by runBackfill; .dismissed only when rerunSettled: true.
    // 12. acceptAppliesPendingSuggestion — pending create → applier.createTask called,
    //     state .accepted, createdTaskNumber stamped; pending assign → applier.assign.
    // 13. dismissMarksDismissed.
    // 14. unavailableProviderIsNoOp — provider.availability = .osTooOld → nothing runs.
}
```

Write all 14 tests in full (the comment block is the checklist, not a substitute).

- [ ] **Step 2: Run to verify failure** — `-only-testing:AppFeedbackTests_macOS/FeedbackTriageCoordinatorTests`, BUILD FAILURE.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// Seam over TaskService so triage tests run without GitHub or Keychain.
@MainActor
protocol TriageTaskApplying: AnyObject {
    func assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws
    /// Returns the created task's number.
    func createTask(in repo: ProductConfig, title: String, summary: String,
                    feedbackNumber: Int) async throws -> Int
}

@MainActor
final class TaskServiceTriageApplier: TriageTaskApplying {
    private let service: TaskService
    init(service: TaskService = TaskService()) { self.service = service }

    func assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws {
        var refs = Set(task.feedbackRefs)
        refs.insert(feedbackNumber)
        try await service.setFeedbackRefs(repo: repo, task: task, refs: refs.sorted())
    }

    func createTask(in repo: ProductConfig, title: String, summary: String,
                    feedbackNumber: Int) async throws -> Int {
        try await service.createTask(repo: repo, title: title, prose: summary,
                                     feedbackRefs: [feedbackNumber],
                                     status: .todo, priority: .med, milestoneNumber: nil)
    }
}

/// Orchestrates AI feedback triage: filters new feedback, runs the two-stage
/// pipeline, and routes outcomes by `TriageMode`. Serial by design — one on-device
/// inference at a time, and a batch's created tasks join the roster so five
/// duplicate crash reports become one create plus four assigns.
@Observable @MainActor
final class FeedbackTriageCoordinator {
    private let provider: IntelligenceProvider
    private let store: TriageVerdictStore
    private let settings: TriageSettings
    private let applier: TriageTaskApplying

    private(set) var isProcessing = false
    /// (processed, total) for the running pass — drives backfill progress UI.
    private(set) var progress: (done: Int, total: Int)?

    init(provider: IntelligenceProvider, store: TriageVerdictStore,
         settings: TriageSettings, applier: TriageTaskApplying) {
        self.provider = provider
        self.store = store
        self.settings = settings
        self.applier = applier
    }

    typealias RepoGroup = (repo: ProductConfig, issues: [FeedbackIssue])

    // MARK: Entry points

    /// Refresh hook: triages feedback with no verdict yet. First sighting of a repo
    /// snapshots the existing backlog as `.preexisting` instead (no AI calls).
    func processLoaded(_ groups: [RepoGroup]) async {
        guard begin() else { return }
        defer { end() }
        for group in groups {
            await processRepo(group, retriableStates: [])
        }
    }

    /// Manual backfill over one product: re-triages `.preexisting` and `.skipped`
    /// records (plus `.dismissed`/`.notActionable` when `rerunSettled`).
    func runBackfill(repo: ProductConfig, issues: [FeedbackIssue], rerunSettled: Bool = false) async {
        guard begin() else { return }
        defer { end() }
        settings.markSnapshotted(owner: repo.owner, repo: repo.repo)
        let retriable: Set<TriageState> = rerunSettled
            ? [.preexisting, .skipped, .dismissed, .notActionable]
            : [.preexisting, .skipped]
        await processRepo((repo, issues), retriableStates: retriable)
    }

    /// Applies a pending suggestion (chip Accept).
    func accept(record: TriageVerdictRecord, repo: ProductConfig, issues: [FeedbackIssue]) async throws {
        let tasks = issues.filter(TaskItem.isTask).map(TaskItem.init(issue:))
        if let n = record.suggestedTaskNumber, let task = tasks.first(where: { $0.number == n }) {
            try await applier.assign(feedbackNumber: record.feedbackNumber, to: task, in: repo)
        } else if let title = record.suggestedTitle {
            record.createdTaskNumber = try await applier.createTask(
                in: repo, title: title, summary: record.suggestedSummary ?? "",
                feedbackNumber: record.feedbackNumber)
        } else {
            throw IntelligenceError.empty   // malformed record: nothing to apply
        }
        store.setState(record, .accepted)
    }

    func dismiss(record: TriageVerdictRecord) {
        store.setState(record, .dismissed)
    }

    // MARK: UI queries

    func pendingSuggestion(owner: String, repo: String, number: Int) -> TriageVerdictRecord? {
        guard let rec = store.record(owner: owner, repo: repo, number: number),
              rec.state == TriageState.pending.rawValue else { return nil }
        return rec
    }

    func aiCreatedTaskNumbers(owner: String, repo: String) -> Set<Int> {
        store.aiCreatedTaskNumbers(owner: owner, repo: repo)
    }

    // MARK: Pipeline

    private func begin() -> Bool {
        guard settings.mode != .off, provider.availability.isReady, !isProcessing else { return false }
        isProcessing = true
        return true
    }

    private func end() {
        isProcessing = false
        progress = nil
    }

    private func processRepo(_ group: RepoGroup, retriableStates: Set<TriageState>) async {
        let repo = group.repo
        let tasks = group.issues.filter(TaskItem.isTask).map(TaskItem.init(issue:))
        var linked = Set(tasks.flatMap(\.feedbackRefs))
        let feedback = group.issues.filter { !TaskItem.isTask($0) }

        if !settings.hasSnapshotted(owner: repo.owner, repo: repo.repo) {
            store.snapshotPreexisting(owner: repo.owner, repo: repo.repo,
                                      numbers: feedback.map(\.number).filter { !linked.contains($0) })
            settings.markSnapshotted(owner: repo.owner, repo: repo.repo)
            return
        }

        var roster = tasks.filter { !$0.isCompleted }
            .map { TriageTaskRosterEntry(number: $0.number, title: $0.title) }
        var taskByNumber = Dictionary(uniqueKeysWithValues: tasks.map { ($0.number, $0) })

        let candidates = feedback.filter { issue in
            guard !linked.contains(issue.number) else { return false }
            guard let rec = store.record(owner: repo.owner, repo: repo.repo, number: issue.number) else {
                return true
            }
            return TriageState(rawValue: rec.state).map(retriableStates.contains) ?? false
        }
        guard !candidates.isEmpty else { return }
        progress = (0, candidates.count)

        for (index, issue) in candidates.enumerated() {
            await triageOne(issue, repo: repo, roster: &roster,
                            taskByNumber: &taskByNumber, linked: &linked)
            progress = (index + 1, candidates.count)
        }
    }

    private func triageOne(_ issue: FeedbackIssue, repo: ProductConfig,
                           roster: inout [TriageTaskRosterEntry],
                           taskByNumber: inout [Int: TaskItem],
                           linked: inout Set<Int>) async {
        let classification: TriageClassificationDTO
        do {
            classification = try await provider.triageClassify(issue: issue)
        } catch {
            // Guardrail block, exhausted context ladder, or transient failure:
            // park as skipped so refreshes don't retry; backfill can.
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) {
                $0.state = TriageState.skipped.rawValue
            }
            return
        }

        guard classification.isActionable, let kind = classification.kind else {
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) {
                $0.state = TriageState.notActionable.rawValue
                $0.isActionable = false
                $0.signal = classification.signal
            }
            return
        }

        let decision: TriageDecisionDTO
        do {
            decision = try await provider.triageMatch(
                signal: classification.signal, kind: kind, roster: roster)
        } catch {
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) {
                $0.state = TriageState.skipped.rawValue
            }
            return
        }

        await route(decision, for: issue, repo: repo, classification: classification,
                    kind: kind, roster: &roster, taskByNumber: &taskByNumber, linked: &linked)
    }

    private func route(_ decision: TriageDecisionDTO, for issue: FeedbackIssue,
                       repo: ProductConfig, classification: TriageClassificationDTO,
                       kind: TriageKind,
                       roster: inout [TriageTaskRosterEntry],
                       taskByNumber: inout [Int: TaskItem],
                       linked: inout Set<Int>) async {
        func recordSuggestion(_ state: TriageState) {
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) { rec in
                rec.state = state.rawValue
                rec.isActionable = true
                rec.kind = kind.rawValue
                rec.signal = classification.signal
                switch decision {
                case .assign(let n):
                    rec.suggestedTaskNumber = n
                case .createNew(let title, let summary):
                    rec.suggestedTitle = title
                    rec.suggestedSummary = summary
                }
            }
        }

        switch (decision, settings.mode) {
        case (.assign(let n), .hybrid), (.assign(let n), .fullAuto):
            // Race re-check: the freshly loaded pass may already link this feedback.
            guard let task = taskByNumber[n], !linked.contains(issue.number) else {
                recordSuggestion(.pending)
                return
            }
            do {
                try await applier.assign(feedbackNumber: issue.number, to: task, in: repo)
                linked.insert(issue.number)
                taskByNumber[n] = task.withFeedbackRefs(task.feedbackRefs + [issue.number])
                recordSuggestion(.autoApplied)
            } catch {
                recordSuggestion(.pending)   // demoted; chip offers retry via Accept
            }

        case (.createNew(let title, let summary), .fullAuto):
            do {
                let created = try await applier.createTask(
                    in: repo, title: title, summary: summary, feedbackNumber: issue.number)
                linked.insert(issue.number)
                roster.append(TriageTaskRosterEntry(number: created, title: title))
                taskByNumber[created] = TaskItem(
                    number: created, title: title,
                    body: TaskService.body(prose: summary, feedbackRefs: [issue.number]),
                    feedbackRefs: [issue.number], status: .todo, priority: .med,
                    milestoneTitle: nil, isClosed: false)
                store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) { rec in
                    rec.state = TriageState.autoApplied.rawValue
                    rec.isActionable = true
                    rec.kind = kind.rawValue
                    rec.signal = classification.signal
                    rec.suggestedTitle = title
                    rec.suggestedSummary = summary
                    rec.createdTaskNumber = created
                }
            } catch {
                recordSuggestion(.pending)
            }

        default:
            // Suggest mode entirely, and hybrid's createNew.
            recordSuggestion(.pending)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — all 14 tests green.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/FeedbackTriageCoordinator.swift AppFeedbackTests/FeedbackTriageCoordinatorTests.swift AppFeedbackTests/Fakes/MockTriageApplier.swift AppFeedback.xcodeproj
git commit -m "feat(triage): add serial triage coordinator with mode routing"
```

---

### Task 7: App wiring + refresh hook

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (container schemas ~lines 79–116; service construction after line 167; `sharedEnvironment` ~line 315)
- Modify: `AppFeedback/Services/IssueLoaderRegistry.swift`
- Test: extend `AppFeedbackTests/IssueLoaderRegistryTests.swift` (create if missing)

**Interfaces:**
- Consumes: `FeedbackTriageCoordinator.processLoaded`, `TriageSettings`, `TriageVerdictStore`, `TaskServiceTriageApplier` (Task 6).
- Produces: `IssueLoaderRegistry.triageSink: (([(repo: ProductConfig, issues: [FeedbackIssue])]) async -> Void)?` and `loadedProductGroups`; app-level `triageSettings` / `triageCoordinator` in the SwiftUI environment.

- [ ] **Step 1: Write the failing test** — in `IssueLoaderRegistryTests`, following the file's existing fixture style (it already constructs registries with a stub factory/tokenProvider; mirror that):

```swift
@Test func refreshTickInvokesTriageSinkWithLoadedGroups() async {
    // Arrange a registry whose single loader is in .loaded state (existing test
    // helpers in this file show how), then:
    var received: [(repo: ProductConfig, issues: [FeedbackIssue])] = []
    registry.triageSink = { groups in received = groups }
    await registry.refreshTick()
    #expect(received.map(\.repo.repo) == ["r"])
    #expect(received.first?.issues.count == expectedIssues.count)
}
```

- [ ] **Step 2: Run to verify failure** — no `triageSink` member.

- [ ] **Step 3: Implement**

`IssueLoaderRegistry.swift` — add the sink property, the product-typed groups, and the hook at the end of `refreshTick()`:

```swift
    /// Invoked after each refresh tick with every loaded product's issues —
    /// the AI triage entry point. Optional and fire-and-forget like the
    /// notification differ; triage self-gates on its own settings.
    var triageSink: (([(repo: ProductConfig, issues: [FeedbackIssue])]) async -> Void)?

    /// Like `loadedGroups` but keyed by full ProductConfig (triage needs owner,
    /// repo, and the config for TaskService writes).
    var loadedProductGroups: [(repo: ProductConfig, issues: [FeedbackIssue])] {
        products.compactMap { repo in
            guard let loader = loaders[repo.id],
                  case .loaded(let issues, _) = loader.state else { return nil }
            return (repo: repo, issues: issues)
        }
    }
```

In `refreshTick()`, after the `diffAndNotify` line:

```swift
        await triageSink?(loadedProductGroups)
```

`AppFeedbackApp.swift`:
1. Add `TriageVerdictRecord.self` to BOTH the test-config model list (after `AppStoreReviewMirror.self`, ~line 91) and the production `localSchema` (~line 96) and the production container `for:` list (~line 114).
2. Add stored properties alongside the other `@State` services:

```swift
    @State private var triageSettings: TriageSettings
    @State private var triageCoordinator: FeedbackTriageCoordinator
```

3. In `init()`, after `_intelligenceService` (line 167):

```swift
        let triageSettingsLocal = TriageSettings()
        _triageSettings = State(initialValue: triageSettingsLocal)
        let triageCoordinatorLocal = FeedbackTriageCoordinator(
            provider: _intelligenceService.wrappedValue,
            store: TriageVerdictStore(context: ModelContext(container)),
            settings: triageSettingsLocal,
            applier: TaskServiceTriageApplier()
        )
        _triageCoordinator = State(initialValue: triageCoordinatorLocal)
```

4. After `issueRegistry` is created (~line 299):

```swift
        issueRegistry.triageSink = { groups in
            await triageCoordinatorLocal.processLoaded(groups)
        }
```

5. In `sharedEnvironment`, add `.environment(triageSettings)` and `.environment(triageCoordinator)`.

- [ ] **Step 4: Run to verify** — the registry test passes AND the full `AppFeedbackTests_macOS` suite shows no new failures (schema change touches app startup in the test host).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift AppFeedback/Services/IssueLoaderRegistry.swift AppFeedbackTests/IssueLoaderRegistryTests.swift AppFeedback.xcodeproj
git commit -m "feat(triage): wire triage coordinator into refresh loop and app environment"
```

---

### Task 8: UI — settings picker, suggestion chip, backfill action, AI badge

**Files:**
- Modify: `AppFeedback/Views/Settings/IntelligenceSettingsSection.swift` (+ its call site `AppFeedback/Views/Settings/SettingsView.swift:77`)
- Create: `AppFeedback/Views/Issues/TriageSuggestionChip.swift`
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift` (+ its call site `AppFeedback/Views/Issues/IssueListView.swift:287`)
- Modify: `AppFeedback/Views/Issues/IssueListView.swift` (toolbar backfill action)
- Modify: task row view in `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift` (AI badge)
- Test: `AppFeedbackTests/TriageSuggestionChipSmokeTests.swift`

This task is view integration; TDD applies to the chip's smoke test, and the rest follows existing view patterns. Read each integration file before editing — parameter threading must match its current style (IssueCardView takes flat optional properties with closure callbacks; follow that).

- [ ] **Step 1: Smoke test for the chip**

```swift
import Testing
import SwiftUI
@testable import AppFeedback

@MainActor
struct TriageSuggestionChipSmokeTests {
    @Test func chipRendersBothSuggestionShapes() {
        let assignRec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                            feedbackNumber: 1, state: TriageState.pending.rawValue)
        assignRec.suggestedTaskNumber = 42
        let createRec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                            feedbackNumber: 2, state: TriageState.pending.rawValue)
        createRec.suggestedTitle = "Fix crash"
        _ = TriageSuggestionChip(record: assignRec, onAccept: {}, onDismiss: {}).body
        _ = TriageSuggestionChip(record: createRec, onAccept: {}, onDismiss: {}).body
    }
}
```

(Instantiating `.body` matches the existing `AttachmentStripViewSmokeTests` pattern; a `TriageVerdictRecord` used without a container must not be saved — construct only.)

- [ ] **Step 2: Run to verify failure**, then implement the chip:

```swift
import SwiftUI

/// One-tap AI triage suggestion shown on a feedback card: assign to an existing
/// task or create a proposed one. Pending records only.
struct TriageSuggestionChip: View {
    let record: TriageVerdictRecord
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var label: String {
        if let n = record.suggestedTaskNumber {
            return "Assign to task #\(n)"
        }
        return "New task: \(record.suggestedTitle ?? "Untitled")"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Add", action: onAccept)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: Integrate** (read each file first; follow its local style):
  - **IssueCardView:** add `var triageSuggestion: TriageVerdictRecord? = nil`, `var onAcceptSuggestion: (() -> Void)? = nil`, `var onDismissSuggestion: (() -> Void)? = nil`; render the chip at the bottom of the card's VStack when `triageSuggestion != nil`.
  - **IssueListView (card call site, line ~287):** read `@Environment(FeedbackTriageCoordinator.self)`; pass `triageSuggestion: coordinator.pendingSuggestion(owner: repoOwner, repo: repoName, number: issue.number)`; `onAcceptSuggestion` runs `Task { try? await coordinator.accept(record:repo:issues:) }` with the current product config and loaded issues (both already available in this view's context — trace how `attachedTasks` gets there and use the same source), then triggers the same post-create refresh path RootView uses; `onDismissSuggestion` calls `coordinator.dismiss(record:)`.
  - **IssueListView toolbar:** add a menu/button "Triage Feedback with AI" → `Task { await coordinator.runBackfill(repo: config, issues: loadedIssues) }`, disabled when `triageSettings.mode == .off || !intelligenceService.availability.isReady || coordinator.isProcessing`; show `ProgressView` with `coordinator.progress` while processing.
  - **IntelligenceSettingsSection:** add `@Bindable var triageSettings: TriageSettings` and a new section (update the `SettingsView.swift:77` call site):

```swift
            Section("Feedback Triage") {
                Picker("Auto-triage new feedback", selection: $triageSettings.mode) {
                    ForEach(TriageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!availability.isReady)
                Text("On-device AI decides whether new feedback is task-worthy, then assigns it to an existing task or proposes a new one. Nothing leaves this device until a task is created or assigned.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
```

  - **ProjectInspectorPanel task row:** where the row renders the task title, append when `coordinator.aiCreatedTaskNumbers(owner:repo:).contains(task.number)`:

```swift
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Created by AI triage")
```

- [ ] **Step 4: Build + full test suite** — `xcodegen generate` (git status first), build both platforms if quick (`AppFeedback_macOS` at minimum), run the full `AppFeedbackTests_macOS` suite: no new failures.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Issues/TriageSuggestionChip.swift AppFeedback/Views/Issues/IssueCardView.swift AppFeedback/Views/Issues/IssueListView.swift AppFeedback/Views/Settings/IntelligenceSettingsSection.swift AppFeedback/Views/Settings/SettingsView.swift AppFeedback/Views/Inspector/ProjectInspectorPanel.swift AppFeedbackTests/TriageSuggestionChipSmokeTests.swift AppFeedback.xcodeproj
git commit -m "feat(triage): add settings picker, suggestion chip, backfill action, and AI badge"
```

---

## Final verification

- [ ] Full `AppFeedbackTests_macOS` run: only the ~11 known Keychain failures.
- [ ] Manual smoke (needs a device/simulator with Apple Intelligence): enable Suggest mode, refresh, confirm a chip appears on actionable feedback and Accept creates/assigns through GitHub.
- [ ] Confirm no `TriageVerdictRecord` rows sync: the model must appear ONLY in `localSchema` in `AppFeedbackApp.swift`.
