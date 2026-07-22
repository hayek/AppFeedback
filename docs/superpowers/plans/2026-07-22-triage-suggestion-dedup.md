# Triage Create-Suggestion Dedup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Similar feedback shares one create-suggestion (checked by the pairwise verifier), and accepting it creates one task with every sharing feedback attached.

**Architecture:** Expose the existing pairwise verification as a provider method (`triageVerify`); the coordinator consults it against the repo's pending create-suggestions before recording a new proposal (identical title = grouping key), and `accept` merges all same-title pending records into the created task via the existing applier.

**Tech Stack:** SwiftUI/SwiftData app code, FoundationModels (fenced), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-22-triage-suggestion-dedup-design.md`
**Builds on:** commit `31b92a1` (pairwise verify stage: `triageVerifyInstructions`, `TriagePairVerifyDecision`, `TriagePromptBuilder.buildVerifyPrompt`, `verifyAssign` in `IntelligenceService`).

## Global Constraints

- Dedup applies only to createNew outcomes that land as PENDING suggestions (suggest mode + hybrid creates); fullAuto keeps its roster-growth dedup. Cap: 5 most recent pending candidates. Verify errors skip the candidate (worst case = today's duplicate).
- Identical `suggestedTitle` is the grouping key — reuse must copy the candidate's title VERBATIM.
- Accept-time merge failure semantics: the failed record stays `pending` with `suggestedTaskNumber` set to the created task (its chip becomes a retryable assign suggestion).
- Protocol change ripples: `IntelligenceProvider`, `IntelligenceService`, `MockIntelligenceProvider` — mock default returns `false` so all existing coordinator tests keep their behavior.
- Test target `AppFeedbackTests_macOS`; run focused classes via `-only-testing`; full suite once before commit; both schemes build. No new files → no xcodegen.
- Commit: stage only touched files; trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: triageVerify API + coordinator dedup + accept merge

**Files:**
- Modify: `AppFeedback/Services/Intelligence/IntelligenceProvider.swift`
- Modify: `AppFeedback/Services/Intelligence/IntelligenceService.swift` (add `triageVerify`/`runTriageVerify`; refactor `verifyAssign` at lines ~236-253 onto the shared core)
- Modify: `AppFeedback/Services/TriageVerdictStore.swift` (add `pendingCreateSuggestions`)
- Modify: `AppFeedback/Services/FeedbackTriageCoordinator.swift` (`route` dedup + `accept` merge)
- Modify: `AppFeedbackTests/MockIntelligenceProvider.swift`, `AppFeedbackTests/Fakes/MockTriageApplier.swift`
- Test: `AppFeedbackTests/TriageVerdictStoreTests.swift`, `AppFeedbackTests/FeedbackTriageCoordinatorTests.swift` (extend)

**Interfaces:**
- Consumes: `triageVerifyInstructions`, `TriagePairVerifyDecision`, `TriagePromptBuilder.buildVerifyPrompt(feedbackTitle:signal:kind:task:)`, `TriageTaskRosterEntry(number:title:coveredFeedbackTitles:)`, `TaskService.body(prose:feedbackRefs:)`, `TaskItem` memberwise init, coordinator harness from existing tests.
- Produces: `IntelligenceProvider.triageVerify(feedbackTitle:signal:kind:candidate:) async throws -> Bool`; `TriageVerdictStore.pendingCreateSuggestions(owner:repo:) -> [TriageVerdictRecord]`; `MockIntelligenceProvider.triageVerifyHandler` + `triageVerifyCalls`; `MockTriageApplier.assignErrorToThrow`.

- [ ] **Step 1: Write the failing tests**

Append to `TriageVerdictStoreTests`:

```swift
    @Test func pendingCreateSuggestionsFiltersAndOrdersNewestFirst() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.pending.rawValue; $0.suggestedTitle = "Older"
        }
        store.upsert(owner: "o", repo: "r", number: 2) {
            $0.state = TriageState.pending.rawValue; $0.suggestedTitle = "Newer"
        }
        store.upsert(owner: "o", repo: "r", number: 3) {   // pending ASSIGN — excluded
            $0.state = TriageState.pending.rawValue; $0.suggestedTaskNumber = 42
        }
        store.upsert(owner: "o", repo: "r", number: 4) {   // accepted — excluded
            $0.state = TriageState.accepted.rawValue; $0.suggestedTitle = "Done"
        }
        let result = store.pendingCreateSuggestions(owner: "o", repo: "r")
        #expect(result.map(\.suggestedTitle) == ["Newer", "Older"])
    }
