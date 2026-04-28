# Apple Intelligence (Foundation Models) Integration

**Date:** 2026-04-28
**Status:** Approved design — ready for implementation plan

## Overview

Add two on-device intelligence features powered by the Foundation Models framework:

1. **Unread summary** — auto-generated headline + themed bullets summarizing unread issues for the current sidebar selection. Lives in a collapsible card below the filter bar.
2. **Per-issue translation** — non-target-language issues (title + body) translated to the user's chosen language, with a per-card "Show original / Show translation" toggle.

Both features are gated to **macOS 26 / iOS 26+** via `#available` and `SystemLanguageModel.default.availability`. On unsupported configurations the summary view is hidden; non-target-language cards show a one-line "Apple Intelligence required to translate" hint. Settings always show the current availability status.

## Decisions

| Question | Choice |
|---|---|
| Summary scope | Follows current sidebar selection; regenerates as selection / unread set changes |
| Summary trigger | Automatic (debounced) |
| Summary format | 1-line headline + 3–5 themed bullets, each with an issue count |
| Summary skip threshold | Skip when fewer than 2 unread issues |
| Summary view | Collapsible card below `FilterBarView`; collapse state persisted per selection |
| Translation scope | Title + body of each issue card (and the summary itself if non-target-language) |
| Translation toggle | Per-issue text button ("Show original" / "Show translation") |
| Target language | Picker in Settings; defaults to system locale; on by default |
| Detection | `NLLanguageRecognizer` (cheap, OS-native, all OS versions) |
| Persistence | Translations persisted on `CachedIssue` (SwiftData); summaries regenerated (in-memory only) |
| Service shape | One `IntelligenceService` actor for both features |
| Translation timing | Proactive background after each issue fetch |
| Unavailability UX | Hide summary view; per-card hint when a non-target-language issue can't be translated; Settings shows live status |

## Architecture

### New files

- `Services/Intelligence/IntelligenceService.swift` — `actor`. Single entry point. Holds an observable `availability: ModelAvailability`, plus two `LanguageModelSession`s (summary + translation) so contexts don't bleed between unrelated tasks. Public API:
  - `func summarize(issues: [FeedbackIssue], targetLanguage: Locale.Language) async throws -> IssueSummary`
  - `func translate(text: String, from: String?, to: Locale.Language) async throws -> String`
- `Services/Intelligence/LanguageDetector.swift` — sync wrapper around `NLLanguageRecognizer`.
- `Services/Intelligence/IssueSummary.swift` — `@Generable` value type: `headline: String`, `bullets: [Bullet]` where `Bullet = { text: String, issueCount: Int }`.
- `Services/Intelligence/IntelligenceSettings.swift` — `@Observable` store backed by `UserDefaults` + iCloud KVS (matches existing settings pattern). Holds `translationEnabled: Bool`, `targetLanguage: Locale.Language`.
- `ViewModels/UnreadSummaryViewModel.swift` — owns summary lifecycle for current selection. Subscribes to the unread set on `IssueListViewModel`, debounces ~500ms, calls into `IntelligenceService`, exposes `state: SummaryState` (`.idle / .loading / .ready(IssueSummary) / .skipped / .unavailable / .failed`).
- `Views/Issues/UnreadSummaryView.swift` — collapsible card. Collapse state persisted per selection via `@AppStorage`.
- `Views/Settings/IntelligenceSettingsSection.swift` — new section in the existing Settings window.

### Changed files

- `Models/CachedIssue.swift` — add optional fields: `detectedLanguageCode: String?`, `translatedTitle: String?`, `translatedBody: String?`, `translationTargetLanguage: String?`. Additive SwiftData migration.
- `Models/FeedbackIssue.swift` — add the same translation fields as transient state plus `displayedTitle(translated: Bool)` / `displayedBody(translated: Bool)` helpers.
- `ViewModels/IssueListViewModel.swift` — after each issue load/refresh, queue background translation tasks for non-target-language issues lacking cached translations.
- `Views/Issues/IssueCardView.swift` — when a translation exists, render translated text by default with a "Show original" text button; tapping toggles a per-card `@State var showOriginal: Bool`. When the feature is unavailable but a non-target-language issue is detected, show "Apple Intelligence required to translate".
- `Views/Issues/IssueListView.swift` — insert `UnreadSummaryView` between `FilterBarView` and the issue list.

## Data Flow

### Translation pipeline

