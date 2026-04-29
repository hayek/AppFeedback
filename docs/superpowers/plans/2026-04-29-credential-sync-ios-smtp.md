# Plan A — Credential Sync Foundation + iOS SMTP Send

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move SMTP/IMAP settings from `UserDefaults` into a CloudKit-synced SwiftData model, bring in-app SMTP sending to iOS (replacing today's `mailto:` open), prepare `MailComposer` for reply-threading headers, and surface IMAP-credential fields in the settings UI (data-only — no poller in this plan).

**Architecture:**
- New `@Model MailAccount` joins the existing CloudKit-synced cloud schema next to `Repo` / `SeenIssue` / `HiddenApp`. A `MailAccountStore` (`@MainActor`) replaces `MailSettings` as the source of truth, with a one-time migration from the old `UserDefaults` blob on first launch.
- SwiftMail is added as a dependency for the iOS target (today macOS-only); `ComposeMailView` and `EmailSettingsView` are made cross-platform.
- `MailComposer` is extended to stamp every outbound mail with a `Message-ID` and accept an optional `inReplyTo` parent for `In-Reply-To` / `References` headers (the inline-reply UX itself is built in Plan B; here we only build the plumbing).
- Passwords keep using the existing `KeychainService` (already iCloud-synced via `kSecAttrSynchronizable=true`); we add `imap.password` alongside `smtp.password`. Verify keychain access group is set so iOS and macOS targets can read each other's items.

**Tech Stack:** SwiftData (with CloudKit private DB), SwiftMail (SMTP), SwiftUI, iCloud Keychain via `SecItem`.

**Spec:** `docs/superpowers/specs/2026-04-29-email-threads-design.md`

---

## File Plan

### Create

| Path | Purpose |
|---|---|
| `AppFeedback/Models/MailAccount.swift` | `@Model MailAccount` for the cloud schema |
| `AppFeedback/Services/Mail/MailAccountStore.swift` | `@MainActor` store wrapping the `MailAccount` singleton (CRUD + observation) |
| `AppFeedback/Services/Mail/MailAccountMigration.swift` | One-time migration from the old `UserDefaults` `mail.credentials` / `mail.template` blobs into a `MailAccount` row |
| `AppFeedback/Services/Mail/MessageIDGenerator.swift` | Pure `Sendable` struct that returns RFC-style `<uuid@app-feedback.local>` IDs |
| `AppFeedback/Services/Mail/ReplyHeaderBuilder.swift` | Pure functions: given an optional parent `MailMessageHeaders`, build `inReplyTo` + `references` strings |
| `AppFeedback/Models/MailMessageHeaders.swift` | Tiny value type used by `ReplyHeaderBuilder` (`messageID`, `inReplyTo`, `references`) — the eventual SwiftData `MailMessage` from Plan B will conform/expose these |
| `AppFeedbackTests/MailAccountStoreTests.swift` | SwiftData-backed CRUD + idempotency tests |
| `AppFeedbackTests/MailAccountMigrationTests.swift` | UserDefaults → MailAccount migration tests |
| `AppFeedbackTests/MessageIDGeneratorTests.swift` | Format + uniqueness tests |
| `AppFeedbackTests/ReplyHeaderBuilderTests.swift` | Header chain build / no-parent / synthetic-id behaviour |

### Modify

| Path | What changes |
|---|---|
| `project.yml` | Add SwiftMail to iOS platform; add `MailAccount` to schemas comment; (re-run XcodeGen) |
| `AppFeedback/App/AppFeedbackApp.swift` | Add `MailAccount.self` to cloud schema + `ModelContainer`; create `MailAccountStore`; run migration on first launch; pass store via `@Environment` |
| `AppFeedback/App/RootView.swift` | Replace `MailSettings` environment injection with `MailAccountStore` |
| `AppFeedback/Services/Mail/MailComposer.swift` | Strip the `#if canImport(SwiftMail)` outer guard (since iOS now has SwiftMail); accept optional `messageID: String` and `replyHeaders: ReplyHeaderBuilder.Output?` parameters; stamp the Email accordingly |
| `AppFeedback/Services/Mail/MailSender.swift` | Strip outer `#if canImport(SwiftMail)` (same reason) |
| `AppFeedback/Services/Mail/MailSettings.swift` | **Delete** — replaced by `MailAccountStore`. (Keep `SMTPCredentials.Preset` enum + `MailTemplatePlainText` helpers — move them into `MailAccount.swift` or a new `MailTypes.swift`.) |
| `AppFeedback/ViewModels/ComposeMailViewModel.swift` | Switch from `MailSettings` to `MailAccountStore`; generate Message-ID per send; thread an optional `inReplyTo: MailMessageHeaders?` constructor param through to `MailComposer.compose(...)`; cross-platform (drop `#if canImport(SwiftMail)` outer guard) |
| `AppFeedback/Views/Mail/ComposeMailView.swift` | Lift `#if os(macOS)` guard; use cross-platform layout (`NavigationStack` on iOS, current AppKit-flavoured layout on macOS); keep using `MailAccountStore` |
| `AppFeedback/Views/Issues/IssueCardView.swift` | At line ~199–214, present `ComposeMailView` on iOS instead of opening `mailto:` |
| `AppFeedback/Views/Settings/EmailSettingsView.swift` | Lift `#if os(macOS)` guard; rebind to `MailAccountStore`; add IMAP host/port/username + IMAP password fields under a new "Receiving (IMAP)" section; preset selection auto-fills IMAP defaults too |
| `AppFeedback/Services/KeychainService.swift` | Add `imap.password` symmetric pair (`saveIMAPPassword` / `loadIMAPPassword` / `deleteIMAPPassword`) using the same synchronizable keychain pattern |
| `AppFeedback/AppFeedback.entitlements` | Verify `com.apple.developer.icloud-services` includes CloudKit; verify Keychain Sharing access group is consistent across targets (no change if already correct — see Task 0) |
| `AppFeedbackTests/MailComposerTests.swift` | Add cases for Message-ID stamp + reply headers |
| `AppFeedbackTests/ComposeMailViewModelTests.swift` | Switch fixtures to `MailAccountStore`; add reply-path test |
| `AppFeedbackTests/MailSettingsTests.swift` | **Delete** (obsoleted by `MailAccountStoreTests`) |

### Delete

- `AppFeedback/Services/Mail/MailSettings.swift`
- `AppFeedbackTests/MailSettingsTests.swift`

---

## Build / test commands (zcode skill)

This project uses the `zcode` skill for builds. Use it for all build/test/clean operations. Schemes are `AppFeedback_iOS` and `AppFeedback_macOS`. Use both — Plan A's whole point is platform parity.

---

### Task 0: Verify cross-platform foundations

**Goal:** Confirm SwiftMail builds on iOS and that iCloud Keychain entitlement is in place on both targets — these are the two "verify before you build" items from the spec.

**Files:**
- Read: `AppFeedback/AppFeedback.entitlements`, `project.yml`

- [ ] **Step 1: Inspect entitlements**

Read `AppFeedback/AppFeedback.entitlements`. Confirm it contains:
- `com.apple.developer.icloud-services` (with `CloudKit`)
- `keychain-access-groups` (any group is fine; if absent, add one — see Step 3)

If `keychain-access-groups` is absent, add this to the plist:

```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.amirhayek.AppFeedback</string>
</array>
```

- [ ] **Step 2: Try building SwiftMail on iOS**

Edit `project.yml` so the SwiftMail dependency is available on iOS too:

```yaml
    dependencies:
      - package: SwiftMail
        product: SwiftMail
```

(Remove the `platforms: [macOS]` constraint.)

Regenerate the Xcode project: run `xcodegen generate` from the repo root.

Then build the iOS scheme via the zcode skill (e.g. `zcode build` for `AppFeedback_iOS`).

- [ ] **Step 3: Confirm or fix and commit**

Expected: iOS build succeeds. If it fails because SwiftMail uses an iOS-incompatible API, **stop the plan and report back** — Plan B's IMAP work depends on this, and we may need to vendor swift-nio-imap directly or fall back to `MFMailComposeViewController` on iOS only.

If everything works:

```bash
git add project.yml AppFeedback/AppFeedback.entitlements
git commit -m "build: enable SwiftMail on iOS, verify iCloud Keychain entitlement"
```

---

### Task 1: Pure helpers — `MessageIDGenerator`

**Files:**
- Create: `AppFeedback/Services/Mail/MessageIDGenerator.swift`
- Test: `AppFeedbackTests/MessageIDGeneratorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AppFeedback

final class MessageIDGeneratorTests: XCTestCase {

    func test_generate_returnsAngleWrappedRFC5322Form() {
        let id = MessageIDGenerator.generate()
        XCTAssertTrue(id.hasPrefix("<"))
        XCTAssertTrue(id.hasSuffix("@app-feedback.local>"))
    }

    func test_generate_returnsUniqueIDs() {
        let ids = (0..<1000).map { _ in MessageIDGenerator.generate() }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func test_isSynthetic_detectsSyntheticIDs() {
        let synthetic = "<uid-12345.42@imap-synthetic>"
        let real = MessageIDGenerator.generate()
        XCTAssertTrue(MessageIDGenerator.isSynthetic(synthetic))
        XCTAssertFalse(MessageIDGenerator.isSynthetic(real))
    }
}
```

- [ ] **Step 2: Run test to confirm it fails**

Run the iOS test scheme via the zcode skill. Expected: build fails because `MessageIDGenerator` does not exist.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum MessageIDGenerator {
    static func generate() -> String {
        "<\(UUID().uuidString.lowercased())@app-feedback.local>"
    }

    static func isSynthetic(_ id: String) -> Bool {
        id.contains("@imap-synthetic")
    }
}
```

- [ ] **Step 4: Run tests on both schemes**

Run iOS scheme tests, then macOS scheme tests via zcode. Expected: PASS on both.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MessageIDGenerator.swift AppFeedbackTests/MessageIDGeneratorTests.swift
git commit -m "feat(mail): add MessageIDGenerator for outbound headers"
```

---

### Task 2: Pure helpers — `ReplyHeaderBuilder` + `MailMessageHeaders`

**Files:**
- Create: `AppFeedback/Models/MailMessageHeaders.swift`
- Create: `AppFeedback/Services/Mail/ReplyHeaderBuilder.swift`
- Test: `AppFeedbackTests/ReplyHeaderBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AppFeedback

final class ReplyHeaderBuilderTests: XCTestCase {

    func test_noParent_returnsNil() {
        let out = ReplyHeaderBuilder.build(parent: nil, newMessageID: "<n@x>")
        XCTAssertNil(out)
    }

    func test_parentWithoutReferences_setsInReplyToAndReferences() {
        let parent = MailMessageHeaders(messageID: "<p@x>", inReplyTo: nil, references: [])
        let out = ReplyHeaderBuilder.build(parent: parent, newMessageID: "<n@x>")
        XCTAssertEqual(out?.inReplyTo, "<p@x>")
        XCTAssertEqual(out?.references, ["<p@x>"])
    }

    func test_parentWithChain_appendsToReferences() {
        let parent = MailMessageHeaders(
            messageID: "<p@x>",
            inReplyTo: "<root@x>",
            references: ["<root@x>", "<mid@x>"]
        )
        let out = ReplyHeaderBuilder.build(parent: parent, newMessageID: "<n@x>")
        XCTAssertEqual(out?.inReplyTo, "<p@x>")
        XCTAssertEqual(out?.references, ["<root@x>", "<mid@x>", "<p@x>"])
    }

    func test_parentWithSyntheticID_skipsInReplyToButKeepsReferences() {
        let parent = MailMessageHeaders(
            messageID: "<uid-1.1@imap-synthetic>",
            inReplyTo: nil,
            references: ["<root@x>"]
        )
        let out = ReplyHeaderBuilder.build(parent: parent, newMessageID: "<n@x>")
        XCTAssertNil(out?.inReplyTo)
        XCTAssertEqual(out?.references, ["<root@x>"])
    }
}
```

- [ ] **Step 2: Run test, confirm failure**

Run iOS test scheme via zcode. Expected: types missing.

- [ ] **Step 3: Implement `MailMessageHeaders`**

```swift
import Foundation

struct MailMessageHeaders: Equatable, Sendable {
    var messageID: String
    var inReplyTo: String?
    var references: [String]
}
```

- [ ] **Step 4: Implement `ReplyHeaderBuilder`**

```swift
import Foundation

enum ReplyHeaderBuilder {
    struct Output: Equatable, Sendable {
        var inReplyTo: String?
        var references: [String]
    }

    static func build(parent: MailMessageHeaders?, newMessageID: String) -> Output? {
        guard let parent else { return nil }
        let inReplyTo = MessageIDGenerator.isSynthetic(parent.messageID) ? nil : parent.messageID
        var refs = parent.references
        if !MessageIDGenerator.isSynthetic(parent.messageID) {
            refs.append(parent.messageID)
        }
        return Output(inReplyTo: inReplyTo, references: refs)
    }
}
```

- [ ] **Step 5: Run tests on both schemes**

Expected: PASS on both.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Models/MailMessageHeaders.swift AppFeedback/Services/Mail/ReplyHeaderBuilder.swift AppFeedbackTests/ReplyHeaderBuilderTests.swift
git commit -m "feat(mail): add ReplyHeaderBuilder + MailMessageHeaders"
```

---

### Task 3: Extend `MailComposer` for outbound headers

**Files:**
- Modify: `AppFeedback/Services/Mail/MailComposer.swift`
- Modify: `AppFeedbackTests/MailComposerTests.swift`

- [ ] **Step 1: Add failing tests to `MailComposerTests`**

Append to `AppFeedbackTests/MailComposerTests.swift`:

```swift
func test_compose_stampsMessageIDHeader() {
    let composer = MailComposer()
    let draft = DraftMessage(recipient: "to@x", subject: "S", body: NSAttributedString(string: "hi"))
    let ctx = PlaceholderContext(
        sender: SMTPCredentials.defaults(for: .gmail),
        recipient: "to@x",
        appName: "App", issueTitle: nil, issueURL: nil, date: Date()
    )
    let email = composer.compose(
        draft: draft,
        context: ctx,
        template: MailTemplate.empty,
        messageID: "<m@x>",
        replyHeaders: nil
    )
    XCTAssertEqual(email.additionalHeaders["Message-ID"], "<m@x>")
    XCTAssertNil(email.additionalHeaders["In-Reply-To"])
    XCTAssertNil(email.additionalHeaders["References"])
}

func test_compose_stampsReplyHeaders() {
    let composer = MailComposer()
    let draft = DraftMessage(recipient: "to@x", subject: "Re: S", body: NSAttributedString(string: "ok"))
    let ctx = PlaceholderContext(
        sender: SMTPCredentials.defaults(for: .gmail),
        recipient: "to@x",
        appName: "App", issueTitle: nil, issueURL: nil, date: Date()
    )
    let reply = ReplyHeaderBuilder.Output(
        inReplyTo: "<p@x>",
        references: ["<root@x>", "<p@x>"]
    )
    let email = composer.compose(
        draft: draft,
        context: ctx,
        template: MailTemplate.empty,
        messageID: "<n@x>",
        replyHeaders: reply
    )
    XCTAssertEqual(email.additionalHeaders["Message-ID"], "<n@x>")
    XCTAssertEqual(email.additionalHeaders["In-Reply-To"], "<p@x>")
    XCTAssertEqual(email.additionalHeaders["References"], "<root@x> <p@x>")
}
```

> Note: SwiftMail's `Email` exposes headers via either `additionalHeaders` or a similar property. **Verify the actual API** in `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/checkouts/SwiftMail/Sources/SwiftMail/Email.swift` (or the package readme) before implementing — adjust the property name in both the test and implementation if it differs. If SwiftMail won't let us inject headers, add an extension on `Email` in this same file with a stored-property workaround (associated objects) and stop to flag it.

- [ ] **Step 2: Run tests, confirm failure**

Run iOS + macOS test schemes via zcode. Expected: build fails — `compose` doesn't accept `messageID:` / `replyHeaders:`.

- [ ] **Step 3: Update `MailComposer.compose` signature and body**

In `AppFeedback/Services/Mail/MailComposer.swift`:
- Drop the outer `#if canImport(SwiftMail)` guard (SwiftMail is now on both platforms after Task 0).
- Change signature to:

```swift
func compose(
    draft: DraftMessage,
    context: PlaceholderContext,
    template: MailTemplate,
    messageID: String,
    replyHeaders: ReplyHeaderBuilder.Output?
) -> SwiftMail.Email
```

- After constructing the `Email`, inject headers (use the actual SwiftMail API confirmed in Step 1):

```swift
var email = SwiftMail.Email(
    sender: EmailAddress(name: context.sender.senderName, address: context.sender.username),
    recipients: [EmailAddress(name: nil, address: draft.recipient)],
    subject: draft.subject,
    textBody: combinedText,
    htmlBody: combinedHTML
)
email.additionalHeaders["Message-ID"] = messageID
if let reply = replyHeaders {
    if let inReplyTo = reply.inReplyTo {
        email.additionalHeaders["In-Reply-To"] = inReplyTo
    }
    if !reply.references.isEmpty {
        email.additionalHeaders["References"] = reply.references.joined(separator: " ")
    }
}
return email
```

- [ ] **Step 4: Update existing call sites of `compose(...)`**

There is exactly one call site: `AppFeedback/ViewModels/ComposeMailViewModel.swift` line ~73. Update it to pass `messageID: MessageIDGenerator.generate(), replyHeaders: nil` for now (Task 7 will properly thread `replyHeaders` through).

- [ ] **Step 5: Run tests**

Run iOS + macOS test schemes via zcode. Expected: PASS, including the new tests.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/Mail/MailComposer.swift AppFeedback/ViewModels/ComposeMailViewModel.swift AppFeedbackTests/MailComposerTests.swift
git commit -m "feat(mail): stamp Message-ID and reply headers on outbound mail"
```

---

### Task 4: `MailAccount` SwiftData model + add to schemas

**Files:**
- Create: `AppFeedback/Models/MailAccount.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Define `MailAccount`**

```swift
import Foundation
import SwiftData

@Model
final class MailAccount {
    var id: UUID = UUID()
    var presetRaw: String = "gmail"
    var smtpHost: String = ""
    var smtpPort: Int = 587
    var smtpUsername: String = ""
    var senderName: String = ""
    var imapHost: String = ""
    var imapPort: Int = 993
    var imapUsername: String = ""
    var pollIntervalSeconds: Int = 300
    var pollingEnabled: Bool = true
    var attachmentFolderBookmark: Data? = nil
    var templateHeaderHTML: String = ""
    var templateFooterHTML: String = ""
    var backfillCompleted: Bool = false
    var createdAt: Date = Date()

    init(id: UUID = UUID(),
         presetRaw: String = "gmail",
         smtpHost: String = "",
         smtpPort: Int = 587,
         smtpUsername: String = "",
         senderName: String = "",
         imapHost: String = "",
         imapPort: Int = 993,
         imapUsername: String = "",
         pollIntervalSeconds: Int = 300,
         pollingEnabled: Bool = true,
         attachmentFolderBookmark: Data? = nil,
         templateHeaderHTML: String = "",
         templateFooterHTML: String = "",
         backfillCompleted: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.presetRaw = presetRaw
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.senderName = senderName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUsername = imapUsername
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollingEnabled = pollingEnabled
        self.attachmentFolderBookmark = attachmentFolderBookmark
        self.templateHeaderHTML = templateHeaderHTML
        self.templateFooterHTML = templateFooterHTML
        self.backfillCompleted = backfillCompleted
        self.createdAt = createdAt
    }

    var preset: SMTPCredentials.Preset {
        SMTPCredentials.Preset(rawValue: presetRaw) ?? .gmail
    }
}
```

> All properties have defaults — required because CloudKit-backed SwiftData models can't have non-optional properties without defaults.

- [ ] **Step 2: Add to schemas in `AppFeedbackApp.swift`**

In `AppFeedback/App/AppFeedbackApp.swift` line 31:

```swift
let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self])
```

And in the `ModelContainer` `for:` list (line 43-46):

```swift
container = try ModelContainer(
    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, CachedIssue.self,
    configurations: cloudConfig, localConfig
)
```

- [ ] **Step 3: Build both schemes**

Run `zcode build` for both schemes. Expected: succeeds, no test changes yet.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Models/MailAccount.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(mail): add MailAccount SwiftData model to cloud schema"
```

---

### Task 5: `MailAccountStore` (replaces `MailSettings`)

**Files:**
- Create: `AppFeedback/Services/Mail/MailAccountStore.swift`
- Test: `AppFeedbackTests/MailAccountStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailAccountStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        return ModelContext(container)
    }

    func test_account_returnsNilWhenEmpty() throws {
        let store = MailAccountStore(context: try makeContext())
        XCTAssertNil(store.account)
    }

    func test_upsert_createsAccountWhenAbsent() throws {
        let store = MailAccountStore(context: try makeContext())
        store.upsert { acc in
            acc.smtpUsername = "alice@x"
            acc.senderName = "Alice"
        }
        XCTAssertEqual(store.account?.smtpUsername, "alice@x")
        XCTAssertEqual(store.account?.senderName, "Alice")
    }

    func test_upsert_updatesExistingAccount() throws {
        let ctx = try makeContext()
        let store = MailAccountStore(context: ctx)
        store.upsert { $0.smtpUsername = "first@x" }
        store.upsert { $0.smtpUsername = "second@x" }

        let descriptor = FetchDescriptor<MailAccount>()
        let rows = try ctx.fetch(descriptor)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.smtpUsername, "second@x")
    }

    func test_delete_removesAccount() throws {
        let store = MailAccountStore(context: try makeContext())
        store.upsert { $0.smtpUsername = "x@x" }
        store.deleteAccount()
        XCTAssertNil(store.account)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

Expected: `MailAccountStore` does not exist.

- [ ] **Step 3: Implement**

```swift
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailAccountStore {
    private let context: ModelContext
    private(set) var account: MailAccount?

    init(context: ModelContext) {
        self.context = context
        self.account = Self.fetch(context)
    }

    func upsert(_ mutate: (MailAccount) -> Void) {
        let target: MailAccount
        if let existing = account {
            target = existing
        } else {
            let new = MailAccount()
            context.insert(new)
            target = new
        }
        mutate(target)
        try? context.save()
        account = target
    }

    func deleteAccount() {
        guard let acc = account else { return }
        context.delete(acc)
        try? context.save()
        account = nil
    }

    private static func fetch(_ context: ModelContext) -> MailAccount? {
        var descriptor = FetchDescriptor<MailAccount>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
```

- [ ] **Step 4: Run tests on both schemes**

Expected: PASS on both.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailAccountStore.swift AppFeedbackTests/MailAccountStoreTests.swift
git commit -m "feat(mail): MailAccountStore wraps SwiftData CRUD"
```

---

### Task 6: One-time UserDefaults → MailAccount migration

**Files:**
- Create: `AppFeedback/Services/Mail/MailAccountMigration.swift`
- Test: `AppFeedbackTests/MailAccountMigrationTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailAccountMigrationTests: XCTestCase {

    private func makeStore() throws -> (MailAccountStore, UserDefaults) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        let suite = "MailAccountMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (MailAccountStore(context: ModelContext(container)), defaults)
    }

    func test_noLegacyData_doesNothing() throws {
        let (store, defaults) = try makeStore()
        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)
        XCTAssertNil(store.account)
        XCTAssertTrue(defaults.bool(forKey: "mail.migration.v1.completed"))
    }

    func test_legacyCredentials_migrateIntoMailAccount() throws {
        let (store, defaults) = try makeStore()
        let creds = SMTPCredentials(
            preset: .gmail, host: "smtp.gmail.com", port: 587,
            username: "alice@x", senderName: "Alice"
        )
        defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")
        let template = MailTemplate(headerHTML: "<p>hi</p>", footerHTML: "<p>bye</p>")
        defaults.set(try JSONEncoder().encode(template), forKey: "mail.template")

        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)

        XCTAssertEqual(store.account?.smtpUsername, "alice@x")
        XCTAssertEqual(store.account?.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(store.account?.smtpPort, 587)
        XCTAssertEqual(store.account?.senderName, "Alice")
        XCTAssertEqual(store.account?.presetRaw, "gmail")
        XCTAssertEqual(store.account?.imapHost, "imap.gmail.com")
        XCTAssertEqual(store.account?.imapPort, 993)
        XCTAssertEqual(store.account?.templateHeaderHTML, "<p>hi</p>")
        XCTAssertEqual(store.account?.templateFooterHTML, "<p>bye</p>")
    }

    func test_runIfNeeded_isIdempotent() throws {
        let (store, defaults) = try makeStore()
        let creds = SMTPCredentials.defaults(for: .icloud)
        defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")

        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)
        let firstID = store.account?.id

        // Second run is a no-op: leaves the same account untouched.
        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)

        XCTAssertEqual(store.account?.id, firstID)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement**

