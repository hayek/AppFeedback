# Phase 0 — Repo→Product Rename + CloudKit Migration Shim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `Repo` `@Model`/`RepoConfig`/`RepoStore` triad to `Product`/`ProductConfig`/`ProductStore` (adding the four new App-Store/email config fields as config-only) and add `MailAccount.feedbackProductID`, behind an idempotent CloudKit data-copy migration that preserves all existing synced data, with zero behavior change beyond the rename.

**Architecture:** A SwiftData entity rename starts an empty `CD_Product` CloudKit record type and orphans existing `CD_Repo` rows, so we keep a read-only legacy `Repo` `@Model` registered for one release and run an idempotent, `AppStorage`-flag-gated `ProductMigration.run(context:defaults:)` (in `AppFeedbackApp.init()` when not testing, exactly like `MailAccountMigration`) that copies each `Repo` → `Product` preserving `id`/`owner`/`repo` and every field. Because every foreign key is the `owner/repo` string pair (`CachedIssue`, `MailThread`, `RepoFilterPreference`, `RepoFetchState`, Keychain `accountKey`) and `SidebarSelection` keys by `id` — both preserved verbatim — nothing downstream breaks. The `Repo*`-prefixed persisted companions (`RepoFilterPreference`, `RepoFetchState`) keep their type names; only the model triad and user-facing strings change.

> **No `VersionedSchema`/`SchemaMigrationPlan`.** The live container is built with **two `ModelConfiguration`s (`cloudConfig` + `localConfig`) and NO `migrationPlan:` argument**, so a `SchemaMigrationPlan` would never fire — it is dead code. We ship ONLY the `ProductMigration.run` data copy, invoked directly from `init()`. Do not add a `migrationPlan:` to the container and do not create a `ProductSchema.swift`.

> **The rename is ONE atomic unit (Tasks 3–7).** Renaming the `Repo`/`RepoConfig`/`RepoStore` triad cannot be done file-by-file with a green tree at each step — once `RepoConfig.swift`/`RepoStore.swift` are removed (Tasks 3–4), the whole target stops compiling until `AppFeedbackApp.swift` is fixed (Task 7). Treat Tasks 3–7 as a single rename unit whose **first green build + single atomic commit lands at Task 7**. In the intermediate tasks (3–6) the build is **expected RED**; do NOT run any per-task `-only-testing` invocation mid-rename — there is nothing to link until Task 7. The migration-logic test (Task 6) is *written* against the new `Product`/`Repo` types but *run* only at the unit's green point (Task 7, then again with the full suite in Task 8). Tasks 1 and 2 are the exception: each leaves the tree green (the old `Repo` and the new `Product` coexist) and is committed on its own.

**Tech Stack:** Swift, SwiftUI, SwiftData (+CloudKit), CryptoKit, async/await actors; xcodegen project; Swift Testing/XCTest in target AppFeedbackTests_macOS.

## Global Constraints
- iOS deployment floor 18.6; macOS floor 15.0. Single `AppFeedback` target → `AppFeedback_iOS` / `AppFeedback_macOS`.
- xcodegen-generated project: new `.swift` files in any subfolder are auto-picked up; NEVER hand-edit the pbxproj. Stage narrowly with explicit paths in every `git add` — a broad `git add` sweeps the user's unrelated WIP + untracked files into the pbxproj.
- Build/test via the zcode skill; treat `xcodebuild` as ground truth (the zcode /api/test summary can mask a hard crash). Test target is `AppFeedbackTests_macOS`; **use scheme `AppFeedback_macOS` for every build and test command** (the only exception is the iOS-platform compile check in Task 10, which must use scheme `AppFeedback_iOS` to target iOS — there is no iOS test target). Tests run in-memory with `cloudKitDatabase: .none`.
- ~11 pre-existing test failures (KeychainServicePerAccountTests + GitHubAccountStoreTests) come from the test host having no Keychain — they are NOT regressions; do not "fix" them.
- Any new `@Model` must be registered in BOTH places in `AppFeedbackApp.init()`: the `isTesting` single-config container AND the cloud/local Schema split (`cloudSchema` for CloudKit-synced types, `localSchema` for device-only caches).
- Any new @Observable store must bump its `version` counter on `NSPersistentStoreRemoteChange` AND `cloudKitImportSucceeded`, not only on local saves (otherwise cross-device data stays invisible until relaunch).
- Do NOT assert a store's `version` across coordinator polls in tests — in-memory SwiftData posts async remote-change notifications; assert version only in synchronous store-level tests.
- Frequent commits. Every commit message ends with the trailer:
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
- DRY, YAGNI, TDD (red→green→commit). Each task ends with an independently testable deliverable.

## Shared Contracts (authoritative across all phases)
```swift
// ── Phase 0 establishes (rename + migration) ──────────────────────────────
@Model final class Product {            // renamed from Repo; SAME fields preserved (id, displayName, owner, repo, hiddenAppNames, appColors, colorHex, createdAt, mirrorEmailsToGitHub, redactEmailAddresses, connectedRepoOwner, connectedRepoName) PLUS:
    var appStoreIssuerID: String?
    var appStoreKeyID: String?
    var appStoreAppAppleID: String?     // opaque ASC app id (numeric string); nil ⇒ App Store source off
    var feedbackInboxAccountID: UUID?   // → a MailAccount whose feedbackProductID == self.id; nil ⇒ email source off
}
struct ProductConfig { /* renamed from RepoConfig; same fields + the four new ones above */ }
@MainActor @Observable final class ProductStore {   // renamed from RepoStore
    private(set) var repos: [ProductConfig]          // stored name kept (least churn)
    var products: [ProductConfig] { repos }          // alias — PREFER `products` in all new code
    func add(_ config: ProductConfig); func update(_ config: ProductConfig)   // carry the 4 new fields
    // Test seam: an in-memory init/factory other phases reuse to seed products (Phase 0 documents the exact call).
}
// MailAccount gains exactly one stored field:
//   var feedbackProductID: UUID?       // nil ⇒ legacy reply-mirror account; non-nil ⇒ feedback inbox for that product
//   (the inbox-vs-reply-mirror "role" is DERIVED from feedbackProductID != nil; do NOT add a stored role.)
// Migration: a single idempotent, AppStorage-gated `ProductMigration.run(context:defaults:)` invoked from
//   AppFeedbackApp.init() when not testing (like MailAccountMigration). It copies each legacy Repo → Product,
//   preserving id/owner/repo and all fields. A read-only legacy `Repo` @Model stays in the schema one release.
//   DO NOT ship a VersionedSchema/SchemaMigrationPlan — the container has no migrationPlan: and it would be dead code.
// Persisted Repo*-prefixed companions (RepoFilterPreference, RepoFetchState) KEEP their type names (no extra CloudKit migration); only user-facing strings say "Product".

// ── Phase 1 establishes (source contract + filters + badges) ──────────────
enum FeedbackSource: String, Codable, CaseIterable, Sendable {
    case sdk       = "sdk"
    case appStore  = "app-store"
    case email     = "email"
}
// Body-marker KEYS added to the SDK BodyMarkers vocabulary (exact strings):
//   "source","rating","reviewerNickname","territory","reviewId","reviewCreatedAt","fromAddress","messageId"
// GitHub LABELS (exact strings): "source:app-store","source:email","rating:1"…"rating:5"
// CachedIssue gains (local schema, additive): var source: String?   var rating: Int?
//   (nil source ⇒ treat as .sdk for legacy issues)
// FeedbackIssue gains: var source: FeedbackSource   var rating: Int?   (toFeedbackIssue maps source ?? .sdk)
// RepoFilterPreference gains persisted: sources stored as [String] ⇄ Set<FeedbackSource>; default = all cases.

// ── Phase 3 establishes (App Store read path) ─────────────────────────────
@Model final class AppStoreReviewMirror {   // CloudKit-synced
    var reviewId: String
    var productID: UUID
    var issueNumber: Int
    var contentHash: String        // SHA-256 hex of normalized rating+\n+title+\n+body
    var responseState: String?     // nil | "PENDING_PUBLISH" | "PUBLISHED"
    var responseId: String?
}
protocol AppStoreConnectClientProtocol: Sendable {
    func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage
    func listApps() async throws -> [ASCApp]
    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse  // POST upsert
    func deleteResponse(responseId: String) async throws
}
struct ASCReviewPage: Sendable { let reviews: [ASCReview]; let nextCursor: String?; let rateRemaining: Int? }
struct ASCReview: Sendable { let id: String; let rating: Int; let title: String?; let body: String?; let reviewerNickname: String?; let createdDate: Date; let territory: String; let response: ASCResponse? }
struct ASCResponse: Sendable { let id: String; let responseBody: String; let state: String; let lastModifiedDate: Date }
struct ASCApp: Sendable { let id: String; let bundleId: String; let name: String }
actor AppStoreConnectAuth { init(issuerID: String, keyID: String, p8PEM: String); func token() async throws -> String }  // ES256, exp≤20m, cached ~15m
actor AppStoreReviewCoordinator { /* poll loop, incremental + periodic full re-scan */ }
@MainActor final class AppStoreReviewCoordinatorRegistry { /* one coordinator per product-with-ASC; mirrors MailSyncCoordinatorRegistry */ }
protocol FeedbackSourceIngestor: Sendable { func poll() async throws }   // thin seam; AppStoreReviewCoordinator conforms

// ── Phase 4 establishes (App Store write-back) ────────────────────────────
// Inspector "Respond on App Store" panel for feedback where source == .appStore, keyed by the issue's reviewId marker.
// Uses AppStoreConnectClientProtocol.createOrUpdateResponse / deleteResponse; updates AppStoreReviewMirror.responseState/responseId.

// ── Phase 5 establishes (email feedback source) ───────────────────────────
final class MailToFeedbackMirror { /* detached Task in MailSyncCoordinator.pollOnce(); gated on feedbackProductID != nil */ }
//   thread root → new issue (label source:email, markers source/fromAddress/messageId); reply in known thread → comment.
```

