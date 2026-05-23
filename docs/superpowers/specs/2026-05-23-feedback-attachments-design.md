# Feedback Attachments — Design

**Status:** Drafted 2026-05-23
**Surface:** AppFeedbackSDK (FeedbackCore + FeedbackUI) and AppFeedback inbox app (Issue viewer, Mail compose/receive, MailComposer, IssueBodyParser shim)

## 1. Goals & non-goals

### Goals

1. Let SDK consumers attach images and a few non-image files to a `FeedbackReport`. The SDK uploads them to GitHub and links them in the issue body.
2. Show those attachments in the AppFeedback Mac/iOS inbox issue viewer. Images render as inline thumbnails; non-images render as chips. Tap = Quick Look.
3. Let inbox users send attachments outbound when replying to a thread (inline reply and full compose).
4. Receive attachments inbound on mail threads. (Mostly already works; this design extends the existing chip to use Quick Look so behavior matches the issue viewer.)
5. Mirror SDK-supplied attachments into the initial outbound acknowledgement email so the user sees what they submitted alongside the rest of the thread.

### Non-goals (v1)

- No screen recording / camera capture inside the feedback sheet.
- No automatic janitor for orphaned blobs in the attachments branch (we accept some bytes-of-waste on partial failures; future work).
- No configurable attachments repo / branch / path — hardcoded defaults only. Inbox-repo privacy caveat documented below.
- No support for files outside the curated allowlist.
- No on-device image annotation/redaction before upload.
- No re-encoding of non-image files (logs and JSON are uploaded byte-for-byte).
- No HTML-inline image embedding (`<img>` cid:) in outbound mail. Attachments are sent as regular MIME parts.

### Allowlist (v1)

| MIME | Extension | Notes |
| --- | --- | --- |
| `image/png` | `.png` | Re-encoded to strip metadata. |
| `image/jpeg` | `.jpg`/`.jpeg` | Re-encoded to strip EXIF/GPS. |
| `image/heic` | `.heic` | Transcoded to JPEG before upload. |
| `image/gif` | `.gif` | Pass-through (preserve animation). |
| `text/plain` | `.txt`, `.log` | Pass-through. |
| `application/json` | `.json` | Pass-through. |
| `application/pdf` | `.pdf` | Pass-through. |

### Limits

| Scope | Files | Per-file | Total |
| --- | --- | --- | --- |
| SDK report attachments | 3 | 5 MB | 10 MB |
| Outbound mail attachments | 3 | 5 MB | 10 MB |

Size limits apply **post-preprocessing** — a 6 MB HEIC that transcodes to a 3 MB JPEG passes.

### Known caveat: private inbox repos

Attachments are committed to the same repo that hosts the inbox issues, under a dedicated `feedback-attachments` branch. GitHub's "More Secure Private Attachments" (GA, 2024) means `raw.githubusercontent.com` URLs from private repos require an authenticated GitHub session to fetch. Consequences:

- The AppFeedback inbox app fetches with its PAT — works fine.
- The SDK doesn't fetch them back — N/A.
- **Email recipients without a GitHub session will see broken-image icons** in the mirrored acknowledgement email when the inbox repo is private.

We accept this for v1 because the alternative — making the attachments repo configurable — was explicitly rejected. The mitigation is to recommend a public inbox repo, or to revisit configurable storage later.

## 2. SDK public API

### `FeedbackAttachment`

```swift
public struct FeedbackAttachment: Sendable, Equatable {
    /// Display filename. Basename only — leading directories stripped. Sanitized by the SDK.
    public let filename: String

    /// Canonical MIME type from the allowlist. Caller is responsible for picking the right one.
    public let mimeType: String

    /// Raw bytes. Images are pre-processed (EXIF strip, HEIC→JPEG) before upload.
    public let data: Data

    public init(filename: String, mimeType: String, data: Data)
}
```

### `FeedbackReport` change

