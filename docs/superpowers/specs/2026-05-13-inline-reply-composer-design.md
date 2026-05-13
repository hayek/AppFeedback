# Inline Reply Composer — Design

**Status:** Draft
**Date:** 2026-05-13

## Motivation

Today the mail composer always opens out-of-context:

- On macOS, tapping **Reply** in a `MailThreadView` (or tapping an email address in an `IssueCardView`) opens a separate `Compose` window via `WindowGroup("Compose", id: "compose", for: UUID.self)` at `AppFeedback/App/AppFeedbackApp.swift:303`.
- On iOS, the same actions present a modal `.sheet` (see `MailThreadView.swift:92` and `IssueListView.swift:177`).

Both paths interrupt the user's reading flow: the issue and its existing thread disappear behind a window or sheet while the user composes a reply. The change moves composing into the place the user is already looking — inside the thread (for replies) or inside the issue card (for first-time emails) — and eliminates the windowed/sheet plumbing entirely.

## Goals

- Replying inside an existing thread renders an inline composer directly below the messages, in place of the **Reply** button.
- Tapping an email address on an issue card with no existing thread opens an inline composer inside the card.
- Drafts survive thread collapse/expand and `LazyVStack` recycling. They are cleared on successful send or explicit discard.
- The windowed (macOS) and sheet (iOS) compose paths are removed in the same change; there is no dual code path after this lands.
- Behavior parity with today's composer: per-account "Reply From" selection, header/footer template previews, send via existing `ComposeMailViewModel.send()`, mirror to GitHub via `MailToGitHubMirror`.

## Non-goals

- Drafts surviving app relaunch (in-memory only).
- Multiple simultaneous open composers per thread or per issue card. Only one composer per target may be open at a time.
- Rich-text editing changes. The body editor stays as today (`TextEditor` over `vm.body.string`).
- Changes to send logic, threading headers, GitHub mirror flow, or `OutboundSendTracker` / `OutboundFailureStore` integration. Those are unchanged.

## Architecture

### Component overview

```
┌────────────────────────────────────────────────────────────┐
│ IssueCardView                                              │
│  ├─ existing card content                                  │
│  ├─ MailThreadView (when a thread exists)                  │
│  │    ├─ message rows                                      │
│  │    └─ replyArea:                                        │
│  │         ┌─ ReplyBadgeButton  (when not replying)        │
│  │         └─ InlineReplyView   (when replying) ───────┐   │
│  └─ inline first-email area                            │   │
│       ┌─ InlineReplyView (when activeInlineEmail set) ─┤   │
│                                                        │   │
│                                                        ▼   │
│                                            ComposeFormCore │
│                                          (rows + editor +  │
│                                          send button)      │
└────────────────────────────────────────────────────────────┘
```

### New types

- **`MailDraftStore`** — `@Observable` reference type in `AppFeedback/Services/Mail/MailDraftStore.swift`. In-memory store keyed by `DraftKey`:

  ```swift
  enum DraftKey: Hashable {
      case reply(threadID: UUID)
      case newEmail(repoOwner: String, repoName: String, issueNumber: Int, recipient: String)
  }

  struct Draft {
      var subject: String
      var body: String
  }
  ```

  API: `draft(for:) -> Draft?`, `setSubject(_:for:)`, `setBody(_:for:)`, `clear(_:)`. Installed in the environment by `AppFeedbackApp` alongside `MailAccountStore` etc.

- **`ComposeFormCore`** — a view in `AppFeedback/Views/Mail/ComposeFormCore.swift` that renders the form rows (From, To, Subject, header preview, body editor, footer preview) plus the send button. It owns nothing; it is parameterised by:
  - `vm: ComposeMailViewModel` (binding-style, observable)
  - `onSend: () -> Void`
  - `onDiscard: () -> Void`
  - `discardLabel: String` (e.g., "Cancel" inline; reused for any future shell)

  No `ScrollView`, no fixed minimum frame, no title bar — those are the shell's concern.

- **`InlineReplyView`** — a view in `AppFeedback/Views/Mail/InlineReplyView.swift`. Builds and owns a `ComposeMailViewModel` for the target, hydrates it from `MailDraftStore` on appear, writes subject/body changes back on every edit, and renders:
  - A one-line header strip: `"Reply to alice@example.com"` (or `"New email to …"`) with a trailing `×` discard button.
  - `ComposeFormCore` underneath, scaled to the parent's width.

  On `Send` the view calls `vm.send()` (async), then clears the draft and calls a parent-supplied `onClose()`. On `Discard` it shows a confirmation alert only when the body is non-empty, then clears the draft and calls `onClose()`.

### Changes to existing types