---

## File Structure

### Create
- `AppFeedback/Models/Product.swift` — the renamed `Repo` `@Model` (all original fields preserved verbatim + the four new optional source-config fields). CloudKit-synced.
- `AppFeedback/Models/LegacyRepo.swift` — the read-only legacy `Repo` `@Model` kept for one release so existing `CD_Repo` CloudKit rows still load and can be migrated.
- `AppFeedback/Models/ProductConfig.swift` — the renamed `RepoConfig` DTO (same fields + the four new ones).
- `AppFeedback/Services/ProductStore.swift` — the renamed `RepoStore` `@Observable @MainActor` store (operates on `Product`; `add`/`update`/`remove`/`reload` carry the four new fields; adds the computed `products` alias).
- `AppFeedback/Services/ProductMigration.swift` — `enum ProductMigration` with `run(context:defaults:)`: idempotent, `AppStorage`/`UserDefaults`-flag-gated data-copy that creates a `Product` for every legacy `Repo` lacking a matching `Product` (same `id`/`owner`/`repo` + all fields), retiring the `Repo` row only on success. There is NO `ProductSchema.swift`/`VersionedSchema`/`SchemaMigrationPlan` — the live container has two `ModelConfiguration`s and no `migrationPlan:`, so such a plan would never fire (dead code); the data copy is invoked directly from `init()`.
- `AppFeedbackTests/ProductMigrationTests.swift` — seeds legacy `Repo` rows, runs `ProductMigration`, asserts `Product` with identical `id`/`owner`/`repo`, foreign-key resolution (`CachedIssue`/`MailThread`/`RepoFilterPreference` by `owner/repo`), and idempotency on re-run.
- `AppFeedbackTests/ProductStoreTests.swift` — the renamed `RepoStoreTests` plus a test that the four new fields round-trip through `add`/`reload`/`update`.

### Modify
- `AppFeedback/Models/Repo.swift` — DELETE (content moves to `Product.swift`; legacy declaration moves to `LegacyRepo.swift`).
- `AppFeedback/Models/RepoConfig.swift` — DELETE (content moves to `ProductConfig.swift`).
- `AppFeedback/Services/RepoStore.swift` — DELETE (content moves to `ProductStore.swift`).
- `AppFeedback/Models/MailAccount.swift` — add stored `var feedbackProductID: UUID? = nil` + init param.
- `AppFeedback/App/AppFeedbackApp.swift` — register `Product` + legacy `Repo` in both the test container and `cloudSchema`; rename `RepoStore`→`ProductStore`, `RepoConfig`→`ProductConfig`, `RepoConfigSnapshot`→`ProductConfigSnapshot`; run `ProductMigration.run(context:)` when not testing.
- `AppFeedback/Services/KeychainService.swift` — change `RepoConfig` param types to `ProductConfig` (key string `owner/repo` unchanged).
- `AppFeedback/Services/IssueLoader.swift`, `AppFeedback/Services/ReleaseNotificationService.swift`, `AppFeedback/Services/TaskService.swift`, `AppFeedback/Services/VersionService.swift` — `RepoConfig`→`ProductConfig`.
- `AppFeedback/Services/Mail/MailToGitHubMirror.swift` — `RepoStore`→`ProductStore`, `RepoConfig`→`ProductConfig`.
- `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`, `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift` — `RepoStore`→`ProductStore`.
- `AppFeedback/App/RootView.swift` — `RepoStore`→`ProductStore`, `RepoConfig`→`ProductConfig`.
- `AppFeedback/Views/Settings/SettingsView.swift` — `RepoStore`→`ProductStore`; `SettingsTab.repos`→`.products`; user-facing "Repository/Repositories/Repo" strings → "Product/Products".
- `AppFeedback/Views/Settings/AddEditRepoView.swift` — `RepoStore`/`RepoConfig`→`ProductStore`/`ProductConfig`; carry the four new fields when building the config; user-facing strings → "Product".
- `AppFeedback/Views/Sidebar/SidebarView.swift`, `AppFeedback/Views/Sidebar/RepoSectionView.swift` — `RepoStore`→`ProductStore`; user-facing "Repo" strings → "Product".
- `AppFeedback/Views/Inspector/CreateTaskSheet.swift`, `AppFeedback/Views/Inspector/ProjectInspectorPanel.swift`, `AppFeedback/Views/Inspector/ReleaseRecipientsSheet.swift`, `AppFeedback/Views/Inspector/TaskDetailView.swift`, `AppFeedback/Views/Inspector/VersionDetailView.swift` — `RepoConfig`→`ProductConfig`.
- `AppFeedbackTests/RepoStoreTests.swift` — DELETE (replaced by `ProductStoreTests.swift`).
- `AppFeedbackTests/IssueLoaderTests.swift`, `AppFeedbackTests/ModelsTests.swift` — `RepoConfig`→`ProductConfig` (both reference the DTO, not the `@Model`, so the `sed` rename in Task 3 covers them; `ModelsTests` additionally GAINS the new Product field-default test in Task 1 and the `MailAccount.feedbackProductID` tests in Task 5).

---

## Tasks

### Task 1: Create `Product` model (renamed `Repo` + 4 new config fields)

**Files:**
- Create `AppFeedback/Models/Product.swift`
- Test `AppFeedbackTests/ModelsTests.swift` (add a Product field-default test; full conversion of the file's old `Repo` refs happens in Task 3)

**Interfaces:**
- Produces: `@Model final class Product` with stored fields `id: UUID`, `displayName: String`, `owner: String`, `repo: String`, `hiddenAppNames: [String]`, `appColors: [String: String]`, `colorHex: String?`, `createdAt: Date`, `mirrorEmailsToGitHub: Bool`, `redactEmailAddresses: Bool`, `connectedRepoOwner: String?`, `connectedRepoName: String?`, `appStoreIssuerID: String?`, `appStoreKeyID: String?`, `appStoreAppAppleID: String?`, `feedbackInboxAccountID: UUID?`; and a designated `init` whose first 12 params exactly mirror today's `Repo.init` (so call sites need no reordering) followed by the four new optional params defaulting to `nil`.
- Consumes: nothing.

- [ ] **Step 1: Write a failing field-default test.** Append to `AppFeedbackTests/ModelsTests.swift`:
  ```swift
  func test_productDefaults_newSourceFieldsAreNil() {
      let p = Product(displayName: "P", owner: "o", repo: "r")
      XCTAssertNil(p.appStoreIssuerID)
      XCTAssertNil(p.appStoreKeyID)
      XCTAssertNil(p.appStoreAppAppleID)
      XCTAssertNil(p.feedbackInboxAccountID)
      XCTAssertTrue(p.mirrorEmailsToGitHub)
      XCTAssertTrue(p.redactEmailAddresses)
  }
  ```
- [ ] **Step 2: Build to confirm the test fails (RED).** Run the zcode build (scheme `AppFeedback_macOS`). Expect FAIL: "Cannot find 'Product' in scope".
- [ ] **Step 3: Create `AppFeedback/Models/Product.swift`** with the renamed model. The first 12 init params are byte-for-byte the existing `Repo.init` so no caller has to reorder arguments:
  ```swift
  import Foundation
  import SwiftData

  @Model
  final class Product {
      var id: UUID = UUID()
      var displayName: String = ""
      var owner: String = ""
      var repo: String = ""
      var hiddenAppNames: [String] = []
      var appColors: [String: String] = [:]
      /// Optional sidebar accent color for this product, as a 6-digit hex string. `nil` = default.
      var colorHex: String? = nil
      var createdAt: Date = Date()
      /// When true, every email this app sends or receives for an issue in this product is
      /// also posted as a comment on the GitHub issue.
      var mirrorEmailsToGitHub: Bool = true
      /// When true, sender addresses in mirrored comments are redacted to `a***@host.tld`.
      var redactEmailAddresses: Bool = true
      var connectedRepoOwner: String? = nil
      var connectedRepoName: String? = nil
      // App Store source (the .p8 lives in Keychain, never here / never in CloudKit):
      var appStoreIssuerID: String? = nil
      var appStoreKeyID: String? = nil
      /// Opaque ASC app id (numeric string); nil ⇒ App Store source off.
      var appStoreAppAppleID: String? = nil
      /// → a MailAccount whose feedbackProductID == self.id; nil ⇒ email source off.
      var feedbackInboxAccountID: UUID? = nil

      init(
          id: UUID = UUID(),
          displayName: String,
          owner: String,
          repo: String,
          hiddenAppNames: [String] = [],
          appColors: [String: String] = [:],
          colorHex: String? = nil,
          createdAt: Date = Date(),
          mirrorEmailsToGitHub: Bool = true,
          redactEmailAddresses: Bool = true,
          connectedRepoOwner: String? = nil,
          connectedRepoName: String? = nil,
          appStoreIssuerID: String? = nil,
          appStoreKeyID: String? = nil,
          appStoreAppAppleID: String? = nil,
          feedbackInboxAccountID: UUID? = nil
      ) {
          self.id = id
          self.displayName = displayName
          self.owner = owner
          self.repo = repo
          self.hiddenAppNames = hiddenAppNames
          self.appColors = appColors
          self.colorHex = colorHex
          self.createdAt = createdAt
          self.mirrorEmailsToGitHub = mirrorEmailsToGitHub
          self.redactEmailAddresses = redactEmailAddresses
          self.connectedRepoOwner = connectedRepoOwner
          self.connectedRepoName = connectedRepoName
          self.appStoreIssuerID = appStoreIssuerID
          self.appStoreKeyID = appStoreKeyID
          self.appStoreAppAppleID = appStoreAppAppleID
          self.feedbackInboxAccountID = feedbackInboxAccountID
      }
  }
  ```
- [ ] **Step 4: Do NOT delete `Repo.swift` yet.** `Repo` is still referenced everywhere; it is converted to the legacy declaration in Task 2 and references are migrated in later tasks. Build will still fail at this point only inside `ModelsTests` if it references `Product`; that's expected to compile now. Run the zcode build (scheme `AppFeedback_macOS`) and expect it to SUCCEED for app sources (both `Repo` and `Product` exist side by side — no name clash because the entity-name conflict is resolved in Task 2's note).
  > NOTE: Two `@Model` types with the same SwiftData entity name in one container throw at runtime, never at compile time. `Repo` and `Product` are *different* entity names, so they coexist fine. We do not register `Product` in any container until Task 7.