```swift
public struct FeedbackReport: Sendable, Equatable {
    // existing: type, title, description, contactEmail, extraFields
    public var attachments: [FeedbackAttachment] = []
}
```

The default `[]` keeps every existing call site compiling unchanged.

### Validation error surface

A new public error enum, surfaced through the existing `FeedbackSubmissionError`:

```swift
public enum FeedbackAttachmentError: Sendable, Equatable {
    case tooManyAttachments(limit: Int, got: Int)
    case fileTooLarge(filename: String, sizeBytes: Int, limit: Int)
    case totalSizeTooLarge(totalBytes: Int, limit: Int)
    case unsupportedMimeType(filename: String, mimeType: String)
    case imageProcessingFailed(filename: String)
}

public enum FeedbackSubmissionError: Error, Sendable {
    // existing cases
    case attachmentValidation(FeedbackAttachmentError)         // synchronous, pre-network
    case attachmentUpload(filename: String, underlying: any Error & Sendable)
}
```

Validation is performed by an internal `FeedbackAttachmentValidator` before the transport touches the network.

### `FeedbackSheet` UI

The picker UI lives in the existing `FeedbackSheet`. Affordances:

- **"Add attachment" button** below the description field. On iOS/iPadOS opens `PhotosPicker` for images + `.fileImporter` for non-images. On macOS opens a single `NSOpenPanel` configured with the allowlist content types.
- **Drag-and-drop onto the sheet** (macOS). The entire sheet is a drop target — sheet has the existing hero background, so a subtle drop-overlay visual cue when the drag enters.
- **Paste from clipboard** (`⌘V` on macOS, paste menu on iOS). If pasteboard contains an image, insert it as a `pasted-image-<n>.png` attachment.

Selected attachments render as a horizontal strip below the picker:

- Images: 56×56pt rounded thumbnail.
- Non-images: filename chip with system-image icon (`doc.text`, `curlybraces`, `doc.fill`).
- Each tile has an `x` button to remove.

Validation errors surface inline as a small red banner under the strip. Submit is disabled while any validation error is unresolved.

## 3. Image preprocessing

A new internal `ImagePreprocessor` runs on every image attachment before upload, on the transport's task context (pure compute, no I/O). Cross-platform — uses `ImageIO` (`CGImageSource` / `CGImageDestination`) so it works on every Apple platform without `#if`s.

| Input MIME | Output MIME | Action |
| --- | --- | --- |
| `image/heic` | `image/jpeg` | Decode → re-encode JPEG @ q=0.85. Filename extension swapped to `.jpg`. EXIF + GPS dropped. |
| `image/jpeg` | `image/jpeg` | Re-write through `CGImageDestination` with `kCGImageMetadataShouldExcludeGPS=true` and metadata replaced by an empty `CGImageMetadata`. Bytes change; visual content does not. |
| `image/png` | `image/png` | Re-write through `CGImageDestination` to drop tEXt/iTXt chunks. |
| `image/gif` | `image/gif` | Pass-through (preserve animation). |
| Non-image | unchanged | Bypassed. |

Failure mode: if preprocessing throws for any reason (corrupt input, unreadable HEIC, ImageIO error), the **whole submission fails** with `attachmentValidation(.imageProcessingFailed(filename:))` before any upload happens. The image is not silently dropped.

The 5 MB per-file ceiling is re-applied after preprocessing — bytes-on-GitHub is what counts, not bytes the user picked.

## 4. GitHub upload mechanics

`GitHubDirectTransport.submit(_:deviceInfo:)` becomes a two-phase operation when `report.attachments` is non-empty:

```text
1. validate(report.attachments)               // throws attachmentValidation
2. preprocessed = report.attachments.map(ImagePreprocessor.process)
3. ensureAttachmentsBranchExists()            // idempotent
4. submissionID = UUID().uuidString.lowercased()
5. for att in preprocessed:
       upload(att, into: "attachments/{submissionID}/{sanitizedFilename}")
       → URL                                  // raw.githubusercontent.com
6. body = IssueBodyFormatter.format(report, deviceInfo, uploaded)
7. POST /repos/{owner}/{repo}/issues
```

