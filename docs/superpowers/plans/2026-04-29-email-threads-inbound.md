# Plan B — Inbound Email Threads + UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show full email threads (sent + received replies) under each `FeedbackIssue` with collapse/expand UX, fetched live from IMAP and synced across devices via CloudKit. Reply inline. Lazy-download attachments.

**Architecture:** SwiftData `@Model` types (`MailThread` / `MailMessage` / `MailAttachment`) join the cloud schema; `IMAPClient` (actor, SwiftMail-backed) fetches new mail on a schedule driven by `MailSyncCoordinator`; `ThreadMatcher` (pure functions) attaches inbound mail to threads via `In-Reply-To` / `References`, with a subject fallback. UI: `MailThreadView` embedded at the bottom of `IssueCardView`, with a per-thread and per-message collapse state.

**Tech Stack:** SwiftMail (IMAP — already validated cross-platform in Plan A), SwiftData + CloudKit private DB, SwiftUI, iCloud Keychain (for IMAP password — already wired in Plan A).

**Spec:** `docs/superpowers/specs/2026-04-29-email-threads-design.md`
**Builds on:** `docs/superpowers/plans/2026-04-29-credential-sync-ios-smtp.md` (must ship first)

---

## File Plan

### Create — Models (cloud schema)

| Path | Purpose |
|---|---|
| `AppFeedback/Models/MailThread.swift` | `@Model` for one conversation thread |
| `AppFeedback/Models/MailMessage.swift` | `@Model` for an individual message inside a thread |
| `AppFeedback/Models/MailAttachment.swift` | `@Model` for attachment metadata only (bytes stay off CloudKit) |

### Create — Models (local schema)

| Path | Purpose |
|---|---|
| `AppFeedback/Models/MailAttachmentLocal.swift` | Per-device record of where a downloaded attachment lives on disk |
| `AppFeedback/Models/MailAccountLocalState.swift` | Per-device IMAP cursors (UID + UIDValidity) + backoff counter |

### Create — Services

| Path | Purpose |
|---|---|
| `AppFeedback/Services/Mail/MailThreadStore.swift` | `@MainActor` SwiftData CRUD over the three thread models, with `Message-ID` dedupe and thread-merge logic |
| `AppFeedback/Services/Mail/ThreadMatcher.swift` | Pure functions: header-based attach, subject fallback, issue-link by subject substring against `RepoStore` cached titles |
| `AppFeedback/Services/Mail/IMAPClient.swift` | Actor wrapping SwiftMail's `IMAPServer`/`IMAPConnection`; surface `connect()` / `listInboxSince(uid:)` / `listSentSince(date:)` / `fetchMessage(uid:)` / `fetchAttachmentBytes(uid:partID:)` |
| `AppFeedback/Services/Mail/MailSyncCoordinator.swift` | Actor that schedules polls (launch + foreground interval + manual), drives one-time backfill, writes through `MailThreadStore`, logs to `ActivityLog` |
| `AppFeedback/Services/Mail/AttachmentDownloader.swift` | Actor that fetches body-part bytes via `IMAPClient`, writes to the user's chosen folder, records `MailAttachmentLocal` |
| `AppFeedback/Services/Mail/AttachmentFolder.swift` | Cross-platform helper: resolve security-scoped bookmark on macOS, use iOS-picked Files folder, fall back to `~/Downloads` / app `Documents/Attachments` |

### Create — UI

| Path | Purpose |
|---|---|
| `AppFeedback/Views/Mail/MailThreadView.swift` | Collapsible thread block (list of messages, per-message collapse, "Reply" button) |
| `AppFeedback/Views/Mail/MailMessageRowView.swift` | One message, with sender/date header, body (HTML rendered through existing sanitizer), attachment chips |
| `AppFeedback/Views/Mail/AttachmentChipView.swift` | Pill: filename + size, tap to download + open |

### Modify

