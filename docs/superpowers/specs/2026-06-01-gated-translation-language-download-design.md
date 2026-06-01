# User-gated language downloads for translation fallback

**Date:** 2026-06-01
**Status:** Approved, pending implementation plan

## Problem

When an issue is routed to the Apple Translation-framework fallback (because the
on-device Foundation Models translator refused with `unsupportedLanguageOrLocale`
or a guardrail false-positive), `TranslationFallbackHost` creates a
`TranslationSession` immediately. If the source/target language pair is *supported
but not yet downloaded*, the first `session.translate(...)` call makes the
framework auto-present its system "Download Languages to Translate" sheet —
unprompted, the moment such an issue scrolls into the pipeline.

We want the download to be **user-initiated**: surface an inline affordance under
the affected feedback, and only present the system sheet when the user taps it.

## Key technical fact

`LanguageAvailability().status(from:to:)` returns three states; the current code
(`TranslationFallbackHost.swift:44`) only special-cases `.unsupported`:

- `.installed` — both languages on-device; `translate()` runs silently.
- `.supported` — supported but **not downloaded**; `translate()` auto-presents the
  system download sheet. (Returned when *either* source or target is missing — the
  sheet then lists every missing language for the pair, so one affordance covers it.)
- `.unsupported` — not supported; dropped/blacklisted.

`.supported` currently falls through to creating `activeConfig`, which is what
triggers the unprompted sheet. That fall-through is the seam we intercept.

## Design

### 1. Gate the `.supported` case in the host

In `TranslationFallbackHost.pumpIfIdle()` the status switch gains a third branch:

- `.installed` → create config, translate silently (**unchanged**).
- `.unsupported` → `handleFallbackUnavailable(next)` (**unchanged**).
- `.supported` **and the pair is not yet user-approved** → call
  `viewModel.markFallbackNeedsDownload(detected:target:)` and **skip this pair**,
  then continue pumping.

**Queue must not stall on a gated pair.** `pumpIfIdle` currently always takes
`pendingFallbacks.first`. It must instead take the first pending request whose pair
is neither gated (awaiting download) nor currently pumping — otherwise a gated
Arabic issue at the head blocks a downloadable Spanish issue behind it.

### 2. View-model state (`IssueListViewModel`)

A language pair is `(detected, target)`. Since the target is global, the source
language alone is usually sufficient as the key, but we model the full pair to stay
correct if the user switches the global target mid-session.

- `pairsNeedingDownload: Set<LangPair>` — pairs awaiting user opt-in; drives the UI.
- `approvedDownloadPairs: Set<LangPair>` — pairs the user has tapped; lets
  `pumpIfIdle` proceed past the `.supported` gate for these.
- `func markFallbackNeedsDownload(detected:target:)` — called by the host; inserts
  into `pairsNeedingDownload`.
- `func needsLanguageDownload(_ issue) -> String?` — returns the source-language
  **display name** to show in the card, or `nil`. Non-nil iff the issue is pending
  in `pendingFallbacks`, its pair is in `pairsNeedingDownload`, and not approved.
- `func approveLanguageDownload(for issue)` — moves the pair from
  `pairsNeedingDownload` → `approvedDownloadPairs` and bumps an observable tick the
  host watches, so the host re-pumps and now creates the config for that pair.

### 3. Card UI (`IssueCardView`)

In the footer block (same place as `isTranslating` / "Show original", around
`IssueCardView.swift:236`), add a branch **before** the `isTranslating` branch:

```swift
else if let lang = needsDownloadLanguage {
    Button { onRequestDownload() } label: {
        Label("Translate · download \(lang)", systemImage: "arrow.down.circle")
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .font(.system(size: 11, weight: .medium))
    .padding(.top, 4)
}
```

New props `needsDownloadLanguage: String?` and `onRequestDownload: () -> Void` are
threaded through `IssueListView` (around line 280), mirroring the existing
`isTranslating:` wiring. Plain 11pt secondary text, matching the current footer
controls (per design decision: per-issue line, plain text link).

### 4. Tap → download → resume

Tapping calls `approveLanguageDownload(for:)`, which approves the pair and nudges
the host. `pumpIfIdle` now creates `activeConfig` for the approved `.supported`
pair; `drain()` runs `session.translate(...)`, presenting the system sheet. On
successful download, source + target install, translation proceeds, and **every**
queued issue in that pair drains and commits — clearing each card's prompt
automatically (per design decision: one tap unblocks the whole language; other
same-language cards are not deduped, they simply resolve as the queue drains).

### 5. Dismiss / cancel handling (the tricky edge)

If the user opens the sheet and taps **Done** without downloading, the pair is
still `.supported`. The current `drain()` catch path treats the resulting error as
transient and calls `dropPendingFallback` — which would make the prompt vanish with
nothing translated and no way back.

Fix: after a translate attempt for an approved pair, if availability still reports
`.supported` (i.e. the user did not download), **re-gate** the pair — remove it from
`approvedDownloadPairs`, re-insert into `pairsNeedingDownload`, and leave the
requests pending — so the inline affordance reappears instead of disappearing. Only
genuine transient errors on an `.installed` pair keep the existing drop behavior.

### 6. Testability improvement

The real `LanguageAvailability().status(...)` call lives inside the view and needs a
device/framework, making the gating logic hard to test. Inject the status lookup as
a closure on `TranslationFallbackHost` (defaulting to the real call), so the
view-model gating state machine can be unit-tested in `AppFeedbackTests_macOS`:

- a `.supported` signal puts the pair in `pairsNeedingDownload` and the issue reports
  a non-nil `needsLanguageDownload`;
- `approveLanguageDownload` clears the gate and marks the pair approved;
- after a simulated successful drain, the issue is no longer pending and reports nil;
- after a simulated dismiss (still `.supported`), the pair is re-gated.

## Out of scope (YAGNI)

- No global banner — per-issue line only.
- No dedup / "download once" collapse across same-language cards.
- No deep-link to System Settings; the system sheet is the only download surface.

## Affected files

- `AppFeedback/Views/Issues/TranslationFallbackHost.swift` — `.supported` gate,
  skip-gated-pair pump selection, injected status closure, re-gate on dismiss.
- `AppFeedback/ViewModels/IssueListViewModel.swift` — gating state + the four
  methods above.
- `AppFeedback/Views/Issues/IssueCardView.swift` — inline affordance branch + props.
- `AppFeedback/Views/Issues/IssueListView.swift` — thread `needsDownloadLanguage` /
  `onRequestDownload` into the card.
- `AppFeedbackTests_macOS` — gating state-machine tests.
