# Multi-account Mail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support multiple email accounts. One is the default sender for replies. All accounts fetch in parallel. The user can override the sender per-reply via right-click. The Email settings screen becomes a list of accounts plus a separate "Mail templates & defaults" section.

**Architecture:** `MailAccount` becomes multi-row with an `isDefaultSender` flag. Shared template/folder/poll-interval settings move into a new `MailSettings` singleton. Keychain entries become per-account UUID-keyed. A `MailSyncCoordinatorRegistry` runs one `MailSyncCoordinator` per account. `ComposeMailViewModel` takes a `senderAccountID`. Right-click on a reply offers "Reply from ▸" with all configured accounts.

**Tech Stack:** Swift 6, SwiftData (CloudKit-synced), SwiftUI, Keychain Services, SwiftMail (conditional `canImport(SwiftMail)`).

**Reference spec:** `docs/superpowers/specs/2026-05-12-multi-account-mail-design.md`.

---

## File map

**New files:**

- `AppFeedback/Models/MailSettings.swift` — SwiftData singleton for header/footer/attachment-folder/poll interval.
- `AppFeedback/Services/Mail/MailSettingsStore.swift` — @Observable wrapper around `MailSettings`.
- `AppFeedback/Services/Mail/MailSyncCoordinatorRegistry.swift` — creates/tears down one coordinator per account.
- `AppFeedback/Views/Settings/EmailAccountEditor.swift` — per-account editor (macOS), used by the master/detail layout.
- `AppFeedback/Views/Settings/EmailAccountList.swift` — master pane: list + Add button.
- `AppFeedback/Views/Settings/AddEmailAccountSheet.swift` — modal "add account" flow.
- `AppFeedback/Views/Settings/MailDefaultsSection.swift` — shared template/folder/poll settings panel.
- `AppFeedback/Views/Settings/IOSEmailAccountList.swift` — iOS list of accounts.
- `AppFeedback/Views/Settings/IOSEmailAccountEditor.swift` — iOS per-account editor.
- `AppFeedback/Views/Settings/IOSMailDefaultsView.swift` — iOS templates/defaults editor.
- `AppFeedbackTests/MailSettingsStoreTests.swift`
- `AppFeedbackTests/MailSyncCoordinatorRegistryTests.swift`

**Modified files:**

- `AppFeedback/Models/MailAccount.swift` — add `isDefaultSender`; remove shared-settings fields.
- `AppFeedback/Models/MailMessage.swift` — add `accountID: UUID?`.
- `AppFeedback/Models/MailThread.swift` — add `accountID: UUID?`.
- `AppFeedback/Services/KeychainService.swift` — add per-account password methods; keep legacy read once.
- `AppFeedback/Services/Mail/MailAccountStore.swift` — multi-account API.
- `AppFeedback/Services/Mail/MailAccountMigration.swift` — v2 migration.
- `AppFeedback/Services/Mail/MailSyncCoordinator.swift` — per-account `accountID`.
- `AppFeedback/Services/Mail/IMAPClientProvider.swift` — per-account.
- `AppFeedback/Services/Mail/MailThreadStore.swift` — set `accountID` on records.
- `AppFeedback/Services/Mail/MailSender.swift` (and `MailSending`) — unchanged signatures; callers supply account-scoped creds.
- `AppFeedback/Services/Mail/AttachmentDownloader.swift` — read folder bookmark from `MailSettings`.
- `AppFeedback/ViewModels/ComposeMailViewModel.swift` — `senderAccountID`.
- `AppFeedback/Views/Mail/ComposeMailView.swift` — shows From row; templates from `MailSettings`.
- `AppFeedback/Views/Mail/MailThreadView.swift` — sender resolution + reply-from menu.
- `AppFeedback/Views/Mail/MailMessageRowView.swift` — use message.accountID to fetch attachments via the right account.
- `AppFeedback/Views/Settings/EmailSettingsView.swift` — becomes the macOS container that hosts list + editor + defaults.
- `AppFeedback/Views/Settings/IOSEmailSettingsView.swift` — becomes a NavigationStack hosting the iOS list / editor / defaults.
- `AppFeedback/App/AppFeedbackApp.swift` — wire `MailSettingsStore` + registry.
- `AppFeedbackTests/MailAccountStoreTests.swift`
- `AppFeedbackTests/MailAccountMigrationTests.swift`
- `AppFeedbackTests/MailSyncCoordinatorTests.swift`
- `AppFeedbackTests/ComposeMailViewModelTests.swift`

**Build/test commands** (use the `zcode` skill for these):