```swift
import Foundation

enum MailAccountMigration {
    private static let completedKey = "mail.migration.v1.completed"
    private static let legacyCredentialsKey = "mail.credentials"
    private static let legacyTemplateKey = "mail.template"

    @MainActor
    static func runIfNeeded(store: MailAccountStore, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }
        defer { defaults.set(true, forKey: completedKey) }

        let legacyCreds: SMTPCredentials? = defaults.data(forKey: legacyCredentialsKey)
            .flatMap { try? JSONDecoder().decode(SMTPCredentials.self, from: $0) }
        let legacyTemplate: MailTemplate? = defaults.data(forKey: legacyTemplateKey)
            .flatMap { try? JSONDecoder().decode(MailTemplate.self, from: $0) }

        guard legacyCreds != nil || legacyTemplate != nil else { return }

        store.upsert { acc in
            if let creds = legacyCreds {
                acc.presetRaw = creds.preset.rawValue
                acc.smtpHost = creds.host
                acc.smtpPort = creds.port
                acc.smtpUsername = creds.username
                acc.senderName = creds.senderName
                let imap = MailAccountMigration.imapDefaults(for: creds.preset)
                acc.imapHost = imap.host
                acc.imapPort = imap.port
                acc.imapUsername = creds.username
            }
            if let tmpl = legacyTemplate {
                acc.templateHeaderHTML = tmpl.headerHTML
                acc.templateFooterHTML = tmpl.footerHTML
            }
        }
    }

    static func imapDefaults(for preset: SMTPCredentials.Preset) -> (host: String, port: Int) {
        switch preset {
        case .gmail:   return ("imap.gmail.com", 993)
        case .icloud:  return ("imap.mail.me.com", 993)
        case .outlook: return ("outlook.office365.com", 993)
        case .custom:  return ("", 993)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Expected: PASS on both schemes.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailAccountMigration.swift AppFeedbackTests/MailAccountMigrationTests.swift
git commit -m "feat(mail): migrate legacy MailSettings UserDefaults into MailAccount"
```