| Path | What changes |
|---|---|
| `AppFeedback/App/AppFeedbackApp.swift` | Add the new five `@Model` types to schemas + `ModelContainer.for:`; create `MailThreadStore` and `MailSyncCoordinator`; pass via `@Environment`; trigger `coordinator.start()` on app launch and on scenePhase `.active` |
| `AppFeedback/Models/MailAccount.swift` | Adds nothing; existing `backfillCompleted` / `pollIntervalSeconds` / `pollingEnabled` / `attachmentFolderBookmark` are now used |
| `AppFeedback/Views/Issues/IssueCardView.swift` | Embed `MailThreadView` at the bottom of the card; collapsed by default, "X messages — last reply Yd ago" header expands |
| `AppFeedback/Views/Settings/EmailSettingsView.swift` | Add: polling toggle + interval picker; attachment-folder picker (`NSOpenPanel` on Mac); "Refresh now" button; IMAP test-connection button mirroring SMTP one |
| `AppFeedback/Services/ActivityLog.swift` | Add `Kind` cases: `fetchMail`, `downloadAttachment` |
| `AppFeedback/Views/Mail/ComposeMailView.swift` | (Already accepts `inReplyTo`; no further changes — used as the inline-reply composer) |
| `AppFeedback/Views/Settings/IOSEmailSettingsView.swift` (NEW) | iOS-native settings UI for SMTP/IMAP/template/attachment folder. Mirrors the macOS form using SwiftUI `Form` + `NavigationStack`; uses `UIDocumentPickerViewController` for attachment folder |
| `AppFeedback/Views/Settings/SettingsView.swift` | iOS branch routes to `IOSEmailSettingsView` when present |

### Tests (create unless noted)

| Path | Coverage |
|---|---|
| `AppFeedbackTests/MailThreadStoreTests.swift` | Insert idempotency by `Message-ID`, thread merge on collision, cascade delete, reparenting on backfill, issue-link upsert |
| `AppFeedbackTests/ThreadMatcherTests.swift` | Header `In-Reply-To` match, `References` chain match, no match → new thread, subject fallback (Re-stripped equality, recipient mismatch, multiple candidates → newest wins), issue-link by subject substring |
| `AppFeedbackTests/IMAPSyntheticIDTests.swift` | UID + UIDValidity → synthetic Message-ID format; round-trips through `MessageIDGenerator.isSynthetic` |
| `AppFeedbackTests/MailSyncCoordinatorTests.swift` | `MockIMAPClient` returning canned messages: dedupe across polls, failure path writes ActivityLog and backs off, manual refresh forces poll regardless of interval, backfill runs once and flips `MailAccount.backfillCompleted` |
| `AppFeedbackTests/AttachmentDownloaderTests.swift` | Idempotent download (returns existing local path on second call), folder fallback when bookmark fails to resolve, `MailAttachmentLocal` row written |
| `AppFeedbackTests/MailThreadViewSnapshotTests.swift` (optional, if SnapshotTesting is already in target) | Skip for v1; defer to manual review |

---

## Build / test commands

Use the `zcode` skill for schemes `AppFeedback_iOS` and `AppFeedback_macOS`. New SwiftData models join the **cloud** schema (`Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, MailThread.self, MailMessage.self, MailAttachment.self])`) and the **local** schema (`Schema([CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self])`).

---

### Task 1: SwiftData models

**Files:** see "Create — Models" above. **Pattern to follow:** `AppFeedback/Models/MailAccount.swift` (defaults on every property, `@Model final class`).

- [ ] **Step 1: Define `MailThread`**

