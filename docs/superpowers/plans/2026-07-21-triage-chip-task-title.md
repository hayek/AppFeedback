# Triage Chip Task Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Assign-type triage chips show the target task's title inline plus an icon-only button that opens the task.

**Architecture:** Pure view-layer threading: `IssueListView.issueCard(for:)` looks the suggested `TaskItem` up in `viewModel.tasks` and passes `title` + an open closure through two new optional `IssueCardView` properties into `TriageSuggestionChip`. No model, coordinator, or store changes.

**Tech Stack:** SwiftUI, Swift Testing (smoke test).

**Spec:** `docs/superpowers/specs/2026-07-21-triage-chip-task-title-design.md`

## Global Constraints

- All new chip/card properties are optional with `nil` defaults — existing call sites and tests must keep compiling unchanged.
- Fallback: suggested task not found in `viewModel.tasks` → label stays `Assign to task #N`, no open button.
- Open action must reuse the existing `onOpenTask: ((TaskItem) -> Void)?` path (identical behavior to clicking a task tag), and mirror the task-tag pattern of calling `onInteract?()` (mark-seen) before opening — see `IssueCardView.swift:307`.
- Test target `AppFeedbackTests_macOS`; run `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/TriageSuggestionChipSmokeTests 2>&1 | tail -15` (xcodebuild is ground truth, not zcode /api/test). No new files → no xcodegen run needed.
- Both schemes must build (iOS: `-scheme AppFeedback_iOS -destination 'generic/platform=iOS'`).
- Commit: stage only the four touched files; end message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Title + open button on assign chips

**Files:**
- Modify: `AppFeedback/Views/Issues/TriageSuggestionChip.swift`
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift` (new properties near line 91; chip render near line 409)
- Modify: `AppFeedback/Views/Issues/IssueListView.swift` (`issueCard(for:)`, near line 348)
- Test: `AppFeedbackTests/TriageSuggestionChipSmokeTests.swift` (extend)

**Interfaces:**
- Consumes: `TriageVerdictRecord.suggestedTaskNumber: Int?`; `IssueListViewModel.tasks: [TaskItem]` (`TaskItem.number`, `.title`); existing `IssueCardView.onOpenTask: ((TaskItem) -> Void)?` and `onInteract: (() -> Void)?`.
- Produces: `TriageSuggestionChip(record:taskTitle:isAccepting:onAccept:onDismiss:onOpenTask:)` (new optionals `taskTitle: String? = nil`, `onOpenTask: (() -> Void)? = nil`); `IssueCardView` properties `suggestedTaskTitle: String? = nil`, `onOpenSuggestedTask: (() -> Void)? = nil`.

- [ ] **Step 1: Write the failing test** — append to `TriageSuggestionChipSmokeTests`:

```swift
    @Test func assignChipWithTitleAndOpenButtonRenders() {
        let rec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                      feedbackNumber: 3, state: TriageState.pending.rawValue)
        rec.suggestedTaskNumber = 511
        let chip = TriageSuggestionChip(
            record: rec,
            taskTitle: "Unable to log in to the app",
            onAccept: {}, onDismiss: {},
            onOpenTask: {}
        )
        _ = chip.body
    }
```

- [ ] **Step 2: Run to verify failure** — the test command above. Expected: BUILD FAILURE (`extra arguments 'taskTitle'/'onOpenTask'`).

- [ ] **Step 3: Implement**

`TriageSuggestionChip.swift` — full new body of the struct (property order matters for the memberwise init used by the test):

```swift
/// One-tap AI triage suggestion shown on a feedback card: assign to an existing
/// task or create a proposed one. Pending records only.
struct TriageSuggestionChip: View {
    let record: TriageVerdictRecord
    /// Title of the assign-target task, when it exists in the loaded task list.
    /// nil (task deleted / create-new suggestion) falls back to the number-only label.
    var taskTitle: String? = nil
    /// True while this suggestion's accept is in flight; disables Add and shows a spinner
    /// in its place so a double-tap can't fire two GitHub creates/assigns.
    var isAccepting: Bool = false
    let onAccept: () -> Void
    let onDismiss: () -> Void
    /// Opens the assign-target task. nil hides the open button.
    var onOpenTask: (() -> Void)? = nil

    private var label: String {
        if let n = record.suggestedTaskNumber {
            if let taskTitle {
                return "Assign to #\(n) · \(taskTitle)"
            }
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
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let onOpenTask {
                Button(action: onOpenTask) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Open task")
            }
            if isAccepting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button("Add", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(isAccepting)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

`IssueCardView.swift` — add two properties directly after `onDismissSuggestion` (line ~96):

```swift
    /// Title of the suggestion's assign-target task (shown inline in the chip).
    var suggestedTaskTitle: String? = nil
    /// Opens the suggestion's assign-target task; nil hides the chip's open button.
    var onOpenSuggestedTask: (() -> Void)? = nil
```

and update the chip render (line ~409; mirror task tags' `onInteract` mark-seen composition from line ~307):

```swift
                    if let triageSuggestion {
                        TriageSuggestionChip(
                            record: triageSuggestion,
                            taskTitle: suggestedTaskTitle,
                            isAccepting: isAcceptingSuggestion,
                            onAccept: { onAcceptSuggestion?() },
                            onDismiss: { onDismissSuggestion?() },
                            onOpenTask: onOpenSuggestedTask.map { open in
                                { onInteract?(); open() }
                            }
                        )
                    }
```

(Keep any modifiers currently attached to the chip in that block unchanged — read the existing block first; only the argument list grows.)

`IssueListView.swift` — in `issueCard(for:)` (line ~347), after the existing `let suggestion = ...` line add:

```swift
        let suggestedTask = suggestion?.suggestedTaskNumber.flatMap { n in
            viewModel.tasks.first(where: { $0.number == n })
        }
```

and add to the `IssueCardView(...)` argument list, after `onDismissSuggestion:`:

```swift
            suggestedTaskTitle: suggestedTask?.title,
            onOpenSuggestedTask: suggestedTask.flatMap { task in
                onOpenTask.map { open in { open(task) } }
            }
```

- [ ] **Step 4: Verify**

- Chip smoke tests pass (all variants including the new one).
- Full `AppFeedbackTests_macOS` suite: no new failures.
- Both schemes build.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Issues/TriageSuggestionChip.swift AppFeedback/Views/Issues/IssueCardView.swift AppFeedback/Views/Issues/IssueListView.swift AppFeedbackTests/TriageSuggestionChipSmokeTests.swift
git commit -m "feat(triage): show assign-target task title and open button on suggestion chip"
```

---

## Final verification

- [ ] Manual: an assign suggestion shows "Assign to #N · <title>", the open icon opens the task detail like a task tag does, long titles truncate, and a create-new suggestion looks unchanged.
