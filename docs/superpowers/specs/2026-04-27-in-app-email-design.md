# In-App Email Sending — Design Spec

**Date:** 2026-04-27
**Status:** Approved (pending user spec review)

## Summary

Add the ability to send email from inside AppFeedback using the user's own SMTP credentials. Tapping an email address surfaced on an issue (parsed from the issue body and shown as a badge) opens a compose sheet. The user types a message and sends. A new "Email" tab in Settings holds SMTP credentials and a customizable HTML header/footer template applied to every outgoing message. A new "Activity" window logs all background work (issue fetches, email sends) with success/failure status.

Scheduled sends (e.g. for app-release announcements) are explicitly out of scope for this spec; the architecture here leaves room for that as a future addition.

## Goals

- User can send email from inside the app, as themselves, without launching a third-party mail client.
- Each user authenticates with their own SMTP credentials (Gmail/iCloud/Outlook app-passwords or generic SMTP). No shared sender. No backend.
- Outgoing mail is wrapped in a user-customizable HTML header/footer with placeholder substitution.
- All background activity (fetches, sends) is observable in a dedicated Activity window with persistent history and a "Clear All" affordance.

## Non-Goals (v1)

- OAuth (XOAUTH2) for Gmail/Outlook — app-passwords only. OAuth is a future upgrade.
- Scheduled sends — out of scope.
- Rich text in header/footer beyond what AppKit's HTML renderer produces from `NSAttributedString`.
- Mail.app-style outbox with retries — failures are logged once; the user re-sends manually.
- Attachments.
- Reading mail (IMAP) — SwiftMail supports it, but we don't use it.

## Use Cases

1. **One-off reply to an issue reporter.** User opens an issue whose body contains an email address (parsed and shown as a badge). User taps the badge, types a short reply, sends. Compose sheet dismisses immediately. User checks Activity if they want to confirm delivery.
2. **Future: scheduled release announcement** — design must not preclude this. Out of scope to implement.

## SMTP Account Model

User-owned credentials, stored in Keychain. Three preset providers + generic:

| Preset  | Host             | Port | TLS       | Auth                   |
|---------|------------------|------|-----------|------------------------|
| Gmail   | smtp.gmail.com   | 587  | STARTTLS  | App-password (LOGIN)   |
| iCloud  | smtp.mail.me.com | 587  | STARTTLS  | App-password (LOGIN)   |
| Outlook | smtp-mail.outlook.com | 587 | STARTTLS | App-password (LOGIN) |
| Custom  | user-supplied    | user | user      | LOGIN/PLAIN            |

XOAUTH2 is supported by the SwiftMail dependency but not exposed in v1's UI. Settings have a "Test connection" button that connects, authenticates, and disconnects without sending mail — used to validate credentials before the user composes.

## Compose Body and Templating

- **Per-message body**: rich-text editor backed by `NSTextView` (wrapped in `NSViewRepresentable`). Supports bold/italic/underline/links via system shortcuts and a small toolbar. AppKit's `NSAttributedString → HTML` conversion produces the HTML alternative; the plain-text alternative is the same content rendered as plain text.
- **Header and footer**: rich-text editors in Settings → Email, also `NSTextView`-based. Stored as HTML strings. Both support placeholder tokens.
- **HTML sanitization**: AppKit's HTML output is verbose and CSS-heavy. Before sending, the assembled HTML is passed through an allowlist sanitizer keeping `<p> <br> <strong> <em> <u> <a> <ul> <ol> <li> <blockquote>` and stripping inline event handlers, `<script>`, `<style>`, etc. Same sanitizer applies to header, body, and footer.
- **Final HTML**: header → body → footer, concatenated, wrapped in a minimal `<html><body>…</body></html>` shell.
- **Final plain text**: header text → blank line → body text → blank line → footer text.
- **multipart/alternative**: assembled by SwiftMail by setting both `Email.textBody` and `Email.htmlBody`.

### Placeholders

Substituted at send time in header and footer (not in the user-typed body).

| Token                   | Source                                                 |
|-------------------------|--------------------------------------------------------|
| `{{recipient_email}}`   | The address being mailed                               |
| `{{sender_name}}`       | `MailSettings.credentials.senderName`                  |
| `{{sender_email}}`      | `MailSettings.credentials.username`                    |
| `{{date}}`              | Send date, formatted via `Date.FormatStyle.dateTime`   |
| `{{app_name}}`          | Currently selected repo's name                         |
| `{{issue_title}}`       | The issue from which the email was launched            |
| `{{issue_url}}`         | `https://github.com/<owner>/<repo>/issues/<n>`         |