```swift
import Foundation
import SwiftData

@Model
final class MailThread {
    var id: UUID = UUID()
    var messageIDRoot: String = ""
    var subject: String = ""
    var participants: [String] = []
    var lastMessageAt: Date = Date.distantPast
    var issueRepoOwner: String = ""
    var issueRepoName: String = ""
    var issueNumber: Int = 0           // 0 = unlinked
    var matchSourceRaw: String = "direct"
    @Relationship(deleteRule: .cascade, inverse: \MailMessage.thread)
    var messages: [MailMessage] = []

    enum MatchSource: String, Sendable { case direct, header, subjectFallback, backfillFuzzy }
    var matchSource: MatchSource {
        get { MatchSource(rawValue: matchSourceRaw) ?? .direct }
        set { matchSourceRaw = newValue.rawValue }
    }

    var isLinkedToIssue: Bool { issueNumber > 0 }
    init(...) { /* per existing pattern, defaults all */ }
}
```

- [ ] **Step 2: Define `MailMessage`**

Properties from the spec data-model section: `messageID` (primary dedupe), `inReplyTo`, `references` (newline-joined), `fromAddress`, `fromName`, `toAddresses`, `ccAddresses`, `date`, `subject`, `bodyPlain`, `bodyHTML`, `directionRaw` ("outbound"/"inbound"), `thread: MailThread?`, attachments relationship. Provide a computed `headers: MailMessageHeaders` so `ReplyHeaderBuilder.build(parent:newMessageID:)` can be called directly with a stored message.

- [ ] **Step 3: Define `MailAttachment`**

Properties: `id`, `messageID` (denormalized for lookup), `partID`, `filename`, `mimeType`, `sizeBytes`, `message: MailMessage?`. No body data.

- [ ] **Step 4: Define `MailAttachmentLocal` and `MailAccountLocalState`**

```swift
@Model final class MailAttachmentLocal {
    var messageID: String = ""
    var partID: String = ""
    var localPath: String = ""
    var downloadedAt: Date = Date()
    init(...) { ... }
}

@Model final class MailAccountLocalState {
    var accountID: UUID = UUID()
    var inboxLastUID: UInt32 = 0
    var inboxUIDValidity: UInt32 = 0
    var sentLastUID: UInt32 = 0
    var sentUIDValidity: UInt32 = 0
    var lastSuccessfulPollAt: Date? = nil
    var consecutiveFailures: Int = 0
    init(...) { ... }
}
```

- [ ] **Step 5: Register in schemas**

In `AppFeedbackApp.swift`:
- Add `MailThread.self`, `MailMessage.self`, `MailAttachment.self` to `cloudSchema` and the `for:` list.
- Add `MailAttachmentLocal.self`, `MailAccountLocalState.self` to `localSchema` and the `for:` list.

- [ ] **Step 6: Build both schemes** (no behaviour yet)

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(mail): SwiftData models for threads, messages, attachments"
```

---

### Task 2: `MailThreadStore` with dedupe + thread merge

**Files:**
- Create: `AppFeedback/Services/Mail/MailThreadStore.swift`
- Test: `AppFeedbackTests/MailThreadStoreTests.swift`

**API surface** (`@MainActor`):

```swift
final class MailThreadStore {
    init(context: ModelContext)

    func recordOutbound(
        messageID: String,
        repoOwner: String, repoName: String, issueNumber: Int,
        from: String, fromName: String?,
        to: [String], cc: [String],
        subject: String, bodyPlain: String, bodyHTML: String?,
        date: Date,
        replyHeaders: ReplyHeaderBuilder.Output?
    ) -> MailMessage

    func recordInbound(
        message: ParsedInboundMessage  // value type from IMAPClient
    ) -> MailMessage?  // nil if dedupe-skipped

    func attachToIssue(thread: MailThread, owner: String, repo: String, number: Int)

    func threads(forIssue: (owner: String, repo: String, number: Int)) -> [MailThread]

