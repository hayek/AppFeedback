# Persistent GitHub Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist GitHub sign-in across Add-Repository sessions and devices by introducing connected GitHub accounts (multi-account), so adding a repo becomes "pick from a list grouped by account" instead of a fresh device-flow login every time, with per-account disconnect/reconnect.

**Architecture:** A new `GitHubAccount` SwiftData `@Model` (CloudKit-synced, mirroring `MailAccount`) holds account identity; the OAuth token lives in iCloud Keychain keyed by account UUID (mirroring the existing SMTP/IMAP per-account slots). A `GitHubAccountStore` (`@MainActor @Observable`, mirroring `MailAccountStore`) owns CRUD + CloudKit dedup. `GitHubLoginView` is trimmed to a connect-account-only device flow; the Add Repository sheet gains an `AccountRepoPicker` that lists each account's repos live (one collapsible section per account) and reuses the existing per-repo save path so downstream services are untouched.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData + NSPersistentCloudKitContainer, Security framework (Keychain), XCTest, xcodegen, zcode/xcodebuild.

**Build/test conventions (read once):**
- This is an **xcodegen** project. After creating any new `.swift` file under `AppFeedback/` or `AppFeedbackTests/`, regenerate the project from the repo root: `xcodegen generate`.
- Build/run/test via the **zcode skill** (scheme `AppFeedback_macOS`; test target `AppFeedbackTests_macOS`).
- Ground-truth test command (project memory: zcode's test summary can mask trap crashes — prefer this if a crash is suspected):
  ```bash
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
    -only-testing:AppFeedbackTests_macOS
  ```
  Scope to one suite while iterating, e.g. `-only-testing:AppFeedbackTests_macOS/GitHubAccountStoreTests`.
- Commit message trailer (every commit): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Branch first — this plan runs on a feature branch off `main` (the repo has unrelated WIP in the working tree; do not stage it).

---

## Task 0: Create the feature branch and commit the spec

**Files:**
- Existing: `docs/superpowers/specs/2026-06-03-persistent-github-accounts-design.md` (already written)

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feat/persistent-github-accounts
```

- [ ] **Step 2: Commit only the spec (leave unrelated WIP unstaged)**

```bash
git add docs/superpowers/specs/2026-06-03-persistent-github-accounts-design.md \
        docs/superpowers/plans/2026-06-03-persistent-github-accounts.md
git commit -m "docs: spec + plan for persistent GitHub accounts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 1: Keychain — per-account GitHub token slots

**Files:**
- Modify: `AppFeedback/Services/KeychainService.swift` (add a new `MARK: - GitHub account tokens` section after the per-account SMTP/IMAP helpers, before `MARK: - Shared helpers` at line 181)
- Test: `AppFeedbackTests/KeychainServicePerAccountTests.swift` (append cases)

- [ ] **Step 1: Write the failing tests** — append to `KeychainServicePerAccountTests.swift` (inside the existing `final class KeychainServicePerAccountTests`):

```swift
    func test_gitHubTokenRoundTripIsAccountScoped() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteGitHubToken(for: a) }
            Task { await KeychainService.deleteGitHubToken(for: b) }
        }
        _ = await KeychainService.saveGitHubToken("tok-a", for: a)
        _ = await KeychainService.saveGitHubToken("tok-b", for: b)
        let loadedA = await KeychainService.loadGitHubToken(for: a)
        let loadedB = await KeychainService.loadGitHubToken(for: b)
        XCTAssertEqual(loadedA, "tok-a")
        XCTAssertEqual(loadedB, "tok-b")
        XCTAssertEqual(KeychainService.loadGitHubTokenSync(for: a), "tok-a")
    }

    func test_deleteGitHubTokenLeavesOthers() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteGitHubToken(for: a) }
            Task { await KeychainService.deleteGitHubToken(for: b) }
        }
        _ = await KeychainService.saveGitHubToken("a", for: a)
        _ = await KeychainService.saveGitHubToken("b", for: b)
        await KeychainService.deleteGitHubToken(for: a)
        let afterDeleteA = await KeychainService.loadGitHubToken(for: a)
        let afterDeleteB = await KeychainService.loadGitHubToken(for: b)
        XCTAssertNil(afterDeleteA)
        XCTAssertEqual(afterDeleteB, "b")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/KeychainServicePerAccountTests
```
Expected: FAIL — `saveGitHubToken`/`loadGitHubToken`/`loadGitHubTokenSync`/`deleteGitHubToken` are not members of `KeychainService` (compile error).

- [ ] **Step 3: Implement the methods** — in `KeychainService.swift`, insert immediately before `// MARK: - Shared helpers` (line 181):

```swift
    // MARK: - GitHub account tokens

    private static func gitHubTokenAccountKey(for accountID: UUID) -> String {
        "github.token.\(accountID.uuidString)"
    }

    @discardableResult
    static func saveGitHubToken(_ token: String, for accountID: UUID) async -> Bool {
        await saveSynchronizablePassword(token, account: gitHubTokenAccountKey(for: accountID))
    }

    static func loadGitHubToken(for accountID: UUID) async -> String? {
        await loadSynchronizablePassword(account: gitHubTokenAccountKey(for: accountID))
    }

    /// Synchronous variant for `@Sendable () -> String?` / non-async callers,
    /// parallelling `loadSync(for:)`.
    static func loadGitHubTokenSync(for accountID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        gitHubTokenAccountKey(for: accountID),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteGitHubToken(for accountID: UUID) async {
        await deleteSynchronizablePassword(account: gitHubTokenAccountKey(for: accountID))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/KeychainServicePerAccountTests
```
Expected: PASS (all KeychainServicePerAccountTests green).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/KeychainService.swift AppFeedbackTests/KeychainServicePerAccountTests.swift
git commit -m "feat(keychain): per-account GitHub token slots

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Auth service — `GitHubUser` model + `fetchCurrentUser`

**Files:**
- Modify: `AppFeedback/Models/GitHubAuthModels.swift` (add `GitHubUser`)
- Modify: `AppFeedback/Services/GitHubAuthService.swift` (add `fetchCurrentUser`)
- Test: `AppFeedbackTests/GitHubAuthTests.swift` (append cases to `GitHubAuthModelsTests` and `GitHubAuthServiceTests`)

- [ ] **Step 1: Write the failing tests**

Append to `GitHubAuthModelsTests`:

```swift
    func test_gitHubUser_decodesFromGitHubJSON() throws {
        let json = """
        { "login": "octocat", "avatar_url": "https://example.com/a.png" }
        """.data(using: .utf8)!
        let user = try JSONDecoder().decode(GitHubUser.self, from: json)
        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.avatarURL, "https://example.com/a.png")
    }
```

Append to `GitHubAuthServiceTests`:

```swift
    // MARK: fetchCurrentUser

    func test_fetchCurrentUser_decodesLoginAndAvatar() async throws {
        let json = """
        { "login": "octocat", "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4", "id": 1 }
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in (self.ok(req), json) }
        let service = GitHubAuthService(session: .mock)
        let user = try await service.fetchCurrentUser(token: "tok")
        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.avatarURL, "https://avatars.githubusercontent.com/u/1?v=4")
    }

    func test_fetchCurrentUser_throwsOnUnauthorized() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.fetchCurrentUser(token: "tok")
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.apiError(let code) {
            XCTAssertEqual(code, 401)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/GitHubAuthModelsTests \
  -only-testing:AppFeedbackTests_macOS/GitHubAuthServiceTests
```
Expected: FAIL — `GitHubUser` is undefined and `fetchCurrentUser` is not a member of `GitHubAuthService` (compile errors).

- [ ] **Step 3a: Add `GitHubUser`** — append to `AppFeedback/Models/GitHubAuthModels.swift`:

```swift

struct GitHubUser: Decodable, Sendable {
    let login: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}
```

- [ ] **Step 3b: Add `fetchCurrentUser`** — in `AppFeedback/Services/GitHubAuthService.swift`, insert after `listRepos(token:)` (after line 111, before the closing brace of the actor):

```swift

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)",                 forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AuthError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(GitHubUser.self, from: data)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/GitHubAuthModelsTests \
  -only-testing:AppFeedbackTests_macOS/GitHubAuthServiceTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/GitHubAuthModels.swift AppFeedback/Services/GitHubAuthService.swift AppFeedbackTests/GitHubAuthTests.swift
git commit -m "feat(github): fetchCurrentUser + GitHubUser model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `GitHubAccount` model + CloudKit schema registration

**Files:**
- Create: `AppFeedback/Models/GitHubAccount.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (register in 3 places: test container `for:` list ~lines 76-82, `cloudSchema` line 86, production container `for:` list ~lines 95-101)

- [ ] **Step 1: Create the model** — `AppFeedback/Models/GitHubAccount.swift`:

```swift
import Foundation
import SwiftData

@Model
final class GitHubAccount {
    var id: UUID = UUID()
    /// GitHub username (login), e.g. "octocat". Case-insensitive identity key.
    var login: String = ""
    /// owner.avatar_url from GET /user, for the section header. Optional for CloudKit.
    var avatarURL: String? = nil
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        login: String = "",
        avatarURL: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 2: Register in the test container** — in `AppFeedbackApp.swift`, the `ModelContainer(for:...)` at lines 75-84, add `GitHubAccount.self,` to the type list (e.g. right after `MailAccount.self,` on line 76):

```swift
                container = try ModelContainer(
                    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        GitHubAccount.self,
                        MailSettings.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self, IssueSummaryCache.self,
                        ProjectVersion.self, SentReleaseNotification.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                    configurations: testConfig
                )
```

- [ ] **Step 3: Register in `cloudSchema`** — modify line 86 to include `GitHubAccount.self`:

```swift
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self])
```

- [ ] **Step 4: Register in the production container** — in the `ModelContainer(for:...)` at lines 94-103, add `GitHubAccount.self,` after `MailAccount.self,` (line 95):

```swift
                container = try ModelContainer(
                    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        GitHubAccount.self,
                        MailSettings.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self, IssueSummaryCache.self,
                        ProjectVersion.self, SentReleaseNotification.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                    configurations: cloudConfig, localConfig
                )