- Build: `zcode build` (the project's wrapper around xcodebuild).
- Run tests: `zcode test`.
- Run a specific test: `zcode test --only AppFeedbackTests/MailSettingsStoreTests`.

For any step labelled "Run … and verify", use the `zcode` skill rather than direct `xcodebuild` calls.

---

## Phase 1 — Data model groundwork (no behavior change)

### Task 1: Add `accountID` to `MailMessage` and `MailThread`

**Files:**
- Modify: `AppFeedback/Models/MailMessage.swift`
- Modify: `AppFeedback/Models/MailThread.swift`

- [ ] **Step 1: Add optional `accountID` to `MailMessage`**

Edit `AppFeedback/Models/MailMessage.swift`. Insert after the `sentAt: Date? = nil` property (line 31):

```swift
    /// UUID of the `MailAccount` that sent or fetched this message. `nil` on legacy rows
    /// that pre-date the multi-account migration; the UI falls back to the global default
    /// sender when resolving a reply-from account.
    var accountID: UUID? = nil
```

Update the initializer parameter list — add `accountID: UUID? = nil` (place it right after `sentAt`):

```swift
        sentAt: Date? = nil,
        accountID: UUID? = nil,
        thread: MailThread? = nil,
```

And assign it in the body: `self.accountID = accountID`.

- [ ] **Step 2: Add optional `accountID` to `MailThread`**

Edit `AppFeedback/Models/MailThread.swift`. Insert after `var matchSourceRaw` (line 14):

```swift
    /// UUID of the `MailAccount` whose poll loop produced this thread, or whose outbound
    /// send created it. `nil` on legacy rows.
    var accountID: UUID? = nil
```

Add the parameter `accountID: UUID? = nil` to the initializer right after `matchSourceRaw`, and assign it.

- [ ] **Step 3: Verify build**

Run: `zcode build`
Expected: build succeeds; no behavior change yet because nothing reads `accountID`.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Models/MailMessage.swift AppFeedback/Models/MailThread.swift
git commit -m "feat(mail): add optional accountID to MailMessage and MailThread

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `isDefaultSender` to `MailAccount`

**Files:**
- Modify: `AppFeedback/Models/MailAccount.swift`
- Modify: `AppFeedbackTests/MailAccountStoreTests.swift`

- [ ] **Step 1: Add the field to the model**

Edit `AppFeedback/Models/MailAccount.swift`. Insert after `backfillCompleted` (line 20):

```swift
    /// Exactly one configured account has this true at a time. Used as the default FROM for
    /// new replies. `MailAccountStore` enforces the invariant.
    var isDefaultSender: Bool = false
```

Add `isDefaultSender: Bool = false` as a parameter after `backfillCompleted` in the init, and assign it.

- [ ] **Step 2: Verify build**

Run: `zcode build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Models/MailAccount.swift
git commit -m "feat(mail): add isDefaultSender flag to MailAccount

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Introduce `MailSettings` model

**Files:**
- Create: `AppFeedback/Models/MailSettings.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Create the model file**

Create `AppFeedback/Models/MailSettings.swift`:

```swift
import Foundation
import SwiftData

/// Shared mail settings that apply across all configured `MailAccount`s. The store keeps a
/// single row; if more exist they are coalesced to the oldest one. CloudKit-synced so a new
/// device picks up the user's header/footer and folder choice on first launch.
@Model
final class MailSettings {
    var id: UUID = UUID()
    var templateHeaderHTML: String = ""
    var templateFooterHTML: String = ""
    var attachmentFolderBookmark: Data? = nil
    var pollIntervalSeconds: Int = 300
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        templateHeaderHTML: String = "",
        templateFooterHTML: String = "",
        attachmentFolderBookmark: Data? = nil,
        pollIntervalSeconds: Int = 300,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.templateHeaderHTML = templateHeaderHTML
        self.templateFooterHTML = templateFooterHTML
        self.attachmentFolderBookmark = attachmentFolderBookmark
        self.pollIntervalSeconds = pollIntervalSeconds
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 2: Register the model in the SwiftData container**

Edit `AppFeedback/App/AppFeedbackApp.swift`. Update the two schema declarations to include `MailSettings.self`:

```swift
                    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                         MailSettings.self,
                         MailThread.self, MailMessage.self, MailAttachment.self,
                         IssueTranslation.self, IssueSummaryCache.self,
```

(Both the `for:` argument list and the `Schema([...])` array must include it. Search the file for `MailAccount.self` and add `MailSettings.self` immediately after each occurrence.)

- [ ] **Step 3: Build to confirm SwiftData accepts the schema**

Run: `zcode build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Models/MailSettings.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(mail): add MailSettings SwiftData model

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Add `MailSettingsStore` with TDD

**Files:**
- Create: `AppFeedback/Services/Mail/MailSettingsStore.swift`
- Create: `AppFeedbackTests/MailSettingsStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/MailSettingsStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailSettingsStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([MailSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    func test_emptyStoreReturnsSettingsWithDefaults() throws {
        let ctx = try makeContext()
        let store = MailSettingsStore(context: ctx)
        XCTAssertEqual(store.settings.templateHeaderHTML, "")
        XCTAssertEqual(store.settings.templateFooterHTML, "")
        XCTAssertEqual(store.settings.pollIntervalSeconds, 300)
        XCTAssertNil(store.settings.attachmentFolderBookmark)
    }

    func test_updatePersistsAcrossStoreInstances() throws {
        let ctx = try makeContext()
        let store = MailSettingsStore(context: ctx)
        store.update { s in
            s.templateHeaderHTML = "<p>Hi</p>"
            s.pollIntervalSeconds = 600
        }
        let reload = MailSettingsStore(context: ctx)
        XCTAssertEqual(reload.settings.templateHeaderHTML, "<p>Hi</p>")
        XCTAssertEqual(reload.settings.pollIntervalSeconds, 600)
    }

    func test_singletonInvariantIfMultipleRowsExist() throws {
        let ctx = try makeContext()
        ctx.insert(MailSettings(templateHeaderHTML: "old", createdAt: Date(timeIntervalSince1970: 1)))
        ctx.insert(MailSettings(templateHeaderHTML: "new", createdAt: Date(timeIntervalSince1970: 2)))
        try ctx.save()
        let store = MailSettingsStore(context: ctx)
        // Coalesces to oldest by createdAt.
        XCTAssertEqual(store.settings.templateHeaderHTML, "old")
        // Other rows are deleted.
        let count = try ctx.fetch(FetchDescriptor<MailSettings>()).count
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail (no store yet)**

Run: `zcode test --only AppFeedbackTests/MailSettingsStoreTests`
Expected: FAIL with "Cannot find 'MailSettingsStore' in scope".

- [ ] **Step 3: Implement `MailSettingsStore`**

Create `AppFeedback/Services/Mail/MailSettingsStore.swift`:

```swift
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailSettingsStore {
    private(set) var settings: MailSettings

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.settings = Self.fetchOrCreate(in: context)
    }

    func update(_ mutate: (MailSettings) -> Void) {
        mutate(settings)
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                assertionFailure("MailSettingsStore save failed: \(error)")
            }
        }
    }

    func reload() {
        settings = Self.fetchOrCreate(in: context)
    }

    private static func fetchOrCreate(in context: ModelContext) -> MailSettings {
        let descriptor = FetchDescriptor<MailSettings>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        if let first = rows.first {
            // Coalesce extras (can happen via CloudKit race on first multi-device sync).
            for extra in rows.dropFirst() {
                context.delete(extra)
            }
            if context.hasChanges { try? context.save() }
            return first
        }
        let fresh = MailSettings()
        context.insert(fresh)
        try? context.save()
        return fresh
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zcode test --only AppFeedbackTests/MailSettingsStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailSettingsStore.swift AppFeedbackTests/MailSettingsStoreTests.swift
git commit -m "feat(mail): add MailSettingsStore singleton with coalesce-on-fetch

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Keychain (per-account slots)

### Task 5: Per-account Keychain methods with TDD

**Files:**
- Modify: `AppFeedback/Services/KeychainService.swift`
- Create: `AppFeedbackTests/KeychainServicePerAccountTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/KeychainServicePerAccountTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class KeychainServicePerAccountTests: XCTestCase {
    func test_smtpRoundTripIsAccountScoped() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteSMTPPassword(for: a) }
            Task { await KeychainService.deleteSMTPPassword(for: b) }
        }
        _ = await KeychainService.saveSMTPPassword("aaaa", for: a)
        _ = await KeychainService.saveSMTPPassword("bbbb", for: b)
        let loadedA = await KeychainService.loadSMTPPassword(for: a)
        let loadedB = await KeychainService.loadSMTPPassword(for: b)
        XCTAssertEqual(loadedA, "aaaa")
        XCTAssertEqual(loadedB, "bbbb")
    }

    func test_imapRoundTripIsAccountScoped() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteIMAPPassword(for: a) }
            Task { await KeychainService.deleteIMAPPassword(for: b) }
        }
        _ = await KeychainService.saveIMAPPassword("aaaa", for: a)
        _ = await KeychainService.saveIMAPPassword("bbbb", for: b)
        XCTAssertEqual(await KeychainService.loadIMAPPassword(for: a), "aaaa")
        XCTAssertEqual(await KeychainService.loadIMAPPassword(for: b), "bbbb")
    }

    func test_deleteForOneAccountLeavesOthers() async throws {
        let a = UUID()
        let b = UUID()
        _ = await KeychainService.saveSMTPPassword("a", for: a)
        _ = await KeychainService.saveSMTPPassword("b", for: b)
        await KeychainService.deleteSMTPPassword(for: a)
        XCTAssertNil(await KeychainService.loadSMTPPassword(for: a))
        XCTAssertEqual(await KeychainService.loadSMTPPassword(for: b), "b")
        await KeychainService.deleteSMTPPassword(for: b)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `zcode test --only AppFeedbackTests/KeychainServicePerAccountTests`
Expected: FAIL with "Cannot find 'saveSMTPPassword(_:for:)' in scope".

- [ ] **Step 3: Add per-account Keychain methods**

Edit `AppFeedback/Services/KeychainService.swift`. After the existing `static let imapAccount = "imap.password"` block, but before the closing `}`, add:

```swift
    private static func smtpAccountKey(for accountID: UUID) -> String {
        "smtp.password.\(accountID.uuidString)"
    }

    private static func imapAccountKey(for accountID: UUID) -> String {
        "imap.password.\(accountID.uuidString)"
    }

    @discardableResult
    static func saveSMTPPassword(_ password: String, for accountID: UUID) async -> Bool {
        await saveSynchronizablePassword(password, account: smtpAccountKey(for: accountID))
    }

    static func loadSMTPPassword(for accountID: UUID) async -> String? {
        await loadSynchronizablePassword(account: smtpAccountKey(for: accountID))
    }

    static func deleteSMTPPassword(for accountID: UUID) async {
        await deleteSynchronizablePassword(account: smtpAccountKey(for: accountID))
    }

    @discardableResult
    static func saveIMAPPassword(_ password: String, for accountID: UUID) async -> Bool {
        await saveSynchronizablePassword(password, account: imapAccountKey(for: accountID))
    }

    static func loadIMAPPassword(for accountID: UUID) async -> String? {
        loadIMAPPasswordResult(for: accountID).password
    }

    /// Mirrors `loadIMAPPasswordResult()` so callers can distinguish "missing"
    /// from transient OSStatus failures, per the existing single-account path.
    static func loadIMAPPasswordResult(for accountID: UUID) -> (password: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccountKey(for: accountID),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    static func deleteIMAPPassword(for accountID: UUID) async {
        await deleteSynchronizablePassword(account: imapAccountKey(for: accountID))
    }

    // MARK: - shared helpers

    private static func saveSynchronizablePassword(_ password: String, account: String) async -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
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

    private static func loadSynchronizablePassword(account: String) async -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSynchronizablePassword(account: String) async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zcode test --only AppFeedbackTests/KeychainServicePerAccountTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/KeychainService.swift AppFeedbackTests/KeychainServicePerAccountTests.swift
git commit -m "feat(keychain): add per-account SMTP and IMAP password methods

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — `MailAccountStore` multi-account API

### Task 6: Expand `MailAccountStore` with TDD

**Files:**
- Modify: `AppFeedback/Services/Mail/MailAccountStore.swift`
- Modify: `AppFeedbackTests/MailAccountStoreTests.swift`

- [ ] **Step 1: Write the new failing tests (add to existing file)**

Edit `AppFeedbackTests/MailAccountStoreTests.swift` and append these tests to the existing class (before the closing `}`):

```swift
    func test_addReturnsAccountAndAppends() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "first@x" }
        let b = store.add { $0.smtpUsername = "second@x" }
        XCTAssertEqual(store.accounts.map(\.smtpUsername), ["first@x", "second@x"])
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_firstAccountBecomesDefaultSender() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        XCTAssertTrue(a.isDefaultSender)
        XCTAssertEqual(store.defaultSender?.id, a.id)
    }

    func test_secondAccountDoesNotBecomeDefault() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        let b = store.add { $0.smtpUsername = "b@x" }
        XCTAssertTrue(a.isDefaultSender)
        XCTAssertFalse(b.isDefaultSender)
    }

    func test_setDefaultSenderEnforcesSingleFlag() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        let b = store.add { $0.smtpUsername = "b@x" }
        store.setDefaultSender(b)
        XCTAssertFalse(store.account(id: a.id)?.isDefaultSender ?? true)
        XCTAssertTrue(store.account(id: b.id)?.isDefaultSender ?? false)
    }

    func test_deletingDefaultReassignsToOldestRemaining() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x"; $0.createdAt = .init(timeIntervalSince1970: 1) }
        let b = store.add { $0.smtpUsername = "b@x"; $0.createdAt = .init(timeIntervalSince1970: 2) }
        store.delete(a)
        XCTAssertEqual(store.defaultSender?.id, b.id)
        XCTAssertTrue(store.account(id: b.id)?.isDefaultSender ?? false)
    }

    func test_deletingNonDefaultKeepsExistingDefault() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        let b = store.add { $0.smtpUsername = "b@x" }
        store.delete(b)
        XCTAssertEqual(store.defaultSender?.id, a.id)
        XCTAssertEqual(store.accounts.count, 1)
    }

    func test_updateMutatesTargetAccount() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        store.update(id: a.id) { $0.senderName = "Alice" }
        XCTAssertEqual(store.account(id: a.id)?.senderName, "Alice")
    }
```

You also need to add a `makeStore()` helper if the file does not already have one. Search the file; if there's an existing in-memory `ModelContext`-creating helper reuse it. If not, add at the top of the test class:

```swift
    private func makeStore() throws -> MailAccountStore {
        let schema = Schema([MailAccount.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return MailAccountStore(context: ModelContext(container))
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `zcode test --only AppFeedbackTests/MailAccountStoreTests`
Expected: FAIL with "Value of type 'MailAccountStore' has no member 'accounts'" / "...'add'" / "...'setDefaultSender'" / "...'account(id:)'" / "...'update(id:_:)'" / "...'defaultSender'" / "...'delete'".

- [ ] **Step 3: Rewrite `MailAccountStore` for multi-account**

Replace the body of `AppFeedback/Services/Mail/MailAccountStore.swift` with:

```swift
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailAccountStore {
    private(set) var accounts: [MailAccount] = []

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.accounts = Self.fetch(in: context)
    }

    var defaultSender: MailAccount? {
        accounts.first(where: { $0.isDefaultSender }) ?? accounts.first
    }

    func account(id: UUID) -> MailAccount? {
        accounts.first(where: { $0.id == id })
    }

    @discardableResult
    func add(_ mutate: (MailAccount) -> Void = { _ in }) -> MailAccount {
        let new = MailAccount()
        context.insert(new)
        mutate(new)
        if accounts.isEmpty {
            new.isDefaultSender = true
        }
        save()
        reload()
        return account(id: new.id) ?? new
    }

    func update(id: UUID, _ mutate: (MailAccount) -> Void) {
        guard let target = account(id: id) else { return }
        mutate(target)
        save()
    }

    func setDefaultSender(_ target: MailAccount) {
        for acc in accounts {
            let shouldBeDefault = acc.id == target.id
            if acc.isDefaultSender != shouldBeDefault {
                acc.isDefaultSender = shouldBeDefault
            }
        }
        save()
    }

    func delete(_ target: MailAccount) {
        let wasDefault = target.isDefaultSender
        context.delete(target)
        save()
        reload()
        if wasDefault, let oldest = accounts.first {
            setDefaultSender(oldest)
        }
    }

    func reload() {
        accounts = Self.fetch(in: context)
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("MailAccountStore save failed: \(error)")
        }
    }

    private static func fetch(in context: ModelContext) -> [MailAccount] {
        let descriptor = FetchDescriptor<MailAccount>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
```

- [ ] **Step 4: Add backwards-compat shim for the now-legacy single-account API**

The existing `account` property and `upsert` / `deleteAccount` are still called by `MailSyncCoordinator`, `IMAPClientProvider`, `EmailSettingsView`, `IOSEmailSettingsView`, `MailMessageRowView`, `ComposeMailView`, `ComposeMailViewModel`, and `MailAccountMigration`. To keep the build green while later tasks migrate each call site, append to the same file:

```swift
// MARK: - Transitional single-account compatibility
// Removed in Task 17 after all call sites adopt the multi-account API.
extension MailAccountStore {
    var account: MailAccount? { defaultSender ?? accounts.first }

    func upsert(_ mutate: (MailAccount) -> Void) {
        if let acc = accounts.first {
            update(id: acc.id, mutate)
        } else {
            _ = add(mutate)
        }
    }

    func deleteAccount() {
        guard let acc = accounts.first else { return }
        delete(acc)
    }
}
```

- [ ] **Step 5: Update existing tests that used the single-account API**

In `AppFeedbackTests/MailAccountStoreTests.swift`, find tests using `store.account` (already there per the spec exploration) — they should keep passing thanks to the shim.

Run: `zcode test --only AppFeedbackTests/MailAccountStoreTests`
Expected: PASS (all old + new tests).

- [ ] **Step 6: Verify the rest of the suite still builds and passes**

Run: `zcode test`
Expected: full suite PASS. Pay attention to any compile errors — the shim should cover them.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Services/Mail/MailAccountStore.swift AppFeedbackTests/MailAccountStoreTests.swift
git commit -m "feat(mail): multi-account API on MailAccountStore with transitional shim

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Migration

### Task 7: v2 migration (default sender + MailSettings + per-account Keychain + accountID backfill)

**Files:**
- Modify: `AppFeedback/Services/Mail/MailAccountMigration.swift`
- Modify: `AppFeedbackTests/MailAccountMigrationTests.swift`

- [ ] **Step 1: Write the failing migration tests**

Edit `AppFeedbackTests/MailAccountMigrationTests.swift`. Append:

```swift
    func test_v2_marksExistingAccountAsDefaultSender() async throws {
        let (store, settingsStore, threadStore, defaults) = try makeV2Fixtures()
        let acc = store.add { $0.smtpUsername = "old@x" }
        acc.isDefaultSender = false
        defaults.set(false, forKey: "mail.multiaccount.migration.v1.completed")

        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )

        XCTAssertTrue(store.account(id: acc.id)?.isDefaultSender ?? false)
        XCTAssertTrue(defaults.bool(forKey: "mail.multiaccount.migration.v1.completed"))
    }

    func test_v2_movesSharedSettingsIntoMailSettings() async throws {
        let (store, settingsStore, threadStore, defaults) = try makeV2Fixtures()
        let acc = store.add { a in
            a.smtpUsername = "old@x"
            a.templateHeaderHTML = "<p>hello</p>"
            a.templateFooterHTML = "<p>cheers</p>"
            a.pollIntervalSeconds = 600
        }
        defaults.set(false, forKey: "mail.multiaccount.migration.v1.completed")

        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )

        XCTAssertEqual(settingsStore.settings.templateHeaderHTML, "<p>hello</p>")
        XCTAssertEqual(settingsStore.settings.templateFooterHTML, "<p>cheers</p>")
        XCTAssertEqual(settingsStore.settings.pollIntervalSeconds, 600)
        XCTAssertEqual(store.account(id: acc.id)?.templateHeaderHTML, "")
        XCTAssertEqual(store.account(id: acc.id)?.templateFooterHTML, "")
    }

    func test_v2_isIdempotent() async throws {
        let (store, settingsStore, threadStore, defaults) = try makeV2Fixtures()
        _ = store.add { a in
            a.smtpUsername = "old@x"
            a.templateHeaderHTML = "<p>once</p>"
        }
        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )
        // Mutate settings after migration; a second run must NOT overwrite them.
        settingsStore.update { $0.templateHeaderHTML = "<p>edited</p>" }
        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )
        XCTAssertEqual(settingsStore.settings.templateHeaderHTML, "<p>edited</p>")
    }

    func test_v2_backfillsMessageAndThreadAccountID() async throws {
        let (store, settingsStore, threadStore, defaults) = try makeV2Fixtures()
        let acc = store.add { $0.smtpUsername = "old@x" }
        let thread = MailThread(messageIDRoot: "<x>", subject: "S")
        let message = MailMessage(messageID: "<x>", thread: thread)
        threadStore.context.insert(thread)
        threadStore.context.insert(message)
        try threadStore.context.save()

        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )

        XCTAssertEqual(thread.accountID, acc.id)
        XCTAssertEqual(message.accountID, acc.id)
    }

    // MARK: - helpers

    private func makeV2Fixtures() throws -> (MailAccountStore, MailSettingsStore, MailThreadStore, UserDefaults) {
        let schema = Schema([MailAccount.self, MailSettings.self, MailThread.self, MailMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let accountStore = MailAccountStore(context: ctx)
        let settingsStore = MailSettingsStore(context: ctx)
        let threadStore = MailThreadStore(context: ctx)
        let defaults = UserDefaults(suiteName: "mail.migration.v2.\(UUID().uuidString)")!
        return (accountStore, settingsStore, threadStore, defaults)
    }
```

If `MailThreadStore` does not expose a public `context` property, instead pass the raw `ModelContext` to the test and bypass the store — fall back to `ctx.insert(...)` directly using the same `ctx`. (Inspect the store before writing this helper.)

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `zcode test --only AppFeedbackTests/MailAccountMigrationTests`
Expected: FAIL with "no member 'runV2IfNeeded'".

- [ ] **Step 3: Implement v2 migration**

Edit `AppFeedback/Services/Mail/MailAccountMigration.swift`. Append:

```swift
extension MailAccountMigration {
    private static let v2CompletedKey = "mail.multiaccount.migration.v1.completed"
    private static let legacyMailAccountFolderBookmarkKey = "" // unused; bookmark already lives on MailAccount

    /// One-shot multi-account migration. Idempotent.
    ///
    /// Steps:
    ///   1. Mark the existing single MailAccount (if any) as the default sender.
    ///   2. Copy templateHeaderHTML / templateFooterHTML / attachmentFolderBookmark /
    ///      pollIntervalSeconds into `MailSettings` (leaving the fields cleared on
    ///      `MailAccount` so a future schema removal can drop them safely).
    ///   3. Read legacy fixed-slot Keychain creds and re-save them keyed by the account's UUID.
    ///      Then delete the legacy slots. We also re-issue the delete on every launch via
    ///      `purgeLegacyKeychain()` to defeat a downgraded-device resurrecting the legacy slot.
    ///   4. Backfill MailMessage.accountID and MailThread.accountID with the surviving
    ///      account's UUID (only one account existed pre-migration, so this is unambiguous).
    @MainActor
    static func runV2IfNeeded(
        accountStore: MailAccountStore,
        settingsStore: MailSettingsStore,
        threadStore: MailThreadStore,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: v2CompletedKey) else {
            purgeLegacyKeychain()
            return
        }
        defer {
            defaults.set(true, forKey: v2CompletedKey)
            purgeLegacyKeychain()
        }

        guard let legacy = accountStore.accounts.first else {
            return
        }

        // (1) Default sender.
        if !legacy.isDefaultSender {
            accountStore.setDefaultSender(legacy)
        }

        // (2) Shared settings extraction.
        settingsStore.update { s in
            if s.templateHeaderHTML.isEmpty {
                s.templateHeaderHTML = legacy.templateHeaderHTML
            }
            if s.templateFooterHTML.isEmpty {
                s.templateFooterHTML = legacy.templateFooterHTML
            }
            if s.attachmentFolderBookmark == nil {
                s.attachmentFolderBookmark = legacy.attachmentFolderBookmark
            }
            // Only seed the poll interval the first time, so a user who later changes it
            // in MailSettings isn't reset by a re-run.
            if s.pollIntervalSeconds == 300 && legacy.pollIntervalSeconds != 300 {
                s.pollIntervalSeconds = legacy.pollIntervalSeconds
            }
        }
        accountStore.update(id: legacy.id) { a in
            a.templateHeaderHTML = ""
            a.templateFooterHTML = ""
            a.attachmentFolderBookmark = nil
        }

        // (3) Keychain reissue.
        Task { @MainActor in
            if let smtp = await KeychainService.loadSMTPPassword(), !smtp.isEmpty {
                _ = await KeychainService.saveSMTPPassword(smtp, for: legacy.id)
            }
            if let imap = await KeychainService.loadIMAPPassword(), !imap.isEmpty {
                _ = await KeychainService.saveIMAPPassword(imap, for: legacy.id)
            }
            await KeychainService.deleteSMTPPassword()
            await KeychainService.deleteIMAPPassword()
        }

        // (4) Backfill thread / message accountID.
        threadStore.backfillAccountIDIfMissing(legacy.id)
    }

    /// Idempotently deletes the legacy fixed-slot SMTP/IMAP entries. Called on every launch
    /// after v2 has completed, so a brief downgrade-then-upgrade cycle doesn't resurrect
    /// stale credentials.
    @MainActor
    static func purgeLegacyKeychain() {
        Task {
            await KeychainService.deleteSMTPPassword()
            await KeychainService.deleteIMAPPassword()
        }
    }
}
```

- [ ] **Step 4: Add `backfillAccountIDIfMissing` to `MailThreadStore`**

Open `AppFeedback/Services/Mail/MailThreadStore.swift`. Add a new method (idempotent — only sets when nil):

```swift
    /// Stamps every existing thread and message with the given accountID **only when it is
    /// currently nil**. Used by the v2 multi-account migration to retroactively associate
    /// pre-migration rows with the user's sole account. Cheap on re-run: the predicate
    /// short-circuits when nothing is nil.
    func backfillAccountIDIfMissing(_ accountID: UUID) {
        let threadDescriptor = FetchDescriptor<MailThread>(
            predicate: #Predicate { $0.accountID == nil }
        )
        let threads = (try? context.fetch(threadDescriptor)) ?? []
        for t in threads { t.accountID = accountID }

        let messageDescriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.accountID == nil }
        )
        let messages = (try? context.fetch(messageDescriptor)) ?? []
        for m in messages { m.accountID = accountID }

        if !threads.isEmpty || !messages.isEmpty {
            try? context.save()
        }
    }
