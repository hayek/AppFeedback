# Triage Debug Clear Actions — Design

**Date:** 2026-07-22
**Status:** Approved

## Summary

Two `#if DEBUG`-only actions in Settings → Intelligence → Feedback Triage, below
the mode picker, for re-testing the triage pipeline on existing feedback:

1. **Clear Pending Suggestions** — deletes only verdict records in state
   `pending` (the visible chips). Dismissed / not-actionable / skipped /
   auto-applied records survive, so only currently-suggested items re-triage.
2. **Clear All Triage Verdicts** — deletes every `TriageVerdictRecord` across
   all repos. Everything unlinked becomes a fresh triage candidate on the next
   refresh tick or backfill. Local "AI" badges reset (provenance lives in the
   deleted records). Feedback already linked to tasks stays linked on GitHub
   and is skipped by the existing linked-guard.

Per-repo snapshot markers are deliberately KEPT in both actions — clearing them
would re-snapshot the backlog as `preexisting` instead of triaging it.

## Components

- `TriageVerdictStore`: `func deleteAll()` and `func deletePending()`
  (fetch + delete + save; `deletePending` filters `state == TriageState.pending.rawValue`).
- `FeedbackTriageCoordinator`: `func clearAllVerdicts()` /
  `func clearPendingSuggestions()` — thin passthroughs to the store.
- `IntelligenceSettingsSection`: two new optional closure parameters
  (`onClearPendingTriage: (() -> Void)? = nil`,
  `onClearAllTriage: (() -> Void)? = nil`); inside the Feedback Triage section,
  fenced `#if DEBUG`, two buttons (destructive-styled "Clear All Triage
  Verdicts", plain "Clear Pending Suggestions") with a caption
  "Debug: forgets AI triage verdicts so feedback gets triaged again."
  Buttons render only when their closure is non-nil.
- `SettingsView` (`.intelligence` detail case): wires both closures from the
  environment's `FeedbackTriageCoordinator`.

## Testing

- Store unit tests: `deleteAll` removes everything; `deletePending` removes
  only pending records and leaves other states intact.
- Both schemes build; full macOS suite no new failures. DEBUG-only UI is
  covered by the debug build itself.