```

- [ ] **Step 5: Regenerate the project and build**

```bash
xcodegen generate
```
Then build via the zcode skill (scheme `AppFeedback_macOS`), or:
```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED. (`GitHubAccount.swift` is auto-included by the globbed `sources: AppFeedback` path after `xcodegen generate`.)

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Models/GitHubAccount.swift AppFeedback/App/AppFeedbackApp.swift AppFeedback.xcodeproj
git commit -m "feat(github): GitHubAccount model registered in CloudKit schema

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `GitHubAccountStore`

**Files:**
- Create: `AppFeedback/Services/GitHubAccountStore.swift`
- Test: `AppFeedbackTests/GitHubAccountStoreTests.swift`

- [ ] **Step 1: Write the failing tests** — `AppFeedbackTests/GitHubAccountStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class GitHubAccountStoreTests: XCTestCase {

    private func makeStore() throws -> GitHubAccountStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: GitHubAccount.self, configurations: config)
        return GitHubAccountStore(context: ModelContext(container))
    }

    func test_emptyOnInit() throws {
        let store = try makeStore()
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func test_addInsertsRowAndPersistsToken() async throws {
        let store = try makeStore()
        let acc = await store.add(login: "octocat", avatarURL: "https://a/x.png", token: "gho_1")
        defer { Task { await KeychainService.deleteGitHubToken(for: acc.id) } }
        XCTAssertEqual(store.accounts.map(\.login), ["octocat"])
        XCTAssertEqual(store.token(for: acc), "gho_1")
    }

    func test_addExistingLoginUpsertsAndRefreshesToken() async throws {
        let store = try makeStore()
        let first = await store.add(login: "octocat", avatarURL: nil, token: "gho_old")
        let second = await store.add(login: "OctoCat", avatarURL: "https://a/y.png", token: "gho_new")
        defer { Task { await KeychainService.deleteGitHubToken(for: first.id) } }
        XCTAssertEqual(store.accounts.count, 1, "case-insensitive login should upsert, not duplicate")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.token(for: second), "gho_new")
        XCTAssertEqual(store.accounts.first?.avatarURL, "https://a/y.png")
    }

    func test_deleteWithCredentialsRemovesRowAndToken() async throws {
        let store = try makeStore()
        let acc = await store.add(login: "octocat", avatarURL: nil, token: "gho_1")
        await store.deleteWithCredentials(acc)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(KeychainService.loadGitHubTokenSync(for: acc.id))
    }

    func test_coalesceCollapsesDuplicateLoginsFromSync() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: GitHubAccount.self, configurations: config)
        let context = ModelContext(container)
        // Two rows, same login, as if synced from two devices. Oldest wins.
        let older = GitHubAccount(login: "octocat", createdAt: Date(timeIntervalSince1970: 1))
        let newer = GitHubAccount(login: "octocat", createdAt: Date(timeIntervalSince1970: 2))
        context.insert(older)
        context.insert(newer)
        try context.save()
        let store = GitHubAccountStore(context: context)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.id, older.id)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/GitHubAccountStoreTests
```
Expected: FAIL — `GitHubAccountStore` is undefined (compile error).

