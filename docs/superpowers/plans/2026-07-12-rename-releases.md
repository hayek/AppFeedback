# Renaming Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user edit a release's version number (`ProjectVersion.name`) — not just its title and changelog — from the version detail sheet, without orphaning the tasks, sent-email history, and saved filters that are keyed to that name.

**Architecture:** `name` is a foreign key, not a label: `IssueLoader` fetches only `milestone { title }` (never the number), so tasks join to versions by string equality on the name. Rename therefore = validate → PATCH the GitHub milestone title → cascade the four local copies of the old name. GitHub goes first because `TaskItem.milestoneTitle` is sourced *from* GitHub; writing locally first would let the next sync revert the rename and detach every task. The cascade is deterministic and needs no network reconcile, because GitHub is already correct after the PATCH (issues stay attached to the milestone by *number*, which never changes).

**Tech Stack:** Swift 6, SwiftUI, SwiftData (+ CloudKit), XCTest. Multiplatform (macOS + iOS).

**Spec:** `docs/superpowers/specs/2026-07-12-rename-releases-design.md`

## Global Constraints

- **Tests are XCTest.** The suite is 100% XCTest (`@MainActor final class XTests: XCTestCase`). There is zero swift-testing (`@Test`/`#expect`) anywhere. Do not introduce it.
- **Test target is `AppFeedbackTests_macOS`**, not `AppFeedbackTests`.
- **Build/test via the `zcode` skill.** Do not invent xcodebuild invocations.
- **~11 pre-existing test failures** in `KeychainServicePerAccountTests` + `GitHubAccountStoreTests` are caused by the test host having no Keychain. They are **not** regressions — ignore them.
- **`KeychainService.loadSync` fails in the test host.** Anything that calls it (i.e. every `VersionService` method) cannot be unit-tested. Keep validation and cascade logic in separate, Keychain-free types so they *can* be.
- **CloudKit forbids `@Attribute(.unique)` and non-optional new properties.** Any new model property must be `var x: T? = nil` (nullable with a default).
- **The project is xcodegen-generated.** New `.swift` files under `AppFeedback/` and `AppFeedbackTests/` are globbed into the pbxproj — run `xcodegen` (or the zcode build) after adding files, and do not hand-edit `AppFeedback.xcodeproj`.
- **Stay on `main`. No PR.** Commit each task directly.
- **The working tree has the user's unrelated WIP** (modified `AppFeedbackApp.swift`, `Info.plist`, two `.xcscheme`s, and an untracked `2026-06-24-*-design.md`). **Never use a bare `git add -A` / `git add .`** — stage only the exact files each task names.

---

### Task 1: `VersionNameValidator` — the shared validation rule

Pure, Keychain-free, so it's directly unit-testable. Shared by create and rename. Rejects empty names and case-insensitive duplicates within a product (a duplicate is not cosmetic — two versions sharing a name would merge each other's task lists and clobber `versionStates`).

**Files:**
- Create: `AppFeedback/Services/VersionNameValidator.swift`
- Test: `AppFeedbackTests/VersionNameValidatorTests.swift`