---

### Task 7: Wire `MailAccountStore` + migration into the app, retire `MailSettings`

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`
- Modify: `AppFeedback/App/RootView.swift`
- Modify: `AppFeedback/ViewModels/ComposeMailViewModel.swift`
- Modify: `AppFeedback/Views/Mail/ComposeMailView.swift`
- Modify: `AppFeedback/Views/Settings/EmailSettingsView.swift`
- Delete: `AppFeedback/Services/Mail/MailSettings.swift`
- Delete: `AppFeedbackTests/MailSettingsTests.swift`
- Modify: `AppFeedbackTests/ComposeMailViewModelTests.swift`

This is the largest task. Sub-steps:

- [ ] **Step 1: Move `SMTPCredentials.Preset`, `MailTemplate`, `MailTemplatePlainText` out of `MailSettings.swift`**

Cut these three types from `MailSettings.swift` into a new file `AppFeedback/Models/MailTypes.swift`:

```swift
import Foundation
#if os(macOS)
import AppKit
#endif

struct SMTPCredentials: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case gmail, icloud, outlook, custom
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .gmail:   return "Gmail"
            case .icloud:  return "iCloud"
            case .outlook: return "Outlook"
            case .custom:  return "Custom SMTP"
            }
        }
    }
    var preset: Preset
    var host: String
    var port: Int
    var username: String
    var senderName: String

    static func defaults(for preset: Preset) -> SMTPCredentials {
        switch preset {
        case .gmail:   return .init(preset: .gmail,   host: "smtp.gmail.com",        port: 587, username: "", senderName: "")
        case .icloud:  return .init(preset: .icloud,  host: "smtp.mail.me.com",      port: 587, username: "", senderName: "")
        case .outlook: return .init(preset: .outlook, host: "smtp-mail.outlook.com", port: 587, username: "", senderName: "")
        case .custom:  return .init(preset: .custom,  host: "",                      port: 587, username: "", senderName: "")
        }
    }
}

