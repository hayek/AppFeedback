# Triage Chip: Task Title + Open Button — Design

**Date:** 2026-07-21
**Status:** Approved

## Summary

Assign-type triage suggestions currently read "Assign to task #511" — opaque
without knowing the task. Show the target task's title inline and add an
icon-only button that opens the task, reusing the task-tag open affordance.

## Behavior

- **Assign chips:** label becomes `Assign to #511 · <task title>` — single
  line, `.lineLimit(1)` + `.truncationMode(.tail)`. Between the label and the
  Add button, an icon-only borderless button (`arrow.up.forward.square`,
  `.mini` control size, `.help("Open task")`) opens the task.
- **Open action** routes through the existing `onOpenTask: ((TaskItem) -> Void)?`
  path `IssueListView` already uses for task tags — identical behavior to
  clicking a task tag.
- **Fallback:** if the suggested task number is not found in
  `viewModel.tasks` (task deleted/closed since triage), the label stays
  `Assign to task #511` and no open button renders.
- **Create-new chips:** unchanged. **Dismiss/Add/in-flight behavior:** unchanged.

## Components

- `TriageSuggestionChip` (`AppFeedback/Views/Issues/TriageSuggestionChip.swift`):
  new optional properties `taskTitle: String? = nil`,
  `onOpenTask: (() -> Void)? = nil` (defaulted — existing call sites and the
  smoke test keep compiling). Label logic: assign + title → number-dot-title;
  assign without title → current text; create-new → current text.
- `IssueListView` chip call site: look up
  `viewModel.tasks.first(where: { $0.number == record.suggestedTaskNumber })`;
  pass `taskTitle: task?.title` and, when the task exists and the view's
  `onOpenTask` closure is set, `onOpenTask: { onOpenTask?(task) }`.

## Testing

- Extend `TriageSuggestionChipSmokeTests`: a variant with `taskTitle` +
  `onOpenTask` set renders (`.body` evaluation), and the existing variants
  still render.
- Both schemes build; full macOS suite no new failures.