- [ ] **Step 5: Commit (RED→partial GREEN).** Stage only the two files and commit:
  ```
  git add AppFeedback/Models/Product.swift AppFeedbackTests/ModelsTests.swift
  git commit -m "feat(model): add Product @Model (renamed Repo + 4 source-config fields)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2: Demote `Repo` to a read-only legacy `@Model`

**Files:**
- Create `AppFeedback/Models/LegacyRepo.swift`
- Modify `AppFeedback/Models/Repo.swift` (delete)

**Interfaces:**
- Produces: legacy `@Model final class Repo` kept registered for one release so existing `CD_Repo` rows still load for migration. SAME fields/init as before (no new fields — legacy rows have none).
- Consumes: nothing.

- [ ] **Step 1: Create `AppFeedback/Models/LegacyRepo.swift`** containing the *current* `Repo` declaration verbatim (the 12-field model exactly as it exists today in `Repo.swift`), with a header doc comment:
  ```swift
  import Foundation
  import SwiftData

  /// LEGACY — read-only. Kept registered for one release so existing CloudKit `CD_Repo`
  /// rows still load and can be copied into `Product` by `ProductMigration`. Remove the
  /// release after Phase 0 ships. Do NOT add new fields here.
  @Model
  final class Repo {
      var id: UUID = UUID()
      var displayName: String = ""
      var owner: String = ""
      var repo: String = ""
      var hiddenAppNames: [String] = []
      var appColors: [String: String] = [:]
      var colorHex: String? = nil
      var createdAt: Date = Date()
      var mirrorEmailsToGitHub: Bool = true
      var redactEmailAddresses: Bool = true
      var connectedRepoOwner: String? = nil
      var connectedRepoName: String? = nil

      init(
          id: UUID = UUID(),
          displayName: String,
          owner: String,
          repo: String,
          hiddenAppNames: [String] = [],
          appColors: [String: String] = [:],
          colorHex: String? = nil,
          createdAt: Date = Date(),
          mirrorEmailsToGitHub: Bool = true,
          redactEmailAddresses: Bool = true,
          connectedRepoOwner: String? = nil,
          connectedRepoName: String? = nil
      ) {
          self.id = id
          self.displayName = displayName
          self.owner = owner
          self.repo = repo
          self.hiddenAppNames = hiddenAppNames
          self.appColors = appColors
          self.colorHex = colorHex
          self.createdAt = createdAt
          self.mirrorEmailsToGitHub = mirrorEmailsToGitHub
          self.redactEmailAddresses = redactEmailAddresses
          self.connectedRepoOwner = connectedRepoOwner
          self.connectedRepoName = connectedRepoName
      }
  }
  ```
- [ ] **Step 2: Delete the old `Repo.swift`** so there is exactly one `Repo` declaration:
  ```
  git rm AppFeedback/Models/Repo.swift
  ```
- [ ] **Step 3: Build `AppFeedback_macOS`.** Expect SUCCESS (the declaration just moved files; xcodegen auto-picks up the new file). All existing `Repo` call sites still compile against the legacy declaration.
- [ ] **Step 4: Commit.**
  ```
  git add AppFeedback/Models/LegacyRepo.swift
  git commit -m "refactor(model): move Repo to LegacyRepo.swift (read-only shim)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3: Rename `RepoConfig` → `ProductConfig` (with 4 new fields)

**Files:**
- Create `AppFeedback/Models/ProductConfig.swift`
- Modify `AppFeedback/Models/RepoConfig.swift` (delete)
- Modify `AppFeedback/Services/KeychainService.swift`
- Modify `AppFeedback/Services/IssueLoader.swift`, `AppFeedback/Services/ReleaseNotificationService.swift`, `AppFeedback/Services/TaskService.swift`, `AppFeedback/Services/VersionService.swift`
- Modify `AppFeedback/Services/Mail/MailToGitHubMirror.swift`
- Modify `AppFeedback/Views/Inspector/CreateTaskSheet.swift`, `ProjectInspectorPanel.swift`, `ReleaseRecipientsSheet.swift`, `TaskDetailView.swift`, `VersionDetailView.swift`
- Modify `AppFeedbackTests/IssueLoaderTests.swift`, `AppFeedbackTests/ModelsTests.swift`

**Interfaces:**
- Produces: `struct ProductConfig: Identifiable, Codable, Hashable, Sendable` with the existing `RepoConfig` fields PLUS `appStoreIssuerID: String?`, `appStoreKeyID: String?`, `appStoreAppAppleID: String?`, `feedbackInboxAccountID: UUID?` (all defaulting to `nil`).
- Consumes: nothing.
- NOTE: `KeychainService.accountKey(for:)` returns `"\(repo.owner)/\(repo.repo)"`; renaming the param type to `ProductConfig` preserves the exact key string, so Keychain tokens keep resolving.

- [ ] **Step 1: Create `AppFeedback/Models/ProductConfig.swift`:**
  ```swift
  import Foundation

  struct ProductConfig: Identifiable, Codable, Hashable, Sendable {
      let id: UUID
      var displayName: String
      var owner: String
      var repo: String
      var mirrorEmailsToGitHub: Bool
      var redactEmailAddresses: Bool
      var connectedRepoOwner: String?
      var connectedRepoName: String?
      /// Optional sidebar accent color, as a 6-digit hex string. `nil` = default.
      var colorHex: String?
      // App Store source config (Issuer/Key IDs + Apple app id are not secret; the .p8 lives in Keychain).
      var appStoreIssuerID: String?
      var appStoreKeyID: String?
      var appStoreAppAppleID: String?
      // Email feedback-inbox config: the MailAccount providing this product's feedback inbox.
      var feedbackInboxAccountID: UUID?

      init(
          id: UUID = UUID(),
          displayName: String,
          owner: String,
          repo: String,
          mirrorEmailsToGitHub: Bool = true,
          redactEmailAddresses: Bool = true,
          connectedRepoOwner: String? = nil,
          connectedRepoName: String? = nil,
          colorHex: String? = nil,
          appStoreIssuerID: String? = nil,
          appStoreKeyID: String? = nil,
          appStoreAppAppleID: String? = nil,
          feedbackInboxAccountID: UUID? = nil
      ) {
          self.id = id
          self.displayName = displayName
          self.owner = owner
          self.repo = repo
          self.mirrorEmailsToGitHub = mirrorEmailsToGitHub
          self.redactEmailAddresses = redactEmailAddresses
          self.connectedRepoOwner = connectedRepoOwner
          self.connectedRepoName = connectedRepoName
          self.colorHex = colorHex
          self.appStoreIssuerID = appStoreIssuerID
          self.appStoreKeyID = appStoreKeyID
          self.appStoreAppAppleID = appStoreAppAppleID
          self.feedbackInboxAccountID = feedbackInboxAccountID
      }
  }
  ```
- [ ] **Step 2: Delete the old DTO.**
  ```
  git rm AppFeedback/Models/RepoConfig.swift
  ```
- [ ] **Step 3: Rename the type in `KeychainService.swift`.** Change all four method signatures and the helper from `RepoConfig` to `ProductConfig` (key string unchanged). Run, from the repo root:
  ```
  sed -i '' 's/RepoConfig/ProductConfig/g' AppFeedback/Services/KeychainService.swift
  ```
  (Verify afterward with `rg -n RepoConfig AppFeedback/Services/KeychainService.swift` → no matches.)
- [ ] **Step 4: Rename `RepoConfig` → `ProductConfig` in the remaining non-store source files** (the store itself is handled in Task 4). Do NOT touch `RepoStore.swift` here. Run:
  ```
  for f in \
    AppFeedback/Services/IssueLoader.swift \
    AppFeedback/Services/ReleaseNotificationService.swift \
    AppFeedback/Services/TaskService.swift \
    AppFeedback/Services/VersionService.swift \
    AppFeedback/Services/Mail/MailToGitHubMirror.swift \
    AppFeedback/Views/Inspector/CreateTaskSheet.swift \
    AppFeedback/Views/Inspector/ProjectInspectorPanel.swift \
    AppFeedback/Views/Inspector/ReleaseRecipientsSheet.swift \
    AppFeedback/Views/Inspector/TaskDetailView.swift \
    AppFeedback/Views/Inspector/VersionDetailView.swift \
    AppFeedbackTests/IssueLoaderTests.swift; do
    sed -i '' 's/RepoConfig/ProductConfig/g' "$f"
  done
  ```
- [ ] **Step 5: Rename `RepoConfig` → `ProductConfig` in `ModelsTests.swift`** (it constructs the DTO directly):
  ```
  sed -i '' 's/RepoConfig/ProductConfig/g' AppFeedbackTests/ModelsTests.swift
  ```
  > RENAME-UNIT NOTE: From here through Task 7 the tree is **expected RED** — this is the atomic `Repo`→`Product` rename unit (see the Architecture note). Do NOT run a `-only-testing` invocation now; nothing links until Task 7.