```

Append to `FeedbackTriageCoordinatorTests` (follow the file's existing `Harness` style; helpers referenced below — `seedPendingCreate`, actionable classify handler — follow existing fixture patterns in the file):

```swift
    @Test func dedupReusesPendingSuggestionTitleWhenVerifierAgrees() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()
        h.store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.pending.rawValue
            $0.suggestedTitle = "Add Claude Design usage"
            $0.suggestedSummary = "Show Claude Design usage in the app."
        }
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: true, kind: .featureRequest, signal: "wants design tokens usage")
        }
        h.provider.triageMatchHandler = { _, _, _, _ in .createNew(title: "Add Design tokens usage", summary: "s") }
        h.provider.triageVerifyHandler = { _, _, _, _ in true }
        let feedback = FeedbackIssue.triageTestFixture(number: 2, title: "Design tokens", body: "add design tokens usage")
        await h.coordinator.processLoaded([(h.repo, [feedback])])
        let rec = h.store.record(owner: "o", repo: "r", number: 2)
        #expect(rec?.suggestedTitle == "Add Claude Design usage")   // verbatim reuse
        #expect(rec?.state == TriageState.pending.rawValue)
    }

    @Test func dedupKeepsOwnTitleWhenVerifierDisagrees() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()
        h.store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.pending.rawValue
            $0.suggestedTitle = "Add Claude Design usage"
        }
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: true, kind: .featureRequest, signal: "s")
        }
        h.provider.triageMatchHandler = { _, _, _, _ in .createNew(title: "Own title", summary: "s") }
        h.provider.triageVerifyHandler = { _, _, _, _ in false }
        let feedback = FeedbackIssue.triageTestFixture(number: 2, title: "t", body: "b")
        await h.coordinator.processLoaded([(h.repo, [feedback])])
        #expect(h.store.record(owner: "o", repo: "r", number: 2)?.suggestedTitle == "Own title")
    }

    @Test func dedupCapsCandidatesAtFiveAndSkipsOnError() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()
        for n in 1...7 {
            h.store.upsert(owner: "o", repo: "r", number: n) {
                $0.state = TriageState.pending.rawValue; $0.suggestedTitle = "P\(n)"
            }
        }
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: true, kind: .bug, signal: "s")
        }
        h.provider.triageMatchHandler = { _, _, _, _ in .createNew(title: "Own", summary: "s") }
        h.provider.triageVerifyHandler = { _, _, _, _ in throw IntelligenceError.guardrailBlocked }
        let feedback = FeedbackIssue.triageTestFixture(number: 99, title: "t", body: "b")
        await h.coordinator.processLoaded([(h.repo, [feedback])])
        #expect(h.provider.triageVerifyCalls.count == 5)   // capped
        #expect(h.store.record(owner: "o", repo: "r", number: 99)?.suggestedTitle == "Own")   // errors skip
    }

    @Test func acceptMergesSameTitlePendingRecords() async throws {
        let h = try Harness(mode: .suggest)
        let title = "Add Claude Design usage"
        let rec1 = h.store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.pending.rawValue; $0.suggestedTitle = title; $0.suggestedSummary = "s"
        }
        h.store.upsert(owner: "o", repo: "r", number: 2) {
            $0.state = TriageState.pending.rawValue; $0.suggestedTitle = title
        }
        try await h.coordinator.accept(record: rec1, repo: h.repo, issues: [])
        #expect(h.applier.creates.count == 1)
        #expect(h.applier.assigns.map(\.feedback) == [2])
        let rec2 = h.store.record(owner: "o", repo: "r", number: 2)
        #expect(rec2?.state == TriageState.accepted.rawValue)
        #expect(rec2?.createdTaskNumber == h.applier.nextCreatedNumber)
    }

    @Test func acceptMergeFailureLeavesRetryableAssign() async throws {
        let h = try Harness(mode: .suggest)
        let title = "Add Claude Design usage"
        let rec1 = h.store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.pending.rawValue; $0.suggestedTitle = title
        }
        h.store.upsert(owner: "o", repo: "r", number: 2) {
            $0.state = TriageState.pending.rawValue; $0.suggestedTitle = title
        }
        h.applier.assignErrorToThrow = IntelligenceError.empty
        try await h.coordinator.accept(record: rec1, repo: h.repo, issues: [])
        let rec2 = h.store.record(owner: "o", repo: "r", number: 2)
        #expect(rec2?.state == TriageState.pending.rawValue)
        #expect(rec2?.suggestedTaskNumber == h.applier.nextCreatedNumber)   // retryable assign chip
    }