- [ ] **Step 3: Implement the store** — `AppFeedback/Services/GitHubAccountStore.swift`:

```swift
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class GitHubAccountStore {
    private(set) var accounts: [GitHubAccount] = []

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.accounts = Self.fetch(in: context)
    }

    func account(id: UUID) -> GitHubAccount? {
        accounts.first(where: { $0.id == id })
    }

    /// The OAuth token for this account, from iCloud Keychain. Synchronous so views can
    /// read it inline when prefilling the Add form.
    func token(for account: GitHubAccount) -> String? {
        KeychainService.loadGitHubTokenSync(for: account.id)
    }

    /// Inserts a new account or, if one with the same login (case-insensitive) already
    /// exists, refreshes its avatar + token in place. This is also the Reconnect path.
    @discardableResult
    func add(login: String, avatarURL: String?, token: String) async -> GitHubAccount {
        let trimmed = login.trimmingCharacters(in: .whitespaces)
        let target: GitHubAccount
        if let existing = accounts.first(where: { $0.login.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            existing.avatarURL = avatarURL
            target = existing
        } else {
            let new = GitHubAccount(login: trimmed, avatarURL: avatarURL)
            context.insert(new)
            target = new
        }
        save()
        _ = await KeychainService.saveGitHubToken(token, for: target.id)
        reload()
        return account(id: target.id) ?? target
    }

    /// Removes the account row and its Keychain token. Already-added repos keep their own
    /// per-repo token copies and are unaffected.
    func deleteWithCredentials(_ account: GitHubAccount) async {
        let id = account.id
        await KeychainService.deleteGitHubToken(for: id)
        context.delete(account)
        save()
        reload()
    }

    func reload() {
        accounts = Self.fetch(in: context)
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("GitHubAccountStore save failed: \(error)")
        }
    }

    private static func fetch(in context: ModelContext) -> [GitHubAccount] {
        let descriptor = FetchDescriptor<GitHubAccount>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return coalesce(rows, in: context)
    }

    /// Collapses duplicate rows produced by CloudKit syncing the same account across
    /// devices. Duplicates share a login (case-insensitive); the oldest wins. Empty-login
    /// rows (aborted connects) are dropped when any non-empty row exists. Idempotent.
    private static func coalesce(_ rows: [GitHubAccount], in context: ModelContext) -> [GitHubAccount] {
        var winners: [GitHubAccount] = []
        var winnersByLogin: [String: GitHubAccount] = [:]
        var toDelete: [GitHubAccount] = []

        let hasAnyNonEmpty = rows.contains { !$0.login.trimmingCharacters(in: .whitespaces).isEmpty }

        for row in rows {
            let trimmed = row.login.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if hasAnyNonEmpty { toDelete.append(row) } else { winners.append(row) }
                continue
            }
            let key = trimmed.lowercased()
            if winnersByLogin[key] == nil {
                winnersByLogin[key] = row
                winners.append(row)
            } else {
                toDelete.append(row)
            }
        }

        guard !toDelete.isEmpty else { return winners }
        for row in toDelete { context.delete(row) }
        try? context.save()
        return winners
    }
}
```