- [ ] **Step 6: Build `AppFeedback_macOS` to scope remaining work (do NOT treat the failure as a defect).** Expect FAIL only inside `RepoStore.swift` / `AppFeedbackApp.swift` (still referencing `RepoConfig`) — those are renamed in Task 4 and Task 7. If any OTHER file still references `RepoConfig`, run `rg -n RepoConfig AppFeedback AppFeedbackTests` and `sed`-rename it before proceeding.
- [ ] **Step 7: No commit here.** This task is mid-way through the atomic rename unit; the tree does not compile. The first green build + single commit for the whole rename lands at **Task 7, Step 7**. Continue straight to Task 4.

---

### Task 4: Rename `RepoStore` → `ProductStore` (carry the 4 new fields)

**Files:**
- Create `AppFeedback/Services/ProductStore.swift`
- Modify `AppFeedback/Services/RepoStore.swift` (delete)
- Modify `AppFeedback/Services/Mail/MailToGitHubMirror.swift`, `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`, `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift`, `AppFeedback/App/RootView.swift`, `AppFeedback/Views/Settings/SettingsView.swift`, `AppFeedback/Views/Settings/AddEditRepoView.swift`, `AppFeedback/Views/Sidebar/SidebarView.swift`, `AppFeedback/Views/Sidebar/RepoSectionView.swift`

**Interfaces:**
- Produces: `@Observable @MainActor final class ProductStore` with `private(set) var repos: [ProductConfig]`, a computed alias `var products: [ProductConfig] { repos }`, `init(context:hiddenAppStore:)`, `add(_:)`, `update(_:)`, `remove(id:) async`, `hideApp(_:in:)`, `unhideAllApps(in:)`, `hiddenAppsFor(_:)`, `setColor(_:forApp:in:)`, `colorHexFor(app:in:)`, `setColor(_:forRepo:)`, `colorHexFor(repo:)` — identical public surface to `RepoStore`, operating on `Product`, with `add`/`update`/`reload`/`remove` carrying the four new fields. The stored `repos` property name is intentionally kept (existing call sites use `store.repos`); only the type renamed. **All NEW code (Phases 1–5) must read `store.products`, not `store.repos`.**
- Consumes: `Product` (Task 1), `ProductConfig` (Task 3), `KeychainService.delete(for: ProductConfig)` (Task 3), `HiddenAppStore` (unchanged), `NotificationCenter.cloudKitImportSucceeded` (unchanged, defined in this file).

- [ ] **Step 1: Create `AppFeedback/Services/ProductStore.swift`** — the renamed store. It fetches `Product` (not `Repo`), and `add`/`update`/`reload`/`remove` carry the four new fields:
  ```swift
  import Foundation
  import Observation
  import SwiftData
  import CoreData

  @Observable @MainActor
  final class ProductStore {
      private(set) var repos: [ProductConfig] = []
      /// Preferred name in all NEW code. Mirrors the stored `repos` array (the stored
      /// name is kept to avoid churning existing `store.repos` call sites). Reading
      /// `products` registers the same Observation dependency as reading `repos`.
      var products: [ProductConfig] { repos }
      private(set) var hiddenApps: [UUID: Set<String>] = [:]
      private(set) var appColors: [UUID: [String: String]] = [:]

      private let context: ModelContext
      private let hiddenAppStore: HiddenAppStore?
      private var didSaveTask: Task<Void, Never>?
      private var remoteChangeTask: Task<Void, Never>?
      private var cloudKitImportTask: Task<Void, Never>?

      init(context: ModelContext, hiddenAppStore: HiddenAppStore? = nil) {
          self.context = context
          self.hiddenAppStore = hiddenAppStore
          reload()

          let ownContext = ObjectIdentifier(context)
          let didSaves = NotificationCenter.default.notifications(named: ModelContext.didSave)
              .compactMap { @Sendable note -> Bool? in
                  let senderID = (note.object as? ModelContext).map(ObjectIdentifier.init)
                  return senderID == ownContext ? nil : true
              }
          didSaveTask = Task { @MainActor [weak self] in
              for await _ in didSaves { self?.reload() }
          }
          remoteChangeTask = Task { @MainActor [weak self] in
              for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                  self?.reload()
              }
          }
          cloudKitImportTask = Task { @MainActor [weak self] in
              for await _ in NotificationCenter.cloudKitImportSucceeded { self?.reload() }
          }
      }

      isolated deinit {
          didSaveTask?.cancel()
          remoteChangeTask?.cancel()
          cloudKitImportTask?.cancel()
      }

      // MARK: - Products

      func add(_ repo: ProductConfig) {
          let model = Product(
              id: repo.id,
              displayName: repo.displayName,
              owner: repo.owner,
              repo: repo.repo,
              colorHex: repo.colorHex,
              mirrorEmailsToGitHub: repo.mirrorEmailsToGitHub,
              redactEmailAddresses: repo.redactEmailAddresses,
              connectedRepoOwner: repo.connectedRepoOwner,
              connectedRepoName: repo.connectedRepoName,
              appStoreIssuerID: repo.appStoreIssuerID,
              appStoreKeyID: repo.appStoreKeyID,
              appStoreAppAppleID: repo.appStoreAppAppleID,
              feedbackInboxAccountID: repo.feedbackInboxAccountID
          )
          context.insert(model)
          save()
          reload()
      }

      func update(_ repo: ProductConfig) {
          guard let model = fetchModel(id: repo.id) else { return }
          model.displayName = repo.displayName
          model.owner = repo.owner
          model.repo = repo.repo
          model.mirrorEmailsToGitHub = repo.mirrorEmailsToGitHub
          model.redactEmailAddresses = repo.redactEmailAddresses
          model.connectedRepoOwner = repo.connectedRepoOwner
          model.connectedRepoName = repo.connectedRepoName
          model.colorHex = repo.colorHex
          model.appStoreIssuerID = repo.appStoreIssuerID
          model.appStoreKeyID = repo.appStoreKeyID
          model.appStoreAppAppleID = repo.appStoreAppAppleID
          model.feedbackInboxAccountID = repo.feedbackInboxAccountID
          save()
          reload()
      }

      func remove(id: UUID) async {
          guard let model = fetchModel(id: id) else { return }
          let config = ProductConfig(
              id: model.id,
              displayName: model.displayName,
              owner: model.owner,
              repo: model.repo,
              mirrorEmailsToGitHub: model.mirrorEmailsToGitHub,
              redactEmailAddresses: model.redactEmailAddresses,
              connectedRepoOwner: model.connectedRepoOwner,
              connectedRepoName: model.connectedRepoName
          )
          await KeychainService.delete(for: config)
          context.delete(model)
          save()
          reload()
      }

      // MARK: - Hidden apps

      func hideApp(_ appName: String, in repoId: UUID) {
          guard let model = fetchModel(id: repoId) else { return }
          hiddenAppStore?.hide(owner: model.owner, repo: model.repo, appName: appName)
          reload()
      }

      func unhideAllApps(in repoId: UUID) {
          guard let model = fetchModel(id: repoId) else { return }
          hiddenAppStore?.unhideAll(owner: model.owner, repo: model.repo)
          reload()
      }

      func hiddenAppsFor(_ repoId: UUID) -> Set<String> {
          hiddenApps[repoId] ?? []
      }

      // MARK: - App colors

      func setColor(_ hex: String, forApp appName: String, in repoId: UUID) {
          guard let model = fetchModel(id: repoId) else { return }
          if model.appColors[appName] == hex { return }
          model.appColors[appName] = hex
          save()
          reload()
      }

      func colorHexFor(app appName: String, in repoId: UUID) -> String? {
          appColors[repoId]?[appName]
      }

      // MARK: - Product color

      func setColor(_ hex: String?, forRepo repoId: UUID) {
          guard let model = fetchModel(id: repoId) else { return }
          if model.colorHex == hex { return }
          model.colorHex = hex
          save()
          reload()
      }

      func colorHexFor(repo repoId: UUID) -> String? {
          repos.first { $0.id == repoId }?.colorHex
      }

      // MARK: - Internal

      private func fetchModel(id: UUID) -> Product? {
          let descriptor = FetchDescriptor<Product>(predicate: #Predicate { $0.id == id })
          return (try? context.fetch(descriptor))?.first
      }

      private func save() {
          try? context.save()
      }

      private func reload() {
          let models = (try? context.fetch(FetchDescriptor<Product>(
              sortBy: [SortDescriptor(\.createdAt)]
          ))) ?? []
          let newRepos = models.map {
              ProductConfig(
                  id: $0.id,
                  displayName: $0.displayName,
                  owner: $0.owner,
                  repo: $0.repo,
                  mirrorEmailsToGitHub: $0.mirrorEmailsToGitHub,
                  redactEmailAddresses: $0.redactEmailAddresses,
                  connectedRepoOwner: $0.connectedRepoOwner,
                  connectedRepoName: $0.connectedRepoName,
                  colorHex: $0.colorHex,
                  appStoreIssuerID: $0.appStoreIssuerID,
                  appStoreKeyID: $0.appStoreKeyID,
                  appStoreAppAppleID: $0.appStoreAppAppleID,
                  feedbackInboxAccountID: $0.feedbackInboxAccountID
              )
          }
          var newHiddenApps: [UUID: Set<String>] = [:]
          for model in models {
              if let store = hiddenAppStore {
                  store.migrateLegacy(owner: model.owner, repo: model.repo, legacyNames: model.hiddenAppNames)
                  newHiddenApps[model.id] = store.hiddenApps(owner: model.owner, repo: model.repo)
              } else {
                  newHiddenApps[model.id] = Set(model.hiddenAppNames)
              }
          }
          let newAppColors = Dictionary(
              uniqueKeysWithValues: models.map { ($0.id, $0.appColors) }
          )
          if repos != newRepos { repos = newRepos }
          if hiddenApps != newHiddenApps { hiddenApps = newHiddenApps }
          if appColors != newAppColors { appColors = newAppColors }
      }
  }

  extension NotificationCenter {
      /// Successful `.import` events from `NSPersistentCloudKitContainer`, signaling that
      /// remote rows have been merged into the local store and a refetch will see them.
      static var cloudKitImportSucceeded: AsyncCompactMapSequence<NotificationCenter.Notifications, Bool> {
          NotificationCenter.default
              .notifications(named: NSPersistentCloudKitContainer.eventChangedNotification)
              .compactMap { @Sendable note -> Bool? in
                  guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                          as? NSPersistentCloudKitContainer.Event,
                        event.type == .import,
                        event.succeeded
                  else { return nil }
                  return true
              }
      }
  }
  ```