```

If the file's `context` is `private`, change it to `internal` so the test fixture can insert directly. If you'd rather keep `context` private, expose a `func insertForTest(_ thread: MailThread, message: MailMessage)` helper — but bumping access is fine here.

- [ ] **Step 5: Wire v2 into `AppFeedbackApp.init`**

Edit `AppFeedback/App/AppFeedbackApp.swift`. Add a `MailSettingsStore` state property and instantiate it next to `mailAccountStoreLocal`. Then call v2 right after the existing v1:

```swift
        let mailAccountStoreLocal = MailAccountStore(context: ModelContext(container))
        let mailSettingsStoreLocal = MailSettingsStore(context: ModelContext(container))
        await MainActor.run {
            MailAccountMigration.runIfNeeded(store: mailAccountStoreLocal)
            MailAccountMigration.runV2IfNeeded(
                accountStore: mailAccountStoreLocal,
                settingsStore: mailSettingsStoreLocal,
                threadStore: threadStoreLocal
            )
        }
        _mailAccountStore = State(initialValue: mailAccountStoreLocal)
        _mailSettingsStore = State(initialValue: mailSettingsStoreLocal)
```

Add the corresponding `@State private var mailSettingsStore: MailSettingsStore` near the top of `AppFeedbackApp`. Then inject it into both `RootView` and the macOS `Settings` scene via `.environment(mailSettingsStore)`.

The existing `MailAccountMigration.runIfNeeded` is not async; if you nest both calls inside `MainActor.run` block as shown the closure can stay sync — adjust if necessary.

- [ ] **Step 6: Run the tests**

Run: `zcode test --only AppFeedbackTests/MailAccountMigrationTests`
Expected: PASS.

Run: `zcode test`
Expected: full suite PASS.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Services/Mail/MailAccountMigration.swift AppFeedback/Services/Mail/MailThreadStore.swift AppFeedback/App/AppFeedbackApp.swift AppFeedbackTests/MailAccountMigrationTests.swift
git commit -m "feat(mail): v2 migration — default sender, shared settings, per-account keychain, accountID backfill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Coordinator and IMAP provider per-account

### Task 8: `IMAPClientProvider` becomes per-account

**Files:**
- Modify: `AppFeedback/Services/Mail/IMAPClientProvider.swift`

- [ ] **Step 1: Update `IMAPClientProvider` to take an `accountID`**

Edit `AppFeedback/Services/Mail/IMAPClientProvider.swift`. Change:

```swift
actor IMAPClientProvider: IMAPClientProtocol {
    private let accountStore: MailAccountStore
    private let accountID: UUID

    init(accountStore: MailAccountStore, accountID: UUID) {
        self.accountStore = accountStore
        self.accountID = accountID
    }

    // ...listInbox/listSent/fetchAttachmentBytes/testConnection unchanged...

    private func makeClient() async throws -> IMAPClient {
        let accountID = self.accountID
        let snap: (host: String, port: Int, username: String)? = await MainActor.run {
            guard let acc = accountStore.account(id: accountID),
                  !acc.imapHost.isEmpty,
                  !acc.imapUsername.isEmpty else { return nil }
            return (acc.imapHost, acc.imapPort, acc.imapUsername)
        }
        guard let snap else { throw IMAPClientError.passwordUnavailable }
        let password = try await loadIMAPPasswordWithRetry()
        return IMAPClient(host: snap.host, port: snap.port, username: snap.username, password: password)
    }

    private func loadIMAPPasswordWithRetry() async throws -> String {
        for attempt in 0..<2 {
            let (pw, status) = KeychainService.loadIMAPPasswordResult(for: accountID)
            if status == errSecSuccess, let pw, !pw.isEmpty {
                return pw
            }
            if status == errSecItemNotFound || (status == errSecSuccess && (pw ?? "").isEmpty) {
                throw IMAPClientError.passwordUnavailable
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            throw IMAPClientError.transport(underlying: "Keychain read failed (OSStatus \(status))")
        }
        throw IMAPClientError.passwordUnavailable
    }
}
```

- [ ] **Step 2: Verify build**

Run: `zcode build`
Expected: failures in `AppFeedbackApp.swift` ("missing argument for parameter 'accountID'"). That's fine — fixed in Task 10. Confirm there are no other unexpected failures.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Mail/IMAPClientProvider.swift
git commit -m "refactor(mail): scope IMAPClientProvider to one account by UUID

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `MailSyncCoordinator` becomes per-account

**Files:**
- Modify: `AppFeedback/Services/Mail/MailSyncCoordinator.swift`
- Modify: `AppFeedbackTests/MailSyncCoordinatorTests.swift`

- [ ] **Step 1: Update coordinator to take an `accountID`**

Edit `AppFeedback/Services/Mail/MailSyncCoordinator.swift`:

- Add stored property `private let accountID: UUID`.
- Add `accountID: UUID` to the initializer after `client`.
- In `pollOnce`, replace `self.accountStore.account` with `self.accountStore.account(id: accountID)`.
- In `runBackfill`, also use `account(id:)`.
- In the `while !Task.isCancelled` interval loop, similarly use `account(id:)`.

The two `self.accountStore.upsert { acc in acc.backfillCompleted = true }` call sites become:

```swift
self.accountStore.update(id: accountID) { acc in acc.backfillCompleted = true }
```

- [ ] **Step 2: Update the activity log titles to include the account address**

Inside `pollOnce`, fold the account's `smtpUsername` into the activity log title so the user can tell parallel polls apart. Replace the `activityLog.start(...)` calls with:

```swift
        let accountLabel = await MainActor.run { accountStore.account(id: accountID)?.smtpUsername ?? "—" }
        let logID = await MainActor.run {
            self.activityLog.start(kind: .fetchMail, title: "Fetch mail (\(accountLabel))")
        }
```

And similarly the backfill activity title becomes `"Backfill sent folder (\(accountLabel))"` (compute `accountLabel` once at the top of `runBackfill`).

- [ ] **Step 3: Update `MailSyncCoordinatorTests` for the new signature**

Edit `AppFeedbackTests/MailSyncCoordinatorTests.swift`. Every `MailSyncCoordinator(...)` call must pass `accountID:`. Use `accountStore.account!.id` (which the tests already grab in some places). Add the parameter to all instantiations:

```swift
let coordinator = MailSyncCoordinator(
    client: stub,
    accountID: accountStore.account!.id,
    threadStore: ...
    // rest unchanged
)
```

(The keyword `accountID:` slots right after `client:`.) Run the tests after.

- [ ] **Step 4: Run the tests**

Run: `zcode test --only AppFeedbackTests/MailSyncCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailSyncCoordinator.swift AppFeedbackTests/MailSyncCoordinatorTests.swift
git commit -m "refactor(mail): scope MailSyncCoordinator to one account by UUID

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Stamp `accountID` on outbound + inbound messages

**Files:**
- Modify: `AppFeedback/Services/Mail/MailThreadStore.swift`
- Modify: `AppFeedback/Services/Mail/MailSyncCoordinator.swift`
- Modify: `AppFeedback/ViewModels/ComposeMailViewModel.swift`

- [ ] **Step 1: Extend `recordInbound` and `recordOutbound` to accept an `accountID`**

Open `AppFeedback/Services/Mail/MailThreadStore.swift`. Add `accountID: UUID?` to both `recordInbound` and `recordOutbound` signatures (default `nil` so we can roll out call sites one at a time). When inserting/locating the `MailThread`, set `thread.accountID = accountID` if currently nil. When creating the `MailMessage`, set `message.accountID = accountID`.

(Look at the existing function bodies and add `message.accountID = accountID` immediately after the existing assignments; for the thread, set on creation and never overwrite an existing non-nil value.)

- [ ] **Step 2: Pass `accountID` from the coordinator**

Inside `MailSyncCoordinator.pollOnce`, replace the `threadStore.recordInbound(message: msg)` call with:

```swift
self.threadStore.recordInbound(message: msg, accountID: accountID)
```

Inside `runBackfill`, change `self.threadStore.recordOutbound(...)` to pass `accountID: accountID` at the end.

- [ ] **Step 3: Pass `accountID` from compose**

`ComposeMailViewModel` will be updated in Task 12 to know its sender's accountID. For now, change its `threadStore?.recordOutbound(...)` calls to pass `accountID: credentials.accountID`, anticipating the next task. Mark this with a `// set in Task 12` if helpful.

Actually, defer this until Task 12 to avoid an intermediate broken state. Leave the compose side at `accountID: nil` for now and rely on the backfill-on-launch path to stamp it once the coordinator runs a poll. **Decision:** skip this sub-step.

- [ ] **Step 4: Verify build and tests**

Run: `zcode build`
Expected: builds.

Run: `zcode test --only AppFeedbackTests/MailSyncCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailThreadStore.swift AppFeedback/Services/Mail/MailSyncCoordinator.swift
git commit -m "feat(mail): stamp accountID on inbound and backfilled outbound rows

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: `MailSyncCoordinatorRegistry`

**Files:**
- Create: `AppFeedback/Services/Mail/MailSyncCoordinatorRegistry.swift`
- Create: `AppFeedbackTests/MailSyncCoordinatorRegistryTests.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Write the failing registry tests**

Create `AppFeedbackTests/MailSyncCoordinatorRegistryTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailSyncCoordinatorRegistryTests: XCTestCase {
    func test_buildsOneCoordinatorPerAccount() throws {
        let fixtures = try makeFixtures()
        _ = fixtures.accountStore.add { $0.smtpUsername = "a@x" }
        _ = fixtures.accountStore.add { $0.smtpUsername = "b@x" }
        let registry = MailSyncCoordinatorRegistry.makeForTests(fixtures: fixtures)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 2)
    }

    func test_addingAccountSpinsUpCoordinator() throws {
        let fixtures = try makeFixtures()
        _ = fixtures.accountStore.add { $0.smtpUsername = "a@x" }
        let registry = MailSyncCoordinatorRegistry.makeForTests(fixtures: fixtures)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 1)
        _ = fixtures.accountStore.add { $0.smtpUsername = "b@x" }
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 2)
    }

    func test_deletingAccountTearsDownCoordinator() throws {
        let fixtures = try makeFixtures()
        let a = fixtures.accountStore.add { $0.smtpUsername = "a@x" }
        _ = fixtures.accountStore.add { $0.smtpUsername = "b@x" }
        let registry = MailSyncCoordinatorRegistry.makeForTests(fixtures: fixtures)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 2)
        fixtures.accountStore.delete(a)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 1)
    }

    // Helpers -----------------------------------------------------------------

    struct Fixtures {
        let context: ModelContext
        let accountStore: MailAccountStore
        let threadStore: MailThreadStore
        let localStateStore: MailAccountLocalStateStore
        let activityLog: ActivityLog
    }

    private func makeFixtures() throws -> Fixtures {
        let schema = Schema([MailAccount.self, MailSettings.self, MailAccountLocalState.self,
                             MailThread.self, MailMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        return Fixtures(
            context: ctx,
            accountStore: MailAccountStore(context: ctx),
            threadStore: MailThreadStore(context: ctx),
            localStateStore: MailAccountLocalStateStore(context: ctx),
            activityLog: ActivityLog()
        )
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `zcode test --only AppFeedbackTests/MailSyncCoordinatorRegistryTests`
Expected: FAIL with "Cannot find 'MailSyncCoordinatorRegistry' in scope".

- [ ] **Step 3: Implement the registry**

Create `AppFeedback/Services/Mail/MailSyncCoordinatorRegistry.swift`:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class MailSyncCoordinatorRegistry {
    typealias CoordinatorFactory = (UUID) -> MailSyncCoordinator

    private let accountStore: MailAccountStore
    private let factory: CoordinatorFactory
    private var coordinators: [UUID: MailSyncCoordinator] = [:]

    init(accountStore: MailAccountStore, factory: @escaping CoordinatorFactory) {
        self.accountStore = accountStore
        self.factory = factory
    }

    var coordinatorCount: Int { coordinators.count }

    func coordinator(for id: UUID) -> MailSyncCoordinator? { coordinators[id] }

    /// Reconciles the live coordinator set with the current account list. Call this on launch
    /// and whenever the account list changes (add/delete). Idempotent.
    func syncWithAccounts() {
        let currentIDs = Set(accountStore.accounts.map(\.id))

        // Tear down removed accounts.
        for (id, coord) in coordinators where !currentIDs.contains(id) {
            Task { await coord.stop() }
            coordinators[id] = nil
        }

        // Spin up new accounts.
        for acc in accountStore.accounts where coordinators[acc.id] == nil {
            let coord = factory(acc.id)
            coordinators[acc.id] = coord
            Task { await coord.start() }
        }
    }

    func start() {
        for coord in coordinators.values {
            Task { await coord.start() }
        }
    }

    func pollNow() async {
        await withTaskGroup(of: Void.self) { group in
            for coord in coordinators.values {
                group.addTask { await coord.pollNow() }
            }
        }
    }

    func stop() {
        for coord in coordinators.values {
            Task { await coord.stop() }
        }
    }

    func restart(accountID: UUID) {
        guard let coord = coordinators[accountID] else {
            syncWithAccounts()
            return
        }
        Task {
            await coord.stop()
            await coord.start()
        }
    }
}

#if DEBUG
extension MailSyncCoordinatorRegistry {
    /// Test factory that builds a coordinator wired to in-memory stubs. The returned coordinator
    /// is intentionally a *real* coordinator instance (so we can count them) but uses a no-op
    /// IMAP client to avoid network calls during tests.
    static func makeForTests(fixtures: MailSyncCoordinatorRegistryTests.Fixtures) -> MailSyncCoordinatorRegistry {
        MailSyncCoordinatorRegistry(accountStore: fixtures.accountStore) { id in
            MailSyncCoordinator(
                client: NoopIMAPClient(),
                accountID: id,
                threadStore: fixtures.threadStore,
                accountStore: fixtures.accountStore,
                localState: fixtures.localStateStore,
                activityLog: fixtures.activityLog,
                knownIssueTitlesProvider: { [] }
            )
        }
    }
}

private struct NoopIMAPClient: IMAPClientProtocol {
    func listInbox(sinceUID: UInt32, fromAddresses: [String]) async throws -> [ParsedInboundMessage] { [] }
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] { [] }
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data { Data() }
    func testConnection() async throws {}
}
#endif
```

Adjust the test factory path: since `MailSyncCoordinatorRegistryTests.Fixtures` is defined in the test target, the `#if DEBUG` block in the main target can't reference it. Move the `makeForTests` factory and the `NoopIMAPClient` into the test file itself as an extension on `MailSyncCoordinatorRegistry`:

```swift
extension MailSyncCoordinatorRegistry {
    static func makeForTests(fixtures: MailSyncCoordinatorRegistryTests.Fixtures) -> MailSyncCoordinatorRegistry {
        // body as above
    }
}
```

Keep `NoopIMAPClient` as a `fileprivate` type in the test file too. Remove the `#if DEBUG` block from the main-target file.

- [ ] **Step 4: Wire registry into `AppFeedbackApp`**

Edit `AppFeedback/App/AppFeedbackApp.swift`. Replace the `MailSyncCoordinatorHolder` plumbing with a `MailSyncCoordinatorRegistry`:

```swift
        #if canImport(SwiftMail)
        let registryFactory: (UUID) -> MailSyncCoordinator = { id in
            let imapProvider = IMAPClientProvider(accountStore: mailAccountStoreLocal, accountID: id)
            return MailSyncCoordinator(
                client: imapProvider,
                accountID: id,
                threadStore: threadStoreLocal,
                accountStore: mailAccountStoreLocal,
                localState: localStateStore,
                activityLog: activityLogValue,
                mirror: mirrorLocal,
                notificationService: service,
                knownIssueTitlesProvider: { @Sendable in
                    await MainActor.run {
                        let ctx = ModelContext(titlesContainer)
                        let cached = (try? ctx.fetch(FetchDescriptor<CachedIssue>())) ?? []
                        return cached.map { (owner: $0.repoOwner, repo: $0.repoName, number: $0.number, title: $0.title) }
                    }
                }
            )
        }
        let registry = MailSyncCoordinatorRegistry(accountStore: mailAccountStoreLocal, factory: registryFactory)
        registry.syncWithAccounts()
        _coordinatorRegistry = State(initialValue: registry)
        // Attachment downloader still needs ONE IMAPClientProtocol; route through the default sender's provider.
        let defaultSenderID = mailAccountStoreLocal.defaultSender?.id ?? UUID()
        let downloaderProvider = IMAPClientProvider(accountStore: mailAccountStoreLocal, accountID: defaultSenderID)
        let attachmentLocalStore = MailAttachmentLocalStore(context: ModelContext(container))
        let downloader = AttachmentDownloader(client: downloaderProvider, localStore: attachmentLocalStore)
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(downloader))
        #else
        _coordinatorRegistry = State(initialValue: MailSyncCoordinatorRegistry.empty())
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(nil))
        #endif
```

Add a static `empty()` factory to `MailSyncCoordinatorRegistry` for the non-SwiftMail branch:

```swift
    static func empty() -> MailSyncCoordinatorRegistry {
        // Built with an account store that will return zero accounts and a factory that should
        // never be invoked (no accounts → no factory calls). Used in builds without SwiftMail.
        let unreachable: CoordinatorFactory = { _ in fatalError("registry.empty().factory called") }
        // We need an accountStore to instantiate; reuse a sentinel via a dummy MainActor context.
        // In practice the SwiftMail-less branch never calls syncWithAccounts.
        fatalError("empty() must only be reached in non-SwiftMail builds; wire it where called")
    }
```

Actually, since the SwiftMail-less branch is only iOS-simulator-without-SwiftMail in CI, and the rest of the file already handles `#if canImport(SwiftMail)` by storing a holder with `nil` coordinator — the cleanest approach is to make `MailSyncCoordinatorRegistry` itself optional in the environment. Change `_coordinatorRegistry` to `MailSyncCoordinatorRegistry?` and the non-SwiftMail branch sets `nil`. Update environment injection accordingly.

Then replace every existing `coordinatorHolder.coordinator?.start()` / `pollNow()` call site in this file with:

```swift
Task { coordinatorRegistry?.start() }
```
or
```swift
Task { await coordinatorRegistry?.pollNow() }
```

Remove the old `_coordinatorHolder` property declaration, init, and environment injection. Search for `coordinatorHolder` across `AppFeedbackApp.swift` and replace; do not touch other files yet — they still reference `MailSyncCoordinatorHolder` and will be cleaned up in Task 14.

- [ ] **Step 5: Add a `MailSyncCoordinatorHolder` compatibility shim**

`EmailSettingsView.swift` and `IOSEmailSettingsView.swift` still reference `MailSyncCoordinatorHolder` via `@Environment`. To keep them compiling until Task 14 rewrites them, keep the holder file in place and inject a holder that wraps `defaultSender`'s coordinator:

```swift
let holderForLegacyViews = MailSyncCoordinatorHolder(registry.coordinator(for: defaultSenderID))
_coordinatorHolder = State(initialValue: holderForLegacyViews)
```

This isn't great but it keeps the intermediate commits green. Mark with a `// Removed in Task 14.` comment.

- [ ] **Step 6: Run the registry tests**

Run: `zcode test --only AppFeedbackTests/MailSyncCoordinatorRegistryTests`
Expected: PASS (3 tests).

Run: `zcode build`
Expected: builds.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Services/Mail/MailSyncCoordinatorRegistry.swift AppFeedback/App/AppFeedbackApp.swift AppFeedbackTests/MailSyncCoordinatorRegistryTests.swift
git commit -m "feat(mail): MailSyncCoordinatorRegistry — one coordinator per account

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Compose + reply

### Task 12: `ComposeMailViewModel` learns `senderAccountID`

**Files:**
- Modify: `AppFeedback/ViewModels/ComposeMailViewModel.swift`
- Modify: `AppFeedbackTests/ComposeMailViewModelTests.swift`

- [ ] **Step 1: Add a failing test that asserts the FROM and password come from the requested account**

Edit `AppFeedbackTests/ComposeMailViewModelTests.swift`. Append:

```swift
    func test_sendUsesCredentialsAndPasswordForRequestedAccount() async throws {
        let store = try makeStore()
        let a = store.add { acc in
            acc.smtpUsername = "alice@x"
            acc.senderName = "Alice"
            acc.smtpHost = "smtp.x"
            acc.smtpPort = 587
        }
        let b = store.add { acc in
            acc.smtpUsername = "bob@x"
            acc.senderName = "Bob"
            acc.smtpHost = "smtp.x"
            acc.smtpPort = 587
        }

        let sender = StubSender()
        let activityLog = ActivityLog()

        let viewModel = ComposeMailViewModel(
            recipient: "user@example.com",
            issue: makeIssue(),
            repoOwner: "owner",
            repoName: "repo",
            store: store,
            sender: sender,
            activityLog: activityLog,
            senderAccountID: b.id,
            passwordLoader: { @Sendable id in
                XCTAssertEqual(id, b.id)
                return "bob-password"
            }
        )
        viewModel.subject = "Test"
        viewModel.body = NSAttributedString(string: "hello")
        await viewModel.send()

        XCTAssertEqual(sender.lastCredentials?.username, "bob@x")
        XCTAssertEqual(sender.lastPassword, "bob-password")
        _ = a
    }
```

You may need to extend the existing `StubSender` to record `lastCredentials` / `lastPassword`. If those properties already exist (check the file), reuse them.

- [ ] **Step 2: Run the test to confirm it fails**

Run: `zcode test --only AppFeedbackTests/ComposeMailViewModelTests`
Expected: FAIL — "missing argument for parameter 'senderAccountID'".

- [ ] **Step 3: Add `senderAccountID` to the view model**

Edit `AppFeedback/ViewModels/ComposeMailViewModel.swift`:

- Add `let senderAccountID: UUID` after `repoName`.
- Change the `passwordLoader` signature to `@Sendable (UUID) async -> String?` with default `{ @Sendable id in await KeychainService.loadSMTPPassword(for: id) }`.
- Add `senderAccountID: UUID` as a required init parameter (positionally place it right before `passwordLoader`).
- Update `currentCredentials()` to use `store.account(id: senderAccountID)` instead of `store.account`.
- Inside `send()`, replace `await passwordLoader()` with `await passwordLoader(senderAccountID)`.
- Inside `send()`, when calling `threadStore?.recordOutbound(...)`, pass `accountID: senderAccountID` (per Task 10's deferred change).

- [ ] **Step 4: Update all call sites of `ComposeMailViewModel.init`**

Search the codebase:

```
grep -rn "ComposeMailViewModel(" AppFeedback --include="*.swift"
```

Each call site (currently `ComposeMailView.setupViewModel`) must pass `senderAccountID:` — for now, use `store.defaultSender?.id ?? UUID()`. We'll plumb a real value through in Task 13.

- [ ] **Step 5: Run the tests**

Run: `zcode test --only AppFeedbackTests/ComposeMailViewModelTests`
Expected: PASS.

Run: `zcode test`
Expected: full suite PASS.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/ViewModels/ComposeMailViewModel.swift AppFeedbackTests/ComposeMailViewModelTests.swift AppFeedback/Views/Mail/ComposeMailView.swift
git commit -m "feat(mail): ComposeMailViewModel takes senderAccountID

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Reply-from resolution and "Reply from ▸" menu

**Files:**
- Modify: `AppFeedback/Views/Mail/MailThreadView.swift`
- Modify: `AppFeedback/Views/Mail/ComposeMailView.swift`

- [ ] **Step 1: Extend `ReplyTarget` with `senderAccountID`**

Edit `AppFeedback/Views/Mail/MailThreadView.swift`. Change:

```swift
struct ReplyTarget: Identifiable {
    let id = UUID()
    let recipient: String
    let subject: String
    let headers: MailMessageHeaders
    let senderAccountID: UUID
}
```

- [ ] **Step 2: Compute the default sender for this thread**

Inside `MailThreadView`, add a computed property:

```swift
    @Environment(MailAccountStore.self) private var accountStore

    private var resolvedSenderAccountID: UUID? {
        if let last = messages.last, let id = last.accountID, accountStore.account(id: id) != nil {
            return id
        }
        return accountStore.defaultSender?.id
    }
```

Update `beginReply` to accept an override:

```swift
    private func beginReply(senderAccountID: UUID? = nil) {
        guard let last = messages.last, let recipient = replyRecipient else { return }
        guard let chosen = senderAccountID ?? resolvedSenderAccountID else { return }
        let headers = MailMessageHeaders(
            messageID: last.messageID,
            inReplyTo: last.inReplyTo,
            references: last.referencesAsArray
        )
        replyTarget = ReplyTarget(
            recipient: recipient,
            subject: MailSubject.replyPrefixed(last.subject),
            headers: headers,
            senderAccountID: chosen
        )
    }
```

- [ ] **Step 3: Pass `senderAccountID` to `ComposeMailView`**

In the `.sheet(item: $replyTarget)` modifier, add:

```swift
            ComposeMailView(
                recipient: target.recipient,
                issue: issue,
                repoOwner: repoOwner,
                repoName: repoName,
                inReplyTo: target.headers,
                subjectOverride: target.subject,
                senderAccountID: target.senderAccountID
            )
```

In `ComposeMailView` (file: `AppFeedback/Views/Mail/ComposeMailView.swift`), add a stored property `let senderAccountID: UUID`. Pass it into `ComposeMailViewModel` in `setupViewModel()`:

```swift
        viewModel = ComposeMailViewModel(
            ...existing args...,
            senderAccountID: senderAccountID,
            ...
        )
```

For non-reply compose paths (issue list opening compose), the caller is `IssueListView`. Edit that call site to pass `senderAccountID: accountStore.defaultSender?.id ?? UUID()`.

- [ ] **Step 4: Add the "Reply from ▸" submenu on `ReplyBadgeButton`**

Locate `ReplyBadgeButton` (grep: `ReplyBadgeButton`). It's used as `ReplyBadgeButton(email:, color:, onReply:, onCopy:)`. Extend it to accept an optional list of "from" choices and an "on reply from" callback:

```swift
struct ReplyBadgeButton: View {
    let email: String
    let color: Color
    let onReply: () -> Void
    let onCopy: () -> Void
    var replyFromOptions: [ReplyFromOption] = []
    var onReplyFrom: ((UUID) -> Void)? = nil

    struct ReplyFromOption: Identifiable, Hashable {
        let id: UUID
        let address: String
    }

    var body: some View {
        // ...existing chrome around the button...
        .contextMenu {
            Button("Reply") { onReply() }
            if !replyFromOptions.isEmpty, let onReplyFrom {
                Menu("Reply from") {
                    ForEach(replyFromOptions) { opt in
                        Button(opt.address) { onReplyFrom(opt.id) }
                    }
                }
            }
            Button("Copy address") { onCopy() }
        }
    }
}
```

(Locate the actual file declaring `ReplyBadgeButton`; modify in place. Keep all existing styling.)

- [ ] **Step 5: Wire up the menu from `MailThreadView.replyButton`**

```swift
    @ViewBuilder
    private var replyButton: some View {
        if let recipient = replyRecipient {
            let options = accountStore.accounts
                .filter { !$0.smtpUsername.isEmpty }
                .map { ReplyBadgeButton.ReplyFromOption(id: $0.id, address: $0.smtpUsername) }
            ReplyBadgeButton(
                email: recipient,
                color: appColor,
                onReply: { beginReply() },
                onCopy: copyRecipient,
                replyFromOptions: options.count > 1 ? options : [],
                onReplyFrom: { id in beginReply(senderAccountID: id) }
            )
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
```

- [ ] **Step 6: Show the resolved FROM in `ComposeMailView`**

In `ComposeMailView.composeForm`, add a `fromRow` ABOVE `recipientRow`:

```swift
    private var fromRow: some View {
        HStack {
            Text("From:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(store.account(id: senderAccountID)?.smtpUsername ?? "—")
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
```

Insert `fromRow` and a `Divider()` immediately before `recipientRow` in the ScrollView's VStack.

- [ ] **Step 7: Verify build + run app manually**

Run: `zcode build`
Expected: builds.

Use the `zcode` skill (`zcode run`) to launch the app, configure at least two accounts, send a reply normally, then right-click the Reply badge in a thread and select "Reply from ▸ <other address>". Confirm the compose sheet shows the chosen FROM.

If you can't drive the UI right now, note that explicitly in the commit message and lean on the unit tests; an XCUITest is out of scope.

- [ ] **Step 8: Commit**

```bash
git add AppFeedback/Views/Mail/MailThreadView.swift AppFeedback/Views/Mail/ComposeMailView.swift
git commit -m "feat(mail): right-click reply lets user choose sender account

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(If you modified the file declaring `ReplyBadgeButton`, include it in `git add`.)

---

## Phase 7 — Settings UI

### Task 14: macOS Email settings — master/detail rewrite

**Files:**
- Create: `AppFeedback/Views/Settings/EmailAccountList.swift`
- Create: `AppFeedback/Views/Settings/EmailAccountEditor.swift`
- Create: `AppFeedback/Views/Settings/AddEmailAccountSheet.swift`
- Create: `AppFeedback/Views/Settings/MailDefaultsSection.swift`
- Modify: `AppFeedback/Views/Settings/EmailSettingsView.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

This is the biggest UI task. Plan it as four small builds + manual smoke tests rather than TDD (SwiftUI views aren't unit-tested in this project; the underlying view models / stores are.).

- [ ] **Step 1: Create `MailDefaultsSection`**

`AppFeedback/Views/Settings/MailDefaultsSection.swift`:

```swift
#if os(macOS)
import SwiftUI
import AppKit

struct MailDefaultsSection: View {
    @Environment(MailSettingsStore.self) private var settingsStore

    @State private var headerText: String = ""
    @State private var footerText: String = ""
    @State private var pollIntervalMinutes: Int = 5
    @State private var attachmentFolderDisplayPath: String = "Default (~/Downloads)"
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?

    @State private var copiedToken: String?

    var body: some View {
        Form {
            Section("Header") {
                TextEditor(text: $headerText)
                    .font(.body)
                    .frame(minHeight: 120)
            }
            Section("Footer") {
                TextEditor(text: $footerText)
                    .font(.body)
                    .frame(minHeight: 120)
            }
            Section("Attachments") {
                HStack {
                    Button("Attachments folder…") { pickAttachmentFolder() }
                    Text(attachmentFolderDisplayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Section("Fetching") {
                Stepper(
                    "Every \(pollIntervalMinutes) minute\(pollIntervalMinutes == 1 ? "" : "s")",
                    value: $pollIntervalMinutes,
                    in: 1...60
                )
                .onChange(of: pollIntervalMinutes) { _, _ in scheduleSave() }
            }
            Section("Placeholders") {
                placeholdersHint
            }
        }
        .formStyle(.grouped)
        .task { load() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
    }

    private func load() {
        headerText = MailTemplatePlainText.from(html: settingsStore.settings.templateHeaderHTML)
        footerText = MailTemplatePlainText.from(html: settingsStore.settings.templateFooterHTML)
        pollIntervalMinutes = max(1, min(60, settingsStore.settings.pollIntervalSeconds / 60))
        resolveDisplayPath()
        didLoad = true
    }

    private func scheduleSave() {
        guard didLoad else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            settingsStore.update { s in
                s.templateHeaderHTML = MailTemplatePlainText.toHTML(headerText)
                s.templateFooterHTML = MailTemplatePlainText.toHTML(footerText)
                s.pollIntervalSeconds = pollIntervalMinutes * 60
            }
        }
    }

    private func pickAttachmentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder to save downloaded attachments"
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                settingsStore.update { $0.attachmentFolderBookmark = bookmark }
                attachmentFolderDisplayPath = url.path
            }
        }
    }

    private func resolveDisplayPath() {
        guard let data = settingsStore.settings.attachmentFolderBookmark else {
            attachmentFolderDisplayPath = "Default (~/Downloads)"
            return
        }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            attachmentFolderDisplayPath = url.path
        } else {
            attachmentFolderDisplayPath = "Default (~/Downloads)"
        }
    }

    private var placeholdersHint: some View {
        // Copy-pasted from EmailSettingsView so the section is self-contained.
        VStack(alignment: .leading, spacing: 6) {
            Text("Drop these tokens into the header or footer — they'll be replaced when the email is sent. Click a token to copy it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Self.placeholderHints, id: \.token) { hint in
                    GridRow {
                        Button { copyToken(hint.token) } label: {
                            HStack(spacing: 4) {
                                Text(hint.token).font(.system(.caption, design: .monospaced))
                                Image(systemName: copiedToken == hint.token ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(hint.descriptionText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func copyToken(_ token: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)
        copiedToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedToken == token { copiedToken = nil }
        }
    }

    private struct PlaceholderHint { let token: String; let descriptionText: String }
    private static let placeholderHints: [PlaceholderHint] = [
        .init(token: "{{sender_name}}",     descriptionText: "Your sender display name"),
        .init(token: "{{sender_email}}",    descriptionText: "Your from address"),
        .init(token: "{{recipient_email}}", descriptionText: "The recipient's email"),
        .init(token: "{{app_name}}",        descriptionText: "App the issue belongs to"),
        .init(token: "{{issue_title}}",     descriptionText: "Title of the issue"),
        .init(token: "{{issue_url}}",       descriptionText: "Link to the issue"),
        .init(token: "{{date}}",            descriptionText: "Current date and time")
    ]
}
#endif
```

- [ ] **Step 2: Create `EmailAccountEditor`**

`AppFeedback/Views/Settings/EmailAccountEditor.swift`:

```swift
#if os(macOS)
import SwiftUI
import AppKit

struct EmailAccountEditor: View {
    let accountID: UUID

    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailSyncCoordinatorRegistry?.self) private var registry: MailSyncCoordinatorRegistry?

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    @State private var imapHost: String = ""
    @State private var imapPort: String = "993"
    @State private var imapUsername: String = ""
    @State private var imapPassword: String = ""
    @State private var separateIMAPCreds: Bool = false

    @State private var pollingEnabled: Bool = true
    @State private var showAdvanced: Bool = false
    @State private var saveStatus: String?
    @State private var testStatus: String?
    @State private var showRemoveConfirm: Bool = false
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?

    private var account: MailAccount? { store.account(id: accountID) }
    private var isDefault: Bool { account?.isDefaultSender ?? false }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in applyPresetDefaults(new); scheduleSave() }
            }
            Section("Account") {
                TextField("Email address", text: $username)
                HStack {
                    SecureField("Password", text: $password)
                    pasteButton { password = preset.sanitize(password: $0) }
                }
                if preset == .gmail {
                    HStack(spacing: 6) {
                        Text("Gmail requires a 16-character app password (not your account password). 2-Step Verification must be on.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Get app password") { openGmailAppPasswords() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                TextField("Sender display name", text: $senderName)
                Toggle("Auto-fetch replies", isOn: $pollingEnabled)
                    .onChange(of: pollingEnabled) { _, _ in scheduleSave() }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    LabeledContent("SMTP host") { TextField("", text: $host).disabled(preset != .custom) }
                    LabeledContent("SMTP port") { TextField("", text: $port).disabled(preset != .custom) }
                    LabeledContent("IMAP host") { TextField("", text: $imapHost).disabled(preset != .custom) }
                    LabeledContent("IMAP port") { TextField("", text: $imapPort).disabled(preset != .custom) }
                    Toggle("Use a different IMAP login", isOn: $separateIMAPCreds)
                    if separateIMAPCreds {
                        TextField("IMAP username", text: $imapUsername)
                        HStack {
                            SecureField("IMAP password", text: $imapPassword)
                            pasteButton { imapPassword = preset.sanitize(password: $0) }
                        }
                    }
                }
            }
            Section("Tools") {
                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled(username.isEmpty || host.isEmpty || password.isEmpty)
                    if !isDefault {
                        Button("Set as default") {
                            if let acc = account { store.setDefaultSender(acc) }
                        }
                    }
                    Button("Refresh now") {
                        Task { await registry?.coordinator(for: accountID)?.pollNow() }
                    }
                    .disabled(registry?.coordinator(for: accountID) == nil)
                    Spacer()
                    Button("Remove account…", role: .destructive) { showRemoveConfirm = true }
                    if let testStatus { Text(testStatus).foregroundStyle(.secondary) }
                    if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: accountID) { await load() }
        .onChange(of: host)     { _, _ in scheduleSave() }
        .onChange(of: port)     { _, _ in scheduleSave() }
        .onChange(of: username) { _, _ in scheduleSave() }
        .onChange(of: password) { _, new in
            let cleaned = preset.sanitize(password: new)
            if cleaned != new { password = cleaned } else { scheduleSave() }
        }
        .onChange(of: senderName) { _, _ in scheduleSave() }
        .onChange(of: imapHost) { _, _ in scheduleSave() }
        .onChange(of: imapPort) { _, _ in scheduleSave() }
        .onChange(of: imapUsername) { _, _ in scheduleSave() }
        .onChange(of: imapPassword) { _, new in
            let cleaned = preset.sanitize(password: new)
            if cleaned != new { imapPassword = cleaned } else { scheduleSave() }
        }
        .alert("Remove this account?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { Task { await removeAccount() } }
        } message: {
            Text("Mail for this account stays in your inbox/sent folders. The credentials and per-account state are removed from this device.")
        }
    }

    // ...load/scheduleSave/save/removeAccount/testConnection/pasteButton/applyPresetDefaults/openGmailAppPasswords:
    //    copy the corresponding helpers from EmailSettingsView (the original file) but
    //    use store.update(id: accountID) { … } / store.delete / per-account Keychain methods.
}
#endif
```

(Fill in `load`, `scheduleSave`, `save`, `removeAccount`, `testConnection`, `pasteButton`, `applyPresetDefaults`, `openGmailAppPasswords` by adapting from the original `EmailSettingsView` — but everywhere it used `store.upsert` / `KeychainService.saveSMTPPassword(_:)` / `KeychainService.loadSMTPPassword()`, replace with `store.update(id: accountID, ...)` / `KeychainService.saveSMTPPassword(_, for: accountID)` / `KeychainService.loadSMTPPassword(for: accountID)`. Reset/save status text stays the same.)

- [ ] **Step 3: Create `AddEmailAccountSheet`**

`AppFeedback/Views/Settings/AddEmailAccountSheet.swift`:

```swift
#if os(macOS)
import SwiftUI

struct AddEmailAccountSheet: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""
    @State private var status: String?

    var onCreated: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add email account").font(.title3).bold()
            Form {
                Picker("Provider", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Email address", text: $email)
                SecureField("Password", text: $password)
                TextField("Sender display name", text: $senderName)
            }
            .formStyle(.grouped)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { Task { await saveAndDismiss() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func saveAndDismiss() async {
        let smtpDefaults = SMTPCredentials.defaults(for: preset)
        let imapDefaults = MailAccountMigration.imapDefaults(for: preset)
        let acc = store.add { a in
            a.presetRaw = preset.rawValue
            a.smtpHost = smtpDefaults.host
            a.smtpPort = smtpDefaults.port
            a.smtpUsername = email
            a.senderName = senderName
            a.imapHost = imapDefaults.host
            a.imapPort = imapDefaults.port
            a.imapUsername = email
        }
        _ = await KeychainService.saveSMTPPassword(password, for: acc.id)
        _ = await KeychainService.saveIMAPPassword(password, for: acc.id)
        onCreated(acc.id)
        dismiss()
    }
}
#endif
```

- [ ] **Step 4: Create `EmailAccountList`**

`AppFeedback/Views/Settings/EmailAccountList.swift`:

```swift
#if os(macOS)
import SwiftUI

struct EmailAccountList: View {
    @Environment(MailAccountStore.self) private var store
    @Binding var selection: UUID?
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.accounts, id: \.id) { acc in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(acc.smtpUsername.isEmpty ? "New account" : acc.smtpUsername)
                            Text(acc.preset.displayName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if acc.isDefaultSender {
                            Text("Default").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                    .tag(acc.id as UUID?)
                }
            }
            Divider()
            Button { showAddSheet = true } label: {
                Label("Add account", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 220)
        .sheet(isPresented: $showAddSheet) {
            AddEmailAccountSheet { newID in selection = newID }
        }
    }
}
#endif
```

- [ ] **Step 5: Rewrite `EmailSettingsView` as the container**

Replace the body of `AppFeedback/Views/Settings/EmailSettingsView.swift` with:

```swift
#if os(macOS)
import SwiftUI

struct EmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                EmailAccountList(selection: $selection)
                if let id = selectedID {
                    EmailAccountEditor(accountID: id)
                } else {
                    ContentUnavailableView("No account selected",
                                           systemImage: "envelope",
                                           description: Text("Add an account to start sending and receiving."))
                }
            }
            .frame(minHeight: 320)
            Divider()
            MailDefaultsSection()
        }
        .onAppear { selection = selection ?? store.defaultSender?.id ?? store.accounts.first?.id }
    }

    private var selectedID: UUID? {
        if let s = selection, store.account(id: s) != nil { return s }
        return store.accounts.first?.id
    }
}
#endif
```

Delete every old helper that's now duplicated in `EmailAccountEditor` / `MailDefaultsSection` / `AddEmailAccountSheet`. The file should be small (under 50 lines).

- [ ] **Step 6: Wire `MailSettingsStore` and `MailSyncCoordinatorRegistry` into `Settings`**

In `AppFeedback/App/AppFeedbackApp.swift`, both the macOS `Settings { ... }` scene and the iOS `RootView` injection chain must now include `.environment(mailSettingsStore)` and `.environment(coordinatorRegistry)` (the latter as `MailSyncCoordinatorRegistry?`).

Note: there's no SwiftUI `Environment` value for `MailSyncCoordinatorRegistry?` by default. Define a key:

```swift
private struct MailSyncCoordinatorRegistryKey: EnvironmentKey {
    static let defaultValue: MailSyncCoordinatorRegistry? = nil
}

extension EnvironmentValues {
    var mailSyncCoordinatorRegistry: MailSyncCoordinatorRegistry? {
        get { self[MailSyncCoordinatorRegistryKey.self] }
        set { self[MailSyncCoordinatorRegistryKey.self] = newValue }
    }
}
```

Or, simpler, treat `MailSyncCoordinatorRegistry` as `@Observable` and inject it directly: `.environment(coordinatorRegistry)`. (Pick whichever matches the codebase's existing pattern. The other holders in this app use `.environment(...)` on `@Observable` reference types, so prefer the `@Observable` path; have `MailSyncCoordinatorRegistry` be `@Observable` already from Task 11.)

`EmailAccountEditor` reads it via `@Environment(MailSyncCoordinatorRegistry.self) private var registry`. If the value can legitimately be `nil` on builds without SwiftMail, fall back to `.environment(MailSyncCoordinatorRegistry?.none)` — but cleaner: build a no-op `MailSyncCoordinatorRegistry.empty()` whose `coordinator(for:)` always returns `nil`. Update the registry to support that.

- [ ] **Step 7: Build and smoke test**

Run: `zcode build`
Expected: builds.

Run: `zcode run` (or via Xcode) and confirm:

- The Email settings tab now shows an account list + per-account editor + a "Mail templates & defaults" section below.
- Adding an account works, the new row appears, password is saved.
- Removing an account stops its coordinator and clears Keychain.
- Setting another account as default flips the badge.
- Pre-existing single-account users see their account in the list with "Default" already set.

- [ ] **Step 8: Commit**

```bash
git add AppFeedback/Views/Settings/EmailAccountList.swift AppFeedback/Views/Settings/EmailAccountEditor.swift AppFeedback/Views/Settings/AddEmailAccountSheet.swift AppFeedback/Views/Settings/MailDefaultsSection.swift AppFeedback/Views/Settings/EmailSettingsView.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(mail): master/detail Email settings on macOS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: iOS Email settings

**Files:**
- Create: `AppFeedback/Views/Settings/IOSEmailAccountList.swift`
- Create: `AppFeedback/Views/Settings/IOSEmailAccountEditor.swift`
- Create: `AppFeedback/Views/Settings/IOSMailDefaultsView.swift`
- Modify: `AppFeedback/Views/Settings/IOSEmailSettingsView.swift`

- [ ] **Step 1: Implement the three iOS views**

For each, mirror the macOS view but use `Form` + `NavigationLink` + `.navigationTitle("...")` for the iOS look. `IOSEmailAccountList` is a `Form` with one row per account (`NavigationLink` to `IOSEmailAccountEditor(accountID: ...)`) plus a row "+ Add account" (presenting `AddEmailAccountSheet` — that sheet is `os(macOS)`-only; create an iOS twin by copying it under `#if os(iOS)`).

Same data flow as macOS: read/write via `MailAccountStore` and `MailSettingsStore`; password I/O via per-account Keychain methods.

Reuse the existing `IOSEmailSettingsView.swift` helpers — but the file becomes the top-level entry point:

```swift
#if os(iOS)
struct IOSEmailSettingsView: View {
    var body: some View {
        NavigationStack {
            IOSEmailAccountList()
        }
    }
}
#endif
```

- [ ] **Step 2: Build for iOS**

Use `zcode build` with the iOS scheme/destination (the zcode skill exposes scheme/destination selection — use the iOS sim destination).

Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Settings/IOSEmailAccountList.swift AppFeedback/Views/Settings/IOSEmailAccountEditor.swift AppFeedback/Views/Settings/IOSMailDefaultsView.swift AppFeedback/Views/Settings/IOSEmailSettingsView.swift
git commit -m "feat(mail): iOS Email settings with account list and shared defaults

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 8 — Wire shared settings + cleanup

### Task 16: Compose flow reads templates from `MailSettings`; attachment downloader reads folder from `MailSettings`

**Files:**
- Modify: `AppFeedback/ViewModels/ComposeMailViewModel.swift`
- Modify: `AppFeedback/Views/Mail/ComposeMailView.swift`
- Modify: `AppFeedback/Services/Mail/AttachmentDownloader.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: ComposeMailViewModel: replace template source**

Change `ComposeMailViewModel.template` from reading `store.account?.templateHeaderHTML` to a new dependency on `MailSettingsStore`. Add `private let settingsStore: MailSettingsStore` and an init parameter. Update `currentTemplate` references throughout.

```swift
    var template: MailTemplate {
        MailTemplate(
            headerHTML: settingsStore.settings.templateHeaderHTML,
            footerHTML: settingsStore.settings.templateFooterHTML
        )
    }
```

Update the test fixtures and call sites (just `ComposeMailView.setupViewModel()` and tests) to pass `settingsStore`.

- [ ] **Step 2: ComposeMailView: refresh previews from settingsStore**

In `ComposeMailView`, replace:

```swift
.onChange(of: store.account?.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
.onChange(of: store.account?.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }
```

with the settings-store equivalents (inject `@Environment(MailSettingsStore.self) private var settingsStore` and observe `settingsStore.settings.templateHeaderHTML` / `templateFooterHTML`). Update `currentTemplate` to read from `settingsStore.settings`.

- [ ] **Step 3: AttachmentDownloader: read folder from settings**

Open `AppFeedback/Services/Mail/AttachmentDownloader.swift` and find where it consults `MailAccount.attachmentFolderBookmark`. Replace those reads with a `MailSettingsStore` dependency. Add the store as an init parameter; in `AppFeedbackApp.init` pass `mailSettingsStoreLocal` through to `AttachmentDownloader`.

- [ ] **Step 4: Run all tests**

Run: `zcode test`
Expected: full suite PASS. Existing `MailTemplate`-using tests may need their fixtures updated to seed the new `MailSettingsStore` instead of `MailAccount` template fields.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/ViewModels/ComposeMailViewModel.swift AppFeedback/Views/Mail/ComposeMailView.swift AppFeedback/Services/Mail/AttachmentDownloader.swift AppFeedback/App/AppFeedbackApp.swift AppFeedbackTests/ComposeMailViewModelTests.swift
git commit -m "refactor(mail): templates and attachments folder live in MailSettings

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Remove transitional shims

**Files:**
- Modify: `AppFeedback/Services/Mail/MailAccountStore.swift`
- Modify: `AppFeedback/Services/Mail/MailAccountMigration.swift`
- Modify: `AppFeedback/Services/KeychainService.swift`
- Delete: `AppFeedback/Services/Mail/MailSyncCoordinatorHolder.swift` (if extracted; if it still lives inside `MailSyncCoordinator.swift`, delete that struct only)
- Modify: `AppFeedback/App/AppFeedbackApp.swift`
- Modify: any remaining callers of `store.account`, `store.upsert`, `store.deleteAccount`
- Modify: legacy keychain `loadSMTPPassword()` / `saveSMTPPassword(_:)` / `loadIMAPPassword*()` / delete equivalents

- [ ] **Step 1: Search for remaining shim users**

```
grep -rn "store.account\b\|accountStore.account\b\|store.upsert\|store.deleteAccount\|MailSyncCoordinatorHolder\|loadSMTPPassword()\|loadIMAPPassword()" AppFeedback AppFeedbackTests --include="*.swift"
```

For each match:

- `store.account` → `store.defaultSender` (read path) or `store.account(id: …)` (when the caller has a specific UUID).
- `store.upsert { … }` → `store.update(id: someID) { … }` or `store.add { … }`.
- `store.deleteAccount()` → `store.delete(someAccount)`.
- `MailSyncCoordinatorHolder` env reads → `MailSyncCoordinatorRegistry` env reads.
- `KeychainService.loadSMTPPassword()` (no-arg) → caller now has an account UUID; use the per-account method.
- Legacy fixed-slot save methods → delete; only the legacy *delete* method survives, used by `MailAccountMigration.purgeLegacyKeychain`.

The migration's `purgeLegacyKeychain` calls `deleteSMTPPassword()` / `deleteIMAPPassword()` with no argument — rename those legacy entry points to `deleteLegacySMTPPassword()` / `deleteLegacyIMAPPassword()` to make their purpose explicit and keep them as the sole survivors.

- [ ] **Step 2: Remove the compatibility shim from `MailAccountStore`**

Delete the `// MARK: - Transitional single-account compatibility` extension and the legacy save/load methods from `KeychainService`. Keep only the legacy-delete methods (renamed).

- [ ] **Step 3: Remove `MailSyncCoordinatorHolder`**

Delete the `MailSyncCoordinatorHolder` struct entirely. Update `AppFeedbackApp` to inject `MailSyncCoordinatorRegistry` directly.

- [ ] **Step 4: Verify nothing left is referencing the old names**

Run the same grep as Step 1. Expected: zero matches.

- [ ] **Step 5: Build + tests**

Run: `zcode test`
Expected: full suite PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore(mail): remove single-account transitional shims

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 18: Schema cleanup — remove deprecated fields from MailAccount (optional, gated)

**Files:**
- Modify: `AppFeedback/Models/MailAccount.swift`

This is a CloudKit schema migration. Only do it if `MailSettings` round-tripping has been verified on a real iCloud account.

- [ ] **Step 1: Verify the spec's open question is closed**

Confirm with the user whether to remove the unused `templateHeaderHTML`, `templateFooterHTML`, `attachmentFolderBookmark`, and `pollIntervalSeconds` properties from `MailAccount`. The risk: lightweight SwiftData migrations across CloudKit can fail on devices that haven't completed the v2 migration.

- [ ] **Step 2: If approved, remove the fields**

Delete the four properties and corresponding init parameters from `MailAccount.swift`. Remove the now-dead writes in `MailAccountMigration.runV2IfNeeded` that clear those fields.

- [ ] **Step 3: Build + tests**

Run: `zcode test`
Expected: full suite PASS.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Models/MailAccount.swift AppFeedback/Services/Mail/MailAccountMigration.swift
git commit -m "chore(mail): drop deprecated shared fields from MailAccount

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Plan self-review

**Spec coverage check:**

| Spec section                                | Covered by              |
|---------------------------------------------|-------------------------|
| `MailAccount` adds `isDefaultSender`         | Task 2                  |
| New `MailSettings` singleton                 | Tasks 3, 4              |
| `MailMessage` / `MailThread` get `accountID` | Task 1                  |
| Per-account Keychain                         | Task 5                  |
| `MailAccountStore` multi-account API         | Task 6                  |
| `MailSyncCoordinatorRegistry`                | Task 11                 |
| Coordinator + IMAP provider per-account      | Tasks 8, 9              |
| `accountID` stamped on rows                  | Task 10                 |
| Compose `senderAccountID`                    | Task 12                 |
| Reply-from menu and resolution               | Task 13                 |
| macOS master/detail UI                       | Task 14                 |
| iOS analogue                                 | Task 15                 |
| Mail defaults section                        | Tasks 14 (macOS), 15 (iOS), 16 |
| Migration v2                                 | Task 7                  |
| Legacy Keychain purge on every launch        | Task 7 + Task 17        |
| Tests                                        | Tasks 4, 5, 6, 7, 11, 12 |
| Schema cleanup (open item from spec risks)   | Task 18                 |

No spec sections without a task.

**Type consistency check:** `senderAccountID`, `accountID`, `setDefaultSender`, `defaultSender`, `account(id:)`, `add`, `update(id:_:)`, `delete(_:)`, `MailSyncCoordinatorRegistry`, `MailSettingsStore`, `runV2IfNeeded`, `purgeLegacyKeychain`, `backfillAccountIDIfMissing`, `ReplyTarget.senderAccountID`, `ReplyBadgeButton.ReplyFromOption` — names are used consistently across tasks.

**Placeholder scan:** No "TBD"/"TODO" in concrete steps. One deliberate Step in Task 18 is gated on user approval (called out explicitly). Task 14 Step 2 says "fill in the helpers from the original `EmailSettingsView`" with an explicit transformation rule (each `store.upsert` → `store.update(id: accountID, …)`, each fixed-slot Keychain call → per-UUID); the engineer can copy mechanically.