`{{repo_url}}` is intentionally not supported.

When the compose flow is launched without an issue context (a future entry point), `{{issue_title}}` and `{{issue_url}}` substitute to empty strings; the template author is responsible for making templates degrade gracefully (or we add conditional sections later).

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                              UI                                │
│  IssueDetailView  → tap email badge → ComposeMailView (sheet) │
│  SettingsView     → new "Email" tab (SMTP creds + template)   │
│  ActivityWindow   → new window scene, lists ActivityLogEntry  │
└──────────────┬──────────────────┬─────────────────────────────┘
               │                  │
               ▼                  ▼
       ┌───────────────┐    ┌───────────────────┐
       │ MailComposer  │    │ ActivityLog       │  @MainActor @Observable
       │ - templating  │    │ - start/finish    │
       │ - sanitize    │    │ - persist (JSON)  │
       │ - HTML build  │    │ - clearAll()      │
       └──────┬────────┘    └─────────▲─────────┘
              │                       │
              ▼                       │
       ┌───────────────┐              │
       │ MailSender    │──── logs ────┘
       │ (actor, SwiftMail)
       │ - send(...)   │
       └──────┬────────┘
              │
              ▼
       ┌───────────────┐
       │ MailSettings  │  Keychain (creds) + UserDefaults (template)
       └───────────────┘
```

### Module boundaries

- `MailSender` knows SMTP. Doesn't know about issues, templates, or UI.
- `MailComposer` knows templating, HTML sanitization, MIME assembly. Doesn't know SMTP.
- `MailSettings` is a typed wrapper over Keychain + `UserDefaults`. Doesn't know SMTP or composition.
- `ActivityLog` is a passive observable sink. Doesn't know what fetches or sends mean — just stores entries.

## Components

### `MailSettings` — `AppFeedback/Services/Mail/MailSettings.swift`

```swift
struct SMTPCredentials: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable { case gmail, icloud, outlook, custom }
    var preset: Preset
    var host: String
    var port: Int
    var useSTARTTLS: Bool
    var username: String     // doubles as the From address
    var password: String     // app-password; stored in Keychain
    var senderName: String
}

struct MailTemplate: Codable, Equatable {
    var headerHTML: String
    var footerHTML: String
}

@Observable @MainActor
final class MailSettings {
    var credentials: SMTPCredentials? { didSet { persistCredentials() } }
    var template: MailTemplate { didSet { persistTemplate() } }
    // ...
}
```

`credentials.password` is stored in Keychain via the existing `KeychainService`; the rest of `SMTPCredentials` is stored as JSON in `UserDefaults`. `MailTemplate` is stored as JSON in `UserDefaults` (not sensitive).

### `MailComposer` — `AppFeedback/Services/Mail/MailComposer.swift`

```swift
struct DraftMessage {
    var recipient: EmailAddress
    var subject: String
    var body: NSAttributedString
}

struct PlaceholderContext {
    var sender: SMTPCredentials
    var recipient: String
    var appName: String
    var issueTitle: String?
    var issueURL: URL?
    var date: Date
}

struct MailComposer {
    func compose(draft: DraftMessage, context: PlaceholderContext, template: MailTemplate) -> SwiftMail.Email
}
```

Pure value type, no I/O — fully unit-testable. Steps:

1. Render header and footer HTML with placeholder substitution.
2. Convert `draft.body` to (a) HTML via AppKit, (b) plain text via `.string`.
3. Run the HTML allowlist sanitizer over header, body, footer.
4. Concatenate into final HTML and final plain text.
5. Build and return `SwiftMail.Email` with both `textBody` and `htmlBody` set.

### `MailSender` — `AppFeedback/Services/Mail/MailSender.swift`

```swift
protocol MailSending: Sendable {
    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials) async throws
    func testConnection(_ credentials: SMTPCredentials) async throws
}