- [ ] **Step 2: Delete the old store.**
  ```
  git rm AppFeedback/Services/RepoStore.swift
  ```
- [ ] **Step 3: Rename `RepoStore` → `ProductStore` in all consumers** (type references only; their `store.repos` usage is unchanged):
  ```
  for f in \
    AppFeedback/Services/Mail/MailToGitHubMirror.swift \
    AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift \
    AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift \
    AppFeedback/App/RootView.swift \
    AppFeedback/Views/Settings/SettingsView.swift \
    AppFeedback/Views/Settings/AddEditRepoView.swift \
    AppFeedback/Views/Sidebar/SidebarView.swift \
    AppFeedback/Views/Sidebar/RepoSectionView.swift; do
    sed -i '' 's/RepoStore/ProductStore/g' "$f"
  done
  ```
- [ ] **Step 4: Verify no stray references remain in app sources** (excluding `AppFeedbackApp.swift`, handled in Task 7):
  ```
  rg -n "RepoStore|RepoConfig" AppFeedback --glob '!AppFeedback/App/AppFeedbackApp.swift'
  ```
  Expect: no matches. If any appear, `sed`-rename them.
- [ ] **Step 5: Build `AppFeedback_macOS` to scope remaining work (do NOT treat the failure as a defect).** Expect FAIL only inside `AppFeedbackApp.swift` (still references `Repo`/`RepoStore`/`RepoConfig` + registration) — fixed in Task 7.
  > RENAME-UNIT NOTE: The tree is still RED (this is the atomic rename unit). Do NOT commit a non-compiling tree and do NOT run any `-only-testing` invocation. The first green build + single commit lands at **Task 7, Step 7**. Continue straight through Tasks 5–7 without committing.

---

### Task 5: Add `MailAccount.feedbackProductID`

**Files:**
- Modify `AppFeedback/Models/MailAccount.swift`
- Test `AppFeedbackTests/ModelsTests.swift`

**Interfaces:**
- Produces: `MailAccount.feedbackProductID: UUID?` (stored, default `nil`) + matching `init` param. The inbox-vs-reply-mirror role is DERIVED from `feedbackProductID != nil`; NO stored role added.
- Consumes: nothing.

- [ ] **Step 1: Write a failing default test.** Append to `AppFeedbackTests/ModelsTests.swift`:
  ```swift
  func test_mailAccount_feedbackProductIDDefaultsNil() {
      let acc = MailAccount()
      XCTAssertNil(acc.feedbackProductID)
  }

  func test_mailAccount_feedbackProductIDRoundTrips() {
      let id = UUID()
      let acc = MailAccount(feedbackProductID: id)
      XCTAssertEqual(acc.feedbackProductID, id)
  }
  ```
- [ ] **Step 2: Build/run tests.** Expect FAIL: "extra argument 'feedbackProductID' in call" / no member.
- [ ] **Step 3: Add the stored field + init param** in `AppFeedback/Models/MailAccount.swift`. Add the property after `createdAt`:
  ```swift
      var createdAt: Date = Date()
      /// nil ⇒ legacy reply-mirror account; non-nil ⇒ feedback inbox for that product.
      /// The inbox-vs-reply-mirror "role" is DERIVED from this; there is no stored role.
      var feedbackProductID: UUID? = nil
  ```
  Add the init parameter (after `createdAt: Date = Date()`):
  ```swift
          createdAt: Date = Date(),
          feedbackProductID: UUID? = nil
  ```
  And the assignment (after `self.createdAt = createdAt`):
  ```swift
          self.createdAt = createdAt
          self.feedbackProductID = feedbackProductID
  ```
- [ ] **Step 4: Do NOT build/run in isolation.** This file's edit is correct on its own, but the target won't link until Task 7 (atomic rename unit). The two new tests above run at the unit's green point (Task 7 / the full suite in Task 8). Continue to Task 6 without committing.

---

### Task 6: `ProductMigration.run(context:defaults:)` — idempotent data copy

**Files:**
- Create `AppFeedback/Services/ProductMigration.swift`
- Test `AppFeedbackTests/ProductMigrationTests.swift`

**Interfaces:**
- Produces: `enum ProductMigration` with `static func run(context: ModelContext, defaults: UserDefaults = .standard)`. Idempotent + `UserDefaults`-flag-gated (`product.migration.v1.completed`, set only on success): for every legacy `Repo` lacking a `Product` of the same `id`, inserts a `Product` copying `id`/`owner`/`repo` and all fields verbatim, then deletes the `Repo` row; saves once. On the second run the flag short-circuits AND, defensively, a `Repo` whose `id` already has a `Product` is skipped.
- Consumes: legacy `Repo` (Task 2), `Product` (Task 1).

- [ ] **Step 1: Write the failing migration test.** Create `AppFeedbackTests/ProductMigrationTests.swift`:
  ```swift
  import XCTest
  import SwiftData
  @testable import AppFeedback

  @MainActor
  final class ProductMigrationTests: XCTestCase {
      private var container: ModelContainer!
      private var context: ModelContext!
      private var defaults: UserDefaults!

      override func setUp() async throws {
          try await super.setUp()
          // Register BOTH the legacy Repo and the new Product so the migration can copy across.
          let schema = Schema([Repo.self, Product.self, CachedIssue.self, MailThread.self, RepoFilterPreference.self])
          let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          container = try ModelContainer(for: schema, configurations: config)
          context = ModelContext(container)
          defaults = UserDefaults(suiteName: "ProductMigrationTests-\(UUID().uuidString)")!
      }

      override func tearDown() async throws {
          context = nil; container = nil; defaults = nil
          try await super.tearDown()
      }

      func test_migration_copiesRepoToProductPreservingIdentity() throws {
          let id = UUID()
          let legacy = Repo(id: id, displayName: "My App", owner: "octo", repo: "feedback",
                            colorHex: "ff0000", mirrorEmailsToGitHub: false, redactEmailAddresses: true,
                            connectedRepoOwner: "octo", connectedRepoName: "code")
          context.insert(legacy)
          // Foreign-key rows keyed by owner/repo (not Repo.id). NOTE: `CachedIssue.init` has NO
          // defaulted middle params (verified against AppFeedback/Models/CachedIssue.swift) — every
          // arg through `issueDescription` is required, so the four-arg form does NOT compile.
          let issue = CachedIssue(
              repoOwner: "octo", repoName: "feedback", number: 7, title: "Crash",
              createdAt: Date(), rawBody: "", appName: nil, appVersion: nil,
              device: nil, osVersion: nil, email: nil, issueDescription: ""
          )
          context.insert(issue)
          // `MailThread.init` is all-defaulted (verified against AppFeedback/Models/MailThread.swift),
          // so the labeled subset below compiles as-is.
          let thread = MailThread(issueRepoOwner: "octo", issueRepoName: "feedback", issueNumber: 7)
          context.insert(thread)
          let pref = RepoFilterPreference(repoOwner: "octo", repoName: "feedback")
          context.insert(pref)
          try context.save()

          ProductMigration.run(context: context, defaults: defaults)

          let products = try context.fetch(FetchDescriptor<Product>())
          XCTAssertEqual(products.count, 1)
          let p = products[0]
          XCTAssertEqual(p.id, id)
          XCTAssertEqual(p.owner, "octo")
          XCTAssertEqual(p.repo, "feedback")
          XCTAssertEqual(p.displayName, "My App")
          XCTAssertEqual(p.colorHex, "ff0000")
          XCTAssertFalse(p.mirrorEmailsToGitHub)
          XCTAssertEqual(p.connectedRepoName, "code")
          // New source fields default nil.
          XCTAssertNil(p.appStoreIssuerID)
          XCTAssertNil(p.feedbackInboxAccountID)
          // Legacy row retired.
          XCTAssertTrue(try context.fetch(FetchDescriptor<Repo>()).isEmpty)
          // Foreign keys still resolve by owner/repo.
          let issues = try context.fetch(FetchDescriptor<CachedIssue>())
          XCTAssertEqual(issues.first?.repoOwner, "octo")
          XCTAssertEqual(issues.first?.repoName, "feedback")
          let threads = try context.fetch(FetchDescriptor<MailThread>())
          XCTAssertEqual(threads.first?.issueRepoOwner, "octo")
          XCTAssertEqual(threads.first?.issueNumber, 7)
          let prefs = try context.fetch(FetchDescriptor<RepoFilterPreference>())
          XCTAssertEqual(prefs.first?.repoOwner, "octo")
      }

      func test_migration_isIdempotentOnSecondRun() throws {
          let id = UUID()
          context.insert(Repo(id: id, displayName: "A", owner: "o", repo: "r"))
          try context.save()

          ProductMigration.run(context: context, defaults: defaults)
          ProductMigration.run(context: context, defaults: defaults)   // second run no-ops

          let products = try context.fetch(FetchDescriptor<Product>())
          XCTAssertEqual(products.count, 1, "second run must not duplicate")
          XCTAssertEqual(products.first?.id, id)
      }

      func test_migration_defensivelySkipsRepoWithExistingProduct() throws {
          // Flag NOT set, but a Product already exists for this id (e.g. partial prior run).
          let id = UUID()
          context.insert(Repo(id: id, displayName: "A", owner: "o", repo: "r"))
          context.insert(Product(id: id, displayName: "A", owner: "o", repo: "r"))
          try context.save()

          ProductMigration.run(context: context, defaults: defaults)

          XCTAssertEqual(try context.fetch(FetchDescriptor<Product>()).count, 1)
      }
  }
  ```
  > NOTE on `CachedIssue`/`MailThread` constructors (RESOLVED — verified against the real headers): `CachedIssue.init` is `init(repoOwner:repoName:number:title:createdAt:updatedAt:state:rawBody:appName:appVersion:device:osVersion:email:issueDescription:labels:)` — `createdAt`/`rawBody`/`appName`/`appVersion`/`device`/`osVersion`/`email`/`issueDescription` have **no defaults**, so the test passes them all explicitly above. `MailThread.init` defaults every parameter, so the labeled subset (`issueRepoOwner:issueRepoName:issueNumber:`) compiles unchanged. The only assertions that matter are that `repoOwner`/`repoName` (and `issueRepoOwner`/`issueNumber`) survive the migration.