- **`MailThreadView`** (`AppFeedback/Views/Mail/MailThreadView.swift`):
  - Add `@State private var isReplying: Bool = false` and `@State private var replyOptions: ReplyOptions?` where `ReplyOptions` captures the recipient, parent headers, subject override, and chosen sender account id derived from `beginReply(senderAccountID:)`.
  - Replace `replyButton` with `replyArea`:
    ```swift
    @ViewBuilder private var replyArea: some View {
        if isReplying, let opts = replyOptions {
            InlineReplyView(
                key: .reply(threadID: thread.id),
                request: composeRequest(from: opts),
                onClose: { isReplying = false; replyOptions = nil }
            )
        } else if let recipient = replyRecipient {
            ReplyBadgeButton(…)  // unchanged config
        }
    }
    ```
  - `beginReply(senderAccountID:)` no longer calls `presentCompose(_:)`. It sets `replyOptions` and `isReplying = true`.
  - Remove the iOS `.sheet(item: $pendingCompose)` modifier and the `pendingCompose` state.
  - Remove the `#if os(macOS)` `composeHolder` / `openWindow` environment dependencies.
  - Delete `presentCompose(_:)` entirely; it is unused after this change.

- **`IssueCardView`** (`AppFeedback/Views/Issues/IssueCardView.swift`):
  - Add `@State private var activeInlineEmail: String? = nil`.
  - `onTapEmail` becomes purely a state setter (`{ email in activeInlineEmail = email }`); the closure handed in from `IssueListView` is no longer needed because the card owns the inline target locally.
  - Add an inline composer slot below the thread section (or below the body content if no thread exists). When `activeInlineEmail != nil`, render `InlineReplyView(key: .newEmail(…), request: …, onClose: { activeInlineEmail = nil })`.
  - If a thread reply is open in the card *and* the user taps an email, the new email tap is ignored (do not unconditionally clear the thread-reply state; the user has an in-progress draft).

- **`IssueListView`** (`AppFeedback/Views/Issues/IssueListView.swift`):
  - Remove the `tapEmailHandler` factory at `IssueListView.swift:234-255`. Pass `nil` for `onTapEmail` (or remove the parameter — see *Cleanup* below); the card now owns the inline state itself.
  - Remove the iOS `.sheet(item: $pendingCompose)`, the `pendingCompose` state, and the `composeHolder` / `openWindow` environment dependencies.

- **`ComposeMailView`** (`AppFeedback/Views/Mail/ComposeMailView.swift`): **deleted**.

- **`ComposeRequest`** (currently declared inside `MailThreadView.swift`): kept and moved to `AppFeedback/Views/Mail/ComposeRequest.swift` (file split for clarity, no behavior change). Used as the parameter bag passed into `InlineReplyView.init` so the two call sites construct it the same way.

- **`ComposeWindowHolder`** and **`ComposeWindowContent`** (currently in `MailThreadView.swift`): **deleted**.

- **`AppFeedbackApp.swift`**:
  - Delete `@State private var composeWindowHolder = ComposeWindowHolder()` at line 30 and both `.environment(composeWindowHolder)` injections.
  - Delete the `WindowGroup("Compose", id: ComposeWindowHolder.windowID, for: UUID.self)` scene at line 303.
  - Add `@State private var mailDraftStore = MailDraftStore()` and `.environment(mailDraftStore)` next to the existing mail-related store injections.

### Data flow on a reply

1. User taps `ReplyBadgeButton` (default action or "Reply From" menu).
2. `MailThreadView.beginReply(senderAccountID:)` builds a `ComposeRequest` from the last message's headers and sets `isReplying = true`.
3. `InlineReplyView` appears. In `.onAppear` (or `.task`):
   - Builds a `ComposeMailViewModel` using exactly the args `ComposeMailView.setupViewModel()` uses today (`AppFeedback/Views/Mail/ComposeMailView.swift:229-247`), from environment-injected stores.
   - Reads `mailDraftStore.draft(for: .reply(threadID:))`. If present, overrides `vm.subject` and `vm.body` with the stored draft.
4. As the user types:
   - The subject `TextField` binding writes through to `vm.subject` and also calls `mailDraftStore.setSubject(_:for:)`.
   - The body `TextEditor` binding writes through to `vm.body` and also calls `mailDraftStore.setBody(_:for:)`.
5. On `Send`, the view calls `await vm.send()` (unchanged), then `mailDraftStore.clear(.reply(threadID:))`, then `onClose()`. The next sync tick surfaces the sent message in the thread.
6. On `Discard`, the view confirms (if body non-empty), then clears the draft and calls `onClose()`.

### UX details

