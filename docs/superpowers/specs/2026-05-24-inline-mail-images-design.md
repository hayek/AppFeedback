# Inline Mail Images — Design

**Status:** Drafted 2026-05-24
**Follow-up to:** `2026-05-23-feedback-attachments-design.md`

## Problem

Replies from mail clients like Apple Mail embed screenshots as multipart-related: `<img src="cid:foo">` in the HTML body plus a sibling MIME part with `Content-ID: <foo>` carrying the image bytes (`Content-Disposition: inline`).

Today the inbox:

1. Renders message bodies as **plain text** via `IssueBodyText(plainBody:)` — the HTML body and its `<img>` tags are never displayed. (`HTMLSanitizer` is for outbound composition, not inbound rendering.)
2. **Filters out inline parts** at `IMAPClient.swift:335` — `guard isExplicitAttachment || hasFileNotInline || isCalendar else { return nil }`. Inline images (disposition `inline`, no `filename`, but with `Content-ID`) are dropped entirely. The user sees neither the image inline nor a chip.

Net effect: Jake's screenshots are invisible to the inbox.

## Goals

- Inline-image MIME parts are captured during IMAP parse and surface as `MailAttachment` rows.
- The message viewer renders inline images as a thumbnail strip (60×60pt tiles) alongside the existing attachment chip row.
- Tap → Quick Look, consistent with the feedback-attachment UX.

## Non-goals (v1)

- **Positional rendering** of `<img>` tags inside the body text. The inbox renders plain text only; images go to a thumbnail strip near (not inside) the body. Future v2 could render the HTML body with `<img>` substitution.
- **Outbound inline images.** Composer treats all attachments as regular MIME parts. `cid:` composition for sent mail is out of scope.
- **Remote `<img src="https://...">`** auto-loading. Common privacy-tracker vector; explicitly skipped.

## Wire-detail recap

The existing IMAP parse loop at `IMAPClient.swift:328-344` looks at each `BODYSTRUCTURE` part:

```swift
let disp = part.disposition?.lowercased()
let hasFilename = !(part.filename?.isEmpty ?? true)
let isExplicitAttachment = disp == "attachment"
let hasFileNotInline = hasFilename && disp != "inline"
let isCalendar = ct.hasPrefix("text/calendar")
guard isExplicitAttachment || hasFileNotInline || isCalendar else { return nil }
```

SwiftMail's `MessagePart` exposes `contentId: String?` (verified in `~/Library/Developer/Xcode/DerivedData/.../SwiftMail/Sources/SwiftMail/Core/Models/Attachment.swift`). We extend the filter:

```swift
let isInlineImage = (disp == "inline" || disp == nil)
                    && (part.contentId?.isEmpty == false)
                    && ct.hasPrefix("image/")
guard isExplicitAttachment || hasFileNotInline || isCalendar || isInlineImage else { return nil }
```

We also store the `contentID` on the row so the rendering layer (and any future cid-resolution) can find the right part.

## Data model change

`MailAttachment` (SwiftData @Model class in `AppFeedback/Models/MailAttachment.swift`) gains:

```swift
var contentID: String? = nil
```

Default `nil` keeps existing rows compiling and storing. A `bool` computed property surfaces the inline-image distinction at the view layer:

```swift
var isInlineImage: Bool {
    contentID != nil && mimeType.lowercased().hasPrefix("image/")
}
```

## View layer

`MailMessageRowView` currently has one row for attachments:

```swift
private var attachmentsRow: some View {
    HStack { ForEach(attachments) { AttachmentChipView(...) } }
}
```

It splits into two:

- **`inlineImages`** — `attachments.filter(\.isInlineImage)` — rendered as a horizontal strip of `MailAttachmentThumbnailView` tiles (60×60pt, image preview after IMAP fetch, tap = Quick Look gallery).
- **`regularAttachments`** — `attachments.filter { !$0.isInlineImage }` — the existing chip row, unchanged.

New view `MailAttachmentThumbnailView` mirrors the feedback-side `AttachmentThumbnailView` (`AppFeedback/Views/Issues/AttachmentThumbnailView.swift`) but uses `AttachmentDownloader` (IMAP-based) instead of `FeedbackAttachmentDownloader` (HTTPS), and `MailAttachment` instead of `FeedbackAttachmentRef`.

Reuses the existing `ThumbnailCache` (built in F3) — no second cache.

Tap-to-Quick-Look uses the same `QuickLookPresenter.present(urls:startingAt:)` flow. If a message has multiple inline images, tapping any opens the QL gallery with all of them, indexed to the tapped one.

## Testing

- Unit test: `IMAPClient.parse` (or its static helper) given a synthetic message with one inline-image part returns an attachment with `contentID` non-nil. Existing attachment-classification tests stay green.
- Smoke test: `MailAttachmentThumbnailView` initializes without crash given a `MailAttachment` + a nil downloader.

## Tradeoffs

- **Position drift.** Images shown in a strip near the body, not inline at their `<img>` position. Acceptable for v1 — Jake's screenshots become visible and clickable, which is the load-bearing fix. Future v2 can render HTML inline.
- **Disk usage.** Inline images are now downloaded eagerly when their thumbnail tile renders, just like feedback-side image thumbnails. Cached via the existing `AttachmentDownloader` + filesystem flow.
- **Reuses `AttachmentChipView`'s feedback-init pattern.** No: we keep two distinct downloaders (IMAP vs HTTPS) and two distinct view types. A future refactor could unify, but YAGNI for now.