- [ ] **Step 4: Regenerate, then run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/GitHubAccountStoreTests
```
Expected: PASS (5 tests). Note: `add`/`delete` tests touch the real synchronizable Keychain and clean up via `defer`, matching `KeychainServicePerAccountTests`.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/GitHubAccountStore.swift AppFeedbackTests/GitHubAccountStoreTests.swift AppFeedback.xcodeproj
git commit -m "feat(github): GitHubAccountStore with CloudKit dedup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Create + inject `GitHubAccountStore` in the app

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (declare `@State`, init it, inject into both environments)

- [ ] **Step 1: Declare the state property** — after line 41 (`@State private var mailAccountStore: MailAccountStore`), add:

```swift
    @State private var gitHubAccountStore: GitHubAccountStore
```

- [ ] **Step 2: Initialise it in `init()`** — after line 129 (`_store = State(initialValue: RepoStore(...))`), add:

```swift
        _gitHubAccountStore = State(initialValue: GitHubAccountStore(context: ModelContext(container)))
```

- [ ] **Step 3: Inject into the main WindowGroup environment** — after line 275 (`.environment(mailAccountStore)`), add:

```swift
                .environment(gitHubAccountStore)
```

- [ ] **Step 4: Inject into the macOS Settings Window environment** — in the `Window("Settings", id: "settings")` block, after line 352 (`.environment(mailAccountStore)`), add:

```swift
                .environment(gitHubAccountStore)
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(github): provide GitHubAccountStore via environment

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Refactor `GitHubLoginView` to a connect-account-only flow

