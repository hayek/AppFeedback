# Phase 3 — App Store review source (auth, poll, synthesis, edit/delete) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read App Store Connect customer reviews for any product that has ASC credentials, synthesize them into GitHub issues (with edit/deletion/dedup handling), and schedule the poll alongside the existing background refresh drivers — without building the respond/write-back UI (that is Phase 4).

**Architecture:** A per-product `AppStoreReviewCoordinator` actor (incremental poll + periodic full re-scan) drives an injectable `AppStoreConnectClientProtocol` (real `URLSession` impl + an in-test fake) authenticated by an `AppStoreConnectAuth` actor that mints ES256 JWTs via CryptoKit. Each new/edited/deleted review is synthesized into a GitHub issue via the existing `GitHubIssueWriter` (Phase-1 markers + `source:app-store`/`rating:N` labels), recorded in a CloudKit-synced `AppStoreReviewMirror` for cross-device dedup with a duplicate-collapse reconcile (there is no GitHub search API in the app, so the synced mirror is the authority and any cross-device duplicate rows are collapsed to the lowest issue number). An `AppStoreReviewCoordinatorRegistry` mirrors `MailSyncCoordinatorRegistry`, syncing coordinator lifecycle to the product list and hooked into both `MacBackgroundRefreshDriver` and `iOSBackgroundRefreshDriver`. This phase also ships the **real `AppStoreSourceForm`** (Issuer/Key paste, `.p8` import via `.fileImporter` on macOS + iOS Files, a Test button validating the key via `listApps()`, an app picker, save to Keychain + product, and per-source status), reachable from the Phase-2 Sources row, plus the `AppStoreResponderContext` seam Phase 4 consumes.

**Tech Stack:** Swift, SwiftUI, SwiftData (+CloudKit), CryptoKit, async/await actors; xcodegen project; Swift Testing/XCTest in target AppFeedbackTests_macOS.

## Global Constraints
- iOS deployment floor 18.6; macOS floor 15.0. Single `AppFeedback` target → `AppFeedback_iOS` / `AppFeedback_macOS`.
- xcodegen-generated project: new `.swift` files in any subfolder are auto-picked up; NEVER hand-edit the pbxproj. Stage narrowly with explicit paths in every `git add` — a broad `git add` sweeps the user's unrelated WIP + untracked files into the pbxproj.
- Build/test via the zcode skill; treat `xcodebuild` as ground truth (the zcode /api/test summary can mask a hard crash). Test target is `AppFeedbackTests_macOS`; tests run in-memory with `cloudKitDatabase: .none`.
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
@Observable final class ProductStore { /* renamed from RepoStore; add(_:)/update(_:) carry the new fields */ }
// MailAccount gains exactly one stored field:
//   var feedbackProductID: UUID?       // nil ⇒ legacy reply-mirror account; non-nil ⇒ feedback inbox for that product
//   (the inbox-vs-reply-mirror "role" is DERIVED from feedbackProductID != nil; do NOT add a stored role.)
// Migration: a single idempotent, AppStorage-gated ProductMigration.run from AppFeedbackApp.init() when not testing (like MailAccountMigration); keep a read-only legacy Repo @Model one release. DO NOT ship a VersionedSchema/SchemaMigrationPlan — the live container has no migrationPlan: so it would be dead code.
//   ProductMigration.run(context:) — idempotent, AppStorage-flag gated, sets Product.id/owner/repo from each Repo verbatim.
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

// ── Phase 3 establishes (App Store read path) — OWNS the mirror store + setup form ─
@Model final class AppStoreReviewMirror {   // CloudKit-synced (no unique constraint → dedup at read time)
    var reviewId: String
    var productID: UUID
    var issueNumber: Int
    var contentHash: String        // SHA-256 hex of normalized rating+\n+title+\n+body
    var responseState: String?     // nil | "PENDING_PUBLISH" | "PUBLISHED"
    var responseId: String?
}
@MainActor @Observable final class AppStoreReviewMirrorStore {   // SINGLE definition, file AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift
    private(set) var version: Int
    func allFor(productID: UUID) -> [AppStoreReviewMirror]
    func mirror(reviewId: String) -> AppStoreReviewMirror?               // reviewId is globally unique in ASC
    func mirror(productID: UUID, issueNumber: Int) -> AppStoreReviewMirror?
    func upsert(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String)
    func setResponse(reviewId: String, responseId: String?, state: String?)   // CANONICAL — Phase 4 calls this exact shape
    func clearResponse(reviewId: String)
    func deleteByIssue(productID: UUID, issueNumber: Int)                // reconcile deletes a SPECIFIC row (never the kept one)
}
protocol StatusCarryingError: Error { var statusCode: Int { get } }
enum AppStoreConnectError: StatusCarryingError {     // conforms → enables Phase 4's 403 read-only path
    case authFailed, forbidden, rateLimited, http(Int), decoding, badKey
    var statusCode: Int { get }                      // authFailed→401, forbidden→403, rateLimited→429, http(n)→n, else 0
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
actor AppStoreReviewCoordinator {            // poll loop: incremental + periodic FULL re-scan (edits/deletions)
    // exposes observable lastSuccessAt: Date? and lastError: String? for §8 per-source status
}
@MainActor final class AppStoreReviewCoordinatorRegistry {   // one coordinator per product-with-ASC; mirrors MailSyncCoordinatorRegistry
    func responderContext(productID: UUID) async -> AppStoreResponderContext?   // Phase 4 consumes this (async: reads actor-isolated coordinator properties)
}
struct AppStoreResponderContext: Sendable {          // Phase 3 defines; Phase 4 consumes
    let client: any AppStoreConnectClientProtocol
    let isReadOnly: Bool                             // true after a 403 on a response write (read-only key)
    let owner: String; let repo: String              // for the GitHub "responded" record comment
}
protocol FeedbackSourceIngestor: Sendable { func poll() async throws }   // thin seam; AppStoreReviewCoordinator conforms
// The REAL AppStoreSourceForm (Issuer/Key paste, .p8 import via .fileImporter on BOTH platforms incl. iOS Files,
//   Test, app picker via client.listApps(), save .p8→Keychain keyed by product id + IDs→Product, shows
//   lastSuccessAt/lastError) is implemented in THIS PHASE, reachable from the Phase-2 Sources row.
// New KeychainService methods: saveASCKey(_:for:) / loadASCKey(for:) / loadASCKeySync(for:) / deleteASCKey(for:), keyed by product id.

// ── Phase 4 establishes (App Store write-back) ────────────────────────────
// Inspector "Respond on App Store" panel for feedback where source == .appStore, keyed by the issue's reviewId marker.
// Uses AppStoreConnectClientProtocol.createOrUpdateResponse / deleteResponse via registry.responderContext(productID:);
// updates the Phase-3 AppStoreReviewMirrorStore.setResponse/clearResponse.

// ── Phase 5 establishes (email feedback source) ───────────────────────────
final class MailToFeedbackMirror { /* detached Task in MailSyncCoordinator.pollOnce(); gated on feedbackProductID != nil */ }
//   thread root → new issue (label source:email, markers source/fromAddress/messageId); reply in known thread → comment.
```

---

## Phase-3 dependency notes (what we Consume from earlier phases vs. what THIS plan defines)

This plan is scoped so it can be implemented even if Phases 0–2 land first. To avoid coupling to the `Repo → Product` rename, **Phase 3's runtime types read from the existing `RepoConfig`/`RepoStore`/`KeychainService(for: RepoConfig)`** that exist today, and take ASC config (`issuerID`, `keyID`, `appAppleID`) as **explicit parameters / value snapshots** rather than touching `Product`'s new fields directly. The single integration seam where `Product`'s new ASC fields are read is `AppStoreReviewCoordinatorRegistry.syncWithProducts(...)`, which receives a plain `[ASCProductConfig]` value snapshot (defined in this plan) — the caller (Phase 0/2 wiring or `AppFeedbackApp`) maps `Product`/`ProductConfig` into it. That keeps the whole App-Store read path independently buildable and testable here.

- **Consumes (from Shared Contracts / existing code, do NOT re-implement):**
  - `GitHubIssueWriter` actor with the real confirmed signatures:
    `func createIssue(owner: String, repo: String, title: String, body: String, labels: [String], milestoneNumber: Int?, token: String) async throws -> Int`
    `func updateIssue(owner: String, repo: String, number: Int, title: String? = nil, body: String? = nil, labels: [String]? = nil, milestoneNumber: Int?? = nil, state: String? = nil, token: String) async throws`
    and `GitHubIssueWriter.WriteError` (`.apiError(Int, message: String?)`, `.isNotFound`).
  - `GitHubCommentPoster.postComment(owner:repo:issueNumber:body:token:) async throws -> Int`.
  - `KeychainService` (enum of static methods, all `kSecAttrSynchronizable`, `service = "com.feedbackviewer.tokens"`); existing `KeychainService.loadSync(for: RepoConfig) -> String?` for the GitHub token.
  - `MockURLProtocol` + `URLSession.mock` (test helper, already present).
  - `NotificationCenter.cloudKitImportSucceeded` (defined in `RepoStore.swift`).
  - Phase-1 body markers `"source"/"rating"/"reviewerNickname"/"territory"/"reviewId"/"reviewCreatedAt"` and labels `source:app-store`, `rating:1…5`. **If Phase 1 has not landed yet**, this plan defines a self-contained `ASCIssueBody` formatter that emits exactly those marker lines and labels (Task 7) — when Phase 1 lands it owns the parser side; the strings are identical so they round-trip.
- **Produces (later phases rely on these EXACT names):** `AppStoreConnectAuth`, `AppStoreConnectClientProtocol`, `ASCReviewPage`, `ASCReview`, `ASCResponse`, `ASCApp`, `AppStoreConnectClient`, `StatusCarryingError`, `AppStoreConnectError`, `AppStoreReviewMirror`, `AppStoreReviewMirrorStore` (canonical CRUD: `allFor(productID:)`, `mirror(reviewId:)`, `mirror(productID:issueNumber:)`, `upsert(reviewId:productID:issueNumber:contentHash:)`, `setResponse(reviewId:responseId:state:)`, `clearResponse(reviewId:)`, `deleteByIssue(productID:issueNumber:)`), `AppStoreReviewCoordinator` (with observable `lastSuccessAt`/`lastError`), `AppStoreReviewCoordinatorRegistry.responderContext(productID:)`, `AppStoreResponderContext`, `FeedbackSourceIngestor`, `ASCProductConfig`, `AppStoreSourceForm`, `KeychainService.saveASCKey(_:for:)/loadASCKey(for:)/loadASCKeySync(for:)/deleteASCKey(for:)`.

## File Structure

**Create**
- `AppFeedback/Services/AppStore/AppStoreConnectAuth.swift` — actor minting ES256 JWTs via CryptoKit (cached ~15m, exp ≤ 20m).
- `AppFeedback/Services/AppStore/AppStoreConnectModels.swift` — `ASCReview`, `ASCResponse`, `ASCApp`, `ASCReviewPage`, `AppStoreConnectClientProtocol`, `AppStoreConnectError`, `FeedbackSourceIngestor`.
- `AppFeedback/Services/AppStore/AppStoreConnectClient.swift` — real `URLSession` impl: JSON decode, `links.next` follow, `X-Rate-Limit` parse, 401/403/429 mapping.
- `AppFeedback/Services/AppStore/AppStoreReviewSynthesizer.swift` — pure review→GitHub-issue body/title/labels rendering + `contentHash`.
- `AppFeedback/Services/AppStore/AppStoreReviewCoordinator.swift` — actor: incremental + periodic full re-scan; synthesis via `GitHubIssueWriter`; mirror writes; dedup + reconcile; conforms `FeedbackSourceIngestor`.
- `AppFeedback/Services/AppStore/AppStoreReviewCoordinatorRegistry.swift` — `@MainActor @Observable`, one coordinator per product-with-ASC; `syncWithProducts(_:)`; `pollNow()`/`start()`/`stop()`.
- `AppFeedback/Models/AppStoreReviewMirror.swift` — `@Model` (CloudKit-synced) + `ASCProductConfig` value snapshot struct.
- `AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift` — `@MainActor @Observable` store, version-bumps on remote change; canonical CRUD + dedup helpers over `AppStoreReviewMirror`.
- `AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift` — the REAL App Store Connect setup form (replaces the Phase-2 stub): Issuer/Key paste, `.p8` import via `.fileImporter` (macOS + iOS Files), Test, app picker via `client.listApps()` (+ manual numeric-id fallback), save `.p8`→Keychain + IDs→Product, shows `lastSuccessAt`/`lastError`.
- `AppFeedback/Views/Settings/Sources/AppStoreSourceFormModel.swift` — extracted, view-independent `@MainActor @Observable AppStoreSourceFormModel` (key-validation / app-pick / save state) so the form's logic is unit-tested without SwiftUI.
- `AppFeedbackTests/AppStoreConnectAuthTests.swift`
- `AppFeedbackTests/AppStoreConnectClientTests.swift`
- `AppFeedbackTests/AppStoreReviewSynthesizerTests.swift`
- `AppFeedbackTests/AppStoreReviewCoordinatorTests.swift`
- `AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift`
- `AppFeedbackTests/AppStoreSourceFormModelTests.swift` — drives `AppStoreSourceFormModel` (Test → validate key + populate apps; pick app; save) against the fake client.
- `AppFeedbackTests/Fakes/FakeAppStoreConnectClient.swift` — in-test `AppStoreConnectClientProtocol` (canned pages, capture of write calls).
- `AppFeedbackTests/Fakes/FakeIssueWriting.swift` — in-test `IssueWriting` recorder (create/update capture).

**Modify**
- `AppFeedback/Services/KeychainService.swift` — add `.p8` PEM store/load/delete keyed by product id.
- `AppFeedback/Services/GitHubIssueWriter.swift` — extract a tiny `IssueWriting` protocol so the coordinator can take a fake (no behavior change to the actor).
- `AppFeedback/App/AppFeedbackApp.swift` — register `AppStoreReviewMirror` in BOTH schema sites; build the `AppStoreReviewMirrorStore` + `AppStoreReviewCoordinatorRegistry`; sync it to the product list.
- `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift` — call the ASC registry's `pollNow()` during `runRefresh()`.
- `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift` — same hook for iOS.

> **Note on `AppStoreSourceForm.swift`:** Phase 2 created it as a compiling stub (`struct AppStoreSourceForm: View { init(store: ProductStore, product: ProductConfig) }`). This phase **rewrites that file in place** with the real form (Task 14). The `init(store:product:)` signature and the Phase-2 navigation entry from the Sources row are preserved verbatim so nothing in `ProductSettingsView` changes. The real form additionally needs the live `AppStoreReviewCoordinatorRegistry` (for `restart(productID:configs:)` + `responderContext(productID:)` status), injected from the SwiftUI `Environment`.

---

## Tasks

### Task 1: `IssueWriting` protocol seam over `GitHubIssueWriter`

**Files:**
- Modify: `AppFeedback/Services/GitHubIssueWriter.swift` (top of file, after imports)
- Create: `AppFeedbackTests/Fakes/FakeIssueWriting.swift`
- Test: `AppFeedbackTests/AppStoreReviewCoordinatorTests.swift` (compile-only smoke at first)

**Interfaces:**
- Consumes: existing `GitHubIssueWriter.createIssue(owner:repo:title:body:labels:milestoneNumber:token:) async throws -> Int` and `updateIssue(owner:repo:number:title:body:labels:milestoneNumber:state:token:) async throws`.
- Produces: `protocol IssueWriting: Sendable` with `createIssue`/`updateIssue` matching the actor signatures; `GitHubIssueWriter: IssueWriting`. Used by `AppStoreReviewCoordinator` so tests inject a fake.

Steps:
- [ ] **Step 1: Add the protocol.** In `AppFeedback/Services/GitHubIssueWriter.swift`, directly above `actor GitHubIssueWriter`, add:
  ```swift
  /// Narrow seam over `GitHubIssueWriter` so synthesis coordinators can inject a fake writer in
  /// tests. The signatures mirror the actor's exactly.
  protocol IssueWriting: Sendable {
      func createIssue(owner: String, repo: String, title: String, body: String,
                       labels: [String], milestoneNumber: Int?, token: String) async throws -> Int
      func updateIssue(owner: String, repo: String, number: Int,
                       title: String?, body: String?, labels: [String]?,
                       milestoneNumber: Int??, state: String?, token: String) async throws
  }
  ```
- [ ] **Step 2: Conform the actor.** Add the conformance line `extension GitHubIssueWriter: IssueWriting {}` at the bottom of `GitHubIssueWriter.swift`. The existing methods already satisfy it (defaulted params still satisfy a protocol requirement that lists every parameter, because the protocol witness matches by full signature; the existing declarations supply defaults, which is fine for direct calls and for protocol conformance).
- [ ] **Step 3: Create the fake writer.** Write `AppFeedbackTests/Fakes/FakeIssueWriting.swift`:
  ```swift
  import Foundation
  @testable import AppFeedback