actor MailSender: MailSending { ... }
```

`actor` so concurrent sends serialize per-instance. Each call connects, authenticates, sends, disconnects (no connection pooling in v1 — sends are infrequent enough that the ~1s overhead is invisible to the user, who has already returned to the app). Errors thrown to the caller; the caller logs to `ActivityLog`.

`testConnection` does `connect → login → disconnect` without sending — used by Settings' "Test connection" button.

The `MailSending` protocol exists for testability: a `FakeMailSender` implementation in tests asserts on inputs without touching the network.

### `ActivityLog` — `AppFeedback/Services/ActivityLog.swift`

```swift
struct ActivityLogEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case fetchIssues, sendEmail, testConnection }
    enum Status: String, Codable { case inProgress, success, failure }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    var title: String
    var status: Status
    var detail: String?
}

@MainActor @Observable
final class ActivityLog {
    private(set) var entries: [ActivityLogEntry] = []  // newest first

    func start(kind: ActivityLogEntry.Kind, title: String) -> UUID
    func finish(_ id: UUID, status: ActivityLogEntry.Status, detail: String?)
    func clearAll()
}
```

- Persisted to `~/Library/Application Support/AppFeedback/activity.json`. Writes are debounced (~250ms) to coalesce bursty updates.
- Capped at 500 entries. When the cap is exceeded the oldest are dropped.
- `clearAll()` empties memory and overwrites the file with an empty array.
- Loaded synchronously on first access at app launch.

### Views

- **`ComposeMailView`** — sheet presented from `IssueDetailView`. Fields: recipient (read-only badge), subject (`TextField`), body (`RichTextEditor` wrapping `NSTextView`). Buttons: Cancel, Send. If `MailSettings.credentials == nil`, the body area is replaced with a banner "Configure email in Settings → Email" and a button that opens Settings to that tab; Send is disabled.
- **`EmailSettingsView`** — new `Email` tab in `SettingsView`. Sections: (1) Provider preset picker → credentials form → "Test connection" button; (2) Header rich editor; (3) Footer rich editor; (4) Preview button rendering the final HTML against fake placeholder values.
- **`ActivityWindow`** — new `Window("Activity", id: "activity")` scene. List of entries with icon (kind), timestamp, title, status, detail. Filter chips: All / Fetches / Emails. Footer button "Clear All". Menu bar entry under Window → Activity (default ⌥⌘0 unless that conflicts).
- **`RichTextEditor`** — small `NSViewRepresentable` wrapping `NSTextView`. Bound to an `@Binding NSAttributedString`. Used by both compose and the header/footer editors. Toolbar with Bold / Italic / Underline / Link inserted as a separate `View` above the text view.

### Existing code touched

- `AppFeedbackApp.swift` — register the `Window("Activity")` scene + menu command.
- `IssueLoader.swift` — wrap each fetch with `activityLog.start(.fetchIssues, …)` / `finish`.
- `IssueBodyParser.swift` — already detects emails as badges; expose the matched address so the badge tap can carry it.
- `IssueDetailView` (or the badge view) — tap on email badge presents `ComposeMailView` as a `.sheet`.
- `SettingsView` — add "Email" tab.
- `KeychainService.swift` — add a typed accessor for `SMTPCredentials.password` if the existing API requires it; otherwise use the existing generic accessor.

## Data Flow — One Send

```
[User taps email badge in IssueDetailView]
        │
        ▼
[ComposeMailView sheet presents,  recipient/issue context captured]
        │
        ▼
[User types subject + body, taps Send]
        │
        ▼
[ComposeViewModel.sendMail(draft:)]
        │
        ▼
[Sheet dismisses immediately]
        │
        ▼ (Task on MainActor)
let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")
do {
    let context = PlaceholderContext(...)
    let email = composer.compose(draft: draft, context: context, template: settings.template)
    try await sender.send(email, using: settings.credentials!)
    activityLog.finish(id, status: .success, detail: nil)
} catch {
    activityLog.finish(id, status: .failure, detail: errorMessage(error))
}
        │
        ▼