**Files:**
- Modify: `AppFeedback/Views/Settings/GitHubLoginView.swift` (remove repo-picking; depend on `GitHubAccountStore`; add user fetch + account save; delete `RepoPickerContent`)
- Modify: `AppFeedback/Views/Settings/AddEditRepoView.swift` (add `@Environment(GitHubAccountStore.self)`; update the `.sheet` call site)

> After this task, "Sign in with GitHub" connects + persists an account but does not itself add a repo. Repo-picking is wired in Task 8. The app compiles and runs; manual repo entry still works.

- [ ] **Step 1: Replace the dependency and state in `GitHubLoginView`** — change the stored properties (lines 7-19). Replace:

```swift
    @Bindable var store: RepoStore
    var onCompleted: (() -> Void)? = nil

    @State private var authState: AuthState = .requestingCode
    @State private var oauthToken = ""
    @State private var searchText = ""
    @State private var selectedRepo: GitHubRepo?
    @State private var displayName = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var didCopyCode = false

    private let service = GitHubAuthService()
```

with:

```swift
    var accountStore: GitHubAccountStore
    var onCompleted: (() -> Void)? = nil

    @State private var authState: AuthState = .requestingCode
    @State private var pollTask: Task<Void, Never>?
    @State private var didCopyCode = false

    private let service = GitHubAuthService()
```

- [ ] **Step 2: Trim the `AuthState` enum** (lines 21-27). Replace:

```swift
    enum AuthState {
        case requestingCode
        case waitingForUser(DeviceCodeResponse)
        case fetchingRepos
        case pickingRepo([GitHubRepo])
        case failed(String)
    }
```

with:

```swift
    enum AuthState {
        case requestingCode
        case waitingForUser(DeviceCodeResponse)
        case finalizing
        case failed(String)
    }
```

- [ ] **Step 3: Update the `content` switch** (lines 66-80). Replace:

```swift
    @ViewBuilder
    private var content: some View {
        switch authState {
        case .requestingCode:
            centeredProgress("Connecting to GitHub…")
        case .waitingForUser(let response):
            waitingView(response)
        case .fetchingRepos:
            centeredProgress("Loading your repositories…")
        case .pickingRepo(let repos):
            repoPickerView(repos)
        case .failed(let message):
            failedView(message)
        }
    }
```