  /// Records create/update calls and returns deterministic issue numbers so coordinator tests can
  /// assert synthesis without touching the network.
  actor FakeIssueWriting: IssueWriting {
      struct CreateCall: Sendable { let owner, repo, title, body: String; let labels: [String] }
      struct UpdateCall: Sendable { let owner, repo: String; let number: Int; let title: String?; let body: String?; let labels: [String]?; let state: String? }

      private(set) var creates: [CreateCall] = []
      private(set) var updates: [UpdateCall] = []
      private var nextNumber: Int
      var failNextCreate = false

      init(startingNumber: Int = 100) { self.nextNumber = startingNumber }

      func createIssue(owner: String, repo: String, title: String, body: String,
                       labels: [String], milestoneNumber: Int?, token: String) async throws -> Int {
          if failNextCreate { failNextCreate = false; throw GitHubIssueWriter.WriteError.apiError(500, message: "synthetic") }
          creates.append(CreateCall(owner: owner, repo: repo, title: title, body: body, labels: labels))
          defer { nextNumber += 1 }
          return nextNumber
      }
      func updateIssue(owner: String, repo: String, number: Int,
                       title: String?, body: String?, labels: [String]?,
                       milestoneNumber: Int??, state: String?, token: String) async throws {
          updates.append(UpdateCall(owner: owner, repo: repo, number: number, title: title, body: body, labels: labels, state: state))
      }
  }
  ```
- [ ] **Step 4: Build (red is OK — coordinator not yet written).** Run the zcode build for the test target:
  `xcodebuild build-for-testing -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -30`
  Expected: PASS (the protocol + fake compile; the empty test file compiles).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/GitHubIssueWriter.swift AppFeedbackTests/Fakes/FakeIssueWriting.swift AppFeedbackTests/AppStoreReviewCoordinatorTests.swift && git commit -m "feat(app-store): IssueWriting seam over GitHubIssueWriter + test fake" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 2: ASC value models, protocol, error type, and the ingestor seam

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreConnectModels.swift`
- Test: `AppFeedbackTests/AppStoreConnectModelsTests.swift` (statusCode mapping)

**Interfaces:**
- Produces: `ASCReview`, `ASCResponse`, `ASCApp`, `ASCReviewPage`, `AppStoreConnectClientProtocol`, `StatusCarryingError`, `AppStoreConnectError`, `FeedbackSourceIngestor` — all matching the Shared Contracts verbatim. `AppStoreConnectError` conforms to `StatusCarryingError`.

Steps:
- [ ] **Step 1: Write the failing statusCode-mapping test.** Create `AppFeedbackTests/AppStoreConnectModelsTests.swift`:
  ```swift
  import XCTest
  @testable import AppFeedback

  final class AppStoreConnectModelsTests: XCTestCase {
      func testAppStoreConnectErrorStatusCodeMapping() {
          XCTAssertEqual(AppStoreConnectError.authFailed.statusCode, 401)
          XCTAssertEqual(AppStoreConnectError.forbidden.statusCode, 403)
          XCTAssertEqual(AppStoreConnectError.rateLimited.statusCode, 429)
          XCTAssertEqual(AppStoreConnectError.http(500).statusCode, 500)
          XCTAssertEqual(AppStoreConnectError.http(409).statusCode, 409)
          XCTAssertEqual(AppStoreConnectError.decoding("x").statusCode, 0)
          XCTAssertEqual(AppStoreConnectError.badKey("x").statusCode, 0)
      }

      func testErrorIsStatusCarrying() {
          // The seam Phase 4 branches on: a 403 must be detectable through the protocol.
          let err: any StatusCarryingError = AppStoreConnectError.forbidden
          XCTAssertEqual(err.statusCode, 403)
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL — types missing).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectModelsTests 2>&1 | tail -25` — expected FAIL (no `AppStoreConnectError`).
- [ ] **Step 3: Write the models file.** Create `AppFeedback/Services/AppStore/AppStoreConnectModels.swift`:
  ```swift
  import Foundation

  struct ASCResponse: Sendable, Equatable {
      let id: String
      let responseBody: String
      let state: String          // "PUBLISHED" | "PENDING_PUBLISH"
      let lastModifiedDate: Date
  }

  struct ASCReview: Sendable, Equatable {
      let id: String
      let rating: Int            // 1…5
      let title: String?
      let body: String?
      let reviewerNickname: String?
      let createdDate: Date
      let territory: String      // ISO-3166 alpha-3
      let response: ASCResponse?
  }

  struct ASCReviewPage: Sendable {
      let reviews: [ASCReview]
      let nextCursor: String?    // opaque links.next cursor (full URL); nil ⇒ last page
      let rateRemaining: Int?    // X-Rate-Limit user-hour-rem
  }

  struct ASCApp: Sendable, Equatable {
      let id: String             // opaque ASC app id (numeric string)
      let bundleId: String
      let name: String
  }

  /// Errors that carry an HTTP-status hint so callers (e.g. Phase 4's 403 read-only path) can
  /// branch on the wire status without switching on the concrete error type.
  protocol StatusCarryingError: Error {
      var statusCode: Int { get }
  }

  /// Errors surfaced by the App Store Connect client, mapped from HTTP status. `statusCode` is the
  /// canonical mapping consumed by Phase 4: authFailed→401, forbidden→403, rateLimited→429,
  /// http(n)→n, everything else→0.
  enum AppStoreConnectError: StatusCarryingError, Equatable {
      case authFailed                 // 401 — bad/expired JWT
      case forbidden                  // 403 — read-only key (write denied) / no access
      case rateLimited                // 429 RATE_LIMIT_EXCEEDED
      case http(Int)                  // any other non-2xx
      case decoding(String)           // JSON decode failure (detail is for logging only)
      case badKey(String)             // .p8 PEM not loadable (detail is for logging only)

      var statusCode: Int {
          switch self {
          case .authFailed:        return 401
          case .forbidden:         return 403
          case .rateLimited:       return 429
          case let .http(code):    return code
          case .decoding, .badKey: return 0
          }
      }
  }

  protocol AppStoreConnectClientProtocol: Sendable {
      func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage
      func listApps() async throws -> [ASCApp]
      func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse  // POST upsert
      func deleteResponse(responseId: String) async throws
  }

  /// Thin seam so a future feedback source is a well-defined task. App Store reviews conform via
  /// `AppStoreReviewCoordinator`.
  protocol FeedbackSourceIngestor: Sendable {
      func poll() async throws
  }
  ```
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectModelsTests 2>&1 | tail -20` — expected PASS (2 tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreConnectModels.swift AppFeedbackTests/AppStoreConnectModelsTests.swift && git commit -m "feat(app-store): ASC value models + StatusCarryingError + client protocol + ingestor seam" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 3: `AppStoreConnectAuth` — ES256 JWT via CryptoKit

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreConnectAuth.swift`
- Test: `AppFeedbackTests/AppStoreConnectAuthTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `actor AppStoreConnectAuth { init(issuerID:keyID:p8PEM:); func token() async throws -> String }` plus a static `AppStoreConnectAuth.makeJWT(issuerID:keyID:p8PEM:now:) throws -> String` (testable without the cache) and `AppStoreConnectAuth.base64URL(_:) -> String`.

Steps:
- [ ] **Step 1: Write the failing test.** Create `AppFeedbackTests/AppStoreConnectAuthTests.swift`:
  ```swift
  import XCTest
  import CryptoKit
  @testable import AppFeedback

  final class AppStoreConnectAuthTests: XCTestCase {
      // Generate a P256 key IN TEST (never the Keychain) and use its PEM as the .p8.
      private func makeKey() -> (pem: String, pub: P256.Signing.PublicKey) {
          let key = P256.Signing.PrivateKey()
          return (key.pemRepresentation, key.publicKey)
      }

      private func b64urlDecode(_ s: String) -> Data {
          var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
          while t.count % 4 != 0 { t += "=" }
          return Data(base64Encoded: t)!
      }

      func testJWTHeaderPayloadAndExp() throws {
          let (pem, _) = makeKey()
          let now = Date(timeIntervalSince1970: 1_700_000_000)
          let jwt = try AppStoreConnectAuth.makeJWT(issuerID: "ISS-1", keyID: "KID-1", p8PEM: pem, now: now)
          let parts = jwt.split(separator: ".").map(String.init)
          XCTAssertEqual(parts.count, 3)
          let header = try JSONSerialization.jsonObject(with: b64urlDecode(parts[0])) as! [String: Any]
          XCTAssertEqual(header["alg"] as? String, "ES256")
          XCTAssertEqual(header["kid"] as? String, "KID-1")
          XCTAssertEqual(header["typ"] as? String, "JWT")
          let payload = try JSONSerialization.jsonObject(with: b64urlDecode(parts[1])) as! [String: Any]
          XCTAssertEqual(payload["iss"] as? String, "ISS-1")
          XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
          let iat = payload["iat"] as! Int
          let exp = payload["exp"] as! Int
          XCTAssertEqual(iat, Int(now.timeIntervalSince1970))
          XCTAssertLessThanOrEqual(exp - iat, 1200)   // ≤ 20 minutes
          XCTAssertGreaterThan(exp, iat)
      }

      func testSignatureIsRaw64BytesVerifiableByPublicKey() throws {
          let (pem, pub) = makeKey()
          let now = Date(timeIntervalSince1970: 1_700_000_000)
          let jwt = try AppStoreConnectAuth.makeJWT(issuerID: "i", keyID: "k", p8PEM: pem, now: now)
          let parts = jwt.split(separator: ".").map(String.init)
          let signingInput = parts[0] + "." + parts[1]
          let sigData = b64urlDecode(parts[2])
          XCTAssertEqual(sigData.count, 64, "ASC requires 64-byte raw r||s, NOT DER")
          // signature(for:) hashes SHA-256 internally → verify the same way.
          let sig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
          XCTAssertTrue(pub.isValidSignature(sig, for: Data(signingInput.utf8)))
      }

      func testTokenCachesWithinWindow() async throws {
          let (pem, _) = makeKey()
          let auth = AppStoreConnectAuth(issuerID: "i", keyID: "k", p8PEM: pem)
          let a = try await auth.token()
          let b = try await auth.token()
          XCTAssertEqual(a, b, "token() reuses the cached JWT until it nears expiry")
      }