**Interfaces:**
- Consumes: `ProjectVersion` (`AppFeedback/Models/ProjectVersion.swift`).
- Produces: `VersionNameValidator.validate(_:existing:renaming:) throws -> String` (returns the **trimmed** name) and `VersionNameValidator.Failure` (`.empty`, `.duplicate(String)`), used by Tasks 5 and 6.

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/VersionNameValidatorTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class VersionNameValidatorTests: XCTestCase {
    private func version(_ name: String) -> ProjectVersion {
        ProjectVersion(repoOwner: "o", repoName: "r", name: name)
    }

    func testTrimsWhitespace() throws {
        let name = try VersionNameValidator.validate("  1.2.0 ", existing: [])
        XCTAssertEqual(name, "1.2.0")
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertThrowsError(try VersionNameValidator.validate("", existing: [])) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .empty)
        }
        XCTAssertThrowsError(try VersionNameValidator.validate("   ", existing: [])) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .empty)
        }
    }

    func testRejectsDuplicateCaseInsensitively() {
        let existing = [version("1.2.0"), version("2.0-Beta")]
        XCTAssertThrowsError(try VersionNameValidator.validate("2.0-BETA", existing: existing)) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .duplicate("2.0-BETA"))
        }
    }

    /// The version being renamed must not collide with itself — re-applying its own name is a no-op,
    /// not a duplicate.
    func testRenamingVersionDoesNotCollideWithItself() throws {
        let subject = version("1.2.0")
        let name = try VersionNameValidator.validate("1.2.0", existing: [subject], renaming: subject)
        XCTAssertEqual(name, "1.2.0")
    }

    func testRenamingStillRejectsAnotherVersionsName() {
        let subject = version("1.2.0")
        let other = version("1.3.0")
        XCTAssertThrowsError(
            try VersionNameValidator.validate("1.3.0", existing: [subject, other], renaming: subject))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Use the zcode skill to run the `AppFeedbackTests_macOS` target.
Expected: FAIL — `cannot find 'VersionNameValidator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AppFeedback/Services/VersionNameValidator.swift`:

```swift
import Foundation

/// The one rule for what a version may be called, shared by create and rename.
///
/// Uniqueness is enforced here rather than by the model because CloudKit forbids
/// `@Attribute(.unique)`. It matters: `name` is the key that joins tasks, sent release emails, and
/// saved filters to a version, so two versions sharing a name would silently merge each other's
/// task lists. GitHub's 422 on a duplicate milestone title is only a backstop for the remote write.
enum VersionNameValidator {
    enum Failure: LocalizedError, Equatable {
        case empty
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a version name."
            case .duplicate(let name):
                return "This product already has a version named “\(name)”."
            }
        }
    }

    /// Returns the trimmed name, or throws.
    /// - Parameters:
    ///   - existing: every version in the same product.
    ///   - renaming: the version being renamed — excluded from the duplicate check so it doesn't
    ///     collide with itself. `nil` when creating.
    static func validate(_ proposed: String,
                         existing: [ProjectVersion],
                         renaming: ProjectVersion? = nil) throws -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }

        let subjectID = renaming?.id
        let collides = existing.contains {
            $0.id != subjectID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !collides else { throw Failure.duplicate(trimmed) }

        return trimmed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: all 5 `VersionNameValidatorTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/VersionNameValidator.swift AppFeedbackTests/VersionNameValidatorTests.swift
git commit -m "feat(versions): add VersionNameValidator (non-empty, unique per product)"
```

---

### Task 2: `SentReleaseNotification.versionID` — a rename-proof key for the "already emailed" guard

`alreadyNotifiedEmails` is the *only* guard against re-emailing users on a second release pass, and it currently joins by version **name**. A rename would reset it — meaning real users get a duplicate release email. Give the row a UUID foreign key.

The matcher must stay **pure**: `VersionDetailView` calls `sentNotifications` from a computed property during view body evaluation, so mutating models / saving there would be a SwiftUI re-entrancy hazard. Stamping happens on write only (here in `recordSent`; and in Task 3's `rename`).

**Files:**
- Modify: `AppFeedback/Models/SentReleaseNotification.swift`
- Modify: `AppFeedback/Services/VersionStore.swift:47-58` (queries), `:71-78` (`recordSent`)
- Modify: `AppFeedback/Services/ReleaseNotificationService.swift:87`, `:118` (both `recordSent` call sites)
- Modify: `AppFeedback/App/RootView.swift:205` (`alreadyNotifiedEmails` call site)
- Modify: `AppFeedback/Views/Inspector/VersionDetailView.swift:24-26` (`sentNotifications` call site)
- Test: `AppFeedbackTests/VersionStoreTests.swift`

**Interfaces:**
- Consumes: `VersionNameValidator` — not used here.
- Produces, for Tasks 3 and 6:
  - `SentReleaseNotification.versionID: UUID?`
  - `VersionStore.alreadyNotifiedEmails(for version: ProjectVersion) -> Set<String>` (**replaces** the `(owner:repo:versionName:)` signature)
  - `VersionStore.sentNotifications(for version: ProjectVersion) -> [SentReleaseNotification]` (**replaces** the `(owner:repo:versionName:)` signature)
  - `VersionStore.recordSent(version:recipientEmail:feedbackNumbers:threadIssueNumber:status:errorDetail:)` (**replaces** the `(repoOwner:repoName:versionName:...)` signature)

- [ ] **Step 1: Write the failing tests**

Replace the whole of `AppFeedbackTests/VersionStoreTests.swift` with:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class VersionStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ProjectVersion.self, SentReleaseNotification.self, configurations: config)
        return ModelContext(container)
    }

    func testAddAndFetchScopedToRepo() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "first")
        store.create(repoOwner: "o", repoName: "other", name: "9.9", changelog: "")
        let forRepo = store.versions(owner: "o", repo: "r")
        XCTAssertEqual(forRepo.map(\.name), ["1.0.0"])
        XCTAssertEqual(v.changelog, "first")
    }

    func testRecordSentNotification() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("a@b.com"))
    }

    /// `recordSent` stamps the version's UUID, so the row is found by id and not by name.
    func testRecordSentStampsVersionID() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        XCTAssertEqual(store.sentNotifications(for: v).first?.versionID, v.id)
    }

    /// A legacy row (synced from an older build, so `versionID == nil`) is still matched by name.
    func testLegacyRowWithoutVersionIDMatchesByName() throws {
        let context = try makeContext()
        let store = VersionStore(context: context)
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        context.insert(SentReleaseNotification(
            repoOwner: "o", repoName: "r", versionName: "1.0.0", recipientEmail: "legacy@b.com",
            feedbackNumbers: [], threadIssueNumber: 1, status: .sent))
        store.saveAndReload()
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("legacy@b.com"))
    }

    /// A stamped row belongs to its version by id — a *different* version that happens to share the
    /// name must not pick it up.
    func testStampedRowDoesNotLeakToASameNamedVersionInAnotherProduct() throws {
        let store = VersionStore(context: try makeContext())
        let mine = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        let theirs = store.create(repoOwner: "o", repoName: "other", name: "1.0.0", changelog: "")
        store.recordSent(version: mine, recipientEmail: "a@b.com",
                         feedbackNumbers: [], threadIssueNumber: 1, status: .sent)
        XCTAssertTrue(store.alreadyNotifiedEmails(for: mine).contains("a@b.com"))
        XCTAssertTrue(store.alreadyNotifiedEmails(for: theirs).isEmpty)
    }

    /// Only `.sent` rows count as "already notified" — a failed send must be retryable.
    func testFailedSendIsNotCountedAsAlreadyNotified() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com", feedbackNumbers: [],
                         threadIssueNumber: 1, status: .failed, errorDetail: "boom")
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).isEmpty)
        XCTAssertEqual(store.sentNotifications(for: v).count, 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Expected: FAIL to compile — `extra argument 'version' in call`, `value of type 'SentReleaseNotification' has no member 'versionID'`.

- [ ] **Step 3: Add `versionID` to the model**

In `AppFeedback/Models/SentReleaseNotification.swift`, add the property after `repoName` and thread it through `init`:

```swift
import Foundation
import SwiftData

@Model
final class SentReleaseNotification {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    /// The `ProjectVersion.id` this row belongs to. Optional because CloudKit forbids non-optional
    /// new properties, so rows written by older builds arrive as nil and are matched by name
    /// instead (see `VersionStore.matches`). Stamped on write, never on read.
    var versionID: UUID? = nil
    /// Display copy of the version's name at send time. Kept in sync by a rename, but `versionID`
    /// — not this — is what identifies the version.
    var versionName: String = ""
    var recipientEmail: String = ""
    var feedbackNumbers: [Int] = []
    var threadIssueNumber: Int = 0
    var sentAt: Date = Date()
    var statusRaw: String = "sent"        // "sent" | "failed"
    var errorDetail: String? = nil

    enum Status: String, Sendable { case sent, failed }
    var status: Status {
        get { Status(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), repoOwner: String, repoName: String, versionID: UUID? = nil, versionName: String,
         recipientEmail: String, feedbackNumbers: [Int], threadIssueNumber: Int,
         sentAt: Date = Date(), status: Status = .sent, errorDetail: String? = nil) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.versionID = versionID
        self.versionName = versionName
        self.recipientEmail = recipientEmail
        self.feedbackNumbers = feedbackNumbers
        self.threadIssueNumber = threadIssueNumber
        self.sentAt = sentAt
        self.statusRaw = status.rawValue
        self.errorDetail = errorDetail
    }
}
```

- [ ] **Step 4: Re-key the `VersionStore` queries onto the version**

In `AppFeedback/Services/VersionStore.swift`, replace the two query methods (currently lines 48-58) with:

```swift
    /// Emails already successfully notified for `version` — the only guard against re-emailing a
    /// user on a second release pass.
    func alreadyNotifiedEmails(for version: ProjectVersion) -> Set<String> {
        Set(sentAll
            .filter { matches($0, version) && $0.status == .sent }
            .map(\.recipientEmail))
    }

    func sentNotifications(for version: ProjectVersion) -> [SentReleaseNotification] {
        sentAll
            .filter { matches($0, version) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    /// Does `row` belong to `version`?
    ///
    /// Stamped rows match by UUID, so a rename can never hide them. Only rows *unclaimed* by any
    /// version (legacy rows from builds before `versionID` existed) fall back to matching by name —
    /// and `rename` stamps those as it rewrites them, so the fallback shrinks to nothing over time.
    ///
    /// Deliberately side-effect-free: `VersionDetailView` calls `sentNotifications` from a computed
    /// property during view body evaluation, so stamping here would mutate models mid-update.
    private func matches(_ row: SentReleaseNotification, _ version: ProjectVersion) -> Bool {
        if let rowVersionID = row.versionID { return rowVersionID == version.id }
        return row.repoOwner == version.repoOwner
            && row.repoName == version.repoName
            && row.versionName == version.name
    }
```

And replace `recordSent` (currently lines 71-78) with:

```swift
    func recordSent(version: ProjectVersion, recipientEmail: String,
                    feedbackNumbers: [Int], threadIssueNumber: Int, status: SentReleaseNotification.Status,
                    errorDetail: String? = nil) {
        let row = SentReleaseNotification(
            repoOwner: version.repoOwner, repoName: version.repoName,
            versionID: version.id, versionName: version.name,
            recipientEmail: recipientEmail, feedbackNumbers: feedbackNumbers,
            threadIssueNumber: threadIssueNumber, status: status, errorDetail: errorDetail)
        context.insert(row); save(); reload()
    }
```

- [ ] **Step 5: Update the three call sites**

In `AppFeedback/Services/ReleaseNotificationService.swift`, both `recordSent` calls (around lines 87 and 118) already have `version` in scope. Replace:

```swift
                versionStore.recordSent(repoOwner: repo.owner, repoName: repo.repo, versionName: version.name,
                    recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                    threadIssueNumber: 0, status: .failed, errorDetail: "No feedback to thread into")
```
with:
```swift
                versionStore.recordSent(version: version,
                    recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                    threadIssueNumber: 0, status: .failed, errorDetail: "No feedback to thread into")
```

and replace:
```swift
            versionStore.recordSent(repoOwner: repo.owner, repoName: repo.repo, versionName: version.name,
                recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                threadIssueNumber: chosen, status: didSend ? .sent : .failed,
                errorDetail: didSend ? nil : "Email send failed")
```
with:
```swift
            versionStore.recordSent(version: version,
                recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                threadIssueNumber: chosen, status: didSend ? .sent : .failed,
                errorDetail: didSend ? nil : "Email send failed")
```

In `AppFeedback/App/RootView.swift` around line 205, replace:
```swift
                    alreadySent: versionStore.alreadyNotifiedEmails(owner: repo.owner, repo: repo.repo, versionName: version.name),
```
with:
```swift
                    alreadySent: versionStore.alreadyNotifiedEmails(for: version),
```

In `AppFeedback/Views/Inspector/VersionDetailView.swift` lines 24-26, replace:
```swift
    private var sent: [SentReleaseNotification] {
        versionStore.sentNotifications(owner: repo.owner, repo: repo.repo, versionName: version.name)
    }
```
with:
```swift
    private var sent: [SentReleaseNotification] { versionStore.sentNotifications(for: version) }
```

- [ ] **Step 6: Run the tests to verify they pass**

Expected: all 6 `VersionStoreTests` PASS. Build succeeds for both macOS and iOS. (`ReleaseNotificationServiceTests` must still pass — if it constructs `SentReleaseNotification` directly, `versionID` defaults to `nil` and no change is needed.)

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Models/SentReleaseNotification.swift AppFeedback/Services/VersionStore.swift AppFeedback/Services/ReleaseNotificationService.swift AppFeedback/App/RootView.swift AppFeedback/Views/Inspector/VersionDetailView.swift AppFeedbackTests/VersionStoreTests.swift
git commit -m "feat(versions): key sent release emails to a version UUID, not its name

The already-emailed guard was joined by version name, so renaming a version
would reset it and re-email users on the next release pass. Rows now carry
versionID; legacy rows without one still match by name."
```

---

### Task 3: `VersionStore.rename` — the local cascade for versions + sent emails

Renames the `ProjectVersion` and rewrites the `SentReleaseNotification` rows that point at it (stamping `versionID` as it goes). Purely local and Keychain-free, so it's fully testable.

**Files:**
- Modify: `AppFeedback/Services/VersionStore.swift` (Mutations section)
- Test: `AppFeedbackTests/VersionStoreTests.swift`

**Interfaces:**
- Consumes: Task 2's `versionID` and `matches`.
- Produces, for Task 5: `VersionStore.rename(_ version: ProjectVersion, to newName: String)`.

- [ ] **Step 1: Write the failing tests**

Append to the `VersionStoreTests` class from Task 2:

```swift
    func testRenamePersistsTheNewName() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        store.rename(v, to: "1.3.0")
        XCTAssertEqual(store.versions(owner: "o", repo: "r").map(\.name), ["1.3.0"])
    }

    /// The regression this whole feature exists to avoid: renaming must not reset the
    /// already-emailed guard, or the next release pass re-mails real users.
    func testRenameKeepsTheAlreadyEmailedGuardIntact() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [7], threadIssueNumber: 7, status: .sent)

        store.rename(v, to: "1.3.0")

        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("a@b.com"))
        XCTAssertEqual(store.sentNotifications(for: v).count, 1)
    }

    /// A legacy row (no `versionID`) is carried across the rename by name, and stamped on the way,
    /// so it is UUID-keyed from then on.
    func testRenameRewritesAndStampsLegacyRows() throws {
        let context = try makeContext()
        let store = VersionStore(context: context)
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        context.insert(SentReleaseNotification(
            repoOwner: "o", repoName: "r", versionName: "1.2.0", recipientEmail: "legacy@b.com",
            feedbackNumbers: [], threadIssueNumber: 1, status: .sent))
        store.saveAndReload()

        store.rename(v, to: "1.3.0")

        let rows = store.sentNotifications(for: v)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.versionID, v.id)
        XCTAssertEqual(rows.first?.versionName, "1.3.0")
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("legacy@b.com"))
    }

    /// A same-named version in a different product must be untouched.
    func testRenameIsScopedToItsOwnProduct() throws {
        let store = VersionStore(context: try makeContext())
        let mine = store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        let theirs = store.create(repoOwner: "o", repoName: "other", name: "1.2.0", changelog: "")
        store.recordSent(version: theirs, recipientEmail: "them@b.com",
                         feedbackNumbers: [], threadIssueNumber: 1, status: .sent)

        store.rename(mine, to: "1.3.0")

        XCTAssertEqual(store.versions(owner: "o", repo: "other").map(\.name), ["1.2.0"])
        XCTAssertEqual(store.sentNotifications(for: theirs).first?.versionName, "1.2.0")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Expected: FAIL to compile — `value of type 'VersionStore' has no member 'rename'`.

- [ ] **Step 3: Write the implementation**

In `AppFeedback/Services/VersionStore.swift`, add to the `// MARK: Mutations` section, right after `create`:

```swift
    /// Renames `version` and re-points the sent-email rows that belong to it.
    ///
    /// Local only — the caller is responsible for having already PATCHed the GitHub milestone title
    /// (see `VersionService.rename`), because `TaskItem.milestoneTitle` is sourced *from* GitHub and
    /// a local-only rename would be reverted by the next sync.
    ///
    /// The rows are resolved *before* the name changes, so legacy rows (which match by name) are
    /// still found; each is then stamped with the version's id so it will never need the name again.
    func rename(_ version: ProjectVersion, to newName: String) {
        let rows = sentAll.filter { matches($0, version) }
        version.name = newName
        for row in rows {
            row.versionID = version.id
            row.versionName = newName
        }
        saveAndReload()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: all 10 `VersionStoreTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/VersionStore.swift AppFeedbackTests/VersionStoreTests.swift
git commit -m "feat(versions): add VersionStore.rename with sent-email cascade"
```

---

### Task 4: `VersionRenameCascade` — the local cascade for cached issues + saved filters

The other two persisted copies of the old name: `CachedIssue.milestoneTitle` (the local issue mirror) and the `VersionScope.versions(Set<String>)` inside the CloudKit-synced `RepoFilterPreference.taskFiltersData`. Without this, tasks detach from the version until a full reconcile, and a saved filter silently matches nothing behind a dead pill.

Keychain-free and injectable, so it's testable.

**Files:**
- Create: `AppFeedback/Services/VersionRenameCascade.swift`
- Test: `AppFeedbackTests/VersionRenameCascadeTests.swift`

**Interfaces:**
- Consumes: `CachedIssue` (`AppFeedback/Models/CachedIssue.swift`), `FilterPreferenceStore` + `PersistedFilterBundle` + `PersistedTaskFilters` (`AppFeedback/Services/FilterPreferenceStore.swift`), `VersionScope` (`AppFeedback/ViewModels/ProjectInspectorModel.swift:53`).
- Produces, for Task 5: `VersionRenameCascade(cacheContext:filterStore:)` and `.apply(owner:repo:from:to:)`.

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/VersionRenameCascadeTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class VersionRenameCascadeTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: CachedIssue.self, RepoFilterPreference.self, configurations: config)
        return ModelContext(container)
    }

    private func cachedIssue(number: Int, owner: String, repo: String, milestone: String?) -> CachedIssue {
        let issue = CachedIssue(
            repoOwner: owner, repoName: repo, number: number, title: "t", createdAt: Date(),
            rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil,
            email: nil, issueDescription: "")
        issue.milestoneTitle = milestone   // not an init parameter — set after construction
        return issue
    }

    func testRewritesCachedIssueMilestoneTitles() throws {
        let context = try makeContext()
        context.insert(cachedIssue(number: 1, owner: "o", repo: "r", milestone: "1.2.0"))
        context.insert(cachedIssue(number: 2, owner: "o", repo: "r", milestone: "9.9"))
        context.insert(cachedIssue(number: 3, owner: "o", repo: "r", milestone: nil))
        try context.save()

        let cascade = VersionRenameCascade(cacheContext: context,
                                           filterStore: FilterPreferenceStore(context: context))
        cascade.apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        let all = try context.fetch(FetchDescriptor<CachedIssue>()).sorted { $0.number < $1.number }
        XCTAssertEqual(all.map(\.milestoneTitle), ["1.3.0", "9.9", nil])
    }

    /// A same-named milestone in another product must be untouched.
    func testCachedIssueRewriteIsScopedToItsOwnProduct() throws {
        let context = try makeContext()
        context.insert(cachedIssue(number: 1, owner: "o", repo: "r", milestone: "1.2.0"))
        context.insert(cachedIssue(number: 2, owner: "o", repo: "other", milestone: "1.2.0"))
        try context.save()

        let cascade = VersionRenameCascade(cacheContext: context,
                                           filterStore: FilterPreferenceStore(context: context))
        cascade.apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        let all = try context.fetch(FetchDescriptor<CachedIssue>()).sorted { $0.number < $1.number }
        XCTAssertEqual(all.map(\.milestoneTitle), ["1.3.0", "1.2.0"])
    }

    /// A persisted `.versions` filter pinned to the old name must follow the rename, or it silently
    /// matches nothing behind a pill that still reads "1.2.0".
    func testRewritesPersistedVersionScopeFilter() throws {
        let context = try makeContext()
        let filterStore = FilterPreferenceStore(context: context)
        var bundle = PersistedFilterBundle()
        bundle.task = PersistedTaskFilters(versionScope: .versions(["1.2.0", "1.1.0"]))
        filterStore.save(owner: "o", repo: "r", bundle: bundle)

        VersionRenameCascade(cacheContext: context, filterStore: filterStore)
            .apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(filterStore.load(owner: "o", repo: "r").task.versionScope,
                       .versions(["1.3.0", "1.1.0"]))
    }

    /// A filter that doesn't name the renamed version is left exactly as it was.
    func testLeavesUnrelatedFilterScopesAlone() throws {
        let context = try makeContext()
        let filterStore = FilterPreferenceStore(context: context)
        var bundle = PersistedFilterBundle()
        bundle.task = PersistedTaskFilters(versionScope: .state(.wip))
        filterStore.save(owner: "o", repo: "r", bundle: bundle)

        VersionRenameCascade(cacheContext: context, filterStore: filterStore)
            .apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(filterStore.load(owner: "o", repo: "r").task.versionScope, .state(.wip))
    }
}
```

> **Note:** `milestoneTitle` is not an `init` parameter on `CachedIssue` — it is assigned after construction (as `CachedIssue.swift:111` does). Do **not** change `CachedIssue`'s initializer to suit the test.

- [ ] **Step 2: Run the tests to verify they fail**

Expected: FAIL to compile — `cannot find 'VersionRenameCascade' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AppFeedback/Services/VersionRenameCascade.swift`:

```swift
import Foundation
import SwiftData

/// Rewrites the local, name-keyed references to a version that has just been renamed.
///
/// GitHub needs no repair — its issues are attached to the milestone by *number*, which a rename
/// doesn't change — so this is a purely local fixup and needs no network reconcile. It covers the
/// two persisted copies of the name that `VersionStore.rename` does not own:
///
/// - `CachedIssue.milestoneTitle`, the local mirror that rehydrates `TaskItem.milestoneTitle`
///   (the app never learns milestone *numbers* for issues: `IssueLoader` selects only
///   `milestone { title }`), so without this every task detaches from the version until a full
///   reconcile — which the default incremental refresh never performs.
/// - The `VersionScope.versions` set inside the persisted task filters, which would otherwise pin a
///   name that no longer exists and silently match nothing.
@MainActor
struct VersionRenameCascade {
    let cacheContext: ModelContext
    let filterStore: FilterPreferenceStore

    func apply(owner: String, repo: String, from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        rewriteCachedIssues(owner: owner, repo: repo, from: oldName, to: newName)
        rewritePersistedFilters(owner: owner, repo: repo, from: oldName, to: newName)
    }

    private func rewriteCachedIssues(owner: String, repo: String, from oldName: String, to newName: String) {
        let predicate = #Predicate<CachedIssue> {
            $0.repoOwner == owner && $0.repoName == repo && $0.milestoneTitle == oldName
        }
        guard let stale = try? cacheContext.fetch(FetchDescriptor<CachedIssue>(predicate: predicate)),
              !stale.isEmpty else { return }
        for issue in stale { issue.milestoneTitle = newName }
        try? cacheContext.save()
    }

    private func rewritePersistedFilters(owner: String, repo: String, from oldName: String, to newName: String) {
        var bundle = filterStore.load(owner: owner, repo: repo)
        guard case .versions(var names) = bundle.task.versionScope, names.contains(oldName) else { return }
        names.remove(oldName)
        names.insert(newName)
        bundle.task.versionScope = .versions(names)
        filterStore.save(owner: owner, repo: repo, bundle: bundle)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: all 4 `VersionRenameCascadeTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/VersionRenameCascade.swift AppFeedbackTests/VersionRenameCascadeTests.swift
git commit -m "feat(versions): cascade a rename into cached issues and saved filters"
```

---

### Task 5: `VersionService.rename` — GitHub first, local second

Orchestrates the whole rename. Ordering is the point: PATCH the milestone title, and only commit locally once GitHub has accepted it.

**Files:**
- Modify: `AppFeedback/Services/VersionService.swift`
- Test: `AppFeedbackTests/GitHubMilestoneReleaseClientTests.swift` (the milestone-title PATCH — `updateMilestone` has never been tested)

**Interfaces:**
- Consumes: Task 1's `VersionNameValidator.validate`, Task 3's `VersionStore.rename`, Task 4's `VersionRenameCascade.apply`, and the existing `GitHubMilestoneReleaseClient.updateMilestone(owner:repo:number:title:description:state:token:)` (`GitHubMilestoneReleaseClient.swift:45`).
- Produces, for Task 6: `VersionService.rename(repo:version:to:cascade:) async throws` and `VersionService.ServiceError.duplicateName(String)`.

- [ ] **Step 1: Write the failing test**

`VersionService.rename` itself calls `KeychainService.loadSync`, which fails in the test host, so it cannot be unit-tested. What *can* and must be tested is the GitHub call it depends on — `updateMilestone(title:)` — which no test has ever covered.

Append to `AppFeedbackTests/GitHubMilestoneReleaseClientTests.swift`:

```swift
    func testUpdateMilestoneSendsTitleInPatchBody() async throws {
        var capturedBody: [String: Any]?
        var capturedMethod: String?
        var capturedURL: String?
        MockURLProtocol.requestHandler = { req in
            capturedMethod = req.httpMethod
            capturedURL = req.url?.absoluteString
            if let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
                capturedBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else if let d = req.httpBody { capturedBody = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"number":5,"title":"1.3.0","state":"open","description":"notes"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let ms = try await client.updateMilestone(owner: "o", repo: "r", number: 5, title: "1.3.0", token: "t")

        XCTAssertEqual(capturedMethod, "PATCH")
        XCTAssertEqual(capturedURL, "https://api.github.com/repos/o/r/milestones/5")
        XCTAssertEqual(capturedBody?["title"] as? String, "1.3.0")
        // A rename must not blank the changelog: the description key is absent, not empty.
        XCTAssertNil(capturedBody?["description"])
        XCTAssertEqual(ms.title, "1.3.0")
    }

    /// GitHub 422s on a duplicate milestone title — the backstop behind the local uniqueness check.
    func testUpdateMilestoneSurfacesDuplicateTitleError() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
             #"{"message":"Validation Failed"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        do {
            _ = try await client.updateMilestone(owner: "o", repo: "r", number: 5, title: "1.3.0", token: "t")
            XCTFail("expected a 422 to throw")
        } catch let GitHubMilestoneReleaseClient.ClientError.apiError(code, _) {
            XCTAssertEqual(code, 422)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Expected: both new tests FAIL (they exercise `updateMilestone(title:)`, which is implemented but has never been called with a title — if they happen to pass immediately, that is fine and confirms the client is already correct; proceed).

- [ ] **Step 3: Write the implementation**

In `AppFeedback/Services/VersionService.swift`, add `duplicateName` to `ServiceError`:

```swift
    enum ServiceError: LocalizedError {
        case noToken
        case noCommitForRelease
        case duplicateName(String)
        var errorDescription: String? {
            switch self {
            case .noToken: return "No GitHub token for this repo. Re-authenticate in Settings."
            case .noCommitForRelease: return "The target repo has no commit to tag. The version was released as a milestone only."
            case .duplicateName(let name): return "GitHub already has a milestone named “\(name)”."
            }
        }
    }
```

and add the `rename` method after `updateDetails`:

```swift
    /// Renames a version: validates, PATCHes the GitHub milestone title, then commits locally and
    /// cascades the local copies of the old name.
    ///
    /// GitHub goes **first**, inverting `updateDetails`'s local-then-remote order. That matters here:
    /// `TaskItem.milestoneTitle` is sourced *from* GitHub, so a local-first rename that then failed
    /// remotely would be silently reverted by the next sync — and every task would detach from the
    /// version in the meantime. Committing locally only after GitHub accepts keeps the two in step.
    ///
    /// Blocked once the version is published: the git tag and the release emails are already public,
    /// and a published Release's name cannot be PATCHed by this client anyway.
    func rename(repo: ProductConfig, version: ProjectVersion, to proposed: String,
                cascade: VersionRenameCascade) async throws {
        guard !version.releasePublished else { return }

        let existing = store.versions(owner: version.repoOwner, repo: version.repoName)
        let newName = try VersionNameValidator.validate(proposed, existing: existing, renaming: version)

        let oldName = version.name
        guard newName != oldName else { return }

        // A version whose milestone was never provisioned (offline create, or a failed provision)
        // has nothing to PATCH — the rename is a pure local edit.
        if let number = version.milestoneNumber {
            guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
            do {
                _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number,
                                                     title: newName, token: token)
            } catch GitHubMilestoneReleaseClient.ClientError.apiError(422, _) {
                throw ServiceError.duplicateName(newName)
            }
        }

        store.rename(version, to: newName)
        cascade.apply(owner: version.repoOwner, repo: version.repoName, from: oldName, to: newName)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: both new `GitHubMilestoneReleaseClientTests` PASS; the build succeeds.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/VersionService.swift AppFeedbackTests/GitHubMilestoneReleaseClientTests.swift
git commit -m "feat(versions): add VersionService.rename (GitHub milestone PATCH, then local cascade)"
```

---

### Task 6: Make the name editable in the version sheet

The user-facing change: `VersionDetailView`'s header stops being a read-only `Text` and becomes an editable `TextField`, folded into the existing `dirty` gate so Apply lights up. Matches `TaskDetailView`'s in-house editable-name idiom, so no new pattern is introduced and it works identically on macOS and iOS.

Unlike `applyDetails()` — which dismisses, writes in the background, and swallows failures with `try?` — a rename keeps the sheet up and reports errors, because a silently-failed rename is indistinguishable from a successful one.

**Files:**
- Modify: `AppFeedback/ViewModels/ProjectInspectorModel.swift` (add `renameVersion(from:to:)`)
- Modify: `AppFeedback/Views/Inspector/VersionDetailView.swift` (editable header, rename in the Apply path)
- Modify: `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift:62-71` (thread `onRename` to the sheet)
- Modify: `AppFeedback/App/RootView.swift` (supply the `onRename` closure — it owns `cacheContext` + `filterStore`)
- Test: `AppFeedbackTests/ProjectInspectorModelTests.swift`

**Interfaces:**
- Consumes: Task 5's `VersionService.rename(repo:version:to:cascade:)`, Task 4's `VersionRenameCascade`.
- Produces: `ProjectInspectorModel.renameVersion(from:to:)`.

- [ ] **Step 1: Write the failing test**

Append to `AppFeedbackTests/ProjectInspectorModelTests.swift` (inside the existing test class — match its existing helpers for building a `TaskItem`; if it has a factory, use it, otherwise use the memberwise `TaskItem(number:title:body:feedbackRefs:status:priority:milestoneTitle:isClosed:)` initializer):

```swift
    func testRenameVersionRepointsLoadedTasks() {
        let model = ProjectInspectorModel()
        model.setTasks([
            TaskItem(number: 1, title: "a", body: "", feedbackRefs: [], status: .todo,
                     priority: .med, milestoneTitle: "1.2.0", isClosed: false),
            TaskItem(number: 2, title: "b", body: "", feedbackRefs: [], status: .todo,
                     priority: .med, milestoneTitle: "9.9", isClosed: false),
            TaskItem(number: 3, title: "c", body: "", feedbackRefs: [], status: .todo,
                     priority: .med, milestoneTitle: nil, isClosed: false),
        ])

        model.renameVersion(from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(model.tasks(forVersionNamed: "1.3.0").map(\.number), [1])
        XCTAssertTrue(model.tasks(forVersionNamed: "1.2.0").isEmpty)
        XCTAssertEqual(model.tasks(forVersionNamed: "9.9").map(\.number), [2])
    }

    func testRenameVersionMovesTheActiveVersionFilter() {
        let model = ProjectInspectorModel()
        model.taskFilters.versionScope = .versions(["1.2.0", "1.1.0"])

        model.renameVersion(from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(model.taskFilters.versionScope, .versions(["1.3.0", "1.1.0"]))
    }

    func testRenameVersionMovesTheDerivedStateEntry() {
        let model = ProjectInspectorModel()
        model.versionStates = ["1.2.0": .wip, "9.9": .new]

        model.renameVersion(from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(model.versionStates["1.3.0"], .wip)
        XCTAssertNil(model.versionStates["1.2.0"])
        XCTAssertEqual(model.versionStates["9.9"], .new)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Expected: FAIL to compile — `value of type 'ProjectInspectorModel' has no member 'renameVersion'`.

- [ ] **Step 3: Add `renameVersion` to `ProjectInspectorModel`**

In `AppFeedback/ViewModels/ProjectInspectorModel.swift`, add near `applyOptimistic` (around line 319):

```swift
    /// Re-points the in-memory view state from `oldName` to `newName` after a version rename, so the
    /// UI updates immediately instead of waiting for a GitHub round-trip. GitHub is already correct
    /// — its issues are attached to the milestone by number, which a rename doesn't change.
    func renameVersion(from oldName: String, to newName: String) {
        guard oldName != newName else { return }

        for (index, task) in tasks.enumerated() where task.milestoneTitle == oldName {
            tasks[index] = task.with(milestone: .some(newName))
        }
        if case .versions(var names) = taskFilters.versionScope, names.contains(oldName) {
            names.remove(oldName)
            names.insert(newName)
            taskFilters.versionScope = .versions(names)
        }
        if let state = versionStates.removeValue(forKey: oldName) {
            versionStates[newName] = state
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: the 3 new `ProjectInspectorModelTests` PASS.

- [ ] **Step 5: Make the header editable in `VersionDetailView`**

In `AppFeedback/Views/Inspector/VersionDetailView.swift`:

(a) Add the closure property, after `var onRelease: () -> Void`:

```swift
    /// Renames the version: PATCHes the GitHub milestone, then cascades the local copies of the old
    /// name. Supplied by `RootView`, which owns the cache context and the filter store.
    var onRename: (String) async throws -> Void
```

(b) Add the name state, alongside the existing `title`/`changelog` state:

```swift
    @State private var name: String = ""           // version number — the identity key
```

(c) A published version cannot be renamed (its git tag and release emails are already public), so gate the field and fold the name into `dirty`. Replace `private var dirty` (line 27) with:

```swift
    private var canRename: Bool { !version.releasePublished }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { canRename && trimmedName != version.name }
    private var dirty: Bool {
        title != version.releaseTitle || changelog != version.changelog || nameChanged
    }
    /// Apply is blocked on an empty name — but only when the name is what's being edited, so a
    /// published version (whose name field is read-only) can still have its changelog applied.
    private var canApply: Bool { dirty && !(canRename && trimmedName.isEmpty) }
```

(d) Replace the header's `Text(version.name)` (line 81) with an editable field that falls back to plain text once published:

```swift
                if canRename {
                    TextField("1.2.0", text: $name)
                        .textFieldStyle(.plain)
                        .font(.largeTitle.weight(.bold))
                        .disabled(working)
                } else {
                    Text(version.name).font(.largeTitle.weight(.bold))
                }
```

(e) Seed the state on appear — change line 68 to:

```swift
        .onAppear { changelog = version.changelog; title = version.releaseTitle; name = version.name }
```

(f) Gate the Apply button on `canApply` — change `.disabled(!dirty)` (line 60) to:

```swift
                    .disabled(!canApply || working)
```

(g) Rewrite `applyDetails()` (lines 199-204). The title/changelog half keeps its fire-and-forget behaviour; the rename half must hold the sheet open and surface failures, because a rename that silently fails looks exactly like one that succeeded:

```swift
    private func applyDetails() {
        let service = VersionService(store: versionStore)
        let newTitle = title, newChangelog = changelog, newName = trimmedName
        let mustRename = nameChanged
        let detailsChanged = newTitle != version.releaseTitle || newChangelog != version.changelog

        guard mustRename else {
            // Unchanged behaviour: no rename in play, so dismiss and write in the background.
            dismiss()
            Task { try? await service.updateDetails(repo: repo, version: version, title: newTitle, changelog: newChangelog) }
            return
        }

        working = true; errorMessage = nil
        Task {
            do {
                if detailsChanged {
                    try await service.updateDetails(repo: repo, version: version, title: newTitle, changelog: newChangelog)
                }
                try await onRename(newName)
                working = false
                dismiss()
            } catch {
                // Keep the sheet up: the name field still holds what the user typed, so they can fix
                // a duplicate and retry rather than lose the edit to a silent failure.
                errorMessage = error.localizedDescription
                working = false
            }
        }
    }
```

(h) `releaseFlow()` (line 207) opens the release flow, and a version can only be released while unpublished — i.e. exactly when a rename is possible. Renaming must happen before the release goes out so the tag and emails carry the new name. Replace its body with:

```swift
    private func releaseFlow() {
        let service = VersionService(store: versionStore)
        let newTitle = title, newChangelog = changelog, newName = trimmedName
        let mustRename = nameChanged
        working = true; errorMessage = nil
        Task {
            do {
                if newTitle != version.releaseTitle || newChangelog != version.changelog {
                    try await service.updateDetails(repo: repo, version: version, title: newTitle, changelog: newChangelog)
                }
                if mustRename { try await onRename(newName) }
                working = false
                onRelease()
            } catch {
                errorMessage = error.localizedDescription
                working = false
            }
        }
    }
```

- [ ] **Step 6: Thread `onRename` through the panel**

In `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`, add a property alongside the existing `onRelease`:

```swift
    var onRename: (ProjectVersion, String) async throws -> Void
```

and pass it into the sheet (lines 62-71):

```swift
                .sheet(item: $versionToOpen) { version in
                    NavigationStack {
                        VersionDetailView(repo: repo, version: version, inspector: inspector,
                                          versionStore: versionStore,
                                          onRelease: { versionToOpen = nil; onRelease(version) },
                                          onRename: { newName in try await onRename(version, newName) },
                                          onDeleteTask: onDeleteTask,
                                          onOpenFeedback: onOpenFeedback,
                                          canEmail: canEmail)
                    }
                }
```

- [ ] **Step 7: Supply the closure from `RootView`**

`RootView` is the only place that holds all three pieces the cascade needs (`cacheContext`, `filterStore`, `versionStore`) plus `inspector`. Add this method near `startRelease` (line 466) in `AppFeedback/App/RootView.swift`. It resolves the repo from the current selection itself, exactly as `startRelease` does — the panel's `onRelease` passes only the version, and `onRename` follows that shape:

```swift
    /// Renames a version end-to-end: GitHub milestone PATCH → local record + sent-email rows →
    /// cached issues + saved filters → the in-memory task list. Throws so the sheet can show why it
    /// failed and keep the user's typing.
    private func renameVersion(_ version: ProjectVersion, to newName: String) async throws {
        guard let repo = store.repos.first(where: { $0.id == selection?.repoId }) else { return }
        let oldName = version.name
        let cascade = VersionRenameCascade(cacheContext: cacheContext, filterStore: filterStore)
        try await VersionService(store: versionStore).rename(repo: repo, version: version, to: newName, cascade: cascade)
        inspector.renameVersion(from: oldName, to: version.name)
    }
```

Then add `onRename` to the `ProjectInspectorPanel(...)` construction in `inspectorPanel(for:)` (line 315), directly after `onRelease:` (line 322):

```swift
            onRelease: { startRelease($0) },
            onRename: { version, newName in try await renameVersion(version, to: newName) },
```

- [ ] **Step 8: Run the tests and build both platforms**

Expected: the full `AppFeedbackTests_macOS` suite passes apart from the ~11 known Keychain failures. Both the macOS and iOS schemes build.

- [ ] **Step 9: Commit**

```bash
git add AppFeedback/ViewModels/ProjectInspectorModel.swift AppFeedback/Views/Inspector/VersionDetailView.swift AppFeedback/Views/Inspector/ProjectInspectorPanel.swift AppFeedback/App/RootView.swift AppFeedbackTests/ProjectInspectorModelTests.swift
git commit -m "feat(versions): make a release's version number editable in the detail sheet"
```

---

### Task 7: Fix the silent milestone-clear (pre-existing data-loss bug)

`TaskDetailView.apply()` resolves the milestone by name and, on a lookup miss, passes `.some(nil)` — which `GitHubIssueWriter` turns into `payload["milestone"] = NSNull()`, **clearing the task's milestone on GitHub**. It fires on *any* Apply, including one that only changed priority.

This is live today, independent of renaming: `ProjectVersion` is CloudKit-synced while tasks come from GitHub, so on a fresh device where issues have loaded but versions have not yet synced, `versions` is empty and every task Apply silently clears its milestone. Renaming widens the window, so it is fixed here.

The fix is to distinguish three cases that the current `Int?` conflates: *clear it* (the user picked "None"), *set it*, and **don't touch it** (we can't resolve the version — say nothing about the milestone).

**Files:**
- Modify: `AppFeedback/Services/TaskService.swift:77-86` (`applyEdits` takes `Int??`)
- Modify: `AppFeedback/Views/Inspector/TaskDetailView.swift:190-200` (`apply`)
- Test: `AppFeedbackTests/TaskServiceTests.swift` (create if absent)

**Interfaces:**
- Consumes: the existing `GitHubIssueWriter.updateIssue(owner:repo:number:title:body:labels:milestoneNumber:state:token:)`, whose `milestoneNumber` is already an `Int??` where `.some(nil)` clears and `nil` means "don't send the key" (`GitHubIssueWriter.swift:56`, `:62-63`).
- Produces: `TaskService.applyEdits(repo:task:title:prose:status:priority:milestoneNumber:)` with `milestoneNumber: Int??`.

- [ ] **Step 1: Write the failing test**

The bug's payoff is in the PATCH body, so test at the writer boundary. Create `AppFeedbackTests/TaskServiceTests.swift` — or append to it if it already exists, matching its existing style:

```swift
import XCTest
@testable import AppFeedback

final class GitHubIssueWriterMilestoneTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    private func capturedPatchBody(milestoneNumber: Int??) async throws -> [String: Any]? {
        var captured: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            if let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
                captured = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else if let d = req.httpBody { captured = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"number":1}"#.data(using: .utf8)!)
        }
        let writer = GitHubIssueWriter(session: .mock)
        try await writer.updateIssue(owner: "o", repo: "r", number: 1, title: "t",
                                     milestoneNumber: milestoneNumber, token: "tok")
        return captured
    }

    /// `nil` (the outer optional) means "say nothing about the milestone" — the key must be absent,
    /// so GitHub leaves the task's existing milestone alone.
    func testOuterNilOmitsTheMilestoneKeyEntirely() async throws {
        let body = try await capturedPatchBody(milestoneNumber: nil)
        XCTAssertFalse(body?.keys.contains("milestone") ?? true,
                       "an unresolvable version must not touch the milestone")
    }

    /// `.some(nil)` is the explicit "None" choice — that, and only that, clears the milestone.
    func testSomeNilClearsTheMilestone() async throws {
        let body = try await capturedPatchBody(milestoneNumber: .some(nil))
        XCTAssertTrue(body?["milestone"] is NSNull)
    }

    func testSomeNumberSetsTheMilestone() async throws {
        let body = try await capturedPatchBody(milestoneNumber: .some(7))
        XCTAssertEqual(body?["milestone"] as? Int, 7)
    }
}
```

> **Note:** `GitHubIssueWriter` already has `init(session: URLSession = .shared)` (`GitHubIssueWriter.swift:37`), so `.mock` works with no production change. Its `updateIssue` already takes `milestoneNumber: Int??` and already treats `nil` as "omit the key" (`GitHubIssueWriter.swift:62-63`) — the writer is *correct*; it is `TaskService`/`TaskDetailView` that destroy the distinction before it gets here. These tests pin the writer's contract so it stays that way.

- [ ] **Step 2: Run the tests to verify they fail**

Expected: `testOuterNilOmitsTheMilestoneKeyEntirely` PASSES already (the writer is correct — it's the *callers* that are wrong), while the file may fail to compile if `GitHubIssueWriter` has no `session:` init. These tests pin the writer's contract; the real fix in Steps 3-4 is what stops `nil` being manufactured by the caller.

- [ ] **Step 3: Make `TaskService.applyEdits` pass the caller's intent through unchanged**

In `AppFeedback/Services/TaskService.swift`, change the signature and drop the `.some(...)` wrapping that currently destroys the distinction (line 85):

```swift
    /// Applies a full set of edits (title, notes, status, priority, version) in a single PATCH.
    /// Used by the task detail's Apply action so everything commits atomically.
    ///
    /// `milestoneNumber` is a double optional and the distinction is load-bearing:
    /// `.some(n)` sets the milestone, `.some(nil)` clears it, and `nil` leaves it untouched.
    /// Never collapse an unresolvable version into `.some(nil)` — that silently clears the task's
    /// milestone on GitHub.
    func applyEdits(repo: ProductConfig, task: TaskItem, title: String, prose: String,
                    status: TaskStatus, priority: TaskPriority, milestoneNumber: Int??) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await ensureLabels(repo: repo, token: token)
        let body = FeedbackTaskRefParser.upsert(into: prose, refs: task.feedbackRefs)
        let state = (status == .done) ? "closed" : "open"
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            title: title, body: body, labels: Self.labels(status: status, priority: priority),
            milestoneNumber: milestoneNumber, state: state, token: token)
    }
```

- [ ] **Step 4: Stop `TaskDetailView` manufacturing a clear**

In `AppFeedback/Views/Inspector/TaskDetailView.swift`, add this above `apply()`:

```swift
    /// What Apply should do to the task's milestone.
    ///
    /// The third case is the one that matters: if the task names a version we can't resolve — its
    /// `ProjectVersion` hasn't synced from CloudKit yet, or it was renamed on GitHub behind our back —
    /// we must say *nothing* about the milestone. Collapsing that into "clear it" silently wipes the
    /// task's milestone on GitHub on any Apply, even one that only changed priority.
    private enum MilestoneUpdate {
        case clear                 // the user explicitly picked "None"
        case set(Int)              // resolved to a real milestone
        case leaveAlone            // unresolvable — don't touch it
    }

    private var milestoneUpdate: MilestoneUpdate {
        guard let versionName else { return .clear }
        guard let number = versions.first(where: { $0.name == versionName })?.milestoneNumber else {
            return .leaveAlone
        }
        return .set(number)
    }
```

and rewrite the head of `apply()` (line 191-197) so the optimistic UI update and the GitHub write agree on that decision:

```swift
    private func apply() {
        let milestoneArgument: Int??
        let optimisticMilestone: String??
        switch milestoneUpdate {
        case .clear:
            milestoneArgument = .some(nil); optimisticMilestone = .some(nil)
        case .set(let number):
            milestoneArgument = .some(number); optimisticMilestone = .some(versionName)
        case .leaveAlone:
            milestoneArgument = nil; optimisticMilestone = nil
        }

        let newBody = FeedbackTaskRefParser.upsert(into: notes, refs: task.feedbackRefs)
        let previous = inspector.applyOptimistic(number: task.number, status: status, priority: priority,
                                                 title: title, body: newBody, milestone: optimisticMilestone)
        dismiss()
        Task {
            do {
                try await service.applyEdits(repo: repo, task: task, title: title, prose: notes,
                                             status: status, priority: priority, milestoneNumber: milestoneArgument)
```

Leave the rest of `apply()`'s `Task { ... }` body (the `catch`/revert path) exactly as it is.

- [ ] **Step 5: Run the tests to verify they pass**

Expected: the 3 new milestone tests PASS; the full suite is green apart from the ~11 known Keychain failures. Both platforms build.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/TaskService.swift AppFeedback/Views/Inspector/TaskDetailView.swift AppFeedbackTests/TaskServiceTests.swift
git commit -m "fix(tasks): don't clear a task's GitHub milestone when its version can't be resolved

applyEdits collapsed an unresolvable version name into .some(nil), which
GitHubIssueWriter sends as milestone: null — wiping the task's milestone on
any Apply. Distinguish 'clear' from 'leave alone'."
```

---

### Task 8: Verify the whole flow in the running app

Tests cover the pieces; this proves the feature. Use the `verify` skill (or the `run` skill to drive the app).

**Files:** none — this task changes no code unless it finds a defect.

- [ ] **Step 1: Build and launch the macOS app**

Use the zcode skill to build and run the macOS scheme.

- [ ] **Step 2: Rename an unpublished version and confirm the cascade**

With a product that has a version carrying at least one task:
1. Open the version from the inspector's Versions section.
2. Confirm the version number is now an editable field, and change it (e.g. `1.2.0` → `1.3.0`).
3. Apply. Confirm the sheet stays up while it works, then dismisses.
4. Confirm: the version row shows the new name; **its task count is unchanged** (this is the cascade working — a broken cascade shows 0 tasks); the tasks still appear under "Tasks in this version"; and the version's state pill (new/wip) has not regressed.
5. Confirm on GitHub that the milestone title changed and its issues are **still attached**.

- [ ] **Step 3: Confirm validation**

Re-open the version, clear the name → Apply is disabled. Type the name of another existing version → Apply reports "This product already has a version named …" and **the sheet stays open with your typing intact**.

- [ ] **Step 4: Confirm a published version cannot be renamed**

Open a released version. Its number must render as plain text, not a field.

- [ ] **Step 5: Confirm the milestone-clear fix**

Open a task that belongs to a version, change only its priority, Apply. Confirm on GitHub that the issue **still has its milestone**.

- [ ] **Step 6: Report**

State plainly what was exercised and what was observed. If anything failed, fix it and re-verify rather than reporting it as done.

---

## Notes for the implementer

- **`VersionScope` is `Codable`** and persisted as JSON inside `RepoFilterPreference.taskFiltersData`. Renaming rewrites the *values* inside `.versions(Set<String>)`, not the enum shape — no migration is needed.
- **Do not add `@Attribute(.unique)`** to `ProjectVersion.name`. CloudKit forbids it; that's why `VersionNameValidator` exists.
- **Do not try to rename the git tag** of a published release. Deleting and recreating a published tag breaks anyone who fetched it. This is why Task 5 blocks rename once `releasePublished`.
- **`updateRelease` cannot PATCH a Release's name** (it takes only `body`/`draft`), and the created Release's id is discarded at `VersionService.swift:73`. Out of scope — noted in the spec.