with:

```swift
    @ViewBuilder
    private var content: some View {
        switch authState {
        case .requestingCode:
            centeredProgress("Connecting to GitHub…")
        case .waitingForUser(let response):
            waitingView(response)
        case .finalizing:
            centeredProgress("Finishing sign-in…")
        case .failed(let message):
            failedView(message)
        }
    }
```

- [ ] **Step 4: Delete `repoPickerView`** (lines 118-126) entirely.

- [ ] **Step 5: Rewrite `startDeviceFlow` and replace `saveSelectedRepo`** — replace the body of `startDeviceFlow()` (lines 171-192) and delete `saveSelectedRepo()` (lines 194-211). New `startDeviceFlow()`:

```swift
    private func startDeviceFlow() {
        authState = .requestingCode
        pollTask?.cancel()
        pollTask = Task {
            do {
                let codeResponse = try await service.requestDeviceCode()
                authState = .waitingForUser(codeResponse)
                let token = try await service.pollForToken(
                    deviceCode: codeResponse.deviceCode,
                    interval: codeResponse.interval
                )
                authState = .finalizing
                let user = try await service.fetchCurrentUser(token: token)
                _ = await accountStore.add(login: user.login, avatarURL: user.avatarURL, token: token)
                onCompleted?()
                dismiss()
            } catch is CancellationError {
                // user dismissed — do nothing
            } catch {
                authState = .failed(error.localizedDescription)
            }
        }
    }
```

- [ ] **Step 6: Delete the `RepoPickerContent` sub-view** — remove the entire `// MARK: - Repo Picker Sub-view` section and the `private struct RepoPickerContent` (lines 214-307). (Its replacement, `AccountRepoPicker`, is built fresh in Task 7.)

- [ ] **Step 7: Update the call site in `AddEditRepoView`** — add the environment dependency after line 5 (`@Bindable var store: RepoStore`):

```swift
    @Environment(GitHubAccountStore.self) private var accountStore
```

Then change the `.sheet` (lines 28-30):

```swift
            .sheet(isPresented: $showGitHubLogin) {
                GitHubLoginView(store: store, onCompleted: { dismiss() })
            }
```

to (connecting an account no longer dismisses the Add sheet — the user then picks a repo):

```swift
            .sheet(isPresented: $showGitHubLogin) {
                GitHubLoginView(accountStore: accountStore)
            }
```

- [ ] **Step 8: Build to verify**

```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add AppFeedback/Views/Settings/GitHubLoginView.swift AppFeedback/Views/Settings/AddEditRepoView.swift
git commit -m "refactor(github): GitHubLoginView connects accounts, not repos

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Build the `AccountRepoPicker` component

**Files:**
- Create: `AppFeedback/Views/Settings/AccountRepoPicker.swift`

> This task adds the component but does not yet wire it into the Add sheet (Task 8), so verification is a successful build. The repo-row visuals mirror the deleted `RepoPickerContent` (lock label, checkmark).

- [ ] **Step 1: Create the component** — `AppFeedback/Views/Settings/AccountRepoPicker.swift`:

```swift
import SwiftUI

/// Lists repositories grouped into one collapsible section per connected GitHub account.
/// Each section loads its repos lazily on first expansion using that account's token.
@MainActor
struct AccountRepoPicker: View {
    let accounts: [GitHubAccount]
    let accountStore: GitHubAccountStore
    /// "owner/name" (lowercased) of repos already added to the app — shown dimmed as "Added".
    let existingRepoKeys: Set<String>
    /// "owner/name" (lowercased) of the currently selected repo — gets a checkmark.
    let selectedKey: String?
    let onSelect: (GitHubAccount, GitHubRepo) -> Void
    let onConnectAnother: () -> Void

    @State private var searchText = ""
    @State private var states: [UUID: AccountRepoState] = [:]
    @State private var expanded: Set<UUID> = []