- **Open animation:** `withAnimation(.easeOut(duration: 0.2)) { isReplying = true }` (and the equivalent for `activeInlineEmail`).
- **Scroll into view:** wrap the outer issue list in the existing `ScrollViewReader` (already present at `IssueListView.swift:114`). Tag the `InlineReplyView` with a stable `.id("compose-\(issueNumber)")`. On open, call `proxy.scrollTo(id, anchor: .bottom)`.
- **Focus:** `@FocusState var bodyFocused: Bool` inside `InlineReplyView`; set to `true` in `.onAppear`.
- **iOS keyboard:** rely on SwiftUI's default safe-area inset behavior. The body editor is the focused element; the surrounding `LazyVStack` ScrollView already adjusts insets for the keyboard. Verified by the test plan below.
- **macOS chrome:** the inline composer renders inside the card's content; no extra window chrome.
- **Header strip:** small caption row showing `"Reply to <recipient>"` / `"New email to <recipient>"` and a trailing `Button { discard() } label: { Image(systemName: "xmark.circle.fill") }` styled `.plain`.
- **From selector:** unchanged — the per-account selection lives on `ReplyBadgeButton.onReplyFrom`. The chosen account id is encoded into the `ComposeRequest` that `InlineReplyView` consumes.

### Error handling

- **Missing credentials:** `InlineReplyView` shows the same yellow `missingCredentialsBanner` that `ComposeMailView` shows today (`AppFeedback/Views/Mail/ComposeMailView.swift:158-171`), just inside the inline frame. The Send button is disabled (`vm.canSend` already covers this).
- **Send failure:** unchanged behavior. `ComposeMailViewModel.send()` records via `OutboundFailureStore` and `ActivityLog`. The inline composer closes after `vm.send()` returns (success or failure) so the user sees the shimmer / failure badge directly on the new message row in the thread.
- **Cancelled discard with body content:** confirmation alert keeps the composer open and the draft intact.

### Cleanup / dead code removal in the same change

- Delete `ComposeMailView` (file + type).
- Delete `ComposeWindowHolder` and `ComposeWindowContent` (currently in `MailThreadView.swift`).
- Delete the `WindowGroup("Compose", …)` scene in `AppFeedbackApp.swift`.
- Delete the iOS `.sheet(item: $pendingCompose)` modifiers and `pendingCompose` state in `MailThreadView.swift` and `IssueListView.swift`.
- Delete the `tapEmailHandler` factory in `IssueListView.swift`.
- Delete the `onTapEmail` parameter on `IssueCardView` if no other call site needs it after this change (verify during implementation; otherwise leave the parameter and ignore the value).
- Remove `composeWindowHolder` state and `.environment(composeWindowHolder)` injections from `AppFeedbackApp.swift`.

### Files affected

New:

- `AppFeedback/Services/Mail/MailDraftStore.swift`
- `AppFeedback/Views/Mail/ComposeFormCore.swift`
- `AppFeedback/Views/Mail/InlineReplyView.swift`
- `AppFeedback/Views/Mail/ComposeRequest.swift` (moved from `MailThreadView.swift`)

Modified:

- `AppFeedback/App/AppFeedbackApp.swift`
- `AppFeedback/Views/Mail/MailThreadView.swift`
- `AppFeedback/Views/Issues/IssueCardView.swift`
- `AppFeedback/Views/Issues/IssueListView.swift`
- `AppFeedback/AppFeedback.xcodeproj/project.pbxproj` (new files added to the target)

Deleted:

- `AppFeedback/Views/Mail/ComposeMailView.swift`

## Test plan

Manual:

1. **Reply happy path (macOS):** Open an issue with a thread → click Reply → composer appears inline below messages → type subject/body → Send → composer closes, message appears at the bottom of the thread, no second window opens at any point.
2. **Reply happy path (iOS):** Same as above, no sheet appears.
3. **Draft persistence across collapse:** Reply → type body → collapse the thread (chevron) → expand → composer is still open with the same body.
4. **Draft persistence across recycling:** Reply → type body → scroll the issue list down so the card leaves the viewport (`LazyVStack` recycles) → scroll back → composer is still open with the same body.
5. **Draft cleared on Send:** Reply → type → Send → reopen Reply on the same thread → composer is empty.
6. **Discard with empty body:** Reply → tap × → composer closes immediately, no prompt.
7. **Discard with body content:** Reply → type → tap × → confirm alert appears → confirm → composer closes, draft cleared.
8. **Reply From selection:** With ≥2 accounts configured → use the "Reply From" menu on the badge → composer opens inline with that account in the From row.
9. **First-time email:** Issue card with no thread → tap email address → inline composer appears inside the card → send → message appears as the start of a new thread.
10. **First-time email draft persistence:** Tap email → type → tap a different issue's email → come back → original draft is still there (keyed by issue+recipient).
11. **Missing credentials:** Configure no SMTP password → open Reply → yellow banner shown inline, Send disabled.
12. **iOS keyboard:** iPhone simulator → open inline reply → focus moves to body → keyboard appears → editor remains visible (not occluded).

Build / type-check:

- `xcodebuild build` for both macOS and iOS targets succeeds with no `ComposeMailView` / `ComposeWindowHolder` / `pendingCompose` references remaining.

## Open questions

None. (Resolved: in-memory drafts only; both call sites go inline; windowed/sheet shell removed in the same change.)
