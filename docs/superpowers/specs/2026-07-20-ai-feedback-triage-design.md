# AI Feedback Triage — Design

**Date:** 2026-07-20
**Status:** Approved

## Summary

When new feedback arrives, on-device AI (FoundationModels) decides whether it is
task-worthy. If it is, the AI either assigns the feedback to an existing open task
or proposes a new task. Depending on a user setting, outcomes apply automatically
or surface as one-tap suggestions. All AI verdicts stay local to the device;
GitHub is only touched when a task is actually created or assigned.

Out of scope for v1: refining task titles/descriptions with new feedback
(deferred until triage quality is proven), per-product enablement, synced
verdicts.

## Decisions (from brainstorming)

- **Autonomy is a setting** with four modes: Off / Suggest (everything needs
  confirmation) / Hybrid (assigns auto-apply, creates need confirmation) /
  Full auto (everything applies, undoable by normal task edits).
- **Trigger scope:** new feedback as it arrives, plus a manual "Triage feedback
  with AI" backfill action over existing feedback.
- **Persistence:** verdicts and pending suggestions are local-only (SwiftData),
  modeled on `IssueSummaryCache`. Nothing AI-related is written to GitHub except
  real task creates/assigns through the existing `TaskService` paths.
- **Task-worthy:** bug reports, feature requests, usability complaints.
  Not task-worthy: praise, content-free negativity, questions/support requests.
- **Pipeline:** two-stage (classify, then match-or-create) to respect the
  ~4096-token session ceiling (TN3193) and keep each prompt focused.
- **No refinement in v1.**

## Architecture & data flow

### Trigger

`IssueLoaderRegistry.refreshTick()` already funnels fresh loads into
`NotificationService.diffAndNotify`, which computes the set of genuinely-new
feedback (diff against `NotifiedIssueStore`). A new
`FeedbackTriageCoordinator` is invoked at the same point with the new feedback
numbers per repo and enqueues them. The manual backfill action feeds the same
queue with the current product's loaded feedback.

### Per-item pipeline

Skip up front (no AI call) when:

- triage mode is Off, or Apple Intelligence is unavailable
  (`IntelligenceAvailability` gating);
- the feedback number already appears in some task's `feedbackRefs`;
- the verdict store already has a verdict for this feedback (unless the
  backfill action was invoked with an explicit re-run option).

Otherwise:

1. **Stage 1 — worthiness.** `IntelligenceService.triageClassify(feedback)`
   returns a `@Generable` verdict: `isActionable`, `kind`
   (bug / featureRequest / usability), and a one-line `signal` summary.
   Non-actionable → store verdict, stop.
2. **Stage 2 — match or create.** `IntelligenceService.triageMatch(signal,
   roster)` receives a compact roster of open tasks (number + title only) and
   returns `assignTo(number)` or `createNew(title, oneLineDescription)`.
3. **Outcome routing by mode:**
   - *Suggest:* store as pending suggestion; UI offers Accept / Dismiss.
   - *Hybrid:* `assignTo` applies immediately via
     `TaskService.setFeedbackRefs`; `createNew` becomes a pending suggestion.
   - *Full auto:* both apply immediately; creates go through
     `TaskService.createTask(..., feedbackRefs: [n])`, which writes the
     existing "Addresses: #n" block.

### Verdict store

`TriageVerdictStore` (SwiftData, local-only): one record per (repo, feedback
number) — verdict fields, suggestion payload, state
(`pending` / `accepted` / `dismissed` / `autoApplied` / `skipped`), timestamp,
and an `aiCreated` marker for tasks created by auto mode (drives a local "AI"
badge; no label is written to the repo). Dismissed stays dismissed; only the
explicit backfill re-run revisits settled verdicts.

## Components

| Component | Location | Role |
|---|---|---|
| `TriageVerdict`, `TaskSuggestion` | `Services/Intelligence/` | `@Generable` structs with `@Guide` annotations (pattern: `IssueSummary`), plus plain-Swift DTO mirrors for views/tests |
| `TriagePromptBuilder` | `Services/Intelligence/` | Stage-1/stage-2 prompts with token-budget-safe config ladder (pattern: `SummaryPromptBuilder.contextSafeConfigs()`); truncates feedback bodies, caps roster size |
| `IntelligenceService.triageClassify` / `triageMatch` | existing file | New methods on `IntelligenceProvider` + FoundationModels implementation reusing guardrail-fallback and context-retry patterns |
| `FeedbackTriageCoordinator` | `Services/` | `@MainActor` orchestrator: queue, up-front skips, serial processing, mode routing, roster maintenance within a batch |
| `TriageVerdictStore` | `Services/` | SwiftData verdict/suggestion records |
| `TriageSettings` | alongside `IntelligenceSettings` | Mode picker persistence |

## UI

- **Suggestion chip** on feedback rows/detail with a pending suggestion —
  "Suggested: new task 'Fix iPad crash'" or "Suggested: assign to #42" — with
  Accept / Dismiss. Accept routes through the same `TaskService` paths as the
  manual UI; editing before accepting opens `CreateTaskSheet` pre-filled.
- **Local "AI" badge** on tasks the verdict store marks as AI-created.
- **Settings:** one mode picker in the intelligence settings area.
- **Backfill:** toolbar/menu action on the feedback list ("Triage feedback with
  AI") over the current product's unlinked, un-triaged feedback, with progress.

## Error handling & edge cases

- **Guardrail false positives** (known FoundationModels issue): mark verdict
  `skipped`, never auto-retry on refresh; item remains manually triageable.
- **Context overflow:** existing smaller-config retry; stage 2 additionally
  shrinks the roster (most recently updated open tasks first) before giving up.
- **Hallucinated task numbers:** `assignTo` validated against the roster
  actually sent; invalid → stored as a pending `createNew` suggestion, never
  applied.
- **Burst coherence:** serial processing; a task created mid-batch joins the
  roster for subsequent items (five crash reports → one create + four assigns).
- **Auto-apply write failures:** demoted to a pending suggestion with retry
  (pattern: `ProjectInspectorModel` optimistic-creation state machine).
- **Multi-device race (full auto):** before applying, re-check freshly-loaded
  issues for an existing `feedbackRefs` link and skip if present. A small
  window remains; accepted v1 trade-off (worst case: a duplicate task the user
  deletes).

## Testing

In `AppFeedbackTests_macOS`, via DTO mirrors and mocked
`IntelligenceProvider` / `IssueWriting` (no FoundationModels, no Keychain):

- **Coordinator:** mode routing per setting; skip-already-linked;
  skip-already-triaged; serial batch with roster growth; invalid-task-number
  demotion; write-failure demotion; availability/off gating.
- **Prompt builder:** body truncation, roster capping, config laddering.
- **Verdict store:** state transitions (pending → accepted/dismissed), re-run
  only via explicit backfill.