    enum AccountRepoState {
        case loading
        case loaded([GitHubRepo])
        case failed(String)
        case expired
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            ForEach(accounts, id: \.id) { account in
                accountSection(account)
                Divider().padding(.leading, 12)
            }
            connectAnotherRow
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if expanded.isEmpty, let first = accounts.first {
                expanded.insert(first.id)
                loadRepos(for: first)
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search repositories…", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
    }

    // MARK: - Account section

    @ViewBuilder
    private func accountSection(_ account: GitHubAccount) -> some View {
        VStack(spacing: 0) {
            sectionHeader(account)
            if expanded.contains(account.id) {
                sectionBody(account)
            }
        }
    }

    private func sectionHeader(_ account: GitHubAccount) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(account)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.contains(account.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    avatar(account)
                    Text("@\(account.login)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if case .expired? = states[account.id] {
                    Button("Reconnect") { onConnectAnother() }
                }
                Button("Disconnect", role: .destructive) {
                    Task {
                        await accountStore.deleteWithCredentials(account)
                        states[account.id] = nil
                        expanded.remove(account.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sectionBody(_ account: GitHubAccount) -> some View {
        switch states[account.id] ?? .loading {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Loading repositories…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        case .loaded(let repos):
            repoList(account, repos)
        case .failed(let message):
            sectionMessage(message, actionTitle: "Retry") { loadRepos(for: account) }
        case .expired:
            sectionMessage("Session expired — reconnect to continue.", actionTitle: "Reconnect", action: onConnectAnother)
        }
    }

    private func sectionMessage(_ message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func repoList(_ account: GitHubAccount, _ repos: [GitHubRepo]) -> some View {
        let filtered = repos.filter {
            searchText.isEmpty || $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
        if filtered.isEmpty {
            Text(repos.isEmpty ? "No repositories for this account." : "No results.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { (repo: GitHubRepo) in
                    repoRow(account, repo)
                }
            }
        }
    }

    private func repoRow(_ account: GitHubAccount, _ repo: GitHubRepo) -> some View {
        let key = "\(repo.owner.login)/\(repo.name)".lowercased()
        let alreadyAdded = existingRepoKeys.contains(key)
        return Button {
            onSelect(account, repo)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.fullName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(alreadyAdded ? .secondary : .primary)
                    if repo.isPrivate {
                        Label("Private", systemImage: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if alreadyAdded {
                    Text("Added")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if selectedKey == key {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 32)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }

    // MARK: - Connect another

    private var connectAnotherRow: some View {
        Button(action: onConnectAnother) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                Text("Connect another account")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatar(_ account: GitHubAccount) -> some View {
        if let urlStr = account.avatarURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    // MARK: - Actions

    private func toggle(_ account: GitHubAccount) {
        if expanded.contains(account.id) {
            expanded.remove(account.id)
        } else {
            expanded.insert(account.id)
            if states[account.id] == nil { loadRepos(for: account) }
        }
    }

    private func loadRepos(for account: GitHubAccount) {
        states[account.id] = .loading
        Task {
            guard let token = accountStore.token(for: account) else {
                states[account.id] = .expired
                return
            }
            do {
                let repos = try await GitHubAuthService().listRepos(token: token)
                states[account.id] = .loaded(repos)
            } catch GitHubAuthService.AuthError.apiError(let code) where code == 401 || code == 403 {
                states[account.id] = .expired
            } catch {
                states[account.id] = .failed(error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate and build to verify**

```bash
xcodegen generate
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Settings/AccountRepoPicker.swift AppFeedback.xcodeproj
git commit -m "feat(github): AccountRepoPicker collapsible per-account repo list

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Wire `AccountRepoPicker` into the Add Repository sheet

**Files:**
- Modify: `AppFeedback/Views/Settings/AddEditRepoView.swift` (swap the new-repo sign-in block for the picker when accounts exist; prefill fields on selection)

- [ ] **Step 1: Add a computed property for already-added repo keys** — in `AddEditRepoView`, after the `isValid` computed property (after line 23), add:

```swift
    private var existingRepoKeys: Set<String> {
        Set(store.repos.map { "\($0.owner)/\($0.repo)".lowercased() })
    }

    private var selectedRepoKey: String? {
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)".lowercased()
    }
```

- [ ] **Step 2: Replace the new-repo header block in `formContent`** — replace the `if !isEditing { … }` block (lines 69-90) with:

```swift
                if !isEditing {
                    if accountStore.accounts.isEmpty {
                        Button {
                            showGitHubLogin = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        AccountRepoPicker(
                            accounts: accountStore.accounts,
                            accountStore: accountStore,
                            existingRepoKeys: existingRepoKeys,
                            selectedKey: selectedRepoKey,
                            onSelect: { account, ghRepo in
                                owner = ghRepo.owner.login
                                repo = ghRepo.name
                                displayName = ghRepo.name
                                token = accountStore.token(for: account) ?? ""
                                redactEmailAddresses = !ghRepo.isPrivate
                            },
                            onConnectAnother: { showGitHubLogin = true }
                        )
                    }

                    HStack {
                        VStack { Divider() }
                        Text("or enter manually")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                }
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification (run the app via the zcode/run skill)**

Verify the full flow:
1. With **no accounts**, open Settings → Repos → **Add Repo**. Confirm the "Sign in with GitHub" button shows. Complete the device flow once → the login sheet closes and the Add sheet now shows your account section with its repos.
2. Without re-authorizing, the account section lists repos; selecting one prefills Display Name + owner/repo and enables **Add**. Click **Add** → repo appears in the sidebar.
3. Open **Add Repo** again → **no device-flow login** is required; your account section is present and expandable immediately. (This is the core fix.)
4. **+ Connect another account** runs the device flow and adds a second section.
5. A section's `⋯` → **Disconnect** removes that account; previously-added repos remain in the sidebar and still load feedback.
6. Already-added repos appear dimmed with an "Added" tag and are not selectable.
7. Manual entry below "or enter manually" still works for a PAT.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Settings/AddEditRepoView.swift
git commit -m "feat(github): pick repos from connected accounts in Add Repository

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the complete test suite**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS
```
Expected: PASS — including `KeychainServicePerAccountTests`, `GitHubAuthModelsTests`, `GitHubAuthServiceTests`, `GitHubAccountStoreTests`, and all pre-existing suites.

- [ ] **Step 2: Confirm no regressions in the device flow tests**

The pre-existing `GitHubAuthServiceTests` (device code, poll, listRepos pagination) must still pass — `requestDeviceCode`/`pollForToken`/`listRepos` were not modified.

- [ ] **Step 3: Final manual smoke test on a clean launch**

Quit and relaunch the app. Open **Add Repo** and confirm connected accounts persist across launches (they are restored from SwiftData + Keychain) with no device-flow prompt.

- [ ] **Step 4: Finish the branch**

Use superpowers:finishing-a-development-branch to choose merge/PR. Suggested PR title: `feat: persistent multi-account GitHub sign-in for Add Repository`.

---

## Notes for the implementer

- **Why repos still "just work" after Add:** selecting a repo copies the account's token into the existing per-repo Keychain slot (`KeychainService.save(token:for:)` inside `AddEditRepoView.save()` at lines 275/295). Every downstream reader (`IssueLoader`, `GitHubCommentPoster`, `FeedbackAttachmentDownloader` via `RepoConfigSnapshot`) keeps reading per-repo tokens — none of them change.
- **No migration:** existing repos keep their per-repo tokens; the account list simply starts empty until the user connects. Do not write a migration.
- **Disconnect is local-only:** it forgets the account row + its session token; it does not revoke the token at GitHub and does not delete already-added repos.
- **`states[account.id] == nil`** compiles because `Optional == nil` does not require `Wrapped: Equatable`.
- If `xcodegen` is not installed, the new files must be added to the Xcode project some other way before building; the globbed `sources: AppFeedback` / `AppFeedbackTests` paths in `project.yml` mean a regenerate is the intended path.
```
