# Template Replies — Design Spec

**Date:** 2026-06-04
**Status:** Approved (design), pending implementation plan

## Summary

Split the existing "Reply" control into a two-segment button: `[ ⤺ Reply | ▤ ]`. The left
segment keeps the current reply behavior unchanged. The new right-segment icon opens a modal
that lists prewritten **reply templates**. The user selects one (single selection) and either:

- **Send** (primary CTA) — sends that template immediately, with the same header/footer that
  normal replies get, or
- **Prefill** (secondary CTA) — drops the template body into the reply composer for editing
  before sending.

Templates are created/edited/deleted from the modal (`+ Add` bottom-left, full CRUD). Each
template is stored under one repo. A segmented toggle at the top of the modal switches between
**this repo's** templates and a **Global** view that merges templates from all repos.

## Goals

- A split reply button with a visual divider, available at **both** reply entry points
  (the no-thread "Reply" badge and the in-thread reply control).
- A template picker modal with single selection, repo/global toggle, and full CRUD.
- Sent template replies carry the **same header/footer** as normal replies.
- Templates sync across devices (CloudKit), matching the rest of the user's mail data.

## Non-goals (v1)

- No separate "global bucket" of repo-less templates (Global is a *merged view*, not a scope).
- No rich-text editing of template bodies (plain text; HTML header/footer still wrap them).
- No per-template subject (subject is auto-derived from the issue like normal replies).
- No template categories/folders, ordering UI, or import/export.

## Decisions (resolved during brainstorming)

1. **Placement:** Both entry points — the no-thread `ReplyBadgeButton`
   (`IssueCardView.swift:679`) and the in-thread reply control (`MailThreadView` /
   `InlineReplyView`).
2. **Global semantics:** Every template belongs to exactly one repo (`repoOwner`/`repoName`).
   The toggle filters: **this repo** = repo-scoped only; **Global** = merged list across all
   repos. No `isGlobal` flag, no repo-less templates. `+ Add` always attaches the new template
   to the *current* repo, even when the Global tab is showing.
3. **Send behavior:** Primary CTA **Send** sends immediately via the in-app SMTP pipeline.
   Secondary CTA **Prefill** opens the host's composer with the body seeded.
4. **Management:** Full CRUD (add / edit / delete) in v1.
5. **Subject:** Auto-derived from the issue (reply-prefixed), same as normal replies. Templates
   store title + body only.
6. **Placeholders:** Template bodies run through the same `{{placeholder}}` substitution
   (`applyPlaceholders`) as header/footer, so `{{sender_name}}`, `{{date}}`, etc. work in
   templates.

## Architecture

### The header/footer contract (why a unified sender)

Header/footer are injected by `MailComposer.compose()` (driven by
`MailSettings.templateHeaderHTML` / `templateFooterHTML`), which builds
`HEADER + USER_BODY + FOOTER`. They are applied **only** on the in-app SMTP send path
(`ComposeMailViewModel.send()` → `MailComposer.compose()` → `MailSender`). The no-thread badge
currently uses `mailto:` / an external compose window, which would **not** apply header/footer.

Therefore **send-now for both paths must route through `compose()`**. To guarantee this
structurally (rather than relying on each host to do the right thing), introduce a single
**`ReplyTemplateSender`** service.

### `ReplyTemplateSender` (new service, `Services/Mail/ReplyTemplateSender.swift`)

A `@MainActor` service that takes a context and a mode:

```swift
struct ReplyTemplateContext {
    let issue: <IssueType>
    let recipient: String          // issue.email
    let repoOwner: String
    let repoName: String
    let parent: <ParentMessage>?   // present for in-thread; nil for first contact
    let senderAccountID: <UUID?>   // resolved sender account
}

enum ReplyTemplateMode { case sendNow, prefill }
```

- **`.sendNow`** — build a `DraftMessage` with `to: recipient`, auto-derived reply-prefixed
  `subject`, and `body` = the placeholder-substituted template body. Route through the existing
  send pipeline (`MailComposer.compose(...)` + `MailSender.send(...)`), building reply headers
  via `ReplyHeaderBuilder.build(parent:newMessageID:)` when `parent != nil`. Record the outbound
  message to `threadStore` exactly as `ComposeMailViewModel.send()` does. Header/footer are
  applied by `compose()` automatically because the template body is passed as `USER_BODY` only.