- [ ] **Step 2: Build/run `ProductMigrationTests`.** Expect FAIL: "Cannot find 'ProductMigration' in scope".
- [ ] **Step 3: Create `AppFeedback/Services/ProductMigration.swift`:**
  ```swift
  import Foundation
  import SwiftData

  /// One-time, idempotent copy of every legacy `Repo` row into a `Product` with the SAME
  /// `id`/`owner`/`repo` and all fields. Run in `AppFeedbackApp.init()` when not testing,
  /// exactly like `MailAccountMigration`. Gated by a `UserDefaults` flag set only on success,
  /// so a failure leaves legacy `Repo` data intact and retries next launch.
  enum ProductMigration {
      static let completedKey = "product.migration.v1.completed"

      @MainActor
      static func run(context: ModelContext, defaults: UserDefaults = .standard) {
          guard !defaults.bool(forKey: completedKey) else { return }

          let legacyRepos: [Repo]
          do {
              legacyRepos = try context.fetch(FetchDescriptor<Repo>())
          } catch {
              // Leave the flag unset so we retry next launch.
              return
          }
          if legacyRepos.isEmpty {
              // Nothing to migrate (fresh install or already migrated + rows retired).
              defaults.set(true, forKey: completedKey)
              return
          }

          // Index existing Products by id to skip any already-copied rows defensively.
          let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []
          var existingIDs = Set(existing.map(\.id))

          for legacy in legacyRepos {
              if existingIDs.contains(legacy.id) {
                  // Already has a Product; retire the legacy row and move on.
                  context.delete(legacy)
                  continue
              }
              let product = Product(
                  id: legacy.id,
                  displayName: legacy.displayName,
                  owner: legacy.owner,
                  repo: legacy.repo,
                  hiddenAppNames: legacy.hiddenAppNames,
                  appColors: legacy.appColors,
                  colorHex: legacy.colorHex,
                  createdAt: legacy.createdAt,
                  mirrorEmailsToGitHub: legacy.mirrorEmailsToGitHub,
                  redactEmailAddresses: legacy.redactEmailAddresses,
                  connectedRepoOwner: legacy.connectedRepoOwner,
                  connectedRepoName: legacy.connectedRepoName
                  // appStore*/feedbackInboxAccountID default nil — config only, no legacy source.
              )
              context.insert(product)
              existingIDs.insert(product.id)
              context.delete(legacy)
          }

          do {
              try context.save()
              defaults.set(true, forKey: completedKey)   // flag ONLY on success
          } catch {
              // Save failed: leave the flag unset so the migration retries next launch.
          }
      }
  }
  ```
- [ ] **Step 4: WRITE the test + migration now; RUN them at the unit's green point (Task 7).** Do NOT run `ProductMigrationTests` here — the whole test target won't link until Task 7 fixes `AppFeedbackApp.swift` (this is the atomic rename unit). The migration tests use their own in-memory container, independent of the app's container, so once the target links they pass regardless of the app container. The test construction (`CachedIssue`/`MailThread`/`RepoFilterPreference`) is already pinned to the real, verified initializers above — no further signature confirmation is needed.
- [ ] **Step 5: No commit here.** Still mid-rename; the tree does not compile. The first green build + single commit lands at **Task 7, Step 7**.

---

### Task 7: Wire `Product` + legacy `Repo` into `AppFeedbackApp` + run the migration (RENAME UNIT GOES GREEN HERE)

**Files:**
- Modify `AppFeedback/App/AppFeedbackApp.swift`

**Interfaces:**
- Consumes: `Product` (Task 1), legacy `Repo` (Task 2), `ProductConfig` (Task 3), `ProductStore` (Task 4), `MailAccount.feedbackProductID` (Task 5), `ProductMigration.run(context:defaults:)` (Task 6).
- Produces: app container registering BOTH `Product` and `Repo` in the test single-config container AND in `cloudSchema`; `ProductMigration.run(context:)` invoked when not testing (mirroring `MailAccountMigration`). This is the FIRST point the whole target compiles since Task 3 — build BOTH platforms green and commit the entire rename unit atomically.

- [ ] **Step 1: Register `Product` + legacy `Repo` in the test container.** In the `if isTesting { … }` `ModelContainer(for:…)` list, replace the leading `Repo.self,` with `Product.self, Repo.self,` (both must be registered so `ProductMigration` can copy). The block becomes:
  ```swift
                  container = try ModelContainer(
                      for: Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                          GitHubAccount.self,
                          MailSettings.self,
                          MailThread.self, MailMessage.self, MailAttachment.self,
                          IssueTranslation.self, IssueSummaryCache.self,
                          ProjectVersion.self, SentReleaseNotification.self,
                          CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                          RepoFetchState.self, FeedbackAttachmentLocal.self,
                          ReplyTemplate.self,
                          RepoFilterPreference.self,
                      configurations: testConfig
                  )
  ```
- [ ] **Step 2: Register `Product` + legacy `Repo` in `cloudSchema` and the non-test `ModelContainer(for:…)`.** Change the `cloudSchema` array's leading `Repo.self` to `Product.self, Repo.self`:
  ```swift
                  let cloudSchema = Schema([Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self, RepoFilterPreference.self])
  ```
  And in the non-test `ModelContainer(for:…)` list replace the leading `Repo.self,` with `Product.self, Repo.self,`:
  ```swift
                  container = try ModelContainer(
                      for: Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                          GitHubAccount.self,
                          MailSettings.self,
                          MailThread.self, MailMessage.self, MailAttachment.self,
                          IssueTranslation.self, IssueSummaryCache.self,
                          ProjectVersion.self, SentReleaseNotification.self,
                          CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                          RepoFetchState.self, FeedbackAttachmentLocal.self,
                          ReplyTemplate.self,
                          RepoFilterPreference.self,
                      configurations: cloudConfig, localConfig
                  )
  ```
- [ ] **Step 3: Rename the snapshot helper + store types in `AppFeedbackApp.swift`.** Run from repo root:
  ```
  sed -i '' -e 's/RepoConfigSnapshot/ProductConfigSnapshot/g' -e 's/\[RepoConfig\]/[ProductConfig]/g' -e 's/RepoStore/ProductStore/g' AppFeedback/App/AppFeedbackApp.swift
  ```
  (`RepoConfigSnapshot` is a private helper class in this file; its `update(_:)` param is `[RepoConfig]` → `[ProductConfig]`. The `repoConfigSnapshot` *variable* name may stay; only the type/closure references change.)
- [ ] **Step 4: Run `ProductMigration` after the mail migrations (when not testing).** In `init()`, inside the existing `if !isTesting { … }` block right after the `MailAccountMigration.runV2IfNeeded(...)` call, add:
  ```swift
              ProductMigration.run(context: cloudContext)
  ```
  > `cloudContext` is already created above as `let cloudContext = ModelContext(container)` and is the context bound to the CloudKit-synced configuration, where both `Repo` and `Product` rows live. Running here (not testing) mirrors `MailAccountMigration`.
- [ ] **Step 5: Verify no stale `Repo`-type/`RepoStore`/`RepoConfig` references remain in `AppFeedbackApp.swift` except the intentional `Repo.self` registrations, AND that no dead schema scaffolding was introduced.** Run:
  ```
  rg -n "RepoStore|RepoConfig|RepoConfigSnapshot" AppFeedback/App/AppFeedbackApp.swift
  rg -n "VersionedSchema|SchemaMigrationPlan|ProductMigrationPlan|migrationPlan:" AppFeedback
  ```
  Expect: no matches for either (the live container intentionally has NO `migrationPlan:`; the data copy runs from `init()`).
