# Email Threads Under Each Feedback

**Date:** 2026-04-29
**Status:** Design

## Goal

Show the full email conversation (sent + replies) under each `FeedbackIssue` in the issue list. The whole thread is collapsible; each individual message inside the thread is also collapsible. The user can reply inline. Threads sync via iCloud so they appear on every device.

A secondary goal: bring SMTP-based sending to iOS (today the iOS path opens `mailto:`), and sync SMTP/IMAP credentials across devices.

## Non-goals

- OAuth-based provider integrations (Gmail API, Microsoft Graph, etc.). Authentication is plain SMTP/IMAP with app passwords.
- Storing attachment binary contents in CloudKit. Only metadata syncs; blobs are downloaded per-device on demand.
- Push-style mail delivery (IMAP IDLE). v1 polls.
- Importing arbitrary mailbox history that wasn't sent from this app's account or doesn't match a feedback issue.
- Rich threading UX beyond the issue list (no separate "Mail" tab).

## Core decisions (locked in via brainstorming)

| Decision | Choice |
|---|---|
| Inbound transport | IMAP, polled |
| Reply matching | `Message-ID`/`In-Reply-To`/`References` headers, with subject fallback (`Re:`-stripped equality + recipient match) |
| Poll cadence | On launch + every 5 min while foregrounded + manual refresh; configurable |
| Backfill | Best-effort scan of Sent folder on first IMAP success; subject substring match against issue titles |
| Storage | SwiftData `@Model` types in the cloud schema; iCloud-synced |
| Dedupe key | `Message-ID` (synthesized from UID + UIDValidity if absent) |
| Multi-device polling | Both Mac + iOS poll; `Message-ID` dedupe in `MailThreadStore` |
| Thread UI placement | Inline on `IssueCardView`, collapsed by default, expandable; per-message collapse inside |
| Reply UX | Inline composer in the thread; sets `In-Reply-To` + `References` |
| iOS send path | Same SwiftMail SMTP path as macOS (replaces today's `mailto:`) |
| Credential sync | SMTP/IMAP metadata in SwiftData cloud schema; passwords in iCloud Keychain (`kSecAttrSynchronizable=true`) |
| Attachment handling | Lazy download to user-chosen folder (default `~/Downloads` mac, `Documents/Attachments` iOS) |

## Architecture

### New services

- **`IMAPClient`** (actor) — connects, lists Inbox + Sent, fetches headers/bodies/attachment metadata. Built on SwiftMail's IMAP support; if a critical capability is missing, fall back to swift-nio-imap. Capability check is the first task in the implementation plan.
- **`MailThreadStore`** (`@MainActor`) — SwiftData CRUD over `MailThread` / `MailMessage` / `MailAttachment`. Owns dedupe by `Message-ID` and issue↔thread linking.
- **`MailSyncCoordinator`** (actor) — schedules polls (launch + interval + manual), drives one-time backfill, writes through `MailThreadStore`, logs to `ActivityLog`.
- **`AttachmentDownloader`** (actor) — lazy fetch by `(messageID, partID)`, writes to the user's folder, records `MailAttachmentLocal`.
- **`ThreadMatcher`** — pure functions: header-based matching, subject-fallback matching, issue↔thread matching by subject substring.
- **`KeychainCredentials`** — wrapper around `SecItem` calls with `kSecAttrSynchronizable=true`, used for both SMTP and IMAP passwords. Shared keychain access group between the iOS and macOS targets.

### Changes to existing code

- **`MailSettings`** → migrated. The `SMTPCredentials` struct + template are replaced by a SwiftData `@Model MailAccount` in the cloud schema. A one-time migration on first launch reads the old `UserDefaults` blob and inserts a `MailAccount`. Passwords already live in Keychain — they're rewritten to be iCloud-synced.
- **`MailComposer`** / **`ComposeMailViewModel`** → take optional `inReplyTo: MailMessage?`. When present, set `In-Reply-To` and `References`, prefill `Re:` subject, swap recipient.
- **`MailComposer`** → always stamp outbound mail with a fresh `Message-ID` of the form `<uuid@app-feedback.local>`.
- **`IssueCardView`** (iOS branch at `IssueCardView.swift:209`) → replace `mailto:` open with the existing macOS `ComposeMailView` flow. The `#if os(macOS) && canImport(SwiftMail)` guard on `ComposeMailView` becomes `#if canImport(SwiftMail)` so iOS gets the same view.
- **`IssueCardView`** → add a thread block at the bottom: "X messages — last reply Yd ago" (collapsed by default), expandable to a `MailThreadView`.
- **`ActivityLog`** — add new `Kind` cases: `fetchMail`, `downloadAttachment`.

### New UI

- **`MailThreadView`** — embedded in `IssueCardView`. Collapse/expand at thread level and per-message. Each message renders sender, date, subject (when different), body (HTML rendered via existing sanitizer; plain-text fallback), attachment chips.
- **`EmailSettingsView`** (existing) gains: IMAP host/port/username/password section, polling toggle + interval picker, attachment folder picker (Files/`NSOpenPanel`), "Refresh now" button, IMAP test-connection button mirroring the SMTP one.

## Data model

### Cloud schema (`Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, MailThread.self, MailMessage.self, MailAttachment.self])`)

```swift
@Model final class MailAccount {
    var id: UUID
    var preset: String                    // gmail / icloud / outlook / custom
    var smtpHost: String
    var smtpPort: Int
    var smtpUsername: String
    var senderName: String
    var imapHost: String
    var imapPort: Int
    var imapUsername: String
    var pollIntervalSeconds: Int          // default 300
    var pollingEnabled: Bool              // default true
    var attachmentFolderBookmark: Data?   // security-scoped, per-device
    var templateHeaderHTML: String
    var templateFooterHTML: String
    var backfillCompleted: Bool           // default false
}

@Model final class MailThread {
    var id: UUID
    var messageIDRoot: String             // anchor for dedupe / thread merge
    var subject: String
    var participants: [String]
    var lastMessageAt: Date
    var issueRepoOwner: String
    var issueRepoName: String
    var issueNumber: Int                  // 0 sentinel = "unlinked"
    var matchSource: String               // header | subjectFallback | backfillFuzzy | direct
    @Relationship(deleteRule: .cascade) var messages: [MailMessage]
}

@Model final class MailMessage {
    var id: UUID
    var messageID: String                 // primary dedupe key
    var inReplyTo: String?
    var references: String                // newline-joined
    var fromAddress: String
    var fromName: String?
    var toAddresses: [String]
    var ccAddresses: [String]
    var date: Date
    var subject: String
    var bodyPlain: String                 // always present
    var bodyHTML: String?                 // sanitized via HTMLSanitizer
    var direction: String                 // outbound | inbound
    var thread: MailThread?
    @Relationship(deleteRule: .cascade) var attachments: [MailAttachment]
}

@Model final class MailAttachment {
    var id: UUID
    var messageID: String                 // parent's Message-ID
    var partID: String                    // IMAP body part id
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var message: MailMessage?
}
```

### Local schema (per-device, alongside `CachedIssue`)

```swift
@Model final class MailAttachmentLocal {
    var messageID: String
    var partID: String
    var localPath: String
    var downloadedAt: Date
}

@Model final class MailAccountLocalState {
    var accountID: UUID                   // matches MailAccount.id
    var inboxLastUID: UInt32
    var inboxUIDValidity: UInt32          // reset cursor if server changes this
    var sentLastUID: UInt32
    var sentUIDValidity: UInt32
    var lastSuccessfulPollAt: Date?
    var consecutiveFailures: Int          // drives backoff
}
```

Per-device IMAP cursors live here, not in the cloud schema, because UID/UIDValidity are server-session-specific and not meaningful across devices.

Attachment **bytes** stay off CloudKit (size, privacy, cost). Metadata syncs so the user sees a paperclip on iPad and can fetch the file there separately.

### Keychain (iCloud-synced)

- `smtp.password` and `imap.password` — `kSecAttrSynchronizable = true`, shared access group between iOS and macOS targets so both can read.

### Dedupe rule

On every `MailThreadStore.recordInbound` / `recordOutbound`: fetch `MailMessage` by `messageID` first; if it exists, return without inserting. CloudKit doesn't enforce uniqueness, so dedupe lives in the store.

### Issue linking

- **Direct (preferred):** when a user sends from an issue, the issue ID is known and stamped on the new `MailThread` at insert time.
- **Backfill / unmatched:** subject substring match against `RepoStore` issue titles. If nothing matches, the thread is stored with `issueNumber = 0` and hidden from the UI until a future reconcile pass.

### Attachment folder caveat

`attachmentFolderBookmark` is a security-scoped bookmark — only meaningful on the device that created it. It rides along in CloudKit but resolves to nothing on other devices, which then fall back to `~/Downloads` (mac) or `Documents/Attachments` (iOS). UX: users should expect to pick the folder once per device.

## Data flow

### Send (new outbound from an issue)

1. User taps "Email" on `IssueCardView` → `ComposeMailView` opens, prefilled from the issue.
2. User hits Send → `ComposeMailViewModel` builds `DraftMessage`, generates a fresh `Message-ID`, passes it to `MailComposer`, which stamps the header on the `SwiftMail.Email`.
3. `MailSender` SMTPs it.
4. On success, `MailThreadStore.recordOutbound(...)` inserts a `MailMessage(direction: outbound)` and creates a `MailThread` linked to the issue. `ActivityLog` gets a `sendEmail` entry as today.
5. CloudKit syncs the new thread/message.

### Reply (inline)

1. User expands a thread, taps Reply on the last message → inline composer opens with subject `Re:` prefilled, recipient = original sender, hidden `inReplyTo: MailMessage` reference.
2. Send path is identical to above except `MailComposer` writes `In-Reply-To: <originalID>` and `References: <root> ... <originalID>`.
3. The new outbound `MailMessage` is appended to the thread immediately (we don't wait for IMAP confirmation).

### Inbound poll

1. `MailSyncCoordinator` triggers on app launch, every `pollIntervalSeconds` while foregrounded, on manual refresh, and once after credential setup.
2. Coordinator asks `IMAPClient` for messages in Inbox newer than `lastInboundUID` (per-account cursor stored locally — UID validity is per-server-per-device).
3. For each new message, `IMAPClient` fetches headers + body parts + attachment metadata (no blobs).
4. `ThreadMatcher.attach(message:)`:
    - `In-Reply-To` matches an existing `MailMessage.messageID` → append.
    - Else any `References` ID matches → append.
    - Else `Re:`-stripped subject + recipient pair match an existing thread we sent → append, `matchSource = subjectFallback`.
    - Else create a new thread with `issueNumber = 0`.
5. Dedupe by `Message-ID` before insert.
6. Coordinator advances `lastInboundUID`, logs success/failure to `ActivityLog`.

### Backfill (one-time, on first IMAP success)

1. `IMAPClient` lists Sent folder messages from the past 365 days.
2. For each, `ThreadMatcher.matchToIssue(...)` tries subject substring against `RepoStore` cached issue titles. Match → link thread. No match → store with `issueNumber = 0`.
3. Inbox replies pulled in the normal poll attach via References, retroactively populating threads.
4. `MailAccount.backfillCompleted = true` prevents re-running.

### Attachment download

1. User taps an attachment chip in `MailThreadView`.
2. `AttachmentDownloader.download(messageID:partID:)`:
    - `MailAttachmentLocal` exists and the file is still there → open it.
    - Else IMAP-fetches the body part bytes, writes to the resolved attachment folder, inserts `MailAttachmentLocal`, opens via `NSWorkspace.open` (mac) / share sheet (iOS).
3. If the folder bookmark fails to resolve, fall back to `~/Downloads` / `Documents/Attachments` and prompt the user (one-time) to re-pick.

### Two-device race

Both devices may discover the same inbound message at the same time. `MailThreadStore.recordInbound` does fetch-by-`Message-ID` inside its `ModelContext`, then inserts if absent. CloudKit converges; the duplicate from one side is dropped. If both write before sync, the next-poll dedupe pass catches it and removes the duplicate (keeping the older `id`).

## Error handling

- **Transport errors** — typed errors per call. `MailSyncCoordinator` catches per-poll failures, writes a `failure` `ActivityLogEntry(kind: .fetchMail)`, exponential backoff capped at the configured interval. Existing threads stay readable.
- **Auth failures** — special-cased: banner in `EmailSettingsView` ("IMAP login failed — re-enter password"). Backoff suspended until credentials change.
- **Password not yet synced via iCloud Keychain** — `IMAPClient`/`MailSender` fail fast with `.passwordUnavailable`. UI shows "Waiting for iCloud Keychain to sync"; retry on app foreground.
- **Malformed messages** — single bad message does not abort the poll. Synthesize `Message-ID` from UID + UIDValidity (`<uid-12345.42@imap-synthetic>`), log warning, continue. Body decode failure → `<attachment unavailable — could not decode>` placeholder. HTML always passes through `HTMLSanitizer` before storage.
- **Attachment write fails** (folder moved/deleted) — fall back to default location, post a one-time settings prompt to re-pick.
- **iOS without a chosen folder** — fall back to app `Documents/Attachments`; share sheet lets users save elsewhere.
- **SwiftData / CloudKit insert failures** — `do/try` with error log (no fatal). Thread merges happen in the next dedupe pass (keep older `id`, reparent messages).
- **CloudKit account unavailable** — feature degrades to local-only; existing `CloudSyncStatus` UI surfaces it.
- **Reply with no parent `Message-ID`** — skip `In-Reply-To`, only set `References` if any are present, send still goes through (just won't thread server-side).

## Testing

Following the existing test style and the `pfw-testing` skill:

- **`ThreadMatcherTests`** — header threading, References-chain, no-match, subject fallback (Re-stripped equality, recipient mismatch, multiple candidates → newest wins), issue-link matching by subject substring.
- **`MessageIDGeneratorTests`** — outbound IDs unique and well-formed.
- **`ReplyHeaderBuilderTests`** — given a parent message, build correct `In-Reply-To` + `References` chain, including when parent already has its own References.
- **`MailComposerTests`** — extended to assert `Message-ID` and reply headers land in the `SwiftMail.Email`.
- **`MailThreadStoreTests`** — in-memory `ModelContainer`. Insert idempotency by `Message-ID`, thread merge when two threads collide, cascade delete, reparenting on backfill.
- **`MailSyncCoordinatorTests`** — `MockIMAPClient` returning canned message lists. Asserts: dedupe across polls, failure path writes ActivityLog and backs off, manual refresh forces poll regardless of interval, backfill runs once.
- **`ComposeMailViewModelTests`** — extend existing tests for the `inReplyTo` path (subject prefilled with `Re:`, recipient swapped, headers requested from composer).
- **`MailSettingsMigrationTests`** — old UserDefaults blob → new `MailAccount` model on first launch; password lookup falls back to non-synchronizable Keychain item if pre-migration.

Excluded from automated tests: real IMAP/SMTP I/O (covered by `testConnection` in EmailSettingsView), iCloud Keychain sync timing.

## Open implementation-time checks

These are "verify before you build" items, surfaced into the implementation plan rather than the design:

- SwiftMail IMAP capability — confirm it supports the operations we need (UID search, body part fetch, Sent folder listing). If not, drop in swift-nio-imap.
- Shared keychain access group between iOS and macOS targets — confirm entitlements + provisioning profile already include or can include a shared group.
- iOS background-poll behaviour — v1 only polls foregrounded; the existing `iOSBackgroundRefreshDriver` is already wired for issues, but we explicitly do **not** add mail polling there for v1 to keep scope tight.