    func mergeThreads(into keep: MailThread, drop: MailThread)
}
```

- [ ] **Step 1: Write failing tests** (in-memory `ModelContainer` with all five mail models). Cover:
  - `recordInbound` is idempotent on duplicate `messageID`
  - `recordInbound` with matching `inReplyTo` appends to existing thread
  - `recordOutbound` creates a thread when none exists; appends when one does
  - `mergeThreads` reparents messages, deletes the dropped thread
  - `attachToIssue` updates denormalized issue fields on a thread

- [ ] **Step 2-N: Implement, alternating with running tests after each method.**

- [ ] **Final step: Commit.**

---

### Task 3: `ThreadMatcher`

**Files:**
- Create: `AppFeedback/Services/Mail/ThreadMatcher.swift`
- Test: `AppFeedbackTests/ThreadMatcherTests.swift`

**Pure functions (no SwiftData dependency — operates on values):**

```swift
enum ThreadMatcher {
    struct Candidate { let messageID: String; let subject: String; let participants: [String]; let lastMessageAt: Date }

    enum AttachResult {
        case header(threadIndex: Int)
        case subject(threadIndex: Int)
        case newThread
    }

    static func attach(
        message: ParsedInboundMessage,
        existing: [Candidate]
    ) -> AttachResult

    static func matchToIssue(
        threadSubject: String,
        knownIssueTitles: [(owner: String, repo: String, number: Int, title: String)]
    ) -> (owner: String, repo: String, number: Int)?
}
```

`ParsedInboundMessage` is the IMAPClient's value-type output (define in this same task or in Task 4 — pick one and stay consistent).

- [ ] Tests cover (each test = own `ThreadMatcher.attach(...)` call):
  - In-Reply-To matches one candidate → `.header`
  - References chain matches → `.header`
  - No header match, subject "Re: foo" + recipient overlap → `.subject`
  - No header match, subject "Re: foo" but recipients disjoint → `.newThread`
  - Two candidates match by subject → newest wins
  - `matchToIssue`: substring match (case-insensitive); no match → nil; multiple matches → most recent issue wins (assume titles are stable enough for this heuristic)

- [ ] Commit.

---

### Task 4: `IMAPClient`

**Pre-flight (do this first, separately from any other code):** open `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/checkouts/SwiftMail/Sources/SwiftMail/IMAP/` and skim:
- `IMAPServer.swift` / `IMAPConnection.swift` (connect, login, select)
- `Sources/SwiftMail/IMAP/IMAP/` (UID search / fetch APIs)

Confirm: SwiftMail can list messages by UID > X, fetch headers + body, fetch a specific body part. If any capability is missing, **stop and escalate** — the spec's fallback is swift-nio-imap, but that's a meaningful re-plan.

**Files:**
- Create: `AppFeedback/Services/Mail/IMAPClient.swift`
- Create: `AppFeedback/Services/Mail/ParsedInboundMessage.swift` (value type)

**API:**

```swift
struct ParsedInboundMessage: Sendable {
    let uid: UInt32
    let folder: String
    let uidValidity: UInt32
    let messageID: String          // synthesized if missing using UID + UIDValidity
    let inReplyTo: String?
    let references: [String]
    let fromAddress: String
    let fromName: String?
    let toAddresses: [String]
    let ccAddresses: [String]
    let date: Date
    let subject: String
    let bodyPlain: String
    let bodyHTML: String?
    let attachments: [ParsedAttachmentMeta]   // metadata only; no bytes
}

struct ParsedAttachmentMeta: Sendable {
    let partID: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
}