struct MailTemplate: Codable, Equatable, Sendable {
    var headerHTML: String
    var footerHTML: String
    static let empty = MailTemplate(headerHTML: "", footerHTML: "")
}

enum MailTemplatePlainText {
    static func from(html: String) -> String {
        guard !html.isEmpty else { return "" }
        #if os(macOS)
        if let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil) {
            return attr.string
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
        }
        #endif
        return html
    }

    static func toHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let withBreaks = escaped.replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(withBreaks)</p>"
    }
}
```

- [ ] **Step 2: Delete `MailSettings.swift` and its test**

```bash
git rm AppFeedback/Services/Mail/MailSettings.swift AppFeedbackTests/MailSettingsTests.swift
```

- [ ] **Step 3: Update `AppFeedbackApp.swift`**

Replace `@State private var mailSettings = MailSettings()` (around line 12) with a `MailAccountStore`. After the `ModelContainer` is created and `cloudContext` exists (around line 51), add:

```swift
let mailAccountStore = MailAccountStore(context: cloudContext)
MailAccountMigration.runIfNeeded(store: mailAccountStore)
_mailAccountStore = State(initialValue: mailAccountStore)
```

Where the property is declared at the top:

```swift
@State private var mailAccountStore: MailAccountStore
```

Find every place `mailSettings` is passed via `.environment(...)` and replace with `mailAccountStore`. (See `RootView.swift` and the `WindowGroup`/`Settings` blocks in `AppFeedbackApp.swift`.)

- [ ] **Step 4: Update `RootView.swift`**

Replace `@Environment(MailSettings.self)` and similar parameters with `MailAccountStore`. Search the file for `MailSettings`/`mailSettings` and adjust each call site.

- [ ] **Step 5: Update `ComposeMailViewModel`**

Replace `MailSettings` with `MailAccountStore`. Add `inReplyTo: MailMessageHeaders?` constructor parameter (default `nil`). In `send()`, generate a `Message-ID` and pass it to `MailComposer.compose(...)`:

```swift
@MainActor
@Observable
final class ComposeMailViewModel {
    var subject: String = ""
    var body: NSAttributedString = NSAttributedString(string: "")

    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let inReplyTo: MailMessageHeaders?