- **`.prefill`** — open the host's composer with the body seeded:
  - In-thread: trigger `beginReply()` and seed the body (extend `ComposeRequest` with an
    optional `initialBody`, consumed by `InlineReplyView` / `ComposeFormCore`).
  - No-thread: build a `ComposeRequest` with `initialBody` set and call
    `drafts.setOpenRequest(...)` (same mechanism `MailThreadView.beginReply` uses).

> The template body is **always** treated as `USER_BODY`. It must **not** contain header/footer
> itself — those are added by `compose()`.

**Account requirement:** `.sendNow` requires a configured sender account. If none exists, the
`Send` CTA is disabled (with a hint) and only `Prefill` (which can fall back to the external
composer / `mailto`) is available.

### `ReplyTemplate` (new `@Model`, `Models/ReplyTemplate.swift`)

Added to the **CloudKit** schema array in `AppFeedbackApp.swift` (so it syncs, matching
`MailSettings` / `MailThread`). Every stored property has a default value (SwiftData+CloudKit
constraint, matching existing models).

```swift
@Model final class ReplyTemplate {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var title: String = ""
    var body: String = ""
    var createdAt: Date = .now
    var updatedAt: Date = .now
    init(...) { ... }
}
```

### `ReplyTemplateStore` (new service, `Services/ReplyTemplateStore.swift`)

`@Observable @MainActor final class`, `init(context: ModelContext)`, modeled on `VersionStore`:

- **Queries:** `templates(owner:repo:) -> [ReplyTemplate]` (repo-scoped, sorted by `updatedAt`
  desc), `allTemplates() -> [ReplyTemplate]` (global merged view, sorted).
- **Mutations:** `create(owner:repo:title:body:)`, `update(_:title:body:)` (bumps `updatedAt`),
  `delete(_:)` — each does `context.insert/save` then `reload()`.
- **Reactivity:** listen for `.didSave` / `.NSPersistentStoreRemoteChange` /
  `cloudKitImportSucceeded`, calling `reload()` (same listeners as `VersionStore`).

Injected once at app root and passed to the hosts, like the other stores.

## UI

### `SplitReplyButton` (new, `Views/Templates/SplitReplyButton.swift`)

Replaces the single pill in `ReplyBadgeButton` and is reused by the in-thread reply control.
Same rounded-rect, accent-tinted pill (`color.opacity(0.12)` fill, `color.opacity(0.4)` stroke).
Two `.plain` tap targets share the pill, separated by a 1pt vertical rule
(`color.opacity(0.4)`):

```
┌──────────────────────────┐
│ ⤺ Reply  │  ▤            │
└──────────────────────────┘
  onReply      onTemplates
```

- Left segment: existing `arrowshape.turn.up.left.fill` + "Reply", fires the existing `onReply`.
- Right segment: SF Symbol `list.bullet.rectangle` (final icon TBD, trivially swappable), fires
  `onTemplates` → presents the modal.

### `ReplyTemplatePickerView` (new modal, `Views/Templates/`)

Presented via `.sheet`. On iOS, wrapped in `NavigationStack` with a `Done` `.confirmationAction`
(app convention, `RootView.swift:740`).

```
┌─────────────────────────────────────────┐
│        [  acme/app   |   Global  ]       │  segmented Picker (ActivityWindow style)
├─────────────────────────────────────────┤
│  ○  Thanks for the report                │  List(selection: selectedID)
│  ●  Fixed in next release    · acme/app  │  ← on Global, show origin repo caption
│  ○  Need more detail                     │
├─────────────────────────────────────────┤
│  [+ Add]            [ Prefill… ] [ Send ] │
└─────────────────────────────────────────┘
```

- **Toggle:** `Picker("", selection:).pickerStyle(.segmented)` over a 2-case enum
  (`.thisRepo`, `.global`); left label is the current repo's `owner/name`. `ActivityWindow.swift`
  style. Switching to Global shows the merged list with an origin-repo caption per row.
- **List:** `List(selection:)` single selection bound to the chosen template's `id`. Each row:
  title (plus a one-line body preview). Empty state when no templates in the current scope.