actor IMAPClient {
    init(host: String, port: Int, username: String, password: String)

    func listInbox(sinceUID: UInt32) async throws -> [ParsedInboundMessage]
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage]   // for backfill
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data
    func testConnection() async throws
}
```

Implementation notes:
- Always synthesize `messageID` when `Message-ID` header is missing: `<uid-\(uid).\(uidValidity)@imap-synthetic>`. `MessageIDGenerator.isSynthetic` already detects this format.
- HTML body — sanitize via existing `HTMLSanitizer` **before** returning (callers shouldn't have to remember).
- Errors: typed `IMAPClientError` enum with `.notConnected`, `.authFailed`, `.malformed(detail:)`, `.passwordUnavailable`, `.cancelled`, `.transport(underlying:)`. `MailSyncCoordinator` keys retry behaviour off these.

- [ ] **Step 1: Skim SwiftMail IMAP API** — record the actual function signatures you'll use in a comment at the top of `IMAPClient.swift`.
- [ ] **Step 2: Implement the actor** + a small set of integration-style tests against a recorded IMAP fixture. **No live network in tests** — if SwiftMail forces real I/O, write a thin `IMAPSession` protocol that the actor uses, and stub it in tests.
- [ ] Commit.

---

### Task 5: `MailSyncCoordinator`

**Files:**
- Create: `AppFeedback/Services/Mail/MailSyncCoordinator.swift`
- Test: `AppFeedbackTests/MailSyncCoordinatorTests.swift`

**Behaviour:**
- Triggers: `start()` (launch), `pollNow()` (manual / scenePhase `.active` after stale interval), and an internal `Task` that sleeps `pollIntervalSeconds`.
- Reads `MailAccount` (CloudKit-synced) + `MailAccountLocalState` (per-device cursor) + IMAP password from Keychain.
- On each poll: connect, fetch new mail since `inboxLastUID`, hand each `ParsedInboundMessage` to `MailThreadStore.recordInbound(...)`, advance cursor on success, log to `ActivityLog`.
- Backoff: per-call retry with exponential backoff capped at the configured interval; auth failures suspend backoff and surface a banner via a published `Status` enum (`.idle`, `.polling`, `.authFailed(message:)`, `.transient(error:)`).
- Backfill: if `MailAccount.backfillCompleted == false`, run `IMAPClient.listSent(sinceDate:)` once on the first successful connect, hand to `ThreadMatcher.matchToIssue`, then flip the flag.

**Tests** use `MockIMAPClient` (define `protocol IMAPClientProtocol` Task 4 conforms to). Cover:
- Two polls returning the same message dedupe via `MailThreadStore`
- A returned auth error sets `.authFailed`, suspends backoff
- `pollNow` while a poll is in flight is coalesced (no concurrent IMAP connects)
- `backfillCompleted` flips after first successful sent-folder scan

- [ ] Implement with TDD; one test per behaviour. Commit.

---

### Task 6: `MailThreadView`

**Files:**
- Create: `AppFeedback/Views/Mail/MailThreadView.swift`
- Create: `AppFeedback/Views/Mail/MailMessageRowView.swift`

`MailThreadView`:
- Input: `[MailMessage]` (sorted by date), parent issue context (for the inline-reply target), and a binding to thread-level expansion state. Source of truth for expansion: a `@State` map `[UUID: Bool]` keyed by `MailThread.id` lifted to the parent (so collapse state survives re-renders without re-fetch).
- Header row: "X messages — last reply Yd ago" + chevron. Tapping toggles `isExpanded`.
- When expanded: vertical stack of `MailMessageRowView`, plus a `Reply` button under the last message that opens `ComposeMailView(recipient:..., issue:..., inReplyTo: lastMessage.headers)` in a sheet.

`MailMessageRowView`:
- Compact: from-name (or address), date, subject if it differs from thread subject, first ~120 chars of plain body, attachment count badge.
- Expanded: full body. HTML rendered through `WebView` (macOS) / `WKWebView` (iOS) with `loadHTMLString`, sandboxed (no JS, no network — `HTMLSanitizer` already strips). Plain-text fallback if `bodyHTML == nil`.
- Per-message expansion: `@State private var isExpanded: Bool` (each row owns its own).

- [ ] Build both schemes; manually preview in Xcode Canvas with a hand-rolled fixture.
- [ ] Commit (no automated tests — UI-only).

---

### Task 7: Embed `MailThreadView` in `IssueCardView`

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`

At the bottom of the existing card layout (after the meta-tag row, before the closing container):