```

(Adapt `upsert`'s `@discardableResult` return usage and handler tuple shapes to the file's actuals; assertions stay as written. If `Harness` lacks a way to reach `applier.nextCreatedNumber` post-create, read `MockTriageApplier`'s counter semantics and assert the concrete number instead.)

- [ ] **Step 2: Run to verify failure** — `-only-testing:AppFeedbackTests_macOS/TriageVerdictStoreTests -only-testing:AppFeedbackTests_macOS/FeedbackTriageCoordinatorTests`. Expected: BUILD FAILURE (`pendingCreateSuggestions` / `triageVerifyHandler` / `assignErrorToThrow` not found).

- [ ] **Step 3: Implement**

`IntelligenceProvider.swift` — add to the protocol:

```swift
    /// Pairwise dedup check: is this feedback the same specific problem as `candidate`
    /// (an existing task or a pending task proposal)?
    func triageVerify(feedbackTitle: String, signal: String, kind: TriageKind,
                      candidate: TriageTaskRosterEntry) async throws -> Bool
```

`IntelligenceService.swift` — public method (same gate shape as the others):

```swift
    nonisolated func triageVerify(feedbackTitle: String, signal: String, kind: TriageKind,
                                  candidate: TriageTaskRosterEntry) async throws -> Bool {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return await runTriageVerify(feedbackTitle: feedbackTitle, signal: signal,
                                         kind: kind, candidate: candidate)
        }
        #endif
        throw IntelligenceError.unavailable
    }
```

Fenced extension — add `runTriageVerify` and refactor `verifyAssign` onto it (drop `verifyAssign`'s now-unneeded `model` parameter and update its call site):

```swift
    /// Shared pairwise-verification core. Returns false on ANY generation failure —
    /// callers treat verification errors as "no match" (conservative for assigns,
    /// opportunistic for dedup).
    fileprivate func runTriageVerify(feedbackTitle: String, signal: String, kind: TriageKind,
                                     candidate: TriageTaskRosterEntry) async -> Bool {
        let instructions = await MainActor.run { triageVerifyInstructions }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let prompt = TriagePromptBuilder.buildVerifyPrompt(
            feedbackTitle: feedbackTitle, signal: signal, kind: kind, task: candidate)
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: TriagePairVerifyDecision.self)
                .content.isSameProblem
        } catch {
            return false
        }
    }

    private func verifyAssign(_ decision: TriageDecisionDTO, task: TriageTaskRosterEntry,
                              feedbackTitle: String, signal: String,
                              kind: TriageKind, fallbackTitle: String) async -> TriageDecisionDTO {
        if await runTriageVerify(feedbackTitle: feedbackTitle, signal: signal, kind: kind, candidate: task) {
            return decision
        }
        return .createNew(title: fallbackTitle, summary: signal)
    }