### Branch existence

```text
GET /repos/{owner}/{repo}/branches/feedback-attachments
  200 → done.
  404 → GET /repos/{owner}/{repo} to read default_branch
        GET /repos/{owner}/{repo}/git/refs/heads/{default_branch} to read SHA
        POST /repos/{owner}/{repo}/git/refs body:{ref:"refs/heads/feedback-attachments", sha:...}
        201 → done.
  other → throw.
```

Always-check on each submission. The check is one cheap GET; we do not cache state between transport invocations because the transport is a value type and may be short-lived.

### Per-file upload

```text
PUT /repos/{owner}/{repo}/contents/{percent_encoded_path}
body: {
  "message": "Add attachment for feedback submission <submissionID>",
  "content": "<base64>",
  "branch": "feedback-attachments"
}
```

- Path scheme: `attachments/{submissionID}/{sanitizedFilename}`. Submission ID is fresh per submission; never includes the issue number (we don't know it yet). Filename collisions within a submission are resolved by appending ` (n)` before the extension.
- Filename sanitization: strip path separators (`/`, `\`), control characters, NUL. Trim leading/trailing whitespace and dots. If empty after sanitization, fall back to `file.bin`. Percent-encode the URL path segment.
- Response payload: GitHub returns `{"content": {"download_url": "..."}}`. We trust `download_url` as the canonical raw URL to embed in the body.

### Partial-failure semantics

If upload N fails after uploads 1..N-1 succeeded, the first N-1 blobs remain committed to `feedback-attachments` but no issue is created. The submission throws `attachmentUpload(filename:underlying:)`. The orphan blobs are unreachable from any issue body and waste a small amount of repo space.

We do not auto-clean. A future janitor task could scan branch contents against issue body markdown and delete unreferenced `attachments/{uuid}/` directories.

### PAT scope

The PAT must already have `repo` (private) or `public_repo` (public) — the same scope already required for `POST /issues`. The Contents and Git Data APIs are covered by these scopes. No new permission required.

## 5. Wire format — `<!-- attachments-v1 -->` block

### Producer (`IssueBodyFormatter`)

After the existing body content, the formatter appends a marker-bounded section when attachments exist:

```markdown
<!-- attachments-v1 -->
## Attachments

![screenshot.png](https://raw.githubusercontent.com/owner/repo/feedback-attachments/attachments/<uuid>/screenshot.png) — image/png, 312 KB

[crash.log](https://raw.githubusercontent.com/owner/repo/feedback-attachments/attachments/<uuid>/crash.log) — text/plain, 4.1 KB

<!-- /attachments-v1 -->
```

Rules:

- Markers are HTML comments so they're invisible when github.com renders the body.
- Inside markers: a `## Attachments` H2, then one paragraph per attachment.
- Image entries use the markdown image embed (`![alt](url)`) so they render inline on github.com.
- Non-image entries use the markdown link (`[name](url)`) so they're clickable but don't try to embed.
- Each entry has a trailing ` — {mime}, {humanSize}` suffix for humans. The parser also reads this for the chip UI; if missing, the parser derives MIME from the URL extension and omits size.

### New `BodyMarker` constants

Added to `AppFeedbackCore/BodyMarkers.swift`:

```swift
enum BodyMarker {
    // existing constants...
    static let attachmentsOpen = "<!-- attachments-v1 -->"
    static let attachmentsClose = "<!-- /attachments-v1 -->"
    static let attachmentsHeader = "## Attachments"
}
```

### Parser (`AppFeedbackCore/IssueBodyParser`)

`IssueBodyParser.parse(_:)` returns a `ParsedBody` that grows a new field:

```swift
public struct ParsedAttachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let url: URL
    public let sizeBytes: Int?
}

public struct ParsedBody: Sendable {
    // existing fields...
    public var attachments: [ParsedAttachment]
}
```

Algorithm:

1. If `attachmentsOpen` is absent: `attachments = []`.
2. Otherwise: slice between `attachmentsOpen` and `attachmentsClose` (first close after the open). If close missing, treat whole tail as the block (forgiving).
3. For each non-empty line in the slice:
   - Match `^!\[(?<name>[^\]]+)\]\((?<url>[^)]+)\)(?:\s+—\s+(?<mime>[^,]+),\s+(?<size>.+))?$` for images.
   - Match `^\[(?<name>[^\]]+)\]\((?<url>[^)]+)\)(?:\s+—\s+(?<mime>[^,]+),\s+(?<size>.+))?$` for files.
   - On match: build a `ParsedAttachment`. On miss: skip the line.
4. If MIME group is missing: infer from URL path extension via `UTType`.
5. If size group is missing: leave `sizeBytes = nil`.

Forward compatibility: if a future SDK emits `<!-- attachments-v2 -->`, this parser skips it (the v1 open marker won't match) and silently returns `attachments = []`. The body content above the block is unaffected.

### Inbox shim

`AppFeedback/Services/IssueBodyParser.swift` (the thin shim) gains a `attachments: [ParsedAttachment]` field on its `ParsedBody` and passes them through.

### Issue body length

GitHub's 65,536-character body limit is the same as today. The attachments block is small — even 3 entries occupy roughly 600 bytes — so this is non-load-bearing.

## 6. Inbox: data model + downloader + cache

### `CachedIssue` extension

`CachedIssue` (the SwiftData mirror) grows one field:

```swift
var attachmentsJSON: String?   // JSON-encoded [ParsedAttachment]
```

The view layer decodes lazily. `toFeedbackIssue()` and `updateFromRemote(_:)` round-trip it. We use JSON-in-a-string rather than a SwiftData relationship because (a) attachment metadata is immutable once parsed (no relational queries needed) and (b) it avoids a CloudKit schema migration for a small payload.

### `FeedbackIssue` extension

The codable struct grows the same field:

```swift
struct FeedbackIssue {
    // existing...
    var attachments: [ParsedAttachment]
}
```

### New SwiftData model — `FeedbackAttachmentLocal`

Mirrors the existing `MailAttachmentLocal`:

```swift
@Model final class FeedbackAttachmentLocal {
    var url: String          // remote raw URL — primary identity
    var localPath: String
    var downloadedAt: Date
    init(url: String, localPath: String, downloadedAt: Date)
}
```

### New service — `FeedbackAttachmentDownloader`

Actor-backed, parallel to `AttachmentDownloader`:

```swift
actor FeedbackAttachmentDownloader {
    init(session: URLSession, localStore: FeedbackAttachmentLocalStore, githubToken: () async -> String?)
    func download(url: URL, filename: String) async throws -> URL
}
```

Behavior:

1. Check `FeedbackAttachmentLocalStore` for `url`. If present and file exists, return cached path.
2. Otherwise `GET url` with `Authorization: Bearer <token>` (private repos need the session-equivalent header; PAT works for raw.githubusercontent.com when the repo is private and the token has access).
3. Write atomically into the `FeedbackAttachments/` directory inside Application Support, under `{url-sha256}/{sanitizedFilename}` to avoid name collisions between issues.
4. Insert `FeedbackAttachmentLocal` row, return URL.

A `@MainActor`-wrapped `FeedbackAttachmentLocalStore` owns the SwiftData reads/writes; same pattern as `MailAttachmentLocalStore`.

An observable `FeedbackAttachmentDownloaderHolder` is injected via `@Environment`, parallel to `AttachmentDownloaderHolder`.

### Thumbnail cache

For the inline thumbnail strip, a separate in-memory `NSCache<NSString, PlatformImage>` keyed by URL. After download, the image bytes are decoded once and scaled to 128pt @2x (256px). Eviction is automatic on memory pressure. Lives on `@MainActor`.

### Why not reuse the mail `AttachmentDownloader`?

The mail downloader fetches via IMAP `FETCH ... BODY[partID]`. Feedback attachments are HTTPS GETs against `raw.githubusercontent.com`. The two share zero plumbing. Keeping them separate is cheaper than introducing a polymorphic abstraction.

## 7. Inbox UI

### `IssueCardView`

Below the body, before the meta column, a new `AttachmentStripView` component:

```text
┌────────┬────────┬────────┬───────────────────────────┬───────────────────────────┐
│ 🖼      │ 🖼      │ 🖼      │ 📄 crash.log · 4.1 KB     │ 🗂 trace.json · 12 KB     │
└────────┴────────┴────────┴───────────────────────────┴───────────────────────────┘
```

- Images first: 56×56pt thumbnails, rounded corners, `.aspectRatio(.fill, .clip)`. Empty placeholder + spinner while the downloader fetches the first time.
- Non-images second: `AttachmentChipView` reused (extended; see §7 below).
- Strip wraps to a second line on narrow widths.
- A long-press / right-click context menu on each item: "Quick Look", "Save As…", "Reveal in Finder" (macOS only), "Copy Link".

### `QuickLookPresenter` — shared service

Cross-platform Quick Look entry point. Two implementations behind one SwiftUI-friendly API.

```swift
@MainActor
@Observable
final class QuickLookPresenter {
    func present(urls: [URL], startingAt index: Int = 0)
}
```

#### macOS

Backed by `QLPreviewPanel.shared()`. A small `NSResponder` subclass conforms to `QLPreviewPanelDataSource` + `QLPreviewPanelDelegate`. The presenter retains it, makes it first responder, and calls `QLPreviewPanel.shared().makeKeyAndOrderFront(nil)`.

#### iOS / iPadOS

Backed by `QLPreviewController` wrapped in a `UIViewControllerRepresentable`. The presenter sets `isPresented` on a `@Published` binding that the root view observes and shows as a full-screen cover.

#### Injection

Injected via `@Environment` from the app root. SwiftUI views call `quickLook.present([url])`.

### `AttachmentChipView` migration (email + feedback unified)

Today's `AttachmentChipView` calls `NSWorkspace.shared.open(url)` on macOS and is a no-op on iOS. Replace both branches with `quickLook.present([url])`.

Net effect:

- Every email attachment tap now opens Quick Look (PDF preview, image preview, text preview — all built in).
- Every feedback attachment tap opens Quick Look.
- "Save As" / "Reveal in Finder" become context-menu items on the chip (macOS only), preserving the prior workflow.

A small migration: the email chip currently takes a `MailAttachment` + `downloader` + `uid` + `folder` + `folderBookmark`. We keep that as-is for the mail path. A new init overload accepts a `ParsedAttachment` + `FeedbackAttachmentDownloader` for the feedback path. Both produce the same chip appearance.

## 8. Mail outbound

### `ComposeRequest` extension

```swift
struct PendingAttachment: Identifiable, Sendable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data
    let imageThumbnail: PlatformImage?   // populated for images
}

struct ComposeRequest {
    // existing fields...
    var attachments: [PendingAttachment] = []
}
```

### Picker UI (`InlineReplyView`, `ComposeFormCore`)

Three affordances, matching the SDK feedback sheet:

1. **Paperclip button** in the toolbar next to send. Opens `NSOpenPanel` (macOS) / `.fileImporter` (iOS). Configured with the same allowlist content types as the SDK.
2. **Drag-and-drop** onto the compose surface (macOS). The editor area becomes a drop target; on enter, a subtle overlay highlights the drop zone.
3. **Paste handler** intercepting `⌘V` in the rich-text editor. If `NSPasteboard.general.image` (macOS) or `UIPasteboard.general.image` (iOS) is non-nil, add as a `pasted-image-<n>.png` attachment instead of inserting into the editor.

Attachments display as the same horizontal strip as in the SDK sheet (thumbnails + chips, each with a remove `x`).

Validation: same SDK limits (3 / 5 MB / 10 MB total). Send is disabled while violated; an inline red banner explains.

### `MailComposer` change

`MailComposer.compose(...)` gains:

```swift
func compose(
    draft: DraftMessage,
    context: PlaceholderContext,
    template: MailTemplate,
    messageID: String? = nil,
    replyHeaders: ReplyHeaderBuilder.Output? = nil,
    attachments: [PendingAttachment] = []
) -> SwiftMail.Email
```

For each `PendingAttachment` it appends a `SwiftMail.Attachment` to the produced email with `filename`, `mimeType`, and `data`. `MailSender` already takes a built `SwiftMail.Email`, so no downstream change.

Per SwiftMail's API, the resulting MIME structure is `multipart/mixed` containing the existing `multipart/alternative` (text+html) and one part per attachment.

## 9. SDK → email thread mirror

### Template placeholder

`MailTemplate` already supports placeholders rendered by `MailComposer.applyPlaceholders`. Add `{{feedback_attachments}}`.

For each `ParsedAttachment` on the originating issue, render two forms:

**HTML (rendered inside the existing template HTML)**:
```html
<div class="feedback-attachments">
  <a href="{url}"><img src="{url}" alt="{filename}" style="max-width:240px;border-radius:6px"/></a>   <!-- images -->
  <div><a href="{url}">{filename}</a> ({size})</div>                                                   <!-- non-images -->
</div>
```

**Text (used in the plain-text part)**:
```text
Attachments:
- {filename} — {url}
- {filename} — {url}
```

The placeholder expands to empty string when the issue has no attachments.

### `PlaceholderContext` change

```swift
struct PlaceholderContext {
    // existing fields...
    var feedbackAttachments: [ParsedAttachment] = []
}
```

The acknowledgement-send path in `MailToGitHubMirror` (or wherever the initial outbound is composed for SDK-sourced issues) populates this from the parsed body.

### Why links, not re-attached bytes

We don't re-download from `raw.githubusercontent.com` and re-attach as MIME parts in v1. Reasons:

- Same bytes already on GitHub — no duplicated storage.
- The 25 MB SMTP cap on Gmail/iCloud is already lower than what 3×5 MB could fit, so always-attach risks bouncing.
- The private-repo caveat is the one downside, documented up front.

This is reversible: a future "re-attach when private repo" mode is small (download with the inbox PAT, attach via `SwiftMail.Attachment`).

## 10. Error handling & partial-failure semantics

Phases ordered by side-effect commitment:

| Phase | Failure case | State left behind |
| --- | --- | --- |
| Sync validation | `attachmentValidation(.tooMany / .fileTooLarge / .totalSizeTooLarge / .unsupportedMimeType)` | None — caller fixes inputs and retries. |
| Image preprocessing | `attachmentValidation(.imageProcessingFailed(filename))` | None. |
| Branch ensure | `attachmentUpload(filename: "", underlying:)` | Possibly a created (empty) branch on partial branch-create. Idempotent — next submission's `ensure` succeeds. |
| Per-file upload (file N of M) | `attachmentUpload(filename, underlying)` | Files 1..N-1 already committed as orphan blobs. No issue created. |
| Issue create | `transport / httpStatus / decoding` (existing cases) | All M files committed as orphan blobs. No issue created. |

The `attachmentUpload` case is **terminal for the submission** — we don't try to roll back successful uploads. The orphan blobs are documented and accepted; a future janitor is out of scope.

Inbox download failures (HTTPS 404 / network / permission) surface in the chip state as `failed` with a tap-to-retry. Cached `FeedbackAttachmentLocal` rows with a missing file on disk re-download transparently — same pattern as the existing mail downloader.

### Logging

SDK errors are not logged to disk inside the SDK; consumers pass them through `onError` to whatever observability they have. Inbox downloader failures log to the existing `ActivityLog`.

## 11. Testing strategy

### SDK tests (`AppFeedbackSDK/Tests/AppFeedbackCoreTests`)

- **`FeedbackAttachmentValidatorTests`** — one test per rule (too-many, per-file, total, mime). Synthesized inputs only.
- **`ImagePreprocessorTests`** — sample HEIC with embedded GPS → JPEG output, assert no GPS via `CGImageSource.copyMetadataAtIndex`. JPEG-with-EXIF → re-encoded EXIF absent. Over-the-limit JPEG that fails post-transcode check.
- **`IssueBodyFormatterTests`** — empty attachments emits no markers; mixed images/files emit correct ordering and trailing `— mime, size` suffix; submission with images-only; non-images-only.
- **`IssueBodyParserTests`** — happy path roundtrip; missing close marker (forgiving); missing mime/size suffix; unknown future marker (`attachments-v2`) skipped; malformed line skipped (forgiving).
- **`GitHubDirectTransportTests`** — `URLProtocol`-stubbed cases:
  - Happy path: ensure (404 → create), upload x3, issue create.
  - Branch already exists: ensure (200), upload x3, issue create.
  - Upload 2 of 3 fails → `attachmentUpload` thrown, no issue-create call observed.
  - Branch-create fails → `attachmentUpload(filename:"", ...)`.
- **`RoundtripTests`** — extend the existing roundtrip to cover attachments (build `FeedbackReport` → format → parse → assert `ParsedAttachment[]` equality).

### Inbox tests (`AppFeedbackTests`)

- **`FeedbackAttachmentDownloaderTests`** — `URLProtocol`-stubbed: first-call downloads & records; second call returns cached; cached + file-missing-on-disk re-downloads.
- **`MailComposerAttachmentsTests`** — compose with N attachments → produced `SwiftMail.Email` has expected MIME parts (mock SwiftMail or assert on the public properties).
- **`AttachmentMirrorTests`** — `{{feedback_attachments}}` placeholder expands correctly with images + files; renders empty when context has none.
- **`IssueBodyParserShimTests`** — the inbox shim passes the new `attachments` field through.

### UI smoke tests

- **`FeedbackSheetAttachmentsSmokeTests`** (`AppFeedbackSDK/Tests/AppFeedbackUITests`): paperclip button visible; drop / paste simulation adds an attachment; over-limit shows error banner; submit calls transport with attachments.
- **`IssueCardAttachmentsSmokeTests`** (`AppFeedbackTests`): card with attachments renders thumbnail strip; tap presents Quick Look (asserted via the presenter spy).

## 12. Tradeoffs & future work

### Tradeoffs accepted

- **Inbox repo bloat.** Attachments live on a branch in the same repo. Long-term repo grows by user uploads. Mitigation deferred.
- **Private-repo email mirror caveat.** See §1. Documented; revisit when configurable storage is on the table.
- **Orphan blobs on partial failure.** See §4. Janitor deferred.
- **No re-attached bytes on outbound mirror.** See §9. Reversible.
- **Hardcoded SDK defaults.** No `attachmentsRepo` / `attachmentsBranch` parameter in v1. Adds API surface later if needed; no on-the-wire migration required (it'd be a new arg on `GitHubDirectTransport.init`).

### Likely future work

- Configurable attachments repo (single-line `init` change).
- Janitor that reconciles `feedback-attachments` blobs against open issues.
- On-device image annotation in the SDK sheet (markup, redact).
- Re-attach actual bytes in the outbound mirror when inbox repo is private.
- `attachments-v2` body format if/when we need additional metadata fields. Forward-compatible by design.

### Out of scope, explicitly

- Server-side relay transport for attachments (the `FeedbackTransport` protocol stays the same; relay implementations can route attachments however they wish).
- Per-attachment access-control / signed URLs.
- Inline image embedding in outbound mail via `cid:` references.
- Markdown other than the marker block (e.g. inline image syntax inside the user description) — out of scope, would require a different parser.