```swift
@Environment(MailThreadStore.self) private var threadStore
// ...
let threads = threadStore.threads(forIssue: (repoOwner, repoName, issue.number))
if !threads.isEmpty {
    Divider()
    ForEach(threads) { thread in
        MailThreadView(thread: thread, repoOwner: repoOwner, repoName: repoName)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}
```

> Note: `IssueCardView` doesn't currently have `repoOwner`/`repoName` — thread them through from `IssueListView` (already has both via `loader`). Add as parameters with no defaults so call sites must update.

- [ ] Build both schemes. Manually verify with a fixture: insert a `MailThread` into the in-memory store, run the app, see the thread appear under its issue.
- [ ] Commit.

---

### Task 8: Inline reply

**Files:**
- Modify: `AppFeedback/Views/Mail/MailThreadView.swift` (Reply button → sheet)
- Modify: `AppFeedback/Views/Mail/ComposeMailView.swift` only if subject prefill needs adjusting (it already accepts `inReplyTo`)

In `MailThreadView`, when the user taps Reply:
- Build `MailMessageHeaders(messageID: last.messageID, inReplyTo: last.inReplyTo, references: last.referencesAsArray)`.
- Set state `replyParent = headers` and present `ComposeMailView(recipient: last.fromAddress, issue: ..., inReplyTo: headers)`.
- Subject should be prefilled with `Re: ` (only one — strip leading `Re:`/`Fwd:` from the existing subject first). Add a small helper `String.replyPrefixed()` in `MailComposer.swift` or a new `MailSubject.swift` and unit-test it.

- [ ] Add `MailSubjectTests.swift` — `replyPrefixed` strips multiple `Re: Re:` collapses to one.
- [ ] Commit.

---

### Task 9: `AttachmentDownloader` + `AttachmentChipView`

**Files:**
- Create: `AppFeedback/Services/Mail/AttachmentDownloader.swift`
- Create: `AppFeedback/Services/Mail/AttachmentFolder.swift`
- Create: `AppFeedback/Views/Mail/AttachmentChipView.swift`
- Test: `AppFeedbackTests/AttachmentDownloaderTests.swift`

`AttachmentFolder.resolveDestination(account: MailAccount) -> URL`:
- macOS: resolve `attachmentFolderBookmark` (security-scoped). Fall back to `~/Downloads` on failure.
- iOS: same idea; fall back to `FileManager.default.urls(for: .documentDirectory, ...).first!.appendingPathComponent("Attachments", isDirectory: true)`.

`AttachmentDownloader.download(messageID:partID:filename:)`:
- Look up `MailAttachmentLocal` first; if path exists, return it.
- Else `IMAPClient.fetchAttachmentBytes`, write atomically with security-scoped access on Mac, insert `MailAttachmentLocal`.
- Returns the URL.

`AttachmentChipView`:
- Pill with paperclip + filename + size. Tap → call downloader. Spinner while downloading. On success, open via `NSWorkspace.shared.open(url)` (Mac) or share sheet (iOS).

- [ ] Tests use a `MockIMAPClient` that returns canned bytes. Cover idempotency, fallback when bookmark fails to resolve, write to fallback folder.
- [ ] Commit.

---

### Task 10: Folder picker + IMAP test connection in `EmailSettingsView`

**Files:**
- Modify: `AppFeedback/Views/Settings/EmailSettingsView.swift`

Add three things:
- Toggle: "Auto-fetch replies" → bound to `MailAccount.pollingEnabled`.
- Stepper: "Every X minutes" → `pollIntervalSeconds / 60`.
- Folder picker: button "Attachments folder…" + label of resolved path. Uses `NSOpenPanel` (folder selection only) on Mac. Stores the security-scoped bookmark in `MailAccount.attachmentFolderBookmark`.
- "Refresh now" button → `coordinator.pollNow()`.
- "Test IMAP connection" button next to the existing SMTP test.

- [ ] Build, manual test on Mac. Commit.