- [ ] **Step 6: Build `AppFeedback_macOS` AND `AppFeedback_iOS`.** Expect SUCCESS on both. Fix any straggler `RepoStore`/`RepoConfig` references surfaced by the compiler with a targeted `sed` rename.
- [ ] **Step 7: Commit the whole rename + migration wiring atomically** (this is the first point the tree compiles since Task 3 — `Product.swift` and `LegacyRepo.swift` were already committed in Tasks 1–2). The Task-3/4 `git rm` of `RepoConfig.swift`/`RepoStore.swift` is already staged; the `git add` below stages the new files + remaining edits. Stage exactly the touched paths (do NOT use a bare `git add -A`, which would sweep the user's unrelated WIP into the pbxproj):
  ```
  git add \
    AppFeedback/Models/ProductConfig.swift \
    AppFeedback/Services/ProductStore.swift \
    AppFeedback/Models/MailAccount.swift \
    AppFeedback/Services/ProductMigration.swift \
    AppFeedback/Services/KeychainService.swift \
    AppFeedback/Services/IssueLoader.swift \
    AppFeedback/Services/ReleaseNotificationService.swift \
    AppFeedback/Services/TaskService.swift \
    AppFeedback/Services/VersionService.swift \
    AppFeedback/Services/Mail/MailToGitHubMirror.swift \
    AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift \
    AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift \
    AppFeedback/App/AppFeedbackApp.swift \
    AppFeedback/App/RootView.swift \
    AppFeedback/Views/Settings/SettingsView.swift \
    AppFeedback/Views/Settings/AddEditRepoView.swift \
    AppFeedback/Views/Sidebar/SidebarView.swift \
    AppFeedback/Views/Sidebar/RepoSectionView.swift \
    AppFeedback/Views/Inspector/CreateTaskSheet.swift \
    AppFeedback/Views/Inspector/ProjectInspectorPanel.swift \
    AppFeedback/Views/Inspector/ReleaseRecipientsSheet.swift \
    AppFeedback/Views/Inspector/TaskDetailView.swift \
    AppFeedback/Views/Inspector/VersionDetailView.swift \
    AppFeedbackTests/IssueLoaderTests.swift \
    AppFeedbackTests/ModelsTests.swift \
    AppFeedbackTests/ProductMigrationTests.swift
  git commit -m "feat(model): rename Repo→Product (config+store) + idempotent CloudKit migration shim

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 8: Reusable `ProductStore` test helper + port `RepoStoreTests` → `ProductStoreTests`

**Files:**
- Create `AppFeedbackTests/ProductStoreTestSupport.swift` — the documented, reusable in-memory `ProductStore` construction helper (Phases 1–5 reuse it; Phase 5's email tests in particular need a seeded product whose `feedbackInboxAccountID` is set).
- Create `AppFeedbackTests/ProductStoreTests.swift`
- Modify `AppFeedbackTests/RepoStoreTests.swift` (delete)

**Interfaces:**
- Consumes: `ProductStore` (Task 4), `ProductConfig` (Task 3), `Product` (Task 1).
- Produces: `ProductStoreTestHarness` — an in-memory `ModelContainer` + `ProductStore` wrapper with a single `seed(...)` call exposing the four new source-config fields. This is the **test seam** the Shared Contracts reference; later phases construct products through it instead of hand-rolling a container.

- [ ] **Step 1: Create `AppFeedbackTests/ProductStoreTestSupport.swift`** — the reusable harness. The EXACT seed call signature is `seed(owner:repo:displayName:redactEmailAddresses:feedbackInboxAccountID:appStoreIssuerID:appStoreKeyID:appStoreAppAppleID:)`; all but `owner`/`repo` are defaulted, so Phase 5 calls it as e.g. `harness.seed(owner: "octo", repo: "feedback", redactEmailAddresses: true, feedbackInboxAccountID: inboxID)`:
  ```swift
  import Foundation
  import SwiftData
  @testable import AppFeedback

  /// Reusable in-memory `ProductStore` for tests. Phases 1–5 build products through this
  /// helper rather than hand-rolling a container, so the seed surface stays in one place.
  ///
  /// Example (Phase 5 email source):
  /// ```
  /// let harness = try ProductStoreTestHarness()
  /// let inboxID = UUID()
  /// let product = harness.seed(owner: "octo", repo: "feedback",
  ///                            redactEmailAddresses: true,
  ///                            feedbackInboxAccountID: inboxID)
  /// ```
  @MainActor
  struct ProductStoreTestHarness {
      let container: ModelContainer
      let context: ModelContext
      let store: ProductStore

      /// `extraModels` lets a caller widen the schema (e.g. Phase 5 adds `MailThread.self`,
      /// `MailAccount.self`) while still getting the standard `Product` + `HiddenApp` registration.
      init(extraModels: [any PersistentModel.Type] = []) throws {
          let schema = Schema([Product.self, HiddenApp.self] + extraModels)
          let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          container = try ModelContainer(for: schema, configurations: config)
          context = ModelContext(container)
          store = ProductStore(context: context, hiddenAppStore: HiddenAppStore(context: context))
      }

      /// Seeds one product and returns its config. Mirrors `ProductConfig`'s field set so a
      /// caller can set any source-config field at construction time.
      @discardableResult
      func seed(
          owner: String,
          repo: String,
          displayName: String = "Test Product",
          redactEmailAddresses: Bool = true,
          feedbackInboxAccountID: UUID? = nil,
          appStoreIssuerID: String? = nil,
          appStoreKeyID: String? = nil,
          appStoreAppAppleID: String? = nil
      ) -> ProductConfig {
          let config = ProductConfig(
              displayName: displayName,
              owner: owner,
              repo: repo,
              redactEmailAddresses: redactEmailAddresses,
              appStoreIssuerID: appStoreIssuerID,
              appStoreKeyID: appStoreKeyID,
              appStoreAppAppleID: appStoreAppAppleID,
              feedbackInboxAccountID: feedbackInboxAccountID
          )
          store.add(config)
          return config
      }
  }
  ```
- [ ] **Step 2: Create `AppFeedbackTests/ProductStoreTests.swift`** — the ported `RepoStoreTests` (schema uses `Product`, store is `ProductStore`, DTO is `ProductConfig`) PLUS a round-trip test for the four new fields. It uses the harness from Step 1 for setup:
  ```swift
  import XCTest
  import SwiftData
  @testable import AppFeedback

  @MainActor
  final class ProductStoreTests: XCTestCase {
      private var harness: ProductStoreTestHarness!
      private var store: ProductStore { harness.store }

      override func setUp() async throws {
          try await super.setUp()
          harness = try ProductStoreTestHarness()
      }

      override func tearDown() async throws {
          harness = nil
          try await super.tearDown()
      }

      func test_initiallyEmpty() { XCTAssertTrue(store.repos.isEmpty) }

      func test_products_mirrorsRepos() {
          store.add(ProductConfig(displayName: "Test", owner: "org", repo: "feedback"))
          XCTAssertEqual(store.products, store.repos)
      }

      func test_harnessSeed_setsFeedbackInboxAccountID() {
          let inboxID = UUID()
          harness.seed(owner: "octo", repo: "feedback",
                       redactEmailAddresses: true, feedbackInboxAccountID: inboxID)
          XCTAssertEqual(store.products.first?.feedbackInboxAccountID, inboxID)
      }

      func test_add_appendsProduct() {
          store.add(ProductConfig(displayName: "Test", owner: "org", repo: "feedback"))
          XCTAssertEqual(store.repos.count, 1)
          XCTAssertEqual(store.repos.first?.owner, "org")
      }

      func test_remove_deletesProduct() async {
          let p = ProductConfig(displayName: "Test", owner: "org", repo: "feedback")
          store.add(p)
          await store.remove(id: p.id)
          XCTAssertTrue(store.repos.isEmpty)
      }

      func test_update_replacesProduct() {
          var p = ProductConfig(displayName: "Old", owner: "org", repo: "feedback")
          store.add(p)
          p.displayName = "New"
          store.update(p)
          XCTAssertEqual(store.repos.first?.displayName, "New")
      }

      func test_hideApp_recordsName() {
          let p = ProductConfig(displayName: "T", owner: "o", repo: "r")
          store.add(p)
          store.hideApp("AppA", in: p.id)
          XCTAssertEqual(store.hiddenAppsFor(p.id), ["AppA"])
      }

      func test_persistsAcrossInstances() {
          store.add(ProductConfig(displayName: "Persisted", owner: "x", repo: "y"))
          let store2 = ProductStore(context: ModelContext(harness.container))
          XCTAssertEqual(store2.repos.first?.displayName, "Persisted")
      }

      func test_setColor_storesAndReadsHex() {
          let p = ProductConfig(displayName: "T", owner: "o", repo: "r")
          store.add(p)
          store.setColor("4ef8d0", forApp: "AppA", in: p.id)
          XCTAssertEqual(store.colorHexFor(app: "AppA", in: p.id), "4ef8d0")
          XCTAssertNil(store.colorHexFor(app: "AppB", in: p.id))
      }

      func test_setProductColor_storesAndReadsHex() {
          let p = ProductConfig(displayName: "T", owner: "o", repo: "r")
          store.add(p)
          store.setColor("7b8cff", forRepo: p.id)
          XCTAssertEqual(store.colorHexFor(repo: p.id), "7b8cff")
      }

      func test_connectedRepoRoundTrips() throws {
          var cfg = ProductConfig(displayName: "P", owner: "o", repo: "r")
          cfg.connectedRepoOwner = "o2"; cfg.connectedRepoName = "code"
          store.add(cfg)
          let reloaded = store.repos.first { $0.owner == "o" }
          XCTAssertEqual(reloaded?.connectedRepoOwner, "o2")
          XCTAssertEqual(reloaded?.connectedRepoName, "code")
      }

      func test_newSourceFields_roundTripThroughAddAndReload() {
          let inboxID = UUID()
          var cfg = ProductConfig(displayName: "P", owner: "o", repo: "r")
          cfg.appStoreIssuerID = "iss-1"
          cfg.appStoreKeyID = "key-1"
          cfg.appStoreAppAppleID = "1234567890"
          cfg.feedbackInboxAccountID = inboxID
          store.add(cfg)
          let reloaded = store.repos.first { $0.owner == "o" }
          XCTAssertEqual(reloaded?.appStoreIssuerID, "iss-1")
          XCTAssertEqual(reloaded?.appStoreKeyID, "key-1")
          XCTAssertEqual(reloaded?.appStoreAppAppleID, "1234567890")
          XCTAssertEqual(reloaded?.feedbackInboxAccountID, inboxID)
      }

      func test_newSourceFields_updateMutatesModel() {
          var cfg = ProductConfig(displayName: "P", owner: "o", repo: "r")
          store.add(cfg)
          cfg.appStoreAppAppleID = "999"
          store.update(cfg)
          let reloaded = store.repos.first { $0.owner == "o" }
          XCTAssertEqual(reloaded?.appStoreAppAppleID, "999")
      }
  }
  ```
- [ ] **Step 3: Delete the old store tests.**
  ```
  git rm AppFeedbackTests/RepoStoreTests.swift
  ```
- [ ] **Step 4: Run `ProductStoreTests` + `ProductMigrationTests` via xcodebuild (ground truth).** The tree is green (Task 7 committed the rename unit), so per-suite `-only-testing` is now allowed:
  ```
  xcodebuild test -scheme AppFeedback_macOS \
    -destination 'platform=macOS' \
    -only-testing:AppFeedbackTests_macOS/ProductStoreTests \
    -only-testing:AppFeedbackTests_macOS/ProductMigrationTests \
    -only-testing:AppFeedbackTests_macOS/ModelsTests 2>&1 | tail -40
  ```
  Expect: all selected tests PASS (no crash; watch the raw xcodebuild output, not the /api/test summary).
- [ ] **Step 5: Commit.**
  ```
  git add AppFeedbackTests/ProductStoreTestSupport.swift AppFeedbackTests/ProductStoreTests.swift
  git commit -m "test(product): reusable ProductStore harness + port RepoStoreTests→ProductStoreTests

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 9: Rename user-facing strings to "Product" + `SettingsTab.products`

**Files:**
- Modify `AppFeedback/Views/Settings/SettingsView.swift`
- Modify `AppFeedback/Views/Settings/AddEditRepoView.swift`
- Modify `AppFeedback/Views/Sidebar/SidebarView.swift`
- Modify `AppFeedback/Views/Sidebar/RepoSectionView.swift`

**Interfaces:**
- Consumes: `ProductStore` (Task 4).
- Produces: `SettingsTab.products` (replaces `.repos`); user-facing copy reading "Product(s)" instead of "Repo/Repository". `RepoFilterPreference`/`RepoFetchState` type names UNCHANGED (only strings change). The `repos` property on `ProductStore` and `SidebarSelection.allIssues(repoId:)` enum case names are NOT renamed in this phase (no behavior change; later phases own the UI rework).

- [ ] **Step 1: Rename `SettingsTab.repos` → `.products`** in `AppFeedback/Views/Settings/SettingsView.swift`. Change the enum case and every `.repos` reference (the `selectedTab` default, the `tabContent(selection:)` `case .repos:` arm, and any `allTabIdentifiers()`/`displayName`/`systemImageName` switch arm). Replace:
  ```swift
  enum SettingsTab: String, Hashable, CaseIterable {
      case repos
  ```
  with:
  ```swift
  enum SettingsTab: String, Hashable, CaseIterable {
      case products
  ```
  and `var selectedTab: SettingsTab = .repos` → `= .products`, and `case .repos:` → `case .products:`. Find every `.repos` SettingsTab usage with `rg -n '\.repos\b' AppFeedback/Views/Settings/SettingsView.swift` and update each (be careful NOT to rewrite `store.repos`, which is the store array property and must stay).
- [ ] **Step 2: Update user-facing copy in `SettingsView.swift`.** Replace these literal strings (left → right), leaving `store.repos` and any GitHub-specific "GitHub repository" phrasing that genuinely refers to the underlying repo intact where the spec keeps it:
  - `"Add Repository"` → `"Add Product"`
  - `"Repositories"` → `"Products"`
  - `"Tap a repository to edit. Swipe left to remove."` → `"Tap a product to edit. Swipe left to remove."`
  - `"Add a GitHub repository to start browsing feedback."` → `"Add a product to start browsing feedback."`
  - `"No Repositories"` → `"No Products"`
  - `"Add a GitHub repo to start browsing feedback."` → `"Add a product to start browsing feedback."`
  - `"\(store.repos.count) repo\(store.repos.count == 1 ? "" : "s")"` → `"\(store.repos.count) product\(store.repos.count == 1 ? "" : "s")"`
  - `"Add Repo"` → `"Add Product"`
- [ ] **Step 3: Update user-facing copy in `AddEditRepoView.swift`.** Replace:
  - `isEditing ? "Edit Repository" : "Add Repository"` → `isEditing ? "Edit Product" : "Add Product"` (both the `.navigationTitle` and the header `Text`)
  - `Text(isEditing ? "Save" : "Add Repository")` → `Text(isEditing ? "Save" : "Add Product")`
  - `Text(isEditing ? "Update connection settings" : "Connect a GitHub repo to browse feedback")` → `… : "Connect a GitHub repo to browse feedback")` (KEEP — this genuinely describes the GitHub connection). Leave the `label: "GitHub Repository"` / `hint: "The owner and repository name on GitHub"` strings as-is — they describe the GitHub connection field, not the Product concept.
- [ ] **Step 4: Update user-facing copy in `RepoSectionView.swift`.** Replace:
  - `Label("Remove Repo", systemImage: "trash")` → `Label("Remove Product", systemImage: "trash")`
  - `Text("This will remove the repo from the sidebar. Your GitHub data will not be affected.")` → `Text("This will remove the product from the sidebar. Your GitHub data will not be affected.")`
- [ ] **Step 5: Update user-facing copy in `SidebarView.swift`.** Replace:
  - `Label("No Repos", systemImage: "tray")` → `Label("No Products", systemImage: "tray")`
  - `Text("Add a GitHub repo to start collecting feedback.")` → `Text("Add a product to start collecting feedback.")`
  - `Button("+ Add Repo") { onAddRepo() }` → `Button("+ Add Product") { onAddRepo() }` (KEEP the `onAddRepo` callback name — renaming it is gratuitous churn; only the visible label changes.)
- [ ] **Step 6: Build `AppFeedback_macOS` AND `AppFeedback_iOS`.** Expect SUCCESS on both. The `SettingsTab` rawValue persistence: `.products` raw string differs from the old `.repos`, so a previously-persisted `selectedTab` of `"repos"` will fail to decode and fall back to the default — acceptable (it only resets the open tab, no data loss). Confirm there are no remaining `.repos` SettingsTab references with `rg -n 'SettingsTab' AppFeedback`.
- [ ] **Step 7: Run the full `AppFeedbackTests_macOS` suite via xcodebuild (ground truth) to confirm no regressions beyond the ~11 known Keychain/GitHubAccount failures.**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -60
  ```
  Expect: only the pre-existing ~11 `KeychainServicePerAccountTests` + `GitHubAccountStoreTests` failures; everything else (incl. `ProductStoreTests`, `ProductMigrationTests`, `ModelsTests`, `IssueLoaderTests`, `FilterPreferenceStoreTests`) PASS. No hard crash.
- [ ] **Step 8: Commit.**
  ```
  git add \
    AppFeedback/Views/Settings/SettingsView.swift \
    AppFeedback/Views/Settings/AddEditRepoView.swift \
    AppFeedback/Views/Sidebar/SidebarView.swift \
    AppFeedback/Views/Sidebar/RepoSectionView.swift
  git commit -m "feat(ui): rename user-facing Repo→Product strings + SettingsTab.products

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 10: Final verification sweep

**Files:** none (verification only).

**Interfaces:** Consumes everything above.

- [ ] **Step 1: Confirm the type rename is complete in app sources.** Run:
  ```
  rg -n "\bRepoStore\b|\bRepoConfig\b|RepoConfigSnapshot" AppFeedback AppFeedbackTests
  ```
  Expect: no matches anywhere (the only surviving `Repo` symbol is the legacy `@Model` in `LegacyRepo.swift`, the `Repo.self` registrations in `AppFeedbackApp.swift`, the `RepoFilterPreference`/`RepoFetchState` type names, and `Repo` references inside `ProductMigration.swift`/`ProductMigrationTests.swift`).
- [ ] **Step 2: Confirm the persisted companions kept their names** (no accidental rename):
  ```
  rg -n "RepoFilterPreference|RepoFetchState" AppFeedback | head
  ```
  Expect: both still present (in their model files, `AppFeedbackApp.swift` schema lists, `FilterPreferenceStore.swift`, etc.).
- [ ] **Step 3: Confirm both schema-registration sites include `Product` and legacy `Repo`.**
  ```
  rg -n "Product.self, Repo.self" AppFeedback/App/AppFeedbackApp.swift
  ```
  Expect: 3 matches (test container, `cloudSchema`, non-test container).
- [ ] **Step 4: Confirm the migration is invoked when not testing, and that NO dead schema-migration scaffolding exists.**
  ```
  rg -n "ProductMigration.run" AppFeedback/App/AppFeedbackApp.swift
  rg -n "VersionedSchema|SchemaMigrationPlan|ProductMigrationPlan|migrationPlan:" AppFeedback
  ```
  Expect: exactly one `ProductMigration.run(context: cloudContext)` call inside the `if !isTesting` block of `init()`, and ZERO matches for the second command (the live container has no `migrationPlan:`; a `SchemaMigrationPlan` would never fire and would be dead code).
- [ ] **Step 5: Final clean build of BOTH platforms.**
  ```
  xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -5
  xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS' 2>&1 | tail -5
  ```
  Expect: `** BUILD SUCCEEDED **` on both.
- [ ] **Step 6: No commit needed** (verification only). Phase 0 is complete: full `Repo`→`Product` rename of the model triad, four new config-only fields, `MailAccount.feedbackProductID`, an idempotent CloudKit migration shim with a read-only legacy `Repo` kept one release, and user-facing strings reading "Product" — with zero behavior change beyond the rename.