- **Footer:** `PanelAddButton` ("Add") bottom-left → opens the editor sheet. Right side:
  `Prefill` (`.bordered`) + `Send` (`.borderedProminent`, `.keyboardShortcut(.defaultAction)`).
  `Send` disabled until a template is selected **and** a sender account exists; show a brief
  inline `ProgressView` while sending (AddEmailAccountSheet idiom).
- **Edit/Delete:** row context menu (and swipe on iOS) → Edit (opens editor) / Delete.

### `ReplyTemplateEditorView` (new, `Views/Templates/`) — add & edit

Sheet presented from the modal. `TextField` for title, `TextEditor` for body, Save/Cancel.
Validates non-empty title and body. On **add**, attaches to the current repo's
`repoOwner`/`repoName` (regardless of which tab is showing). On **edit**, updates the existing
record.

## Data flow

1. Host (IssueCardView no-thread row, or in-thread reply control) shows `SplitReplyButton`.
2. Right segment → presents `ReplyTemplatePickerView` with the `ReplyTemplateStore`, current
   repo, and a `ReplyTemplateContext` describing the reply target.
3. User toggles scope, selects a template, taps **Send** or **Prefill**.
4. Modal calls `ReplyTemplateSender.act(context:template:mode:)`:
   - `.sendNow` → `compose()` (header/footer + placeholders + reply headers) → `MailSender`,
     records to `threadStore`, dismisses on success.
   - `.prefill` → opens host composer with seeded body; modal dismisses.
5. `+ Add` / Edit / Delete go through `ReplyTemplateStore`; CloudKit syncs.

## Error handling

- **No sender account:** `Send` disabled with a hint; `Prefill` remains usable.
- **Send failure:** surface the error inline in the modal (do not dismiss); user can retry or
  fall back to `Prefill`. Mirror `ComposeMailViewModel.send()`'s failure handling.
- **Empty scope:** show an empty state prompting `+ Add`.
- **Validation:** editor blocks save on empty title/body.

## Testing

- **`ReplyTemplateStoreTests`** (in-memory SwiftData, `FeedbackClipboardTests` style): create,
  update (bumps `updatedAt`), delete; repo-scoped query returns only that repo's templates;
  global query merges across repos and sorts; `+ Add` from Global tab attaches to the current
  repo.
- **Placeholder substitution:** unit-test that a template body with `{{...}}` is substituted
  (reuse/exercise `applyPlaceholders`), and that the body is passed as `USER_BODY` (header/footer
  still wrap it) — at the `ReplyTemplateSender` seam, without real SMTP.
- Run with `xcodebuild` against `AppFeedbackTests_macOS` for ground truth (per project notes).

## Files

**New**
- `AppFeedback/Models/ReplyTemplate.swift`
- `AppFeedback/Services/ReplyTemplateStore.swift`
- `AppFeedback/Services/Mail/ReplyTemplateSender.swift`
- `AppFeedback/Views/Templates/SplitReplyButton.swift`
- `AppFeedback/Views/Templates/ReplyTemplatePickerView.swift`
- `AppFeedback/Views/Templates/ReplyTemplateEditorView.swift`
- `AppFeedbackTests/ReplyTemplateStoreTests.swift`

**Changed**
- `AppFeedback/App/AppFeedbackApp.swift` — add `ReplyTemplate` to the cloud schema; construct
  and inject `ReplyTemplateStore`.
- `AppFeedback/Views/Issues/IssueCardView.swift` — `ReplyBadgeButton` → `SplitReplyButton`;
  present the modal; wire no-thread `ReplyTemplateContext`.
- `AppFeedback/Views/Mail/MailThreadView.swift` (+ `InlineReplyView` / `ComposeFormCore` /
  `ComposeRequest`) — in-thread split button + modal; `ComposeRequest.initialBody` for prefill.

## Open items deferred to plan

- Exact `IssueType` / `ParentMessage` / account-resolution types threaded into
  `ReplyTemplateContext` (read from `ComposeMailViewModel` / `MailThreadView.beginReply`).
- Whether the in-thread split button replaces the current reply trigger inline or sits beside it.
- Final SF Symbol for the template segment.