    private let store: MailAccountStore
    private let sender: any MailSending
    private let activityLog: ActivityLog
    private let passwordLoader: @Sendable () async -> String?
    private let composer = MailComposer()

    init(recipient: String,
         issue: FeedbackIssue,
         repoOwner: String,
         repoName: String,
         store: MailAccountStore,
         sender: any MailSending,
         activityLog: ActivityLog,
         inReplyTo: MailMessageHeaders? = nil,
         passwordLoader: @Sendable @escaping () async -> String? = { await KeychainService.loadSMTPPassword() }) {
        self.recipient = recipient
        self.issue = issue
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.store = store
        self.sender = sender
        self.activityLog = activityLog
        self.inReplyTo = inReplyTo
        self.passwordLoader = passwordLoader
    }

    var canSend: Bool {
        store.account != nil
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.length > 0
    }

    func placeholderContext(date: Date = Date()) -> PlaceholderContext {
        let creds = currentCredentials() ?? SMTPCredentials.defaults(for: .gmail)
        let issueURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/issues/\(issue.number)")
        return PlaceholderContext(
            sender: creds, recipient: recipient,
            appName: issue.appName ?? repoName,
            issueTitle: issue.title, issueURL: issueURL, date: date
        )
    }

    var template: MailTemplate {
        guard let acc = store.account else { return .empty }
        return MailTemplate(headerHTML: acc.templateHeaderHTML, footerHTML: acc.templateFooterHTML)
    }