```

(`runTriageMatch`'s `verifyAssign` call drops the `model:` argument and its `try` if no longer throwing.)

`TriageVerdictStore.swift` — add:

```swift
    /// Pending create-suggestions (no target task, has a proposed title), newest
    /// first — the dedup candidates for a newly proposed task.
    func pendingCreateSuggestions(owner: String, repo: String) -> [TriageVerdictRecord] {
        let raw = TriageState.pending.rawValue
        let descriptor = FetchDescriptor<TriageVerdictRecord>(
            predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo && $0.state == raw
                    && $0.suggestedTaskNumber == nil && $0.suggestedTitle != nil
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
```

`FeedbackTriageCoordinator.swift`:

In `route(...)`, first line becomes a shadowed mutable copy plus the dedup step (before `recordSuggestion` is defined):

```swift
        var decision = decision
        // Suggestion dedup: a createNew that will land as a pending suggestion first
        // checks the repo's existing pending proposals; the same problem reuses the
        // existing title VERBATIM (identical title = accept-time merge grouping key).
        if case .createNew(_, let summary) = decision, settings.mode != .fullAuto {
            if let reused = await dedupCandidate(for: issue, repo: repo,
                                                 classification: classification, kind: kind) {
                decision = .createNew(title: reused.title, summary: reused.summary ?? summary)
            }
        }
```

New private helper:

```swift
    /// Returns an existing pending proposal the verifier judges to be the same
    /// problem, capped at the 5 most recent. Verification errors skip the candidate
    /// (worst case: a duplicate suggestion — the old behavior).
    private func dedupCandidate(for issue: FeedbackIssue, repo: ProductConfig,
                                classification: TriageClassificationDTO,
                                kind: TriageKind) async -> (title: String, summary: String?)? {
        let candidates = store.pendingCreateSuggestions(owner: repo.owner, repo: repo.repo)
            .filter { $0.feedbackNumber != issue.number }
            .prefix(5)
        for candidate in candidates {
            guard let title = candidate.suggestedTitle else { continue }
            let entry = TriageTaskRosterEntry(
                number: 0, title: title,
                coveredFeedbackTitles: candidate.suggestedSummary.map { [String($0.prefix(60))] } ?? [])
            if (try? await provider.triageVerify(feedbackTitle: issue.title,
                                                 signal: classification.signal,
                                                 kind: kind, candidate: entry)) == true {
                return (title, candidate.suggestedSummary)
            }
        }
        return nil
    }
```

`accept(...)` — create branch grows the merge; new helper:

```swift
    /// Applies a pending suggestion (chip Accept).
    func accept(record: TriageVerdictRecord, repo: ProductConfig, issues: [FeedbackIssue]) async throws {
        let tasks = issues.filter(TaskItem.isTask).map(TaskItem.init(issue:))
        if let n = record.suggestedTaskNumber, let task = tasks.first(where: { $0.number == n }) {
            try await applier.assign(feedbackNumber: record.feedbackNumber, to: task, in: repo)
            store.setState(record, .accepted)
        } else if let title = record.suggestedTitle {
            let created = try await applier.createTask(
                in: repo, title: title, summary: record.suggestedSummary ?? "",
                feedbackNumber: record.feedbackNumber)
            record.createdTaskNumber = created
            store.setState(record, .accepted)
            await mergeSameTitlePending(intoTask: created, title: title,
                                        summary: record.suggestedSummary ?? "",
                                        acceptedFeedback: record.feedbackNumber, repo: repo)
        } else {
            throw IntelligenceError.empty   // malformed record: nothing to apply
        }
    }

    /// Accept-time merge: every other pending record sharing the accepted proposal's
    /// exact title is attached to the created task. A failed attach leaves the record
    /// pending but pointed at the created task — its chip becomes a retryable assign.
    private func mergeSameTitlePending(intoTask created: Int, title: String, summary: String,
                                       acceptedFeedback: Int, repo: ProductConfig) async {
        let sameTitle = store.pendingCreateSuggestions(owner: repo.owner, repo: repo.repo)
            .filter { $0.suggestedTitle == title && $0.feedbackNumber != acceptedFeedback }
        guard !sameTitle.isEmpty else { return }
        var refs = [acceptedFeedback]   // accumulate so each attach carries prior ones
        for other in sameTitle {
            let optimistic = TaskItem(
                number: created, title: title,
                body: TaskService.body(prose: summary, feedbackRefs: refs),
                feedbackRefs: refs, status: .todo, priority: .med,
                milestoneTitle: nil, isClosed: false)
            do {
                try await applier.assign(feedbackNumber: other.feedbackNumber, to: optimistic, in: repo)
                refs.append(other.feedbackNumber)
                other.createdTaskNumber = created
                store.setState(other, .accepted)
            } catch {
                other.suggestedTaskNumber = created
                store.setState(other, .pending)
            }
        }
    }
```

`MockIntelligenceProvider.swift` — add (default `false` keeps existing tests inert):

```swift
    var triageVerifyHandler: (String, String, TriageKind, TriageTaskRosterEntry) async throws -> Bool = { _, _, _, _ in false }
    private(set) var triageVerifyCalls: [(feedbackTitle: String, candidate: TriageTaskRosterEntry)] = []

    func triageVerify(feedbackTitle: String, signal: String, kind: TriageKind,
                      candidate: TriageTaskRosterEntry) async throws -> Bool {
        await MainActor.run { self.triageVerifyCalls.append((feedbackTitle, candidate)) }
        return try await triageVerifyHandler(feedbackTitle, signal, kind, candidate)
    }
```

`MockTriageApplier.swift` — add `var assignErrorToThrow: Error?`, thrown at the top of `assign` (in addition to the existing `errorToThrow`).

- [ ] **Step 4: Verify** — focused classes pass; full suite no new failures; both schemes build.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceProvider.swift AppFeedback/Services/Intelligence/IntelligenceService.swift AppFeedback/Services/TriageVerdictStore.swift AppFeedback/Services/FeedbackTriageCoordinator.swift AppFeedbackTests/MockIntelligenceProvider.swift AppFeedbackTests/Fakes/MockTriageApplier.swift AppFeedbackTests/TriageVerdictStoreTests.swift AppFeedbackTests/FeedbackTriageCoordinatorTests.swift
git commit -m "feat(triage): dedup create-suggestions via pairwise verifier, merge on accept"
```

---

## Final verification

- [ ] Manual (debug build): clear verdicts, backfill — two similar feedback items now show the SAME "New task: …" chip; accepting one creates a single task with both feedback attached.