---

### Task 11: iOS-native `EmailSettingsView`

**Files:**
- Create: `AppFeedback/Views/Settings/IOSEmailSettingsView.swift`
- Modify: `AppFeedback/Views/Settings/SettingsView.swift` (route iOS to it)

iOS doesn't have `Settings` scene — settings live inside the app's nav stack (likely already wired in `RootView`). Build a SwiftUI `Form` with the same sections as the macOS version: provider picker, SMTP credentials, IMAP credentials, header/footer template, attachment folder (`UIDocumentPickerViewController` representable), polling toggle/interval, "Refresh now", test buttons.

This is the largest UI task — budget roughly a day. Mirror the existing macOS form section layout.

- [ ] Build iOS scheme; manually verify on simulator.
- [ ] Commit.

---

### Task 12: Wire up coordinator + final verification

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- Create `MailSyncCoordinator` after `MailAccountStore` / `MailThreadStore`.
- Pass via `@Environment` to views that need `pollNow` (settings, thread view's manual refresh).
- Hook scenePhase: on `.active` after >= 5 minutes since `lastSuccessfulPollAt`, call `coordinator.pollNow()`.
- On macOS, also run on app activation (`Window` `onChange(of: scenePhase)` already exists — add the same trigger).

- [ ] **Step 1: Run full test suite on both schemes via zcode.** All green expected (modulo the pre-existing translation flake).
- [ ] **Step 2: Manual E2E test plan**
  1. Configure SMTP + IMAP creds on Mac (Gmail with app password is easiest).
  2. Open a feedback issue with an `email` field. Tap Email → send a test email to a test address.
  3. From the test address, reply.
  4. Wait for poll cycle (≤ 5 min) or hit Refresh now. Confirm the reply appears under the issue's thread.
  5. Tap Reply on the inbound message; confirm subject is `Re: …` (no double-prefix), recipient is the original sender, and the new outbound stamps `In-Reply-To` headers correctly (verify via the recipient's mail client).
  6. Send an email with an attachment from the test address. Confirm the chip appears; tap → file downloads to the configured folder.
  7. On iOS (same iCloud account): verify the thread appears within ~30s of the macOS view via CloudKit sync. IMAP password should be available via iCloud Keychain.

- [ ] **Step 3: Done.**

---

## Self-Review

**Spec coverage** (against `2026-04-29-email-threads-design.md`):
- IMAP poll + reply matching (header + subject fallback) ✅ Tasks 4, 3, 5
- Thread storage with CloudKit sync ✅ Tasks 1, 2
- Backfill from Sent folder ✅ Task 5
- Two-device dedupe via Message-ID ✅ Task 2
- Thread UI under issue with collapse/expand ✅ Tasks 6, 7
- Inline reply with header threading ✅ Task 8 (uses Plan A's plumbing)
- Attachments lazy-download with user-chosen folder ✅ Tasks 9, 10
- iOS settings UI ✅ Task 11
- Polling cadence (launch + interval + manual) ✅ Tasks 5, 12

**Type consistency:** `ParsedInboundMessage` is the boundary type between `IMAPClient` and `MailThreadStore` / `ThreadMatcher`. `MailMessageHeaders` (from Plan A) is what `ReplyHeaderBuilder` consumes — `MailMessage` exposes a computed `headers` property that returns a `MailMessageHeaders` from its stored fields, so consumers don't have to construct one ad-hoc. `MatchSource` enum is defined once on `MailThread`.

**Placeholder scan:** No "TBD" / "implement later". Two soft pre-flight items are explicitly flagged with stop-and-escalate criteria (SwiftMail IMAP capability in Task 4; folder bookmark behaviour in Task 9).

**Scope check:** Tasks are sequenced bottom-up: data → IMAP → UI → polish. Each task is independently committable (the system stays buildable between tasks; UI tasks degrade to "no threads visible" rather than breaking when prior tasks are partially done).