[Activity window updates live via @Observable]
```

## Error Handling

Failures surface only in Activity. The compose sheet does not stick around to show errors — by the time it could, it's already gone. Mapping from SwiftMail errors to user-facing detail strings:

| Condition                                   | User-facing detail                                              |
|---------------------------------------------|------------------------------------------------------------------|
| DNS / connection refused                    | "Couldn't reach `<host>:<port>`"                                 |
| TLS handshake / STARTTLS unsupported        | "TLS failed — server may not support STARTTLS on port `<port>`"  |
| SMTP 5xx after AUTH                         | "Authentication failed — check username and app-password"        |
| SMTP 5xx on RCPT TO                         | "Server rejected `<recipient>`: `<server message>`"              |
| Anything else                               | `error.localizedDescription`                                     |

If the user's `MailSettings.credentials` is `nil`, the compose sheet doesn't allow sending in the first place — this state isn't reached.

## Concurrency

- `MailSender` is an `actor` — concurrent calls are serialized per instance.
- `ActivityLog` is `@MainActor` — UI binding is direct, no hops.
- `MailComposer` is a value type with no shared state — callable from anywhere.
- `MailSettings` is `@MainActor @Observable` — UI binding direct.
- All persistence I/O (Keychain, UserDefaults, JSON) happens on the `MainActor` for v1; ActivityLog's debounced JSON writes use `Task.detached` to keep the main thread responsive when bursts of entries occur.

## Persistence Locations

| Data                       | Location                                                                  |
|----------------------------|---------------------------------------------------------------------------|
| SMTP password              | Keychain via `KeychainService` (key: `mail.smtp.password`)                |
| SMTP credentials (rest)    | `UserDefaults` key `mail.credentials` (JSON)                              |
| Mail template              | `UserDefaults` key `mail.template` (JSON)                                 |
| Activity log               | `~/Library/Application Support/AppFeedback/activity.json`                 |

## Dependencies

Add a single SPM dependency:

- **[Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail)** — BSD-2, async/await, actively maintained, supports STARTTLS, AUTH PLAIN/LOGIN/XOAUTH2, multipart/alternative via `Email.htmlBody`, and explicitly supports macOS-client targets. Transitively pulls `swift-nio`, `swift-nio-ssl`, `swift-nio-imap`, `swift-log`, `swift-collections`. The IMAP code is dead-stripped by the linker (we don't link any IMAP symbols), but the source dep is unavoidable.

Rationale for choosing SwiftMail over alternatives: see brainstorming session — sersoft-gmbh/swift-smtp pulls Vapor into resolution and has no docs; Kitura SwiftSMTP is callback-era and the org is dormant; Hedwig predates async/await; community NIO-SMTP repos are unmaintained.

## Testing

Following existing project test conventions (`AppFeedbackTests/*Tests.swift`, Swift Testing):

- **`MailComposerTests`** — pure logic, comprehensive:
  - Each placeholder substitutes correctly (with and without context).
  - Repeated placeholders all substitute.
  - Missing optional context (e.g. no issue) → empty substitution.
  - HTML sanitizer drops `<script>`, `<style>`, inline `on*` handlers; keeps allowed tags.
  - Plain-text alternative reflects HTML structure (paragraph breaks preserved).
  - Header/body/footer ordering correct.
  - Final `Email` has both `textBody` and `htmlBody` populated.
- **`MailSettingsTests`** — round-trip credentials and template through Keychain/UserDefaults using existing test helpers; preset → host/port mapping correct.
- **`ActivityLogTests`** — start/finish state transitions; cap enforcement (501st entry drops oldest); persistence round-trip in a temp Application Support dir; `clearAll()` empties memory and overwrites disk.
- **`MailSenderTests`** — protocol-level only. Use a `FakeMailSender` injected at the call site; assert that `ComposeViewModel` calls it with the expected `Email`. The actual SMTP wire correctness lives in SwiftMail. No in-process SMTP test server in v1.
- **No UI tests** — consistent with the rest of the project today.

## Future Work (explicitly out of scope)

- Scheduled sends. The `MailSender` actor and `ActivityLog` already give the right surface: a future `ScheduledMailQueue` actor can hold drafts with fire dates, persist them, and call `MailSender.send` when due. `ActivityLog` already has a `.sendEmail` kind.
- OAuth (XOAUTH2) for Gmail/Outlook — replace the password field with an OAuth flow per provider; SwiftMail already supports XOAUTH2 server-side.
- Attachments — extend `DraftMessage` with `attachments: [URL]`, map to `SwiftMail.Attachment`.
- An outbox with retries on transient failures — `ActivityLog` entries with `.failure` status could expose a "Retry" affordance that re-runs the same `Email` value (which would need to be persisted in the entry).
- Persistent draft storage — currently a draft is lost if the user dismisses the compose sheet without sending.
