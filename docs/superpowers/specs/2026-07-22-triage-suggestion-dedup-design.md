# Triage Create-Suggestion Dedup — Design

**Date:** 2026-07-22
**Status:** Approved

## Summary

Similar feedback items currently produce separate, differently-worded new-task
suggestions. Instead: when triage proposes a new task, first check the repo's
existing pending create-suggestions with the pairwise verifier (the one
component that measured reliably in the 2026-07-22 diagnostics); if one is the
same problem, the new feedback reuses that suggestion's exact title/summary.
Accepting a shared suggestion creates ONE task and attaches every feedback
item that shares it.

## Behavior

1. **Suggestion-time dedup.** When stage 2 yields `createNew` (including
   verify-demotions), the coordinator gathers the repo's pending
   create-suggestions (state `pending`, `suggestedTaskNumber == nil`,
   `suggestedTitle != nil`), most recent first, capped at 5. For each, it asks
   the provider's pairwise verifier: new feedback (title + signal) vs the
   proposed task (`suggestedTitle` + `suggestedSummary` as detail). The first
   `isSameProblem == true` wins: the new record stores the SAME
   `suggestedTitle`/`suggestedSummary` (verbatim — identical title is the
   grouping key). No match → the model's own proposal is stored as today.
   Because records save immediately, within-batch duplicates dedup for free.
2. **Accept-time merge.** Accepting a create-suggestion creates the task for
   the accepted record, then finds all OTHER pending records in the same repo
   with an identical `suggestedTitle`: each is assigned to the new task via
   the existing applier path and marked `accepted` (with `createdTaskNumber`).
   A failed secondary assign leaves that record `pending` but with
   `suggestedTaskNumber` set to the created task — its chip becomes a
   retryable assign suggestion.
3. **Full-auto mode** already dedups within a batch via roster growth;
   suggestion-time dedup applies only to the pending-suggestion path (suggest
   and hybrid-create outcomes).
4. **Verify-call failures** (guardrail/budget/error) during dedup are
   non-fatal: skip that candidate and continue (worst case: a duplicate
   suggestion, today's behavior).

## Components

- `IntelligenceProvider`: new method
  `triageVerify(feedbackTitle: String, signal: String, kind: TriageKind, taskTitle: String, coveredTitles: [String]) async throws -> Bool`
  — exposes the existing pairwise verification session (same instructions and
  `@Generable` verdict as the assign-claim verify; `coveredTitles` carries the
  candidate suggestion's summary line). `MockIntelligenceProvider` gains a
  handler + call record.
- `IntelligenceService`: implementation reusing `buildVerifyPrompt` and
  `triageVerifyInstructions`; internal assign-claim verification refactors to
  call the same core.
- `FeedbackTriageCoordinator`: dedup step in the createNew routing path;
  merge step in `accept`. New store query
  `pendingCreateSuggestions(owner:repo:)` on `TriageVerdictStore`
  (pending + nil task number + non-nil title, newest first).

## Testing

- Coordinator (mocked provider/applier): reuse-on-match (second similar
  feedback stores identical title); no-reuse-on-no-match; cap respected;
  verify-error skips candidate; accept merges all same-title records
  (applier called per extra record, states accepted, createdTaskNumber set);
  failed secondary assign leaves pending record with suggestedTaskNumber set.
- Store: `pendingCreateSuggestions` filtering + ordering.
- Behavioral spot-check via the TRIAGE_DIAG harness (manual).