    private func currentCredentials() -> SMTPCredentials? {
        guard let acc = store.account else { return nil }
        return SMTPCredentials(preset: acc.preset, host: acc.smtpHost, port: acc.smtpPort,
                               username: acc.smtpUsername, senderName: acc.senderName)
    }

    func send() async {
        guard let creds = currentCredentials() else { return }
        guard let password = await passwordLoader(), !password.isEmpty else {
            let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")
            activityLog.finish(id, status: .failure, detail: "No SMTP password configured.")
            return
        }
        let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")
        let messageID = MessageIDGenerator.generate()
        let replyHeaders = ReplyHeaderBuilder.build(parent: inReplyTo, newMessageID: messageID)
        let context = placeholderContext()
        let draft = DraftMessage(recipient: recipient, subject: subject, body: body)
        let email = composer.compose(draft: draft, context: context, template: template,
                                     messageID: messageID, replyHeaders: replyHeaders)
        do {
            try await sender.send(email, using: creds, password: password)
            activityLog.finish(id, status: .success, detail: nil)
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
        }
    }
}
```

Drop the outer `#if canImport(SwiftMail)` guard — SwiftMail now exists on both platforms (Task 0).

- [ ] **Step 6: Update `ComposeMailView`**

In `AppFeedback/Views/Mail/ComposeMailView.swift`, replace the outer `#if os(macOS) && canImport(SwiftMail)` with `#if canImport(SwiftMail)` so iOS can compile the view too. Replace `@Environment(MailSettings.self)` with `@Environment(MailAccountStore.self)`. References to `settings.template` become `MailTemplate(headerHTML: store.account?.templateHeaderHTML ?? "", footerHTML: store.account?.templateFooterHTML ?? "")`. The macOS-specific `SettingsLink` and `.frame(minWidth:minHeight:)` need to be guarded:

```swift
#if os(macOS)
    .frame(minWidth: 540, minHeight: 460)
#endif
```

For `SettingsLink` usage (the "Open Settings…" / "Edit" affordances), wrap with:

```swift
#if os(macOS)
    SettingsLink { ... }
#else
    Button("Edit") { settingsNavigation.selectedTab = .email }
        .buttonStyle(.borderless)
#endif
```

Update `setupViewModel()` to pass `store: store` (formerly `settings: settings`).

- [ ] **Step 7: Update `EmailSettingsView`**

Lift the `#if os(macOS)` guard. Bind to `MailAccountStore` instead of `MailSettings`. The `applyPresetDefaults` helper now also fills IMAP defaults (call `MailAccountMigration.imapDefaults(for:)` — extract a fileprivate copy if you don't want to depend on the migration enum). Add a new `Section("Receiving (IMAP)")`:

```swift
Section("Receiving (IMAP)") {
    TextField("IMAP host", text: $imapHost)
        .disabled(preset != .custom)
    TextField("IMAP port", text: $imapPort)
        .disabled(preset != .custom)
    TextField("IMAP username", text: $imapUsername)
    SecureField("IMAP password", text: $imapPassword)
}
```

Persist these via `store.upsert { acc in ... }`. Save IMAP password via the new `KeychainService.saveIMAPPassword(...)` (Task 8 — order this task after Task 8 if needed, or stub the calls and fill them in once Task 8 lands).

> Order tip: do Task 8 before Step 7 of this task to avoid a temporarily broken build. Or accept the broken build and finish all sub-steps before running tests.

- [ ] **Step 8: Update `ComposeMailViewModelTests`**

Read the existing file. Replace any `MailSettings` fixture with an in-memory `MailAccountStore`. Add one new test:

```swift
func test_send_withInReplyTo_addsReplyHeaders() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: MailAccount.self, configurations: config)
    let store = MailAccountStore(context: ModelContext(container))
    store.upsert { acc in
        acc.smtpHost = "smtp.gmail.com"
        acc.smtpPort = 587
        acc.smtpUsername = "alice@x"
        acc.senderName = "Alice"
    }

    let captured = CapturingMailSender()
    let log = ActivityLog(persistenceURL: nil)
    let parent = MailMessageHeaders(messageID: "<p@x>", inReplyTo: nil, references: ["<root@x>"])
    let issue = FeedbackIssue.fixture()  // use whatever fixture the existing tests use

    let vm = ComposeMailViewModel(
        recipient: "to@x", issue: issue, repoOwner: "o", repoName: "r",
        store: store, sender: captured, activityLog: log,
        inReplyTo: parent,
        passwordLoader: { "pw" }
    )
    vm.subject = "Re: hi"
    vm.body = NSAttributedString(string: "ok")
    await vm.send()

    XCTAssertEqual(captured.lastEmail?.additionalHeaders["In-Reply-To"], "<p@x>")
    XCTAssertEqual(captured.lastEmail?.additionalHeaders["References"], "<root@x> <p@x>")
}
```

(`CapturingMailSender` already exists in the test target — see existing `ComposeMailViewModelTests`. If not, add a small actor that conforms to `MailSending` and records the email it would have sent.)

- [ ] **Step 9: Build + run tests on both schemes**

Expected: PASS on both `AppFeedback_iOS` and `AppFeedback_macOS`.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor(mail): migrate MailSettings to MailAccount/MailAccountStore"
```

---

### Task 8: IMAP password in `KeychainService`

**Files:**
- Modify: `AppFeedback/Services/KeychainService.swift`

- [ ] **Step 1: Add the symmetric trio for `imap.password`**

Append to `KeychainService.swift`:

```swift
    private static let imapAccount = "imap.password"

    @discardableResult
    static func saveIMAPPassword(_ password: String) async -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func loadIMAPPassword() async -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteIMAPPassword() async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }
```

- [ ] **Step 2: Build both schemes**

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/KeychainService.swift
git commit -m "feat(keychain): add iCloud-synced IMAP password storage"
```

> Order: Run this task **before** Task 7 Step 7 to keep the build green throughout.

---

### Task 9: iOS — present `ComposeMailView` instead of `mailto:`

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`

- [ ] **Step 1: Read existing email-tag block**

Lines ~199–215 in `AppFeedback/Views/Issues/IssueCardView.swift` are the email tag — currently the `else` branch opens `mailto:` via `Link`. Plan: when `onTapEmail` is nil and we're on iOS (or any platform), present `ComposeMailView` in a sheet.

- [ ] **Step 2: Replace the `Link(destination: mailURL)` branch**

Add `@State private var composeRecipient: String?` near the other `@State` declarations in `IssueCardView`. Replace the `else if let encoded = ...` branch with:

```swift
} else {
    Button {
        onInteract?()
        composeRecipient = email
    } label: {
        MetaTagView(key: "✉", value: email, isActive: false)
    }
    .buttonStyle(.plain)
}
```

Add a `.sheet` modifier on the card's outermost container:

```swift
.sheet(item: Binding(
    get: { composeRecipient.map(EmailRecipient.init) },
    set: { composeRecipient = $0?.value }
)) { rec in
    #if canImport(SwiftMail)
    ComposeMailView(
        recipient: rec.value,
        issue: issue,
        repoOwner: repoOwner,
        repoName: repoName
    )
    #else
    Text("Email composer unavailable.")
    #endif
}
```

Where `EmailRecipient` is a tiny `Identifiable` wrapper:

```swift
private struct EmailRecipient: Identifiable {
    let value: String
    var id: String { value }
}
```

> `IssueCardView` currently does not have `repoOwner`/`repoName` — confirm via `Read`. If absent, thread them through from the call site (`IssueListView`) as added parameters with defaults `""` so the rest of the codebase keeps compiling. (Or, since the existing macOS `ComposeMailView` is already presented somewhere, find that call site and reuse the same wiring.)

- [ ] **Step 3: Build + smoke-test on iOS**

Run iOS scheme via zcode. Tap an email tag in a feedback card on iOS Simulator. Expected: `ComposeMailView` opens; once SMTP creds are set up, sending works.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat(ios): in-app SMTP compose replaces mailto: open"
```

---

### Task 10: Final verification + spec coverage

- [ ] **Step 1: Run full test suite on both schemes**

Run iOS + macOS schemes via zcode `test`. Expected: all green.

- [ ] **Step 2: Manual cross-device smoke test (if signed-in iCloud account available)**

1. On macOS: open Settings → Email, configure Gmail account with app password. Send a test email from a feedback card.
2. On iOS (same iCloud account, same dev build): wait ~30 seconds. Open Settings → Email. Confirm the SMTP fields are populated.
3. Confirm IMAP password also synced (it's stored independently — leave it blank if you didn't set one yet).
4. Send a test email from iOS — confirm it arrives.

Document any sync issues in a follow-up. **Do not block the plan on iCloud sync timing** — Plan B's coordinator will handle the "credential not yet synced" UX.

- [ ] **Step 3: Confirm `MailAccount` is in the cloud schema and not duplicated locally**

Open `AppFeedbackApp.swift`. Confirm `MailAccount.self` appears in the `cloudSchema` array and the `ModelContainer for:` list.

- [ ] **Step 4: Done**

This unblocks Plan B (inbound threads). No commit unless changes were made in Step 3.

---

## Self-Review

**Spec coverage** (cross-checking against `2026-04-29-email-threads-design.md` for Plan A scope):
- Cloud-synced credential storage ✅ Tasks 4–7
- iOS SMTP send replacing `mailto:` ✅ Task 9
- Outbound `Message-ID` stamp ✅ Task 3
- Reply-header plumbing (no UI yet) ✅ Tasks 2, 7-Step-5
- IMAP credential fields in settings (data only) ✅ Tasks 7-Step-7, 8
- iCloud Keychain entitlement verification ✅ Task 0
- One-time UserDefaults migration ✅ Task 6

Items deferred to **Plan B** (intentional, not gaps):
- IMAP client / poller / coordinator
- Thread/message/attachment SwiftData models
- Thread UI on `IssueCardView`
- Inline reply UI (uses `inReplyTo` plumbing built here)
- Attachment downloader + folder picker
- `lastInboundUID` cursor (`MailAccountLocalState`)

**Type consistency:** `MailAccountStore` API (`account`, `upsert`, `deleteAccount`) is used identically across Tasks 5–9. `MessageIDGenerator.generate()` and `ReplyHeaderBuilder.build(parent:newMessageID:)` signatures are stable. Test files in Tasks 5–7 each spin up their own in-memory `ModelContainer` rather than sharing setup.

**Placeholder scan:** No "TBD" / "implement later". Each step contains the actual code or the exact mechanical edit. Two soft notes (SwiftMail header API name in Task 3; `IssueCardView` may need `repoOwner`/`repoName` threading in Task 9) are flagged with verification instructions, not unresolved unknowns.