      func testBadPEMThrows() {
          XCTAssertThrowsError(try AppStoreConnectAuth.makeJWT(issuerID: "i", keyID: "k", p8PEM: "not a key", now: Date()))
      }
  }
  ```
- [ ] **Step 2: Run the test (expect FAIL — type missing).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectAuthTests 2>&1 | tail -25` — expected FAIL (compile error: no `AppStoreConnectAuth`).
- [ ] **Step 3: Implement the actor.** Create `AppFeedback/Services/AppStore/AppStoreConnectAuth.swift`:
  ```swift
  import Foundation
  import CryptoKit

  /// Mints an ES256 JWT for App Store Connect from a `.p8` PEM private key, per the ASC auth
  /// contract: header {alg:ES256,kid,typ:JWT}, payload {iss,iat,exp(≤20m),aud:appstoreconnect-v1},
  /// signed with CryptoKit P256 using the 64-byte raw r‖s representation (NOT DER). The token is
  /// cached and only re-minted as it nears expiry (we keep a ~15-minute usable window).
  actor AppStoreConnectAuth {
      private let issuerID: String
      private let keyID: String
      private let p8PEM: String

      private var cached: (token: String, expiresAt: Date)?

      /// Usable lifetime we hand out before re-minting. ASC allows exp ≤ 20 min; we mint with a
      /// 20-minute exp and refresh once under 5 minutes remain, so callers always get ≥ ~15 min.
      private static let lifetime: TimeInterval = 20 * 60
      private static let refreshFloor: TimeInterval = 5 * 60

      init(issuerID: String, keyID: String, p8PEM: String) {
          self.issuerID = issuerID
          self.keyID = keyID
          self.p8PEM = p8PEM
      }

      func token() async throws -> String {
          let now = Date()
          if let cached, cached.expiresAt.timeIntervalSince(now) > Self.refreshFloor {
              return cached.token
          }
          let jwt = try Self.makeJWT(issuerID: issuerID, keyID: keyID, p8PEM: p8PEM, now: now)
          cached = (jwt, now.addingTimeInterval(Self.lifetime))
          return jwt
      }

      // MARK: - Pure JWT minting (testable without the cache)

      static func makeJWT(issuerID: String, keyID: String, p8PEM: String, now: Date) throws -> String {
          let key: P256.Signing.PrivateKey
          do {
              key = try P256.Signing.PrivateKey(pemRepresentation: p8PEM)
          } catch {
              throw AppStoreConnectError.badKey(error.localizedDescription)
          }
          let iat = Int(now.timeIntervalSince1970)
          let exp = iat + 1200   // 20 minutes, the ASC maximum
          let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
          let payload: [String: Any] = ["iss": issuerID, "iat": iat, "exp": exp, "aud": "appstoreconnect-v1"]
          let headerSegment = base64URL(try JSONSerialization.data(withJSONObject: header))
          let payloadSegment = base64URL(try JSONSerialization.data(withJSONObject: payload))
          let signingInput = headerSegment + "." + payloadSegment
          // signature(for:) applies SHA-256 internally — do NOT pre-hash.
          let signature = try key.signature(for: Data(signingInput.utf8))
          let sigSegment = base64URL(signature.rawRepresentation)   // 64-byte r‖s, NOT DER
          return signingInput + "." + sigSegment
      }

      /// base64url: standard base64 with `+`→`-`, `/`→`_`, padding `=` stripped.
      static func base64URL(_ data: Data) -> String {
          data.base64EncodedString()
              .replacingOccurrences(of: "+", with: "-")
              .replacingOccurrences(of: "/", with: "_")
              .replacingOccurrences(of: "=", with: "")
      }
  }
  ```
- [ ] **Step 4: Run the test (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectAuthTests 2>&1 | tail -20` — expected PASS (4 tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreConnectAuth.swift AppFeedbackTests/AppStoreConnectAuthTests.swift && git commit -m "feat(app-store): AppStoreConnectAuth ES256 JWT minting (CryptoKit, raw 64-byte sig)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 4: `AppStoreConnectClient` — real URLSession impl (parse, paginate, rate-limit, status mapping)

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreConnectClient.swift`
- Test: `AppFeedbackTests/AppStoreConnectClientTests.swift`

**Interfaces:**
- Consumes: `AppStoreConnectAuth.token()`; `AppStoreConnectClientProtocol`, `ASCReviewPage`, `ASCReview`, `ASCResponse`, `ASCApp`, `AppStoreConnectError`; `MockURLProtocol`/`URLSession.mock`.
- Produces: `final class AppStoreConnectClient: AppStoreConnectClientProtocol` with `init(auth: AppStoreConnectAuth, session: URLSession = .shared)`.

Steps:
- [ ] **Step 1: Write the failing tests (pagination, include=response, rate-limit, 401/403/429).** Create `AppFeedbackTests/AppStoreConnectClientTests.swift`:
  ```swift
  import XCTest
  import CryptoKit
  @testable import AppFeedback

  final class AppStoreConnectClientTests: XCTestCase {
      override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

      private func auth() -> AppStoreConnectAuth {
          AppStoreConnectAuth(issuerID: "i", keyID: "k", p8PEM: P256.Signing.PrivateKey().pemRepresentation)
      }

      private static let page1 = """
      {"data":[
        {"type":"customerReviews","id":"R1","attributes":{"rating":5,"title":"Great","body":"Love it","reviewerNickname":"sam","createdDate":"2026-06-10T12:00:00.000Z","territory":"USA"},
         "relationships":{"response":{"data":{"type":"customerReviewResponses","id":"RESP1"}}}}
      ],
      "included":[
        {"type":"customerReviewResponses","id":"RESP1","attributes":{"responseBody":"Thanks!","lastModifiedDate":"2026-06-11T09:00:00.000Z","state":"PUBLISHED"}}
      ],
      "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2"}}
      """
      private static let page2 = """
      {"data":[
        {"type":"customerReviews","id":"R2","attributes":{"rating":1,"title":null,"body":"Crashes","reviewerNickname":"lee","createdDate":"2026-06-09T08:00:00.000Z","territory":"GBR"}}
      ],
      "links":{}}
      """

      func testListReviewsParsesIncludedResponseAndCursor() async throws {
          MockURLProtocol.requestHandler = { req in
              XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer "), true)
              let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                  headerFields: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:3490;"])!
              return (resp, Self.page1.data(using: .utf8)!)
          }
          let client = AppStoreConnectClient(auth: auth(), session: .mock)
          let page = try await client.listReviews(appAppleID: "123", page: nil)
          XCTAssertEqual(page.reviews.count, 1)
          XCTAssertEqual(page.reviews[0].id, "R1")
          XCTAssertEqual(page.reviews[0].rating, 5)
          XCTAssertEqual(page.reviews[0].territory, "USA")
          XCTAssertEqual(page.reviews[0].response?.id, "RESP1")
          XCTAssertEqual(page.reviews[0].response?.state, "PUBLISHED")
          XCTAssertEqual(page.reviews[0].response?.responseBody, "Thanks!")
          XCTAssertEqual(page.nextCursor, "https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2")
          XCTAssertEqual(page.rateRemaining, 3490)
      }

      func testTitleAndResponseAbsenceHandled() async throws {
          MockURLProtocol.requestHandler = { req in
              (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
               Self.page2.data(using: .utf8)!)
          }
          let client = AppStoreConnectClient(auth: auth(), session: .mock)
          let page = try await client.listReviews(appAppleID: "123", page: nil)
          XCTAssertEqual(page.reviews[0].id, "R2")
          XCTAssertNil(page.reviews[0].title)         // rating-with-no-title row
          XCTAssertNil(page.reviews[0].response)      // no developer response
          XCTAssertNil(page.nextCursor)               // empty links ⇒ last page
      }

      func testCursorIsUsedVerbatimAsURL() async throws {
          var seenURL: String?
          MockURLProtocol.requestHandler = { req in
              seenURL = req.url?.absoluteString
              return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                      Self.page2.data(using: .utf8)!)
          }
          let client = AppStoreConnectClient(auth: auth(), session: .mock)
          _ = try await client.listReviews(appAppleID: "123", page: "https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2")
          XCTAssertEqual(seenURL, "https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2")
      }

      func testStatusMapping() async {
          func run(_ code: Int, headers: [String: String]? = nil) async -> Error? {
              MockURLProtocol.requestHandler = { req in
                  (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, Data("{}".utf8))
              }
              let client = AppStoreConnectClient(auth: auth(), session: .mock)
              do { _ = try await client.listReviews(appAppleID: "123", page: nil); return nil }
              catch { return error }
          }
          if case AppStoreConnectError.authFailed = (await run(401))! {} else { XCTFail("401→authFailed") }
          if case AppStoreConnectError.forbidden = (await run(403))! {} else { XCTFail("403→forbidden") }
          if case AppStoreConnectError.rateLimited = (await run(429, headers: ["X-Rate-Limit": "user-hour-rem:0;"]))! {} else { XCTFail("429→rateLimited") }
          if case AppStoreConnectError.http(500) = (await run(500))! {} else { XCTFail("500→http") }
          // statusCode mapping is the seam Phase 4 branches on.
          XCTAssertEqual(((await run(403)) as? AppStoreConnectError)?.statusCode, 403)
      }

      func testCreateOrUpdateResponseUpserts() async throws {
          var body: [String: Any]?
          MockURLProtocol.requestHandler = { req in
              if let d = req.httpBody { body = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
              else if let s = req.httpBodyStream {
                  s.open(); defer { s.close() }
                  var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                  while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
                  body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
              }
              XCTAssertEqual(req.httpMethod, "POST")
              let json = """
              {"data":{"type":"customerReviewResponses","id":"RESP9","attributes":{"responseBody":"Hi","state":"PENDING_PUBLISH","lastModifiedDate":"2026-06-18T00:00:00.000Z"}}}
              """
              return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json.data(using: .utf8)!)
          }
          let client = AppStoreConnectClient(auth: auth(), session: .mock)
          let resp = try await client.createOrUpdateResponse(reviewId: "R1", body: "Hi")
          XCTAssertEqual(resp.id, "RESP9")
          XCTAssertEqual(resp.state, "PENDING_PUBLISH")
          let data = body?["data"] as? [String: Any]
          XCTAssertEqual(data?["type"] as? String, "customerReviewResponses")
          let rel = ((data?["relationships"] as? [String: Any])?["review"] as? [String: Any])?["data"] as? [String: Any]
          XCTAssertEqual(rel?["id"] as? String, "R1")
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectClientTests 2>&1 | tail -25` — expected FAIL (no `AppStoreConnectClient`).
- [ ] **Step 3: Implement the client.** Create `AppFeedback/Services/AppStore/AppStoreConnectClient.swift`:
  ```swift
  import Foundation

  /// Real App Store Connect API client. Authenticates each request with an ES256 JWT from
  /// `AppStoreConnectAuth`, decodes the documented `customerReviews` JSON (folding `included`
  /// response resources into each review), follows the opaque `links.next` cursor, parses the
  /// `X-Rate-Limit` `user-hour-rem` header, and maps 401/403/429 to typed errors.
  final class AppStoreConnectClient: AppStoreConnectClientProtocol {
      private let auth: AppStoreConnectAuth
      private let session: URLSession
      private static let base = "https://api.appstoreconnect.apple.com"

      init(auth: AppStoreConnectAuth, session: URLSession = .shared) {
          self.auth = auth
          self.session = session
      }

      // MARK: - Reviews

      func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
          // links.next is a full URL; the first page is built from the field-selection query.
          let urlString = cursor ?? "\(Self.base)/v1/apps/\(appAppleID)/customerReviews"
              + "?sort=-createdDate&limit=200&include=response"
              + "&fields[customerReviews]=rating,title,body,reviewerNickname,createdDate,territory"
              + "&fields[customerReviewResponses]=responseBody,lastModifiedDate,state"
          guard let url = URL(string: urlString) else { throw AppStoreConnectError.http(0) }
          let (data, http) = try await send(url: url, method: "GET", body: nil)
          let rateRemaining = Self.parseRateRemaining(http)
          try Self.mapStatus(http.statusCode, rateRemaining: rateRemaining, data: data)
          let decoded: ReviewsEnvelope
          do { decoded = try Self.decoder.decode(ReviewsEnvelope.self, from: data) }
          catch { throw AppStoreConnectError.decoding(String(describing: error)) }
          let responsesByID = Dictionary(uniqueKeysWithValues:
              (decoded.included ?? [])
                  .filter { $0.type == "customerReviewResponses" }
                  .compactMap { inc -> (String, ASCResponse)? in
                      guard let a = inc.attributes else { return nil }
                      return (inc.id, ASCResponse(id: inc.id, responseBody: a.responseBody ?? "",
                                                  state: a.state ?? "", lastModifiedDate: a.lastModifiedDate ?? .distantPast))
                  })
          let reviews: [ASCReview] = decoded.data.map { row in
              let respID = row.relationships?.response?.data?.id
              return ASCReview(
                  id: row.id,
                  rating: row.attributes?.rating ?? 0,
                  title: row.attributes?.title,
                  body: row.attributes?.body,
                  reviewerNickname: row.attributes?.reviewerNickname,
                  createdDate: row.attributes?.createdDate ?? .distantPast,
                  territory: row.attributes?.territory ?? "",
                  response: respID.flatMap { responsesByID[$0] }
              )
          }
          let next = decoded.links?.next
          return ASCReviewPage(reviews: reviews, nextCursor: (next?.isEmpty == false) ? next : nil, rateRemaining: rateRemaining)
      }

      // MARK: - Apps

      func listApps() async throws -> [ASCApp] {
          guard let url = URL(string: "\(Self.base)/v1/apps?fields[apps]=bundleId,name&limit=200") else {
              throw AppStoreConnectError.http(0)
          }
          let (data, http) = try await send(url: url, method: "GET", body: nil)
          try Self.mapStatus(http.statusCode, rateRemaining: Self.parseRateRemaining(http), data: data)
          do {
              let env = try Self.decoder.decode(AppsEnvelope.self, from: data)
              return env.data.map { ASCApp(id: $0.id, bundleId: $0.attributes?.bundleId ?? "", name: $0.attributes?.name ?? "") }
          } catch { throw AppStoreConnectError.decoding(String(describing: error)) }
      }

      // MARK: - Responses (write-back; Phase 4 UI consumes these)

      func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
          guard let url = URL(string: "\(Self.base)/v1/customerReviewResponses") else { throw AppStoreConnectError.http(0) }
          let payload: [String: Any] = ["data": [
              "type": "customerReviewResponses",
              "attributes": ["responseBody": body],
              "relationships": ["review": ["data": ["type": "customerReviews", "id": reviewId]]],
          ]]
          let json = try JSONSerialization.data(withJSONObject: payload)
          let (data, http) = try await send(url: url, method: "POST", body: json)
          try Self.mapStatus(http.statusCode, rateRemaining: Self.parseRateRemaining(http), data: data)
          do {
              let env = try Self.decoder.decode(SingleResponseEnvelope.self, from: data)
              guard let a = env.data.attributes else { throw AppStoreConnectError.decoding("missing response attributes") }
              return ASCResponse(id: env.data.id, responseBody: a.responseBody ?? body,
                                 state: a.state ?? "PENDING_PUBLISH", lastModifiedDate: a.lastModifiedDate ?? Date())
          } catch let e as AppStoreConnectError { throw e }
          catch { throw AppStoreConnectError.decoding(String(describing: error)) }
      }

      func deleteResponse(responseId: String) async throws {
          guard let url = URL(string: "\(Self.base)/v1/customerReviewResponses/\(responseId)") else { throw AppStoreConnectError.http(0) }
          let (data, http) = try await send(url: url, method: "DELETE", body: nil)
          // 204 No Content on success.
          guard http.statusCode == 204 else {
              try Self.mapStatus(http.statusCode, rateRemaining: Self.parseRateRemaining(http), data: data)
              return
          }
      }

      // MARK: - Transport

      private func send(url: URL, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
          let token = try await auth.token()
          var request = URLRequest(url: url)
          request.httpMethod = method
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          request.setValue("application/json", forHTTPHeaderField: "Accept")
          if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
          let (data, response) = try await session.data(for: request)
          guard let http = response as? HTTPURLResponse else { throw AppStoreConnectError.http(0) }
          return (data, http)
      }

      private static func mapStatus(_ code: Int, rateRemaining: Int?, data: Data) throws {
          switch code {
          case 200...299: return
          case 401: throw AppStoreConnectError.authFailed
          case 403: throw AppStoreConnectError.forbidden
          case 429: throw AppStoreConnectError.rateLimited
          default:  throw AppStoreConnectError.http(code)
          }
      }

      /// Parses `user-hour-rem:<n>` out of the `X-Rate-Limit` header
      /// (e.g. "user-hour-lim:3500;user-hour-rem:3490;").
      static func parseRateRemaining(_ http: HTTPURLResponse) -> Int? {
          guard let raw = http.value(forHTTPHeaderField: "X-Rate-Limit") else { return nil }
          for part in raw.split(separator: ";") {
              let kv = part.split(separator: ":", maxSplits: 1)
              if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "user-hour-rem" {
                  return Int(kv[1].trimmingCharacters(in: .whitespaces))
              }
          }
          return nil
      }

      // MARK: - Decoding shapes

      private static let decoder: JSONDecoder = {
          let d = JSONDecoder()
          let iso = ISO8601DateFormatter()
          iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
          let isoNoFraction = ISO8601DateFormatter()
          isoNoFraction.formatOptions = [.withInternetDateTime]
          d.dateDecodingStrategy = .custom { decoder in
              let s = try decoder.singleValueContainer().decode(String.self)
              if let date = iso.date(from: s) ?? isoNoFraction.date(from: s) { return date }
              throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "bad date \(s)")
          }
          return d
      }()

      private struct ReviewsEnvelope: Decodable {
          let data: [ReviewRow]
          let included: [IncludedRow]?
          let links: Links?
      }
      private struct ReviewRow: Decodable {
          let id: String
          let attributes: ReviewAttributes?
          let relationships: ReviewRelationships?
      }
      private struct ReviewAttributes: Decodable {
          let rating: Int?
          let title: String?
          let body: String?
          let reviewerNickname: String?
          let createdDate: Date?
          let territory: String?
      }
      private struct ReviewRelationships: Decodable {
          let response: RelationshipBox?
      }
      private struct RelationshipBox: Decodable { let data: RelationshipRef? }
      private struct RelationshipRef: Decodable { let id: String; let type: String }
      private struct IncludedRow: Decodable { let id: String; let type: String; let attributes: ResponseAttributes? }
      private struct ResponseAttributes: Decodable {
          let responseBody: String?
          let state: String?
          let lastModifiedDate: Date?
      }
      private struct Links: Decodable { let next: String? }
      private struct AppsEnvelope: Decodable { let data: [AppRow] }
      private struct AppRow: Decodable { let id: String; let attributes: AppAttributes? }
      private struct AppAttributes: Decodable { let bundleId: String?; let name: String? }
      private struct SingleResponseEnvelope: Decodable { let data: IncludedRow }
  }
  ```
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectClientTests 2>&1 | tail -20` — expected PASS (5 tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreConnectClient.swift AppFeedbackTests/AppStoreConnectClientTests.swift && git commit -m "feat(app-store): AppStoreConnectClient (parse+paginate+rate-limit+status mapping)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 5: `KeychainService` `.p8` PEM methods keyed by product id

**Files:**
- Modify: `AppFeedback/Services/KeychainService.swift` (add a "MARK: - App Store Connect .p8" section after the GitHub-token section)
- Test: `AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift` is for the store; the Keychain methods are exercised through a compile-check (the test host has no Keychain, so live round-trips would join the ~11 known failures — do NOT add assert-on-load tests for them).

**Interfaces:**
- Consumes: existing `saveSynchronizablePassword`/`loadSynchronizablePassword`/`deleteSynchronizablePassword` private helpers and `loadSync` pattern in `KeychainService`.
- Produces: `KeychainService.saveASCKey(_:for:) async -> Bool`, `loadASCKey(for:) async -> String?`, `loadASCKeySync(for:) -> String?`, `deleteASCKey(for:) async`, all keyed by `UUID` (product id).

Steps:
- [ ] **Step 1: Add the methods.** In `AppFeedback/Services/KeychainService.swift`, after the `// MARK: - GitHub account tokens` block (before `// MARK: - Shared helpers`), insert:
  ```swift
      // MARK: - App Store Connect .p8 private key (PEM), keyed by product id

      private static func ascKeyAccountKey(for productID: UUID) -> String {
          "appstore.p8.\(productID.uuidString)"
      }

      @discardableResult
      static func saveASCKey(_ pem: String, for productID: UUID) async -> Bool {
          await saveSynchronizablePassword(pem, account: ascKeyAccountKey(for: productID))
      }

      static func loadASCKey(for productID: UUID) async -> String? {
          await loadSynchronizablePassword(account: ascKeyAccountKey(for: productID))
      }

      /// Synchronous variant for `@Sendable () -> String?` / non-async callers, paralleling
      /// `loadGitHubTokenSync(for:)`.
      static func loadASCKeySync(for productID: UUID) -> String? {
          let query: [String: Any] = [
              kSecClass as String:              kSecClassGenericPassword,
              kSecAttrService as String:        service,
              kSecAttrAccount as String:        ascKeyAccountKey(for: productID),
              kSecAttrSynchronizable as String: kCFBooleanTrue!,
              kSecReturnData as String:         true,
              kSecMatchLimit as String:         kSecMatchLimitOne,
          ]
          var result: AnyObject?
          guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data else { return nil }
          return String(data: data, encoding: .utf8)
      }

      static func deleteASCKey(for productID: UUID) async {
          await deleteSynchronizablePassword(account: ascKeyAccountKey(for: productID))
      }
  ```
- [ ] **Step 2: Build.** `xcodebuild build-for-testing -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -20` — expected PASS.
- [ ] **Step 3: Commit.** `git add AppFeedback/Services/KeychainService.swift && git commit -m "feat(app-store): KeychainService .p8 PEM store/load/delete keyed by product id" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 6: `AppStoreReviewMirror` `@Model` + `ASCProductConfig` + schema registration

**Files:**
- Create: `AppFeedback/Models/AppStoreReviewMirror.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (both schema sites: the `isTesting` container `for:` list AND the `cloudSchema` array + cloud-config `for:` list)
- Test: `AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift` (model-shape sanity; full store CRUD in Task 9)

**Interfaces:**
- Consumes: nothing.
- Produces: `@Model final class AppStoreReviewMirror` (CloudKit-synced; fields per Shared Contracts) and `struct ASCProductConfig: Sendable, Equatable` value snapshot.

Steps:
- [ ] **Step 1: Write the model + config.** Create `AppFeedback/Models/AppStoreReviewMirror.swift`:
  ```swift
  import Foundation
  import SwiftData

  /// CloudKit-synced map from an App Store Connect review to the GitHub issue we synthesized for it.
  /// Drives cross-device dedup (so two devices polling the same product don't create two issues),
  /// edit detection (`contentHash`), and deletion handling. CloudKit requires every stored property
  /// to be optional or to carry a default — hence the defaulted initializers below.
  @Model
  final class AppStoreReviewMirror {
      var reviewId: String = ""
      var productID: UUID = UUID()
      var issueNumber: Int = 0
      /// SHA-256 hex of the normalized `rating + "\n" + title + "\n" + body`.
      var contentHash: String = ""
      /// nil ⇒ no developer response; else "PENDING_PUBLISH" | "PUBLISHED".
      var responseState: String?
      /// `customerReviewResponses` id (for DELETE / edit), nil until a response is posted.
      var responseId: String?

      init(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String,
           responseState: String? = nil, responseId: String? = nil) {
          self.reviewId = reviewId
          self.productID = productID
          self.issueNumber = issueNumber
          self.contentHash = contentHash
          self.responseState = responseState
          self.responseId = responseId
      }
  }

  /// Value snapshot of a product's App Store configuration, captured on the MainActor and handed to
  /// the (off-MainActor) coordinator. Decouples the App-Store read path from the `Product`/`Repo`
  /// rename: the wiring layer maps a `Product`/`ProductConfig` into this.
  struct ASCProductConfig: Sendable, Equatable, Identifiable {
      let id: UUID              // product id
      let owner: String         // GitHub owner (the sink)
      let repo: String          // GitHub repo (the sink)
      let issuerID: String
      let keyID: String
      let appAppleID: String    // opaque ASC app id (numeric string)
  }
  ```
- [ ] **Step 2: Register in the `isTesting` container.** In `AppFeedbackApp.init()`, the `if isTesting` branch `ModelContainer(for: ...)` list, add `AppStoreReviewMirror.self,` (place it next to `RepoFilterPreference.self,`).
- [ ] **Step 3: Register in `cloudSchema`.** In the `else` branch, change `let cloudSchema = Schema([... RepoFilterPreference.self])` to include `AppStoreReviewMirror.self` (it is CloudKit-synced, so it belongs in `cloudSchema`, NOT `localSchema`). Then add `AppStoreReviewMirror.self,` to the non-test `ModelContainer(for: ...)` list as well (same place as the test branch).
- [ ] **Step 4: Build.** `xcodebuild build-for-testing -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -25` — expected PASS (CloudKit-synced `@Model` with all-defaulted properties validates).
- [ ] **Step 5: Commit.** `git add AppFeedback/Models/AppStoreReviewMirror.swift AppFeedback/App/AppFeedbackApp.swift && git commit -m "feat(app-store): AppStoreReviewMirror @Model + ASCProductConfig + schema registration" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 7: `AppStoreReviewSynthesizer` — pure review→issue rendering + contentHash

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreReviewSynthesizer.swift`
- Test: `AppFeedbackTests/AppStoreReviewSynthesizerTests.swift`

**Interfaces:**
- Consumes: `ASCReview`. Phase-1 marker keys `"source"/"rating"/"reviewerNickname"/"territory"/"reviewId"/"reviewCreatedAt"` and labels `source:app-store`, `rating:N` (this synthesizer OWNS the formatter side for Phase 3; Phase 1 owns the parser side — the strings are identical so they round-trip).
- Produces: `enum AppStoreReviewSynthesizer` with `static func title(for:) -> String`, `static func body(for:) -> String`, `static func labels(for:) -> [String]`, `static func contentHash(for:) -> String`, `static func editedNote(at:) -> String`, and the constants `reviewDeletedLabel = "review-deleted"`.

Steps:
- [ ] **Step 1: Write the failing tests.** Create `AppFeedbackTests/AppStoreReviewSynthesizerTests.swift`:
  ```swift
  import XCTest
  @testable import AppFeedback

  final class AppStoreReviewSynthesizerTests: XCTestCase {
      private func review(id: String = "R1", rating: Int = 4, title: String? = "Nice",
                          body: String? = "Body text", nick: String? = "sam",
                          territory: String = "USA") -> ASCReview {
          ASCReview(id: id, rating: rating, title: title, body: body, reviewerNickname: nick,
                    createdDate: Date(timeIntervalSince1970: 1_700_000_000), territory: territory, response: nil)
      }

      func testTitleUsesReviewTitle() {
          XCTAssertEqual(AppStoreReviewSynthesizer.title(for: review(title: "Great app")), "Great app")
      }

      func testTitleFallsBackWhenNoTitle() {
          let t = AppStoreReviewSynthesizer.title(for: review(title: nil, body: "Crashes on launch", territory: "GBR"))
          XCTAssertFalse(t.isEmpty)
          XCTAssertTrue(t.contains("★") || t.localizedCaseInsensitiveContains("review"))
      }

      func testBodyContainsAllMarkers() {
          let b = AppStoreReviewSynthesizer.body(for: review())
          XCTAssertTrue(b.contains("source: app-store"))
          XCTAssertTrue(b.contains("rating: 4"))
          XCTAssertTrue(b.contains("reviewerNickname: sam"))
          XCTAssertTrue(b.contains("territory: USA"))
          XCTAssertTrue(b.contains("reviewId: R1"))
          XCTAssertTrue(b.contains("reviewCreatedAt: "))
          XCTAssertTrue(b.contains("Body text"))
      }

      func testLabels() {
          XCTAssertEqual(AppStoreReviewSynthesizer.labels(for: review(rating: 3)),
                         ["source:app-store", "rating:3"])
      }

      func testContentHashChangesWithContent() {
          let h1 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 4, title: "A", body: "B"))
          let h2 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 4, title: "A", body: "B"))
          let h3 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 5, title: "A", body: "B"))
          let h4 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 4, title: "A", body: "B2"))
          XCTAssertEqual(h1, h2, "stable for identical content")
          XCTAssertNotEqual(h1, h3, "rating change ⇒ new hash")
          XCTAssertNotEqual(h1, h4, "body change ⇒ new hash")
          XCTAssertEqual(h1.count, 64, "SHA-256 hex")
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewSynthesizerTests 2>&1 | tail -25` — expected FAIL.
- [ ] **Step 3: Implement.** Create `AppFeedback/Services/AppStore/AppStoreReviewSynthesizer.swift`:
  ```swift
  import Foundation
  import CryptoKit

  /// Pure rendering of an App Store review into the GitHub-issue title/body/labels that the rest of
  /// the app understands. The body carries the Phase-1 source markers verbatim so origin survives the
  /// GitHub round-trip back into the parser. No I/O — fully unit-testable.
  enum AppStoreReviewSynthesizer {
      static let reviewDeletedLabel = "review-deleted"

      private static let iso: ISO8601DateFormatter = {
          let f = ISO8601DateFormatter()
          f.formatOptions = [.withInternetDateTime]
          return f
      }()

      static func title(for review: ASCReview) -> String {
          if let t = review.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
          if let b = review.body?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
              return String(b.prefix(60))
          }
          return "\(stars(review.rating)) review (\(review.territory))"
      }

      /// Inline-star glyph used in the fallback title.
      private static func stars(_ rating: Int) -> String {
          let r = max(0, min(5, rating))
          return String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r)
      }

      static func labels(for review: ASCReview) -> [String] {
          ["source:app-store", "rating:\(max(1, min(5, review.rating)))"]
      }

      static func body(for review: ASCReview) -> String {
          var lines: [String] = []
          lines.append(review.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
          lines.append("")
          lines.append("---")
          lines.append("source: app-store")
          lines.append("rating: \(review.rating)")
          if let nick = review.reviewerNickname, !nick.isEmpty { lines.append("reviewerNickname: \(nick)") }
          lines.append("territory: \(review.territory)")
          lines.append("reviewId: \(review.id)")
          lines.append("reviewCreatedAt: \(iso.string(from: review.createdDate))")
          return lines.joined(separator: "\n")
      }

      /// SHA-256 hex of normalized `rating + "\n" + title + "\n" + body`. Detects edits since the ASC
      /// API exposes no `updatedDate` on reviews.
      static func contentHash(for review: ASCReview) -> String {
          let normalized = "\(review.rating)\n\(review.title ?? "")\n\(review.body ?? "")"
          let digest = SHA256.hash(data: Data(normalized.utf8))
          return digest.map { String(format: "%02x", $0) }.joined()
      }

      static func editedNote(at date: Date) -> String {
          "_Review edited \(iso.string(from: date))_"
      }
  }
  ```
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewSynthesizerTests 2>&1 | tail -20` — expected PASS (5 tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreReviewSynthesizer.swift AppFeedbackTests/AppStoreReviewSynthesizerTests.swift && git commit -m "feat(app-store): AppStoreReviewSynthesizer (markers/labels/contentHash)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 8: `FakeAppStoreConnectClient` test double

**Files:**
- Create: `AppFeedbackTests/Fakes/FakeAppStoreConnectClient.swift`
- Test: compile via the coordinator tests in Task 10.

**Interfaces:**
- Consumes: `AppStoreConnectClientProtocol`, `ASCReviewPage`, `ASCReview`, `ASCResponse`, `ASCApp`, `AppStoreConnectError`.
- Produces: `final class FakeAppStoreConnectClient: AppStoreConnectClientProtocol, @unchecked Sendable` seeded with ordered pages keyed by cursor, recording write calls.

Steps:
- [ ] **Step 1: Write the fake.** Create `AppFeedbackTests/Fakes/FakeAppStoreConnectClient.swift`:
  ```swift
  import Foundation
  import os
  @testable import AppFeedback

  /// In-test `AppStoreConnectClientProtocol`. Returns a programmed sequence of `ASCReviewPage`s
  /// (so tests can drive multi-page pagination + full re-scan), and records response create/delete
  /// calls. Thread-safe via a lock since the protocol is `Sendable` and the coordinator is an actor.
  final class FakeAppStoreConnectClient: AppStoreConnectClientProtocol, @unchecked Sendable {
      private let lock = OSAllocatedUnfairLock<State>(initialState: State())
      private struct State {
          var pages: [ASCReviewPage] = []      // consumed front-to-back, regardless of cursor
          var pageIndex = 0
          var apps: [ASCApp] = []
          var createCalls: [(reviewId: String, body: String)] = []
          var deleteCalls: [String] = []
          var throwOnList: Error?
      }

      init() {}

      // MARK: - Test seams
      func setPages(_ pages: [ASCReviewPage]) { lock.withLock { $0.pages = pages; $0.pageIndex = 0 } }
      func setApps(_ apps: [ASCApp]) { lock.withLock { $0.apps = apps } }
      func setThrowOnList(_ error: Error?) { lock.withLock { $0.throwOnList = error } }
      var createCalls: [(reviewId: String, body: String)] { lock.withLock { $0.createCalls } }
      var deleteCalls: [String] { lock.withLock { $0.deleteCalls } }

      // MARK: - Protocol
      func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
          try lock.withLock { state in
              if let e = state.throwOnList { throw e }
              guard state.pageIndex < state.pages.count else {
                  return ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)
              }
              defer { state.pageIndex += 1 }
              return state.pages[state.pageIndex]
          }
      }
      func listApps() async throws -> [ASCApp] { lock.withLock { $0.apps } }
      func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
          lock.withLock { $0.createCalls.append((reviewId, body)) }
          return ASCResponse(id: "RESP-\(reviewId)", responseBody: body, state: "PENDING_PUBLISH", lastModifiedDate: Date())
      }
      func deleteResponse(responseId: String) async throws {
          lock.withLock { $0.deleteCalls.append(responseId) }
      }
  }

  extension ASCReview {
      /// Convenience builder for coordinator tests.
      static func make(id: String, rating: Int = 4, title: String? = "T", body: String? = "B",
                       nick: String? = "sam", created: Date, territory: String = "USA",
                       response: ASCResponse? = nil) -> ASCReview {
          ASCReview(id: id, rating: rating, title: title, body: body, reviewerNickname: nick,
                    createdDate: created, territory: territory, response: response)
      }
  }
  ```
- [ ] **Step 2: Build.** `xcodebuild build-for-testing -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -20` — expected PASS.
- [ ] **Step 3: Commit.** `git add AppFeedbackTests/Fakes/FakeAppStoreConnectClient.swift && git commit -m "test(app-store): FakeAppStoreConnectClient programmable double" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 9: `AppStoreReviewMirrorStore` — @Observable store with version-bump on remote change

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift`
- Test: `AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift`

**Interfaces:**
- Consumes: `AppStoreReviewMirror`; `NotificationCenter.cloudKitImportSucceeded` (from `RepoStore.swift`).
- Produces: `@MainActor @Observable final class AppStoreReviewMirrorStore` with `init(context:)`, `private(set) var version: Int`, and the **canonical** synchronous CRUD/dedup helpers (must match the Shared Contracts EXACTLY — Phase 4 calls these shapes):
  - `func allFor(productID: UUID) -> [AppStoreReviewMirror]`
  - `func mirror(reviewId: String) -> AppStoreReviewMirror?` — reviewId is globally unique in ASC
  - `func mirror(productID: UUID, issueNumber: Int) -> AppStoreReviewMirror?`
  - `@discardableResult func upsert(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String) -> AppStoreReviewMirror`
  - `func setResponse(reviewId: String, responseId: String?, state: String?)` — CANONICAL: no `productID` (reviewId is the key)
  - `func clearResponse(reviewId: String)`
  - `func deleteByIssue(productID: UUID, issueNumber: Int)` — reconcile deletes a SPECIFIC row; never the kept one
  - plus the reconcile read helper `func allFor(productID: UUID, issueNumber: Int) -> [AppStoreReviewMirror]`.

Steps:
- [ ] **Step 1: Write the failing store test (synchronous version assertions only).** Create `AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift`:
  ```swift
  import XCTest
  import SwiftData
  @testable import AppFeedback

  @MainActor
  final class AppStoreReviewMirrorStoreTests: XCTestCase {
      private func makeContext() throws -> ModelContext {
          let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
          return ModelContext(container)
      }

      func testUpsertCreatesThenUpdatesSameRow() throws {
          let store = AppStoreReviewMirrorStore(context: try makeContext())
          let pid = UUID()
          let v0 = store.version
          let m1 = store.upsert(reviewId: "R1", productID: pid, issueNumber: 42, contentHash: "h1")
          XCTAssertEqual(m1.issueNumber, 42)
          XCTAssertGreaterThan(store.version, v0)
          let m2 = store.upsert(reviewId: "R1", productID: pid, issueNumber: 42, contentHash: "h2")
          XCTAssertEqual(m2.contentHash, "h2")
          XCTAssertEqual(store.allFor(productID: pid).count, 1, "upsert keys on (reviewId, productID)")
      }

      func testMirrorLookupByReviewIdIsGloballyUnique() throws {
          // reviewId is globally unique in ASC: mirror(reviewId:) takes no productID.
          let store = AppStoreReviewMirrorStore(context: try makeContext())
          let pidA = UUID(); let pidB = UUID()
          _ = store.upsert(reviewId: "R1", productID: pidA, issueNumber: 1, contentHash: "a")
          _ = store.upsert(reviewId: "R2", productID: pidB, issueNumber: 2, contentHash: "b")
          XCTAssertEqual(store.mirror(reviewId: "R1")?.issueNumber, 1)
          XCTAssertEqual(store.mirror(reviewId: "R2")?.issueNumber, 2)
          XCTAssertEqual(store.allFor(productID: pidA).count, 1)
          XCTAssertEqual(store.mirror(productID: pidA, issueNumber: 1)?.reviewId, "R1")
          XCTAssertNil(store.mirror(productID: pidA, issueNumber: 999))
      }

      func testSetResponseClearResponseAndDeleteByIssue() throws {
          let store = AppStoreReviewMirrorStore(context: try makeContext())
          let pid = UUID()
          _ = store.upsert(reviewId: "R1", productID: pid, issueNumber: 7, contentHash: "h")
          store.setResponse(reviewId: "R1", responseId: "RESP1", state: "PENDING_PUBLISH")
          XCTAssertEqual(store.mirror(reviewId: "R1")?.responseState, "PENDING_PUBLISH")
          XCTAssertEqual(store.mirror(reviewId: "R1")?.responseId, "RESP1")
          store.clearResponse(reviewId: "R1")
          XCTAssertNil(store.mirror(reviewId: "R1")?.responseState)
          XCTAssertNil(store.mirror(reviewId: "R1")?.responseId)
          store.deleteByIssue(productID: pid, issueNumber: 7)
          XCTAssertNil(store.mirror(reviewId: "R1"))
      }

      func testDeleteByIssueRemovesOnlyTheTargetedRow() throws {
          // Two rows for the same reviewId (cross-device dupes after CloudKit sync, issues 42 & 43).
          let store = AppStoreReviewMirrorStore(context: try makeContext())
          let pid = UUID()
          _ = store.upsert(reviewId: "DUP", productID: pid, issueNumber: 42, contentHash: "h")
          // Insert a SECOND row with the same reviewId via the model directly (upsert would update #42).
          store.insertRawForTest(reviewId: "DUP", productID: pid, issueNumber: 43, contentHash: "h")
          XCTAssertEqual(store.allFor(productID: pid).count, 2)
          store.deleteByIssue(productID: pid, issueNumber: 43)
          let rows = store.allFor(productID: pid)
          XCTAssertEqual(rows.count, 1)
          XCTAssertEqual(rows.first?.issueNumber, 42, "kept row (lowest issue) survives")
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewMirrorStoreTests 2>&1 | tail -25` — expected FAIL.
- [ ] **Step 3: Implement the store.** Create `AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift`:
  ```swift
  import Foundation
  import SwiftData
  import Observation

  /// @Observable store over `AppStoreReviewMirror`. Bumps `version` on every local write AND on
  /// CloudKit remote-change / import so cross-device dedup state surfaces without a relaunch
  /// (mirrors `MailThreadStore`'s pattern). All reads/writes are synchronous on the MainActor.
  ///
  /// `AppStoreReviewMirror` has NO unique constraint (CloudKit forbids them on synced models), so two
  /// devices can independently create a row for the same `reviewId`. `mirror(reviewId:)` returns the
  /// first match; the coordinator's reconcile collapses dupes, deleting the extra row by its specific
  /// `(productID, issueNumber)` via `deleteByIssue` so the kept row is never touched.
  @MainActor
  @Observable
  final class AppStoreReviewMirrorStore {
      private let context: ModelContext
      private(set) var version: Int = 0

      private var remoteChangeTask: Task<Void, Never>?
      private var cloudKitImportTask: Task<Void, Never>?

      init(context: ModelContext) {
          self.context = context
          remoteChangeTask = Task { @MainActor [weak self] in
              for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                  self?.version &+= 1
              }
          }
          cloudKitImportTask = Task { @MainActor [weak self] in
              for await _ in NotificationCenter.cloudKitImportSucceeded {
                  self?.version &+= 1
              }
          }
      }

      isolated deinit {
          remoteChangeTask?.cancel()
          cloudKitImportTask?.cancel()
      }

      // MARK: - Reads

      /// reviewId is globally unique in ASC, so no product scoping is needed. Returns the
      /// lowest-issueNumber row when cross-device dupes exist (deterministic "kept" row).
      func mirror(reviewId: String) -> AppStoreReviewMirror? {
          let d = FetchDescriptor<AppStoreReviewMirror>(
              predicate: #Predicate { $0.reviewId == reviewId },
              sortBy: [SortDescriptor(\.issueNumber, order: .forward)])
          return (try? context.fetch(d))?.first
      }

      func mirror(productID: UUID, issueNumber: Int) -> AppStoreReviewMirror? {
          var d = FetchDescriptor<AppStoreReviewMirror>(
              predicate: #Predicate { $0.productID == productID && $0.issueNumber == issueNumber })
          d.fetchLimit = 1
          return (try? context.fetch(d))?.first
      }

      func allFor(productID: UUID) -> [AppStoreReviewMirror] {
          let d = FetchDescriptor<AppStoreReviewMirror>(predicate: #Predicate { $0.productID == productID })
          return (try? context.fetch(d)) ?? []
      }

      /// All mirror rows for a product that point at a given issue number (used by reconcile).
      func allFor(productID: UUID, issueNumber: Int) -> [AppStoreReviewMirror] {
          let d = FetchDescriptor<AppStoreReviewMirror>(
              predicate: #Predicate { $0.productID == productID && $0.issueNumber == issueNumber })
          return (try? context.fetch(d)) ?? []
      }

      // MARK: - Writes

      @discardableResult
      func upsert(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String) -> AppStoreReviewMirror {
          if let existing = mirror(reviewId: reviewId) {
              existing.issueNumber = issueNumber
              existing.contentHash = contentHash
              save()
              return existing
          }
          let row = AppStoreReviewMirror(reviewId: reviewId, productID: productID,
                                         issueNumber: issueNumber, contentHash: contentHash)
          context.insert(row)
          save()
          return row
      }

      /// CANONICAL response setter — keyed on the globally-unique reviewId, no productID. Phase 4
      /// calls this exact shape after a successful `createOrUpdateResponse`.
      func setResponse(reviewId: String, responseId: String?, state: String?) {
          guard let row = mirror(reviewId: reviewId) else { return }
          row.responseId = responseId
          row.responseState = state
          save()
      }

      func clearResponse(reviewId: String) {
          guard let row = mirror(reviewId: reviewId) else { return }
          row.responseId = nil
          row.responseState = nil
          save()
      }

      /// Deletes the SPECIFIC row identified by `(productID, issueNumber)`. Reconcile uses this to drop
      /// a duplicate row while leaving the kept (lowest-issueNumber) row intact.
      func deleteByIssue(productID: UUID, issueNumber: Int) {
          for row in allFor(productID: productID, issueNumber: issueNumber) {
              context.delete(row)
          }
          save()
      }

      // MARK: - Test seam

      /// Inserts a raw row WITHOUT upsert collapse, so tests can simulate cross-device duplicate rows
      /// (two rows, same reviewId) that only appear after CloudKit sync.
      func insertRawForTest(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String) {
          context.insert(AppStoreReviewMirror(reviewId: reviewId, productID: productID,
                                              issueNumber: issueNumber, contentHash: contentHash))
          save()
      }

      private func save() {
          do { try context.save(); version &+= 1 }
          catch { assertionFailure("AppStoreReviewMirrorStore save failed: \(error)") }
      }
  }
  ```
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewMirrorStoreTests 2>&1 | tail -20` — expected PASS (4 tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift && git commit -m "feat(app-store): AppStoreReviewMirrorStore (@Observable, canonical CRUD, version-bump on remote change)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 10: `AppStoreReviewCoordinator` — incremental poll + synthesis + mirror writes + dedup

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreReviewCoordinator.swift`
- Test: `AppFeedbackTests/AppStoreReviewCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AppStoreConnectClientProtocol` (fake in tests), `IssueWriting` (`FakeIssueWriting`), `AppStoreReviewMirrorStore` (canonical CRUD), `ASCProductConfig`, `AppStoreReviewSynthesizer`, `AppStoreConnectError`, `StatusCarryingError`, `FeedbackSourceIngestor`, `GitHubCommentPoster`. `ActivityLog` (optional). The GitHub token is supplied by an injected `@Sendable () async -> String?` loader (production passes `{ KeychainService.loadSync(for: RepoConfig(...)) }`).
- Produces: `actor AppStoreReviewCoordinator: FeedbackSourceIngestor` with `init(config:client:issueWriter:commentPoster:mirrorStore:tokenLoader:activityLog:clock:)`, `func poll() async throws` (incremental), `func fullRescan() async throws`, `func pollNow() async`, `func start()`, `func stop()`, observable status accessors `func status() -> (lastSuccessAt: Date?, lastError: String?)` (the actor's `lastSuccessAt`/`lastError` state), and `static func backoffSeconds(baseSeconds:consecutiveFailures:)`. After a `403`/`StatusCarryingError statusCode == 403` on a response write, the coordinator flips `isReadOnly = true` (surfaced through the registry's `responderContext(productID:)`).

Steps:
- [ ] **Step 1: Write the failing behavior tests (synthesis, pagination stop, edit, deletion, dedup, 429).** Create `AppFeedbackTests/AppStoreReviewCoordinatorTests.swift`:
  ```swift
  import XCTest
  import SwiftData
  @testable import AppFeedback

  @MainActor
  final class AppStoreReviewCoordinatorTests: XCTestCase {
      private func makeStore() throws -> AppStoreReviewMirrorStore {
          let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
          return AppStoreReviewMirrorStore(context: ModelContext(container))
      }
      private func config(_ pid: UUID = UUID()) -> ASCProductConfig {
          ASCProductConfig(id: pid, owner: "o", repo: "r", issuerID: "i", keyID: "k", appAppleID: "123")
      }
      private func makeCoordinator(_ cfg: ASCProductConfig, client: FakeAppStoreConnectClient,
                                   writer: FakeIssueWriting, store: AppStoreReviewMirrorStore,
                                   clock: @escaping @Sendable () -> Date = { Date() }) -> AppStoreReviewCoordinator {
          AppStoreReviewCoordinator(
              config: cfg, client: client, issueWriter: writer, commentPoster: GitHubCommentPoster(session: .mock),
              mirrorStore: store, tokenLoader: { "tok" }, activityLog: nil, clock: clock)
      }

      func testNewReviewCreatesIssueAndRecordsMirror() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting(startingNumber: 500)
          let store = try makeStore()
          client.setPages([ASCReviewPage(reviews: [
              .make(id: "R1", rating: 5, title: "Great", body: "Love", created: Date(timeIntervalSince1970: 1_700_000_000))
          ], nextCursor: nil, rateRemaining: 3000)])
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          try await coord.poll()
          let creates = await writer.creates
          XCTAssertEqual(creates.count, 1)
          XCTAssertEqual(creates[0].title, "Great")
          XCTAssertTrue(creates[0].labels.contains("source:app-store"))
          XCTAssertTrue(creates[0].labels.contains("rating:5"))
          XCTAssertEqual(store.mirror(reviewId: "R1")?.issueNumber, 500)
      }

      func testKnownReviewIsNotRecreated() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting(startingNumber: 500)
          let store = try makeStore()
          let r = ASCReview.make(id: "R1", rating: 5, title: "Great", body: "Love", created: Date(timeIntervalSince1970: 1_700_000_000))
          _ = store.upsert(reviewId: "R1", productID: cfg.id, issueNumber: 9,
                           contentHash: AppStoreReviewSynthesizer.contentHash(for: r))
          client.setPages([ASCReviewPage(reviews: [r], nextCursor: nil, rateRemaining: nil)])
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          try await coord.poll()
          let creates = await writer.creates
          XCTAssertTrue(creates.isEmpty, "an unchanged known review is skipped")
      }

      func testIncrementalStopsAtFirstKnownReview() async throws {
          // Page1 has a NEW review then a KNOWN one; incremental must stop without fetching page2.
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          let known = ASCReview.make(id: "OLD", created: Date(timeIntervalSince1970: 1_600_000_000))
          _ = store.upsert(reviewId: "OLD", productID: cfg.id, issueNumber: 1,
                           contentHash: AppStoreReviewSynthesizer.contentHash(for: known))
          client.setPages([
              ASCReviewPage(reviews: [.make(id: "NEW", created: Date(timeIntervalSince1970: 1_700_000_000)), known],
                            nextCursor: "PAGE2", rateRemaining: nil),
              ASCReviewPage(reviews: [.make(id: "SHOULD_NOT_FETCH", created: Date(timeIntervalSince1970: 1_500_000_000))],
                            nextCursor: nil, rateRemaining: nil),
          ])
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          try await coord.poll()
          let creates = await writer.creates
          XCTAssertEqual(creates.map(\.title).count, 1, "only NEW synthesized; page2 not walked")
          XCTAssertNil(store.mirror(reviewId: "SHOULD_NOT_FETCH"))
      }

      func testEditedReviewUpdatesIssueOnFullRescan() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          let original = ASCReview.make(id: "R1", rating: 5, title: "Old", body: "old body", created: Date(timeIntervalSince1970: 1_700_000_000))
          _ = store.upsert(reviewId: "R1", productID: cfg.id, issueNumber: 77,
                           contentHash: AppStoreReviewSynthesizer.contentHash(for: original))
          let edited = ASCReview.make(id: "R1", rating: 5, title: "New", body: "new body", created: original.createdDate)
          client.setPages([ASCReviewPage(reviews: [edited], nextCursor: nil, rateRemaining: nil)])
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          try await coord.fullRescan()
          let updates = await writer.updates
          XCTAssertEqual(updates.count, 1)
          XCTAssertEqual(updates[0].number, 77)
          XCTAssertEqual(updates[0].title, "New")
          XCTAssertTrue(updates[0].body?.contains("Review edited") == true)
          XCTAssertEqual(store.mirror(reviewId: "R1")?.contentHash,
                         AppStoreReviewSynthesizer.contentHash(for: edited))
      }

      func testDeletedReviewClosesIssueWithLabel() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          let gone = ASCReview.make(id: "GONE", created: Date(timeIntervalSince1970: 1_700_000_000))
          _ = store.upsert(reviewId: "GONE", productID: cfg.id, issueNumber: 88,
                           contentHash: AppStoreReviewSynthesizer.contentHash(for: gone))
          // Full re-scan returns NO reviews ⇒ "GONE" is absent ⇒ treated as deleted.
          client.setPages([ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)])
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          try await coord.fullRescan()
          let updates = await writer.updates
          XCTAssertEqual(updates.count, 1)
          XCTAssertEqual(updates[0].number, 88)
          XCTAssertEqual(updates[0].state, "closed")
          XCTAssertEqual(updates[0].labels?.contains(AppStoreReviewSynthesizer.reviewDeletedLabel), true)
      }

      func testRateLimitedErrorPropagates() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          client.setThrowOnList(AppStoreConnectError.rateLimited)
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          do { try await coord.poll(); XCTFail("expected throw") }
          catch let e as AppStoreConnectError { if case .rateLimited = e {} else { XCTFail("wrong error \(e)") } }
      }

      func testBackoffClampedToBase() {
          XCTAssertEqual(AppStoreReviewCoordinator.backoffSeconds(baseSeconds: 900, consecutiveFailures: 0), 900)
          XCTAssertEqual(AppStoreReviewCoordinator.backoffSeconds(baseSeconds: 900, consecutiveFailures: 100), 900)
          XCTAssertEqual(AppStoreReviewCoordinator.backoffSeconds(baseSeconds: 900, consecutiveFailures: 1), 30)
      }

      // [F] Per-source status surfaces on the coordinator.
      func testStatusRecordsSuccessThenError() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          client.setPages([ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)])
          let fixed = Date(timeIntervalSince1970: 1_700_000_000)
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store, clock: { fixed })
          await coord.pollNow()
          var status = await coord.status()
          XCTAssertEqual(status.lastSuccessAt, fixed, "a successful poll stamps lastSuccessAt")
          XCTAssertNil(status.lastError)
          // Now force a failure and confirm lastError is recorded (lastSuccessAt is preserved).
          client.setThrowOnList(AppStoreConnectError.rateLimited)
          await coord.pollNow()
          status = await coord.status()
          XCTAssertEqual(status.lastSuccessAt, fixed)
          XCTAssertNotNil(status.lastError)
      }

      // [G] Deletion close preserves the rating badge: the body is NOT rewritten (markers survive),
      // so IssueLoader.resolveRating still yields the rating after the close.
      func testDeletionPreservesRatingMarkerForResolveRating() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          let r = ASCReview.make(id: "R1", rating: 3, title: "T", body: "B",
                                 created: Date(timeIntervalSince1970: 1_700_000_000))
          let originalBody = AppStoreReviewSynthesizer.body(for: r)
          _ = store.upsert(reviewId: "R1", productID: cfg.id, issueNumber: 55,
                           contentHash: AppStoreReviewSynthesizer.contentHash(for: r))
          client.setPages([ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)])  // R1 absent ⇒ deleted
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          try await coord.fullRescan()
          let updates = await writer.updates
          XCTAssertEqual(updates.count, 1)
          XCTAssertEqual(updates[0].state, "closed")
          // The deletion update must NOT rewrite the body (nil body ⇒ markers preserved on GitHub).
          XCTAssertNil(updates[0].body, "deletion must not rewrite the body so rating: marker survives")
          // resolveRating reads the (still-present) rating marker → badge survives even though the
          // labels now only carry source:app-store + review-deleted.
          let parsedRating = 3  // the rating marker value still present in the unchanged body
          XCTAssertEqual(IssueLoader.resolveRating(markerRating: parsedRating,
                                                   labels: ["source:app-store",
                                                            AppStoreReviewSynthesizer.reviewDeletedLabel]), 3)
          XCTAssertTrue(originalBody.contains("rating: 3"), "sanity: original body carried the rating marker")
      }

      // [D-reconcile] Cross-device dupes: two mirror rows for the SAME reviewId (issues 42 & 43).
      // Reconcile keeps the LOWEST (42), closes & deletes 43; never deletes the kept row.
      func testReconcileKeepsLowestIssueClosesAndDeletesHigher() async throws {
          let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
          let store = try makeStore()
          _ = store.upsert(reviewId: "DUP", productID: cfg.id, issueNumber: 42, contentHash: "h")
          store.insertRawForTest(reviewId: "DUP", productID: cfg.id, issueNumber: 43, contentHash: "h")
          XCTAssertEqual(store.allFor(productID: cfg.id).count, 2)
          let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
          await coord.reconcileDuplicatesForTest(reviewId: "DUP")
          // 43 closed via the issue writer.
          let updates = await writer.updates
          XCTAssertEqual(updates.count, 1)
          XCTAssertEqual(updates[0].number, 43)
          XCTAssertEqual(updates[0].state, "closed")
          // 43 deleted from the mirror; 42 (kept) remains.
          let rows = store.allFor(productID: cfg.id)
          XCTAssertEqual(rows.count, 1)
          XCTAssertEqual(rows.first?.issueNumber, 42)
          XCTAssertNotNil(store.mirror(reviewId: "DUP"))
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewCoordinatorTests 2>&1 | tail -30` — expected FAIL.
- [ ] **Step 3: Implement the coordinator.** Create `AppFeedback/Services/AppStore/AppStoreReviewCoordinator.swift`:
  ```swift
  import Foundation

  /// Polls one product's App Store reviews and synthesizes GitHub issues. Two modes:
  ///   • `poll()` (incremental) — walks `links.next` from the top of `-createdDate`, stopping at the
  ///     first review older than the last poll OR already in the mirror, synthesizing only the new
  ///     ones.
  ///   • `fullRescan()` (periodic) — walks ALL pages; catches edits (contentHash changed → update the
  ///     issue + "Review edited" note) and deletions (in the mirror but absent from the scan → close
  ///     the issue + `review-deleted` label + comment). Never hard-deletes.
  /// Cross-device dedup is via the synced `AppStoreReviewMirror`. Failures throw to the caller (the
  /// registry's poll loop owns backoff); the registry/loop never let one source block another.
  actor AppStoreReviewCoordinator: FeedbackSourceIngestor {
      private let config: ASCProductConfig
      private let client: AppStoreConnectClientProtocol
      private let issueWriter: IssueWriting
      private let commentPoster: GitHubCommentPoster
      private let mirrorStore: AppStoreReviewMirrorStore     // @MainActor
      private let tokenLoader: @Sendable () async -> String?
      private let activityLog: ActivityLog?                  // @MainActor
      private let clock: @Sendable () -> Date

      // [F] Per-source status surfaced in AppStoreSourceForm (read via `status()` / the registry).
      private(set) var lastSuccessAt: Date?
      private(set) var lastError: String?
      // [responderContext] Flipped true after a 403 on a response write (read-only ASC key). The
      // registry exposes this through `responderContext(productID:)` so Phase 4 can disable the panel.
      private(set) var isReadOnly = false

      /// The product id this coordinator serves (used by the registry to key its lookups).
      var productID: UUID { config.id }
      /// The injected client (handed to Phase 4 via the registry's responder context).
      var responderClient: any AppStoreConnectClientProtocol { client }
      var sinkOwner: String { config.owner }
      var sinkRepo: String { config.repo }

      /// Snapshot of the per-source status for the settings UI.
      func status() -> (lastSuccessAt: Date?, lastError: String?) { (lastSuccessAt, lastError) }
      func readOnly() -> Bool { isReadOnly }
      /// Phase 4 calls this after a 403 on a response write to disable the respond panel.
      func markReadOnly() { isReadOnly = true }

      private var lastIncrementalPollAt: Date?
      private var loopTask: Task<Void, Never>?
      private var inFlight = false
      private var consecutiveFailures = 0
      /// Run a full re-scan once every ~24h of wall-clock between successful incremental polls.
      private var lastFullRescanAt: Date?
      private static let fullRescanInterval: TimeInterval = 24 * 3600
      private static let maxPages = 200    // safety cap (200 reviews/page × 200 = 40k)

      init(config: ASCProductConfig,
           client: AppStoreConnectClientProtocol,
           issueWriter: IssueWriting,
           commentPoster: GitHubCommentPoster,
           mirrorStore: AppStoreReviewMirrorStore,
           tokenLoader: @escaping @Sendable () async -> String?,
           activityLog: ActivityLog? = nil,
           clock: @escaping @Sendable () -> Date = { Date() }) {
          self.config = config
          self.client = client
          self.issueWriter = issueWriter
          self.commentPoster = commentPoster
          self.mirrorStore = mirrorStore
          self.tokenLoader = tokenLoader
          self.activityLog = activityLog
          self.clock = clock
      }

      // MARK: - FeedbackSourceIngestor

      func poll() async throws { try await incrementalPoll() }

      // MARK: - Lifecycle (background driver / scenePhase drive pollNow())

      func pollNow() async {
          guard !inFlight else { return }
          do {
              if shouldFullRescan() { try await fullRescan() } else { try await incrementalPoll() }
              consecutiveFailures = 0
              lastSuccessAt = clock()      // [F] stamp success; preserve any prior lastError? No — clear it.
              lastError = nil
          } catch {
              consecutiveFailures += 1
              lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)  // [F]
          }
      }

      func start() {
          loopTask?.cancel()
          loopTask = Task { [weak self] in
              guard let self else { return }
              await self.pollNow()
              while !Task.isCancelled {
                  let sleep = await Self.backoffSeconds(baseSeconds: 900, consecutiveFailures: self.failureCount())
                  try? await Task.sleep(nanoseconds: UInt64(sleep) * 1_000_000_000)
                  guard !Task.isCancelled else { return }
                  await self.pollNow()
              }
          }
      }

      func stop() { loopTask?.cancel(); loopTask = nil }

      private func failureCount() -> Int { consecutiveFailures }
      private func shouldFullRescan() -> Bool {
          guard let last = lastFullRescanAt else { return false }   // first poll is incremental
          return clock().timeIntervalSince(last) >= Self.fullRescanInterval
      }

      /// Same Double-clamped formula as `MailSyncCoordinator.backoffSeconds` — clamp in Double space
      /// before the Int conversion so a large failure count can't trap on an out-of-range Double.
      static func backoffSeconds(baseSeconds: Int, consecutiveFailures: Int) -> Int {
          guard consecutiveFailures > 0 else { return baseSeconds }
          let backoff = 30.0 * pow(2.0, Double(consecutiveFailures - 1))
          return Int(min(Double(baseSeconds), backoff))
      }

      // MARK: - Incremental

      private func incrementalPoll() async throws {
          inFlight = true
          defer { inFlight = false }
          let since = lastIncrementalPollAt
          let startedAt = clock()
          var cursor: String? = nil
          var pages = 0
          outer: while pages < Self.maxPages {
              let page = try await client.listReviews(appAppleID: config.appAppleID, page: cursor)
              pages += 1
              for review in page.reviews {
                  // Stop conditions: older than last poll, OR already known & unchanged.
                  if let since, review.createdDate < since {
                      break outer
                  }
                  let known = await MainActor.run { mirrorStore.mirror(reviewId: review.id) }
                  let hash = AppStoreReviewSynthesizer.contentHash(for: review)
                  if let known {
                      if known.contentHash == hash { break outer }   // hit a known, unchanged review
                      try await applyEdit(review: review, mirror: known, hash: hash)
                  } else {
                      try await synthesizeNew(review: review, hash: hash)
                  }
              }
              guard let next = page.nextCursor else { break }
              cursor = next
          }
          lastIncrementalPollAt = startedAt
          if lastFullRescanAt == nil { lastFullRescanAt = startedAt }   // seed so re-scans cadence from first poll
      }

      // MARK: - Full re-scan (edits + deletions)

      func fullRescan() async throws {
          inFlight = true
          defer { inFlight = false }
          let startedAt = clock()
          var cursor: String? = nil
          var pages = 0
          var seenReviewIDs = Set<String>()
          while pages < Self.maxPages {
              let page = try await client.listReviews(appAppleID: config.appAppleID, page: cursor)
              pages += 1
              for review in page.reviews {
                  seenReviewIDs.insert(review.id)
                  let hash = AppStoreReviewSynthesizer.contentHash(for: review)
                  let known = await MainActor.run { mirrorStore.mirror(reviewId: review.id) }
                  if let known {
                      if known.contentHash != hash { try await applyEdit(review: review, mirror: known, hash: hash) }
                  } else {
                      try await synthesizeNew(review: review, hash: hash)
                  }
              }
              guard let next = page.nextCursor else { break }
              cursor = next
          }
          // Deletions: mirror rows whose review wasn't seen this scan.
          let mirrors = await MainActor.run { mirrorStore.allFor(productID: config.id) }
          for m in mirrors where !seenReviewIDs.contains(m.reviewId) {
              try await applyDeletion(mirror: m)
          }
          lastFullRescanAt = startedAt
          lastIncrementalPollAt = startedAt
      }

      // MARK: - Synthesis primitives

      private func synthesizeNew(review: ASCReview, hash: String) async throws {
          guard let token = await tokenLoader(), !token.isEmpty else {
              throw AppStoreConnectError.http(0)   // no GitHub token ⇒ can't synthesize; retried next poll
          }
          // Cross-device backstop: if a mirror row appeared mid-poll (other device synced), skip.
          if let raced = await MainActor.run({ mirrorStore.mirror(reviewId: review.id) }) {
              if raced.contentHash != hash { try await applyEdit(review: review, mirror: raced, hash: hash) }
              return
          }
          let number = try await issueWriter.createIssue(
              owner: config.owner, repo: config.repo,
              title: AppStoreReviewSynthesizer.title(for: review),
              body: AppStoreReviewSynthesizer.body(for: review),
              labels: AppStoreReviewSynthesizer.labels(for: review),
              milestoneNumber: nil, token: token)
          await MainActor.run {
              mirrorStore.upsert(reviewId: review.id, productID: config.id, issueNumber: number, contentHash: hash)
          }
          await reconcileDuplicates(reviewId: review.id, token: token)
      }

      private func applyEdit(review: ASCReview, mirror: AppStoreReviewMirror, hash: String) async throws {
          guard let token = await tokenLoader(), !token.isEmpty else { throw AppStoreConnectError.http(0) }
          let issueNumber = mirror.issueNumber
          let newBody = AppStoreReviewSynthesizer.body(for: review)
              + "\n\n" + AppStoreReviewSynthesizer.editedNote(at: clock())
          try await issueWriter.updateIssue(
              owner: config.owner, repo: config.repo, number: issueNumber,
              title: AppStoreReviewSynthesizer.title(for: review), body: newBody,
              labels: AppStoreReviewSynthesizer.labels(for: review),
              milestoneNumber: nil, state: nil, token: token)
          await MainActor.run {
              mirrorStore.upsert(reviewId: review.id, productID: config.id, issueNumber: issueNumber, contentHash: hash)
          }
      }

      private func applyDeletion(mirror: AppStoreReviewMirror) async throws {
          guard let token = await tokenLoader(), !token.isEmpty else { throw AppStoreConnectError.http(0) }
          let issueNumber = mirror.issueNumber
          // [G] The rating badge MUST survive the deletion close. The body carries the authoritative
          // `rating: N` marker that `IssueLoader.resolveRating` reads, so we pass `body: nil` — the
          // body is NEVER rewritten and every Phase-1 marker (source/rating/reviewId/…) is preserved.
          // We mark the issue closed and add `source:app-store` + `review-deleted`. We do NOT union the
          // existing labels (no GitHub read here); the badge does not depend on the `rating:N` LABEL
          // because the marker is authoritative for `resolveRating`.
          try await issueWriter.updateIssue(
              owner: config.owner, repo: config.repo, number: issueNumber,
              title: nil, body: nil,
              labels: ["source:app-store", AppStoreReviewSynthesizer.reviewDeletedLabel],
              milestoneNumber: nil, state: "closed", token: token)
          _ = try? await commentPoster.postComment(
              owner: config.owner, repo: config.repo, issueNumber: issueNumber,
              body: "_This App Store review was deleted by its author._", token: token)
      }

      /// [D-reconcile] There is no GitHub search API in the app, so the synced `AppStoreReviewMirror`
      /// is the authority. Because the model carries NO unique constraint, two devices polling the same
      /// product can each create an issue + mirror row for the SAME review; after CloudKit sync these
      /// appear as duplicate rows (same `reviewId`, different `issueNumber`). We collapse them:
      ///   • group mirror rows by `reviewId`,
      ///   • KEEP the row with the LOWEST `issueNumber`,
      ///   • close each higher GitHub issue via the issue writer,
      ///   • delete each extra mirror row via `deleteByIssue(productID:issueNumber:)`.
      /// The kept row is NEVER deleted. Idempotent: a single surviving row is a no-op.
      private func reconcileDuplicates(reviewId: String, token: String) async {
          let dupes = await MainActor.run {
              mirrorStore.allFor(productID: config.id).filter { $0.reviewId == reviewId }
          }
          guard dupes.count > 1 else { return }
          // Snapshot issue numbers off the MainActor model objects before doing async work.
          let issueNumbers = dupes.map(\.issueNumber).sorted()
          guard let kept = issueNumbers.first else { return }
          let extras = issueNumbers.dropFirst()   // everything above the lowest
          for higher in extras {
              try? await issueWriter.updateIssue(
                  owner: config.owner, repo: config.repo, number: higher,
                  title: nil, body: nil, labels: nil, milestoneNumber: nil, state: "closed", token: token)
              await MainActor.run {
                  // Delete ONLY the duplicate row; the kept (lowest) row is untouched.
                  mirrorStore.deleteByIssue(productID: config.id, issueNumber: higher)
              }
          }
          _ = kept   // kept row intentionally left in place
      }

      // MARK: - Test seam

      /// Exposes `reconcileDuplicates` to tests without driving a whole poll. Loads the GitHub token
      /// via the same loader production uses.
      func reconcileDuplicatesForTest(reviewId: String) async {
          let token = await tokenLoader() ?? "tok"
          await reconcileDuplicates(reviewId: reviewId, token: token)
      }
  }
  ```
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewCoordinatorTests 2>&1 | tail -25` — expected PASS (10 tests, incl. the [F] status, [G] deletion-rating, and [D-reconcile] duplicate-collapse tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreReviewCoordinator.swift AppFeedbackTests/AppStoreReviewCoordinatorTests.swift && git commit -m "feat(app-store): AppStoreReviewCoordinator (incremental+full re-scan, synthesis, dedup)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 11: `AppStoreReviewCoordinatorRegistry` — one coordinator per product-with-ASC

**Files:**
- Create: `AppFeedback/Services/AppStore/AppStoreReviewCoordinatorRegistry.swift`
- Test: `AppFeedbackTests/AppStoreReviewCoordinatorTests.swift` (add a registry section to the existing file)

**Interfaces:**
- Consumes: `ASCProductConfig`, `AppStoreReviewCoordinator`, `AppStoreConnectClientProtocol`.
- Produces: `struct AppStoreResponderContext: Sendable { let client: any AppStoreConnectClientProtocol; let isReadOnly: Bool; let owner: String; let repo: String }` (Phase 4 consumes this) and `@MainActor @Observable final class AppStoreReviewCoordinatorRegistry` with `typealias CoordinatorFactory = (ASCProductConfig) -> AppStoreReviewCoordinator`, `init(factory:)`, `var coordinatorCount: Int`, `func syncWithProducts(_ configs: [ASCProductConfig])`, `func start()`, `func pollNow() async`, `func stop()`, `func restart(productID:configs:)`, **`func responderContext(productID: UUID) async -> AppStoreResponderContext?`** (the seam Phase 4 consumes; `async` because it reads the coordinator actor's `isReadOnly`/client), and `func status(productID: UUID) async -> (lastSuccessAt: Date?, lastError: String?)?` (for the form). Mirrors `MailSyncCoordinatorRegistry`.

Steps:
- [ ] **Step 1: Write the failing registry test.** Append to `AppFeedbackTests/AppStoreReviewCoordinatorTests.swift` (new `XCTestCase` subclass at the bottom):
  ```swift
  @MainActor
  final class AppStoreReviewCoordinatorRegistryTests: XCTestCase {
      private func makeStore() throws -> AppStoreReviewMirrorStore {
          let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
          return AppStoreReviewMirrorStore(context: ModelContext(container))
      }
      private func cfg(_ id: UUID, app: String) -> ASCProductConfig {
          ASCProductConfig(id: id, owner: "o", repo: "r", issuerID: "i", keyID: "k", appAppleID: app)
      }

      func testSyncSpinsUpAndTearsDownByProduct() throws {
          let store = try makeStore()
          let registry = AppStoreReviewCoordinatorRegistry { cfg in
              AppStoreReviewCoordinator(
                  config: cfg, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                  commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                  tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
          }
          let a = UUID(); let b = UUID()
          registry.syncWithProducts([cfg(a, app: "1"), cfg(b, app: "2")])
          XCTAssertEqual(registry.coordinatorCount, 2)
          registry.syncWithProducts([cfg(a, app: "1")])     // b removed
          XCTAssertEqual(registry.coordinatorCount, 1)
          registry.syncWithProducts([])                     // all removed
          XCTAssertEqual(registry.coordinatorCount, 0)
      }

      func testSyncIsIdempotent() throws {
          let store = try makeStore()
          var built = 0
          let registry = AppStoreReviewCoordinatorRegistry { cfg in
              built += 1
              return AppStoreReviewCoordinator(
                  config: cfg, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                  commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                  tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
          }
          let a = UUID()
          registry.syncWithProducts([cfg(a, app: "1")])
          registry.syncWithProducts([cfg(a, app: "1")])
          XCTAssertEqual(built, 1, "same product not rebuilt")
          XCTAssertEqual(registry.coordinatorCount, 1)
      }

      // [responderContext] The seam Phase 4 consumes.
      func testResponderContextReflectsClientAndSink() async throws {
          let store = try makeStore()
          let client = FakeAppStoreConnectClient()
          let registry = AppStoreReviewCoordinatorRegistry { c in
              AppStoreReviewCoordinator(
                  config: c, client: client, issueWriter: FakeIssueWriting(),
                  commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                  tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
          }
          let a = UUID()
          registry.syncWithProducts([ASCProductConfig(id: a, owner: "acme", repo: "app",
                                                      issuerID: "i", keyID: "k", appAppleID: "1")])
          let ctx = await registry.responderContext(productID: a)
          XCTAssertNotNil(ctx)
          XCTAssertEqual(ctx?.owner, "acme")
          XCTAssertEqual(ctx?.repo, "app")
          XCTAssertEqual(ctx?.isReadOnly, false, "read-only flips only after a 403 write")
          XCTAssertNil(await registry.responderContext(productID: UUID()), "unknown product ⇒ nil")
      }

      func testResponderContextIsReadOnlyAfter403() async throws {
          let store = try makeStore()
          let registry = AppStoreReviewCoordinatorRegistry { c in
              AppStoreReviewCoordinator(
                  config: c, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                  commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                  tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
          }
          let a = UUID()
          registry.syncWithProducts([ASCProductConfig(id: a, owner: "o", repo: "r",
                                                      issuerID: "i", keyID: "k", appAppleID: "1")])
          // Simulate Phase 4 observing a 403 on a write and flipping the coordinator read-only.
          await registry.coordinator(for: a)?.markReadOnly()
          let ctx = await registry.responderContext(productID: a)
          XCTAssertEqual(ctx?.isReadOnly, true)
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewCoordinatorRegistryTests 2>&1 | tail -25` — expected FAIL.
- [ ] **Step 3: Implement the registry.** Create `AppFeedback/Services/AppStore/AppStoreReviewCoordinatorRegistry.swift`:
  ```swift
  import Foundation
  import Observation

  /// What Phase 4's "Respond on App Store" panel needs to act on a review: the authenticated client,
  /// whether the key is read-only (a 403 on a prior write flips this), and the GitHub sink coordinates
  /// for the "responded" record comment. Defined here (Phase 3 owns it); Phase 4 only consumes it.
  struct AppStoreResponderContext: Sendable {
      let client: any AppStoreConnectClientProtocol
      let isReadOnly: Bool
      let owner: String
      let repo: String
  }

  /// Owns one `AppStoreReviewCoordinator` per product that has App Store Connect configured.
  /// Lifecycle is synced to the product list via `syncWithProducts(_:)` (idempotent). Mirrors
  /// `MailSyncCoordinatorRegistry`'s grain: spin-up starts the poll loop, tear-down stops it.
  @MainActor
  @Observable
  final class AppStoreReviewCoordinatorRegistry {
      typealias CoordinatorFactory = (ASCProductConfig) -> AppStoreReviewCoordinator

      private let factory: CoordinatorFactory
      private var coordinators: [UUID: AppStoreReviewCoordinator] = [:]

      init(factory: @escaping CoordinatorFactory) { self.factory = factory }

      var coordinatorCount: Int { coordinators.count }
      func coordinator(for id: UUID) -> AppStoreReviewCoordinator? { coordinators[id] }

      /// [responderContext] The seam Phase 4 consumes. Reads the live coordinator's client + read-only
      /// flag + sink coordinates. `async` because the coordinator is an actor. nil when the product has
      /// no live coordinator (ASC not configured).
      func responderContext(productID: UUID) async -> AppStoreResponderContext? {
          guard let coord = coordinators[productID] else { return nil }
          return AppStoreResponderContext(
              client: await coord.responderClient,
              isReadOnly: await coord.readOnly(),
              owner: await coord.sinkOwner,
              repo: await coord.sinkRepo)
      }

      /// [F] Per-source status for the App Store settings form. nil when no live coordinator.
      func status(productID: UUID) async -> (lastSuccessAt: Date?, lastError: String?)? {
          guard let coord = coordinators[productID] else { return nil }
          return await coord.status()
      }

      /// Reconciles the live coordinator set with the products that have ASC configured. Idempotent.
      func syncWithProducts(_ configs: [ASCProductConfig]) {
          let currentIDs = Set(configs.map(\.id))
          for (id, coord) in coordinators where !currentIDs.contains(id) {
              Task { await coord.stop() }
              coordinators[id] = nil
          }
          for cfg in configs where coordinators[cfg.id] == nil {
              let coord = factory(cfg)
              coordinators[cfg.id] = coord
              Task { await coord.start() }
          }
      }

      func start() { for coord in coordinators.values { Task { await coord.start() } } }

      func pollNow() async {
          await withTaskGroup(of: Void.self) { group in
              for coord in coordinators.values { group.addTask { await coord.pollNow() } }
          }
      }

      func stop() { for coord in coordinators.values { Task { await coord.stop() } } }

      /// Stops and restarts a single product's coordinator (used when its ASC credentials change).
      func restart(productID: UUID, configs: [ASCProductConfig]) {
          if let coord = coordinators[productID] {
              Task { await coord.stop() }
              coordinators[productID] = nil
          }
          syncWithProducts(configs)
      }
  }
  ```
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewCoordinatorRegistryTests 2>&1 | tail -20` — expected PASS (4 tests, incl. the two [responderContext] tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Services/AppStore/AppStoreReviewCoordinatorRegistry.swift AppFeedbackTests/AppStoreReviewCoordinatorTests.swift && git commit -m "feat(app-store): AppStoreReviewCoordinatorRegistry (per-product lifecycle + responderContext seam)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 12: Wire the registry into `AppFeedbackApp` + both background refresh drivers

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (build `AppStoreReviewMirrorStore` + `AppStoreReviewCoordinatorRegistry`; add a helper that maps the current products into `[ASCProductConfig]`; sync on launch and on product-list change; pass the registry into the drivers)
- Modify: `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`
- Modify: `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift`
- Test: build + the existing coordinator/registry suites (no new test; wiring is exercised by a compile + a focused mapping helper test).

**Interfaces:**
- Consumes: `AppStoreReviewMirrorStore`, `AppStoreReviewCoordinatorRegistry`, `AppStoreReviewCoordinator`, `ASCProductConfig`, `RepoStore`/`RepoConfig` (current product source), `KeychainService.loadASCKeySync(for:)`, `KeychainService.loadSync(for: RepoConfig)`.
- Produces: a wired registry that polls during background refresh on both platforms. Produces `ASCProductConfig.from(_:)` mapping helper (static, on `ASCProductConfig`) — placed in `AppStoreReviewMirror.swift`.

Steps:
- [ ] **Step 1: Add the mapping helper + its test.** In `AppFeedback/Models/AppStoreReviewMirror.swift`, append an extension that maps a `RepoConfig` (today's product DTO) into an `ASCProductConfig` ONLY when ASC is configured. Because `RepoConfig` does not yet carry the ASC fields until Phase 0 lands, accept them as explicit args so this compiles today:
  ```swift
  extension ASCProductConfig {
      /// Builds a config from a product's GitHub coordinates + its ASC credentials, or nil when ASC
      /// isn't fully configured (all three of issuerID/keyID/appAppleID must be present & non-empty).
      static func make(id: UUID, owner: String, repo: String,
                       issuerID: String?, keyID: String?, appAppleID: String?) -> ASCProductConfig? {
          guard let issuerID, !issuerID.isEmpty,
                let keyID, !keyID.isEmpty,
                let appAppleID, !appAppleID.isEmpty else { return nil }
          return ASCProductConfig(id: id, owner: owner, repo: repo,
                                  issuerID: issuerID, keyID: keyID, appAppleID: appAppleID)
      }
  }
  ```
  Add `AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift` a test:
  ```swift
  func testASCProductConfigMakeRequiresAllCreds() {
      XCTAssertNil(ASCProductConfig.make(id: UUID(), owner: "o", repo: "r", issuerID: "i", keyID: "k", appAppleID: nil))
      XCTAssertNil(ASCProductConfig.make(id: UUID(), owner: "o", repo: "r", issuerID: "", keyID: "k", appAppleID: "1"))
      XCTAssertNotNil(ASCProductConfig.make(id: UUID(), owner: "o", repo: "r", issuerID: "i", keyID: "k", appAppleID: "1"))
  }
  ```
  Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreReviewMirrorStoreTests 2>&1 | tail -20` — expected PASS.
- [ ] **Step 2: Build the store + registry in `AppFeedbackApp.init()`.** After the `_filterStore`/`_replyTemplateStore` lines, add a `@State private var appStoreReviewMirrorStore: AppStoreReviewMirrorStore` and `@State private var appStoreRegistry: AppStoreReviewCoordinatorRegistry` property (next to the other `@State`s near the top), and in `init()` after the mirrorHolder block insert:
  ```swift
  let ascMirrorStore = AppStoreReviewMirrorStore(context: ModelContext(container))
  _appStoreReviewMirrorStore = State(initialValue: ascMirrorStore)
  let ascRegistry = AppStoreReviewCoordinatorRegistry { cfg in
      let auth = AppStoreConnectAuth(issuerID: cfg.issuerID, keyID: cfg.keyID,
                                     p8PEM: KeychainService.loadASCKeySync(for: cfg.id) ?? "")
      let client = AppStoreConnectClient(auth: auth)
      let owner = cfg.owner; let repo = cfg.repo
      return AppStoreReviewCoordinator(
          config: cfg, client: client, issueWriter: GitHubIssueWriter(),
          commentPoster: GitHubCommentPoster(), mirrorStore: ascMirrorStore,
          tokenLoader: { KeychainService.loadSync(for: RepoConfig(displayName: "", owner: owner, repo: repo)) },
          activityLog: activityLogValue)
  }
  _appStoreRegistry = State(initialValue: ascRegistry)
  ```
- [ ] **Step 3: Define the product→ASC mapping closure + initial sync.** Still in `init()`, after building `ascRegistry`, add a helper that reads the ASC creds. Until Phase 0/2 add the fields to `RepoConfig`, source them from a placeholder that returns `nil` (so the registry stays empty and nothing breaks today); when Phase 0 lands, replace the three `nil`s with `$0.appStoreIssuerID`/`$0.appStoreKeyID`/`$0.appStoreAppAppleID`:
  ```swift
  func ascConfigs(from repos: [RepoConfig]) -> [ASCProductConfig] {
      repos.compactMap { ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                               issuerID: nil, keyID: nil, appAppleID: nil) }
  }
  ascRegistry.syncWithProducts(ascConfigs(from: _store.wrappedValue.repos))
  ```
  Keep `ascConfigs(from:)` as a `private func` on the `AppFeedbackApp` struct (move the body there) so the `body`'s `.task(id:)` can call it too.
- [ ] **Step 4: Sync on product-list change + pollNow on scenePhase.** In `body`, alongside the existing `.task(id: store.repos.map(\.id))` that updates `repoConfigSnapshot`, add inside that same closure: `appStoreRegistry.syncWithProducts(ascConfigs(from: store.repos))`. In the `.onAppear` add `appStoreRegistry.start()`. In each `onChange(of: scenePhase)` `.active` branch, add `Task { await appStoreRegistry.pollNow() }`.
- [ ] **Step 5: Pass the registry to the drivers.** Add an `appStoreRegistry: AppStoreReviewCoordinatorRegistry` parameter to both driver inits (stored property), and in `runRefresh()` of each, after the GitHub loop, add `await appStoreRegistry.pollNow()`. In `AppFeedbackApp.init()` pass `appStoreRegistry: ascRegistry` to both `iOSBackgroundRefreshDriver(...)` and `MacBackgroundRefreshDriver(...)` constructions.
  - In `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`: add `private let appStoreRegistry: AppStoreReviewCoordinatorRegistry`, the matching init param, and `await appStoreRegistry.pollNow()` at the end of `runRefresh()` (before `diffAndNotify`, so synthesized issues are picked up by the GitHub load on the NEXT refresh; calling it last is also acceptable — order does not affect correctness since synthesis lands as GitHub issues read on a subsequent cycle).
  - Same three edits in `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift`.
- [ ] **Step 6: Build the full app + test target.** `xcodebuild build-for-testing -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -30` — expected PASS. Then iOS compile sanity for the iOS driver edits: `xcodebuild build -scheme AppFeedback_iOS -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20` — expected PASS (or BUILD SUCCEEDED) (iOS uses the `AppFeedback_iOS` scheme).
- [ ] **Step 7: Run the whole new App-Store suite as ground truth.** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreConnectAuthTests -only-testing:AppFeedbackTests_macOS/AppStoreConnectClientTests -only-testing:AppFeedbackTests_macOS/AppStoreReviewSynthesizerTests -only-testing:AppFeedbackTests_macOS/AppStoreReviewMirrorStoreTests -only-testing:AppFeedbackTests_macOS/AppStoreReviewCoordinatorTests -only-testing:AppFeedbackTests_macOS/AppStoreReviewCoordinatorRegistryTests 2>&1 | tail -30` — expected ALL PASS. (The ~11 Keychain/GitHubAccount failures are NOT in this set; do not run the full suite expecting zero failures.)
- [ ] **Step 8: Commit.** `git add AppFeedback/App/AppFeedbackApp.swift AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift AppFeedback/Models/AppStoreReviewMirror.swift AppFeedbackTests/AppStoreReviewMirrorStoreTests.swift && git commit -m "feat(app-store): wire review coordinator registry into app + background drivers" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 13: `AppStoreSourceFormModel` — extracted, unit-tested form logic (key validation / app pick / save)

**Files:**
- Create: `AppFeedback/Views/Settings/Sources/AppStoreSourceFormModel.swift`
- Test: `AppFeedbackTests/AppStoreSourceFormModelTests.swift`

**Interfaces:**
- Consumes: `AppStoreConnectClientProtocol` (fake in tests), `ASCApp`, `AppStoreConnectError`/`StatusCarryingError`, `AppStoreConnectAuth`, `AppStoreConnectClient`, `KeychainService.saveASCKey(_:for:)`, `ProductStore`/`ProductConfig` (today: `RepoStore`/`RepoConfig`).
- Produces: `@MainActor @Observable final class AppStoreSourceFormModel` holding the editable fields (`issuerID`, `keyID`, `pemText`, `appAppleID`, `manualAppID`), the test/validation state (`enum Phase { case idle, testing, valid, failed(String) }`, `discoveredApps: [ASCApp]`, `selectedAppID: String?`), and the view-independent operations:
  - `func importPEM(from url: URL)` — reads the `.p8` at a (possibly security-scoped) URL into `pemText`.
  - `func test(makeClient: (String, String, String) -> any AppStoreConnectClientProtocol) async` — validates the key by minting a JWT and calling `client.listApps()`; on success → `.valid` + populates `discoveredApps`; on `403`/`StatusCarryingError statusCode == 401/403` → `.failed` with a clear message.
  - `var canSave: Bool` — true when issuer/key/PEM present AND (a discovered app is selected OR a non-empty `manualAppID`).
  - `func resolvedAppAppleID() -> String?` — `selectedAppID` else trimmed `manualAppID` (numeric) else nil.
  - `func save(productID: UUID, into store: ProductStore) async` — persists `pemText`→Keychain (`saveASCKey(_:for: productID)`) and writes `issuerID`/`keyID`/`resolvedAppAppleID()` onto the product via `store.update(_:)`.

Steps:
- [ ] **Step 1: Write the failing model tests.** Create `AppFeedbackTests/AppStoreSourceFormModelTests.swift`:
  ```swift
  import XCTest
  @testable import AppFeedback

  @MainActor
  final class AppStoreSourceFormModelTests: XCTestCase {
      func testTestSuccessPopulatesAppsAndMarksValid() async {
          let client = FakeAppStoreConnectClient()
          client.setApps([ASCApp(id: "111", bundleId: "com.acme.app", name: "Acme"),
                          ASCApp(id: "222", bundleId: "com.acme.pro", name: "Acme Pro")])
          let model = AppStoreSourceFormModel()
          model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
          await model.test { _, _, _ in client }
          guard case .valid = model.phase else { return XCTFail("expected .valid, got \(model.phase)") }
          XCTAssertEqual(model.discoveredApps.count, 2)
      }

      func testTestForbiddenMarksFailed() async {
          let client = FakeAppStoreConnectClient()
          client.setThrowOnList(AppStoreConnectError.forbidden)
          let model = AppStoreSourceFormModel()
          model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
          await model.test { _, _, _ in client }
          guard case .failed = model.phase else { return XCTFail("expected .failed, got \(model.phase)") }
      }

      func testCanSaveRequiresCredsPlusAppChoice() {
          let model = AppStoreSourceFormModel()
          XCTAssertFalse(model.canSave)
          model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
          XCTAssertFalse(model.canSave, "no app chosen yet")
          model.manualAppID = "  6443123456 "
          XCTAssertTrue(model.canSave)
          XCTAssertEqual(model.resolvedAppAppleID(), "6443123456", "manual id trimmed")
          model.selectedAppID = "999"
          XCTAssertEqual(model.resolvedAppAppleID(), "999", "picker selection wins over manual")
      }

      func testManualAppIDMustBeNumeric() {
          let model = AppStoreSourceFormModel()
          model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
          model.manualAppID = "not-a-number"
          XCTAssertFalse(model.canSave)
          XCTAssertNil(model.resolvedAppAppleID())
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreSourceFormModelTests 2>&1 | tail -25` — expected FAIL (no `AppStoreSourceFormModel`).
- [ ] **Step 3: Implement the model.** Create `AppFeedback/Views/Settings/Sources/AppStoreSourceFormModel.swift`:
  ```swift
  import Foundation
  import Observation

  /// View-independent logic behind `AppStoreSourceForm`, so the key-validation / app-pick / save
  /// behavior is unit-tested without SwiftUI. The form owns one of these as `@State`.
  @MainActor
  @Observable
  final class AppStoreSourceFormModel {
      enum Phase: Equatable {
          case idle, testing, valid
          case failed(String)
      }

      // Editable fields.
      var issuerID = ""
      var keyID = ""
      var pemText = ""           // the .p8 PEM contents (imported via .fileImporter)
      var manualAppID = ""       // numeric ASC app id fallback when the picker can't load

      // Test / validation state.
      var phase: Phase = .idle
      var discoveredApps: [ASCApp] = []
      var selectedAppID: String?

      init() {}

      /// Reads the `.p8` at `url` into `pemText`. Handles iOS Files security-scoped URLs.
      func importPEM(from url: URL) {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          if let text = try? String(contentsOf: url, encoding: .utf8) {
              pemText = text
          } else if let data = try? Data(contentsOf: url) {
              pemText = String(decoding: data, as: UTF8.self)
          }
      }

      /// Validates the key by minting a JWT and calling `listApps()`. `makeClient` is injected so tests
      /// pass a fake; production passes a closure building a real `AppStoreConnectClient`.
      func test(makeClient: (String, String, String) -> any AppStoreConnectClientProtocol) async {
          guard !issuerID.isEmpty, !keyID.isEmpty, !pemText.isEmpty else {
              phase = .failed("Enter Issuer ID, Key ID, and import the .p8 key first."); return
          }
          phase = .testing
          let client = makeClient(issuerID, keyID, pemText)
          do {
              let apps = try await client.listApps()
              discoveredApps = apps.sorted { $0.name < $1.name }
              if selectedAppID == nil { selectedAppID = discoveredApps.first?.id }
              phase = .valid
          } catch {
              let code = (error as? StatusCarryingError)?.statusCode ?? 0
              switch code {
              case 401: phase = .failed("Authentication failed — check the Issuer ID, Key ID, and .p8 key.")
              case 403: phase = .failed("This key is not authorized for the App Store Connect API.")
              default:  phase = .failed((error as? LocalizedError)?.errorDescription ?? "Could not reach App Store Connect.")
              }
          }
      }

      var canSave: Bool {
          !issuerID.trimmingCharacters(in: .whitespaces).isEmpty
              && !keyID.trimmingCharacters(in: .whitespaces).isEmpty
              && !pemText.isEmpty
              && resolvedAppAppleID() != nil
      }

      /// Picker selection wins; otherwise a trimmed numeric manual id; otherwise nil.
      func resolvedAppAppleID() -> String? {
          if let selectedAppID, !selectedAppID.isEmpty { return selectedAppID }
          let trimmed = manualAppID.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
          return trimmed
      }

      /// Persists the PEM to the Keychain (keyed by product id) and writes the IDs onto the product.
      func save(productID: UUID, into store: ProductStore) async {
          guard let appID = resolvedAppAppleID() else { return }
          await KeychainService.saveASCKey(pemText, for: productID)
          guard var product = store.products.first(where: { $0.id == productID }) else { return }
          product.appStoreIssuerID = issuerID.trimmingCharacters(in: .whitespaces)
          product.appStoreKeyID = keyID.trimmingCharacters(in: .whitespaces)
          product.appStoreAppAppleID = appID
          store.update(product)
      }
  }
  ```
  > **Phase-0 dependency:** `ProductStore`/`ProductConfig` (with `products` + the three `appStore*` fields) and `store.update(_:)` land in Phase 0. This view + its model integrate **after Phase 0** (the same integration boundary as Task 14's form and the rest of the Phase-3 wiring), so the code above compiles against the post-Phase-0 `ProductStore`/`ProductConfig`. The form is the consumer of Phase 0's `products` alias and the three ASC fields; there is no pre-Phase-0 variant to ship.
- [ ] **Step 4: Run (expect PASS).** `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreSourceFormModelTests 2>&1 | tail -20` — expected PASS (4 tests).
- [ ] **Step 5: Commit.** `git add AppFeedback/Views/Settings/Sources/AppStoreSourceFormModel.swift AppFeedbackTests/AppStoreSourceFormModelTests.swift && git commit -m "feat(app-store): AppStoreSourceFormModel (validate key + app pick + save logic)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 14: REAL `AppStoreSourceForm` (both platforms; `.p8` import incl. iOS Files; Test; app picker; status)

**Files:**
- Modify (rewrite in place; replaces the Phase-2 stub): `AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift`
- Test: build-gated (SwiftUI view); its logic is covered by Task 13's `AppStoreSourceFormModelTests`. The form is reachable from the Phase-2 Sources row (the `init(store:product:)` signature is preserved).

**Interfaces:**
- Consumes: `AppStoreSourceFormModel` (Task 13), `AppStoreConnectAuth`, `AppStoreConnectClient`, `AppStoreReviewCoordinatorRegistry` (from `Environment`, for `restart(productID:configs:)` + `status(productID:)`), `ProductStore`/`ProductConfig`, `ASCProductConfig.make(...)`, `UniformTypeIdentifiers`.
- Produces: `struct AppStoreSourceForm: View { init(store: ProductStore, product: ProductConfig) }` — the SAME signature the Phase-2 Sources row pushes to (no change in `ProductSettingsView`).

Steps:
- [ ] **Step 1: Rewrite the form.** Replace `AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift` with the real form:
  ```swift
  import SwiftUI
  import UniformTypeIdentifiers

  /// Real App Store Connect setup form (Phase 3 — replaces the Phase-2 stub). Paste Issuer ID +
  /// Key ID, import the `.p8` private key (macOS file picker AND iOS Files via `.fileImporter`), tap
  /// **Test** to validate the key + load the app list, pick the app (or type its numeric id), then
  /// **Save** to store the `.p8` in the Keychain (keyed by product id) and write the IDs onto the
  /// product. Shows the per-source `lastSuccessAt`/`lastError` from the live coordinator.
  struct AppStoreSourceForm: View {
      let store: ProductStore
      let product: ProductConfig

      @Environment(AppStoreReviewCoordinatorRegistry.self) private var registry
      @State private var model = AppStoreSourceFormModel()
      @State private var showImporter = false
      @State private var lastSuccessAt: Date?
      @State private var lastError: String?
      @State private var saving = false

      // The `.p8` UTI — a PEM text file. `.data` is the safe superset that always lets the Files
      // picker surface a `.p8` on iOS; we also accept the explicit extension type when available.
      private var p8Types: [UTType] {
          var types: [UTType] = [.data, .text]
          if let p8 = UTType(filenameExtension: "p8") { types.insert(p8, at: 0) }
          return types
      }

      var body: some View {
          Form {
              credentialsSection
              keySection
              appSection
              statusSection
          }
          .formStyle(.grouped)
          #if os(iOS)
          .navigationTitle("App Store")
          .navigationBarTitleDisplayMode(.inline)
          #endif
          .fileImporter(isPresented: $showImporter, allowedContentTypes: p8Types) { result in
              // iOS Files returns a security-scoped URL; the model handles start/stopAccessing.
              if case .success(let url) = result { model.importPEM(from: url) }
          }
          .task { await refreshStatus() }
          .onAppear(perform: loadExisting)
      }

      private var credentialsSection: some View {
          Section("Credentials") {
              TextField("Issuer ID", text: $model.issuerID)
                  .textContentType(.none)
                  #if os(iOS)
                  .autocapitalization(.none)
                  #endif
              TextField("Key ID", text: $model.keyID)
                  #if os(iOS)
                  .autocapitalization(.none)
                  #endif
          }
      }

      private var keySection: some View {
          Section {
              Button {
                  showImporter = true
              } label: {
                  Label(model.pemText.isEmpty ? "Import .p8 Key…" : "Replace .p8 Key…",
                        systemImage: "key.fill")
              }
              if !model.pemText.isEmpty {
                  Text("Key loaded (\(model.pemText.count) bytes).").font(.caption).foregroundStyle(.secondary)
              }
              Button("Test") { Task { await runTest() } }
                  .disabled(model.issuerID.isEmpty || model.keyID.isEmpty || model.pemText.isEmpty
                            || model.phase == .testing)
              testResultRow
          } header: {
              Text("Private Key (.p8)")
          } footer: {
              Text("Download the API key from App Store Connect → Users and Access → Integrations. The .p8 is stored in your Keychain, never synced to GitHub.")
          }
      }

      @ViewBuilder private var testResultRow: some View {
          switch model.phase {
          case .idle:    EmptyView()
          case .testing: HStack { ProgressView(); Text("Testing…").foregroundStyle(.secondary) }
          case .valid:   Label("Key valid — \(model.discoveredApps.count) app(s) found.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
      }

      @ViewBuilder private var appSection: some View {
          Section {
              if model.discoveredApps.isEmpty {
                  TextField("App Apple ID (numeric)", text: $model.manualAppID)
                      #if os(iOS)
                      .keyboardType(.numberPad)
                      #endif
                  Text("Run **Test** to pick from your apps, or paste the numeric App Store ID.").font(.caption).foregroundStyle(.secondary)
              } else {
                  Picker("App", selection: $model.selectedAppID) {
                      ForEach(model.discoveredApps, id: \.id) { app in
                          Text("\(app.name) (\(app.bundleId))").tag(app.id as String?)
                      }
                  }
              }
              Button {
                  Task { await runSave() }
              } label: {
                  if saving { ProgressView() } else { Text("Save") }
              }
              .disabled(!model.canSave || saving)
          } header: {
              Text("App")
          }
      }

      private var statusSection: some View {
          Section("Status") {
              LabeledContent("Last sync") {
                  Text(lastSuccessAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                      .foregroundStyle(.secondary)
              }
              if let lastError {
                  Label(lastError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
              }
          }
      }

      // MARK: - Actions

      private func loadExisting() {
          model.issuerID = product.appStoreIssuerID ?? ""
          model.keyID = product.appStoreKeyID ?? ""
          model.manualAppID = product.appStoreAppAppleID ?? ""
          if let pem = KeychainService.loadASCKeySync(for: product.id) { model.pemText = pem }
      }

      private func runTest() async {
          await model.test { issuer, kid, pem in
              AppStoreConnectClient(auth: AppStoreConnectAuth(issuerID: issuer, keyID: kid, p8PEM: pem))
          }
      }

      private func runSave() async {
          saving = true
          defer { saving = false }
          await model.save(productID: product.id, into: store)
          // Restart the coordinator so the new credentials take effect immediately.
          let configs = store.products.compactMap {
              ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                    issuerID: $0.appStoreIssuerID, keyID: $0.appStoreKeyID,
                                    appAppleID: $0.appStoreAppAppleID)
          }
          registry.restart(productID: product.id, configs: configs)
          await refreshStatus()
      }

      private func refreshStatus() async {
          if let status = await registry.status(productID: product.id) {
              lastSuccessAt = status.lastSuccessAt
              lastError = status.lastError
          }
      }
  }
  ```
  > **Phase-0/2 dependency:** this reads `ProductConfig.appStore*` fields + `store.products` (Phase 0) and is pushed from the Phase-2 Sources row; the `init(store:product:)` signature matches the Phase-2 stub exactly so `ProductSettingsView` is unchanged. The `AppStoreReviewCoordinatorRegistry` must be injected into the settings view hierarchy via `.environment(appStoreRegistry)` in `AppFeedbackApp` (add this alongside the other `.environment(...)` injections in Task 12 Step 4).
- [ ] **Step 2: Build both platforms.** macOS: `xcodebuild build-for-testing -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -30` — expected PASS. iOS (the `.fileImporter` Files path + `keyboardType` compile only on iOS): `xcodebuild build -scheme AppFeedback_iOS -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20` — expected BUILD SUCCEEDED.
- [ ] **Step 3: Inject the registry into the settings hierarchy.** In `AppFeedbackApp.body`, add `.environment(appStoreRegistry)` next to the existing `.environment(...)` modifiers on the settings/root view so `AppStoreSourceForm`'s `@Environment(AppStoreReviewCoordinatorRegistry.self)` resolves. Re-run the macOS build to confirm PASS.
- [ ] **Step 4: Commit.** `git add AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift AppFeedback/App/AppFeedbackApp.swift && git commit -m "feat(app-store): real AppStoreSourceForm (.p8 import incl. iOS Files, Test, app picker, status)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

## Notes on remaining spec items deferred to other phases (do NOT implement here)
- **"Respond on App Store" inspector panel** + `responseBody` length validation + 422/409 handling + `PENDING_PUBLISH → PUBLISHED` refresh display = Phase 4. This plan ships the client write methods (`createOrUpdateResponse`/`deleteResponse`), the mirror fields (`responseState`/`responseId`) they update, the canonical `AppStoreReviewMirrorStore.setResponse(reviewId:responseId:state:)`/`clearResponse(reviewId:)`, and the `AppStoreReviewCoordinatorRegistry.responderContext(productID:)` seam (which carries `isReadOnly` after a 403).
- **`IssueBodyParser` widening + `CachedIssue.source/rating` columns + badges + Source filter facet** = Phase 1. This plan's `AppStoreReviewSynthesizer` emits the exact marker strings/labels Phase 1 will parse, so they round-trip.
- **`Repo → Product` rename + migration** = Phase 0. This plan reads from today's `RepoConfig`/`RepoStore`; the single integration point (`ascConfigs(from:)` in `AppFeedbackApp`) flips from `nil` ASC fields to the real `Product` fields once Phase 0 lands, with no change to any App-Store type.