```
IssueLoader fetches issues
  → IssueListViewModel updates list
  → For each issue without cached translation matching targetLanguage:
      LanguageDetector.detect(title + body)
      if detected ≠ targetLanguage && availability == .available:
        Task(priority: .utility) {
          translated = await IntelligenceService.translate(...)
          write to CachedIssue (SwiftData)
          mutate FeedbackIssue.translatedTitle/Body
        }
  → IssueCardView observes and re-renders
```

`IntelligenceService` actor serializes translation calls. All needed translations are kicked off as separate tasks and queue inside the actor. Selection change does **not** cancel in-flight translations (results are persisted and remain useful); it cancels and restarts the **summary** task only.

### Summary pipeline

```
IssueListViewModel.unreadIssues changes
  → UnreadSummaryViewModel debounces 500ms
  → if count < 2 → state = .skipped (view hides)
  → if availability ≠ .available → state = .unavailable (view hides)
  → else state = .loading
       summary = await IntelligenceService.summarize(unreadIssues, targetLanguage)
       state = .ready(summary)
  → cancel + restart on next change
```

Summarization uses **guided generation** with `@Generable IssueSummary` so structured output is returned without prose parsing. Input is a compact list of `(title, first 200 chars of body, label names)` per issue. Capped at ~30 unread issues; selections with more get a "+N more" note in the prompt.

### Availability

`IntelligenceService` reads `SystemLanguageModel.default.availability` at init and observes changes. The Intelligence Settings section shows the live status:

- ✅ Apple Intelligence ready
- ⏳ Model downloading… (`.unavailable(.modelNotReady)`)
- ⚠️ Apple Intelligence not enabled — "Open System Settings" button (deep link to `x-apple.systempreferences:com.apple.AppleIntelligenceSettings`)
- ⚠️ Not supported on this device
- ⚠️ Requires macOS 26 or later (when `#available` check fails)

## Settings UI

New "Intelligence" section in the existing Settings window:

- **Status row** — icon + text per the availability table above.
- **Translation toggle** — "Translate non-English issues" (default on; disabled with explanatory text when status is not ready).
- **Target language picker** — defaults to the system locale's language; choices are a curated list of common locales (English, Spanish, French, German, Japanese, Simplified Chinese, Portuguese, …) plus an "Other…" path that surfaces all `Locale.Language` known identifiers. Changing the target invalidates all cached translations (`translatedTitle/Body/translationTargetLanguage` cleared); visible cards re-translate immediately, off-screen ones lazily.

## Error Handling & Edge Cases

**Errors:**

- `LanguageModelSession` errors → logged via existing `ActivityLog`. Per-issue translation errors leave the original text in place; no UI noise.
- Summary errors → `state = .failed` with an inline "Couldn't generate summary — Retry" button.
- `.guardrailViolation` on summarization → fall back to a plain "X unread issues across N apps" headline with no bullets.
- `Task` cancellation is silent.

**Edge cases:**

- **Selection changes mid-summary** — current summary task cancelled; new state is `.loading` until new summary lands.
- **Issue marked read** — debounced; if count drops below 2 the card hides via `.skipped`.
- **Target language change** — clear all `translatedTitle/Body/translationTargetLanguage` columns; visible cards re-translate immediately, others lazily.
- **Mixed-language body** (English title, Japanese body) — detect title and body independently; translate only the parts that need it.
- **Code blocks and stack traces** — fenced code blocks (` ``` `…` ``` `) and 4-space-indented blocks are stripped before being sent to the model and reinserted afterwards.
- **Empty body** — translate title only.

## Testing

- `LanguageDetectorTests` — fixture strings in EN/ES/JA/AR; assert detected language codes.
- `IntelligenceServiceTests` — `IntelligenceService` is fronted by a protocol so tests substitute a `MockIntelligenceProvider`. Verify summarization input shape (issue cap, "+N more" suffix, code-block stripping) and translation cache key behavior.
- `UnreadSummaryViewModelTests` — using the mock provider, verify debounce, skip-when-<2, cancellation on selection change, and state transitions.
- `IssueListViewModel` translation-pipeline test — verify only non-target-language issues are queued and results persist to `CachedIssue`.
- No live Foundation Models calls in tests (would require Apple Silicon + macOS 26 + Apple Intelligence enabled in CI).

## Out of Scope (for now)

- Translating issue comments / replies.
- Per-app or per-repo summary opt-out.
- Custom summary styles / prompts in Settings.
- Use of Foundation Models for any feature beyond summary + translation.
