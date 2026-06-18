# Phase 4 — App Store developer responses (inspector write-back) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Respond on App Store" panel to the feedback detail card so the developer can post, edit, and delete the App Store Connect developer response from inside the app, with mirror-state tracking and a cross-device GitHub comment record.

**Architecture:** A pure `@MainActor @Observable` controller (`AppStoreResponseController`) drives the panel: it owns the editor text + char-limit validation, calls the injected `AppStoreConnectClientProtocol.createOrUpdateResponse`/`deleteResponse`, writes `responseId`/`responseState` back through Phase 3's `AppStoreReviewMirrorStore` (this phase CONSUMES it — it does not define or duplicate it), and posts a `GitHubCommentPoster` comment for cross-device record. A new SwiftUI subview `AppStoreResponsePanel` binds to the controller.

**Where the panel renders (the spec's "inspector"):** The spec says "when the selected feedback has `source == app-store`, the inspector shows a 'Respond on App Store' panel." In this codebase the trailing inspector column (`ProjectInspectorPanel`) is dedicated to Tasks & Versions; the **selected feedback itself is shown via `IssueCardView`** inside the detail pane (`IssueListView`). So the spec's "inspector" panel maps to the feedback card: the panel is added near the bottom of `IssueCardView`'s main `VStack`, shown only when `issue.source == .appStore`. (Confirmed by reading `AppFeedback/App/RootView.swift` — `inspectorPanel(for:)` → `ProjectInspectorPanel` carries tasks/versions, not the selected feedback — and `AppFeedback/Views/Issues/IssueCardView.swift`, which is the view that renders each selected feedback.)

The `reviewId` is parsed from the issue body markers; the `responseId`/state come from the synced `AppStoreReviewMirror`. A 403 (read-only key) puts the controller into a disabled state with an explanatory note. The controller is **cached per `issue.number`** by `IssueListView` (an `@State` dictionary) and passed into `IssueCardView`, so the draft text survives re-renders (e.g. when `mirrorStore.version` bumps on a CloudKit import).

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

## Shared Contracts (authoritative across all phases — synced with the INDEX; the INDEX overrides any drift)
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
}
// MailAccount gains exactly one stored field:
//   var feedbackProductID: UUID?       // nil ⇒ legacy reply-mirror account; non-nil ⇒ feedback inbox for that product
//   (the inbox-vs-reply-mirror "role" is DERIVED from feedbackProductID != nil; do NOT add a stored role.)
// Migration: a single idempotent, AppStorage-gated `ProductMigration.run(context:defaults:)` invoked from
//   AppFeedbackApp.init() (like MailAccountMigration). DO NOT ship a VersionedSchema/SchemaMigrationPlan — the
//   container has no migrationPlan: and it would be dead code. A read-only legacy Repo @Model stays one release.
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

// ── Phase 3 establishes (App Store read path — OWNS the mirror store + setup form) ─────────────
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
    func deleteByIssue(productID: UUID, issueNumber: Int)
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
actor AppStoreReviewCoordinator { /* poll loop, incremental + periodic full re-scan */ }
@MainActor final class AppStoreReviewCoordinatorRegistry {   // one coordinator per product-with-ASC; mirrors MailSyncCoordinatorRegistry
    func responderContext(productID: UUID) -> AppStoreResponderContext?   // Phase 4 consumes this
}
struct AppStoreResponderContext: Sendable {          // Phase 3 DEFINES; Phase 4 CONSUMES
    let client: any AppStoreConnectClientProtocol
    let isReadOnly: Bool                             // true after a 403 on a response write (read-only key)
    let owner: String; let repo: String              // for the GitHub "responded" record comment
}
protocol FeedbackSourceIngestor: Sendable { func poll() async throws }   // thin seam; AppStoreReviewCoordinator conforms

// ── Phase 4 establishes (App Store write-back; consumes Phase 3, defines NO store) ──────────────
// "Respond on App Store" panel shown when the selected feedback's source == .appStore. Reads reviewId from the
//   issue body markers. Uses client.createOrUpdateResponse / deleteResponse via registry.responderContext(productID:).
//   Updates the Phase-3 AppStoreReviewMirrorStore.setResponse/clearResponse. Posts a GitHubCommentPoster record comment.
//   403 (AppStoreConnectError.forbidden / any StatusCarryingError statusCode==403) ⇒ disable panel + explanatory note.
//   The response controller is CACHED per issue.number (not rebuilt in `body`) so the draft survives re-renders.

// ── Phase 5 establishes (email feedback source) ───────────────────────────
final class MailToFeedbackMirror { /* detached Task in MailSyncCoordinator.pollOnce(); gated on feedbackProductID != nil */ }
//   thread root → new issue (label source:email, markers source/fromAddress/messageId); reply in known thread → comment.
```

---

## What this phase consumes (do NOT re-implement)

These are produced by earlier phases and referenced here by their Shared-Contract names:

- **Phase 1:** `enum FeedbackSource` (`.sdk`/`.appStore`/`.email`); `FeedbackIssue.source: FeedbackSource` and `FeedbackIssue.rating: Int?`; the body-marker KEY `"reviewId"` added to the SDK `BodyMarker` vocabulary and surfaced through the app-side `IssueBodyParser` shim as `ParsedBody.reviewId: String?`. *(If the parser exposure is missing at build time, see Task 1 — Phase 4 adds a narrow local helper to extract `reviewId` from `rawBody` rather than block on Phase 1's parser surface.)*
- **Phase 3 (CONSUMED — do NOT redefine any of these):**
  - `@Model AppStoreReviewMirror` (CloudKit-synced; fields `reviewId`, `productID`, `issueNumber`, `contentHash`, `responseState`, `responseId`).
  - `@MainActor @Observable final class AppStoreReviewMirrorStore` at `AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift`, with the canonical API `mirror(reviewId:)`, `mirror(productID:issueNumber:)`, `setResponse(reviewId:responseId:state:)`, `clearResponse(reviewId:)`, `deleteByIssue(productID:issueNumber:)`, and `private(set) var version`. **Phase 4 consumes this store; it does NOT create it or duplicate its test class.**
  - `protocol AppStoreConnectClientProtocol` with `createOrUpdateResponse(reviewId:body:) -> ASCResponse` and `deleteResponse(responseId:)`; `struct ASCResponse { id; responseBody; state; lastModifiedDate }`.
  - `protocol StatusCarryingError: Error { var statusCode: Int { get } }` and `enum AppStoreConnectError: StatusCarryingError` (`.forbidden`.statusCode == 403) — this phase relies on the conformance for the 403 read-only path.
  - `@MainActor final class AppStoreReviewCoordinatorRegistry { func responderContext(productID:) -> AppStoreResponderContext? }` and `struct AppStoreResponderContext { let client: any AppStoreConnectClientProtocol; let isReadOnly: Bool; let owner: String; let repo: String }`. **Phase 4 consumes `responderContext(productID:)`; it does NOT define `AppStoreResponderContext`.**
  - `actor AppStoreConnectAuth(issuerID:keyID:p8PEM:)` and the concrete client `AppStoreConnectClient` (this phase only needs the protocol).

Confirmed existing signatures this phase builds on (read from source):
- `actor GitHubCommentPoster { func postComment(owner: String, repo: String, issueNumber: Int, body: String, token: String) async throws -> Int }` — `AppFeedback/Services/GitHubCommentPoster.swift`. `PostError.apiError(Int, message: String?)`.
- `enum KeychainService { static func loadSync(for repo: RepoConfig) -> String? }` and `static func load(for repo: RepoConfig) async -> String?` — token keyed on `"\(owner)/\(repo)"` via `accountKey(for:)`. `AppFeedback/Services/KeychainService.swift`. *(Phase 0 renames `RepoConfig` → `ProductConfig`; this plan writes against `RepoConfig`/`ProductConfig` whichever exists — see note in Task 4.)*
- `struct IssueCardView: View` with stored `let issue: FeedbackIssue`, `let repoOwner: String`, `let repoName: String`, `let appColor: Color`, then optional members (`var onRemoveTask: ((TaskItem) -> Void)? = nil`, …) — `AppFeedback/Views/Issues/IssueCardView.swift`. `FeedbackIssue` (`AppFeedback/Models/FeedbackIssue.swift`) has `let number: Int` and `let rawBody: String` (plus Phase-1's `source`/`rating`). The panel is added near the bottom of the card's main `VStack`.
- `struct IssueListView` builds each card in a `@ViewBuilder private func issueCard(for issue: FeedbackIssue)`; it is constructed from `RootView`'s `detail:` closure with `repoOwner`/`repoName` and `summaryCollapseKey` last. `AppFeedback/Views/Issues/IssueListView.swift`, `AppFeedback/App/RootView.swift`.
- `@Observable @MainActor final class VersionStore` — the canonical store shape (own-context `didSave` filter + `NSPersistentStoreRemoteChange` + `NotificationCenter.cloudKitImportSucceeded` reload tasks, `isolated deinit`). `AppFeedback/Services/VersionStore.swift`. Phase 3's `AppStoreReviewMirrorStore` already copies this shape with an explicit `version` counter; Phase 4 only reads `version` to drive re-render.

---

## File Structure

### Create
- `AppFeedback/Services/AppStoreReviewIdExtractor.swift` — `enum AppStoreReviewIdExtractor { static func reviewId(fromBody:) -> String? }`: pulls the `reviewId` marker out of a synthesized App Store feedback body.
- `AppFeedback/ViewModels/AppStoreResponseController.swift` — `@Observable @MainActor` controller: editor text + char-count validation, submit/delete via injected client, mirror write-back through Phase 3's `AppStoreReviewMirrorStore`, GitHub comment post, 403/422/409 handling (403 via `StatusCarryingError.statusCode == 403` AND a direct `AppStoreConnectError.forbidden` match), derived button state.
- `AppFeedback/Views/Issues/AppStoreResponsePanel.swift` — SwiftUI subview bound to the controller; text editor + counter + Submit/Edit/Delete + state/error labels, plus a pure `AppStoreResponsePanelModel` label helper.
- `AppFeedbackTests/AppStoreResponseControllerTests.swift` — XCTest class driving the controller with a fake `AppStoreConnectClientProtocol` + fake comment poster: reviewId extraction, char-limit guard, 403 disable (both via a stub `StatusCarryingError` AND the REAL `AppStoreConnectError.forbidden`), 422/409 surfacing, mirror transitions, panel label logic. **This is the ONLY XCTestCase class this phase adds — it does not redefine `AppStoreReviewMirrorStoreTests` (that belongs to Phase 3).**

### Consume (Phase 3 — do NOT create or modify)
- `AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift` — Phase 3's CloudKit-synced mirror store. Phase 4 reads/writes through its canonical API (`setResponse(reviewId:responseId:state:)`, `clearResponse(reviewId:)`, `mirror(reviewId:)`, `mirror(productID:issueNumber:)`).

### Modify
- `AppFeedback/Views/Issues/IssueCardView.swift` — render `AppStoreResponsePanel` when `issue.source == .appStore`, bound to a controller **passed in** (cached by `IssueListView`); add a `var responseController: AppStoreResponseController? = nil` member.
- `AppFeedback/Views/Issues/IssueListView.swift` — own an `@State` per-`issue.number` controller cache; build/reuse a controller for each App Store card (using `mirrorStore` + `appStoreResponder` deps) and pass it into `IssueCardView`.
- `AppFeedback/App/RootView.swift` — inject Phase 3's `AppStoreReviewMirrorStore` and the registry's `responderContext(productID:)` closure into `IssueListView`.

---

## Tasks

> Phase 4 does **not** create `AppStoreReviewMirrorStore` or its test class — Phase 3 owns both (`AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift`). This phase only consumes the store's canonical API. The first task here is the local `reviewId` extractor.

### Task 1: `reviewId` extraction from the feedback body

**Files:**
- Create `AppFeedback/Services/AppStoreReviewIdExtractor.swift`
- Test `AppFeedbackTests/AppStoreResponseControllerTests.swift` *(create here; later tasks extend it)*

**Interfaces:**
- Consumes (Phase 1 Shared Contract): the body-marker KEY `"reviewId"`. The synthesized App Store issue body contains a marker line written by Phase 3 in the form `reviewId: <id>` (the SDK formatter renders markers as `key: value` lines; this matches how `App:`/`App Version:` already round-trip).
- Produces: `enum AppStoreReviewIdExtractor { static func reviewId(fromBody body: String) -> String? }`.

> Rationale: The Shared Contract adds `source`/`rating` to `FeedbackIssue` but NOT `reviewId`. The `reviewId` lives in the issue body markers, so Phase 4 extracts it locally. This keeps Phase 4 independent of whether Phase 1's parser surfaces `reviewId` as a typed field.

- [ ] **Step 1: Write the failing extractor test.**
  Create `AppFeedbackTests/AppStoreResponseControllerTests.swift` with the first test:
  ```swift
  import XCTest
  @testable import AppFeedback

  @MainActor
  final class AppStoreResponseControllerTests: XCTestCase {
      func testReviewIdExtractedFromMarkerLine() {
          let body = """
          Loved the update!

          reviewId: 1234567890ABCDEF
          source: app-store
          rating: 5
          """
          XCTAssertEqual(AppStoreReviewIdExtractor.reviewId(fromBody: body), "1234567890ABCDEF")
      }

      func testReviewIdMissingReturnsNil() {
          XCTAssertNil(AppStoreReviewIdExtractor.reviewId(fromBody: "no markers here"))
      }

      func testReviewIdToleratesExtraWhitespace() {
          XCTAssertEqual(
              AppStoreReviewIdExtractor.reviewId(fromBody: "reviewId:   abc-123  "),
              "abc-123")
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (no `AppStoreReviewIdExtractor`).**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testReviewIdExtractedFromMarkerLine
  ```
  Expected: FAIL — undefined symbol.

- [ ] **Step 3: Implement the extractor.**
  Create `AppFeedback/Services/AppStoreReviewIdExtractor.swift`:
  ```swift
  import Foundation

  /// Pulls the App Store `reviewId` out of a synthesized feedback body. Phase 3 writes the
  /// review's id as a `reviewId: <value>` marker line (same `key: value` grain the SDK uses
  /// for `App:` / `App Version:`); the write-back panel needs it to target the right review.
  enum AppStoreReviewIdExtractor {
      /// The marker key, matching the Phase-1 BodyMarkers vocabulary entry "reviewId".
      private static let markerKey = "reviewId:"

      static func reviewId(fromBody body: String) -> String? {
          for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
              let line = rawLine.trimmingCharacters(in: .whitespaces)
              guard line.hasPrefix(markerKey) else { continue }
              let value = line.dropFirst(markerKey.count).trimmingCharacters(in: .whitespaces)
              return value.isEmpty ? nil : value
          }
          return nil
      }
  }
  ```

- [ ] **Step 4: Run the three extractor tests — expect PASS.**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testReviewIdExtractedFromMarkerLine -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testReviewIdMissingReturnsNil -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testReviewIdToleratesExtraWhitespace
  ```
  Expected: 3 PASS.

- [ ] **Step 5: Commit (stage only the extractor + test file).**
  ```
  git add AppFeedback/Services/AppStoreReviewIdExtractor.swift AppFeedbackTests/AppStoreResponseControllerTests.swift
  git commit -m "feat(app-store): extract reviewId marker from feedback body

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2: `AppStoreResponseController` — char-limit guard + derived state

**Files:**
- Create `AppFeedback/ViewModels/AppStoreResponseController.swift`
- Test `AppFeedbackTests/AppStoreResponseControllerTests.swift` (extend)

**Interfaces:**
- Consumes (Phase 3 Shared Contract): `protocol AppStoreConnectClientProtocol`; `struct ASCResponse { let id: String; let responseBody: String; let state: String; let lastModifiedDate: Date }`.
- Consumes (Phase 3 Shared Contract): `@MainActor @Observable final class AppStoreReviewMirrorStore` (at `AppFeedback/Services/AppStore/AppStoreReviewMirrorStore.swift`) — canonical API `mirror(reviewId:)`, `setResponse(reviewId:responseId:state:)`, `clearResponse(reviewId:)`.
- Consumes (existing): `actor GitHubCommentPoster { func postComment(owner:repo:issueNumber:body:token:) async throws -> Int }`.
- Produces (later tasks + the panel view rely on these exact names):
  - `@MainActor @Observable final class AppStoreResponseController`
  - `static let maxBodyLength = 5970`
  - `enum Mode: Equatable { case noResponse, hasResponse, disabledReadOnly }`
  - `enum SubmitError: Equatable { case tooLong(Int), conflict, validation(String), api(Int, String?), network(String) }`
  - `var draft: String`
  - `var isBusy: Bool { get }`
  - `var lastError: SubmitError? { get }`
  - `var remainingChars: Int { get }`
  - `var overLimit: Bool { get }`
  - `var canSubmit: Bool { get }`
  - `var mode: Mode { get }`
  - `init(reviewId: String, productID: UUID, issueNumber: Int, repoOwner: String, repoName: String, client: any AppStoreConnectClientProtocol, mirrorStore: AppStoreReviewMirrorStore, commentPoster: GitHubCommentPoster, tokenLoader: @escaping @Sendable () async -> String?, readOnly: Bool)`

> The controller is built once per `issue.number` by `IssueListView` (Task 4) from the per-issue values, so it stays a plain class (no SwiftData dependency beyond the injected store). `readOnly` is supplied by the caller (true ⇒ the product's ASC key is a read-only key, surfaced as `AppStoreResponderContext.isReadOnly` by Phase 3) — but the controller ALSO flips to `.disabledReadOnly` if a live call returns 403 (Task 3).

- [ ] **Step 1: Write failing tests for char-limit + derived state (no network).**
  Append to `AppStoreResponseControllerTests.swift`:
  ```swift
  // A no-op fake client; network-call assertions arrive in Task 3.
  private actor FakeASCClient: AppStoreConnectClientProtocol {
      func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
          ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)
      }
      func listApps() async throws -> [ASCApp] { [] }
      func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
          ASCResponse(id: "resp", responseBody: body, state: "PENDING_PUBLISH", lastModifiedDate: Date())
      }
      func deleteResponse(responseId: String) async throws {}
  }

  private func makeController(
      readOnly: Bool = false,
      client: any AppStoreConnectClientProtocol = FakeASCClient(),
      mirrorStore: AppStoreReviewMirrorStore? = nil
  ) throws -> AppStoreResponseController {
      let store: AppStoreReviewMirrorStore
      if let mirrorStore { store = mirrorStore } else {
          let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
          store = AppStoreReviewMirrorStore(context: ModelContext(container))
      }
      return AppStoreResponseController(
          reviewId: "rev-1", productID: UUID(), issueNumber: 1,
          repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store,
          commentPoster: GitHubCommentPoster(),
          tokenLoader: { "tok" }, readOnly: readOnly)
  }

  func testRemainingCharsAndOverLimit() throws {
      let c = try makeController()
      c.draft = String(repeating: "x", count: AppStoreResponseController.maxBodyLength + 5)
      XCTAssertEqual(c.remainingChars, -5)
      XCTAssertTrue(c.overLimit)
      XCTAssertFalse(c.canSubmit)
  }

  func testCannotSubmitEmptyDraft() throws {
      let c = try makeController()
      c.draft = "   "
      XCTAssertFalse(c.canSubmit)
  }

  func testCanSubmitValidDraft() throws {
      let c = try makeController()
      c.draft = "Thanks for the feedback!"
      XCTAssertTrue(c.canSubmit)
      XCTAssertEqual(c.mode, .noResponse)
  }

  func testReadOnlyKeyDisablesPanel() throws {
      let c = try makeController(readOnly: true)
      c.draft = "Thanks!"
      XCTAssertEqual(c.mode, .disabledReadOnly)
      XCTAssertFalse(c.canSubmit)
  }
  ```
  Add `import SwiftData` to the test file's imports.

- [ ] **Step 2: Run — expect FAIL (no `AppStoreResponseController`).**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testRemainingCharsAndOverLimit
  ```
  Expected: FAIL — undefined symbol.

- [ ] **Step 3: Implement the controller (state + validation only; network in Task 3).**
  Create `AppFeedback/ViewModels/AppStoreResponseController.swift`:
  ```swift
  import Foundation
  import Observation

  /// Drives the "Respond on App Store" panel for a single App Store feedback item. Owns the
  /// editor draft, validates against the (community-observed) length cap, and — in Task 3 —
  /// performs the upsert/delete via `AppStoreConnectClientProtocol`, persists the
  /// `responseId`/`responseState` through `AppStoreReviewMirrorStore`, and drops a GitHub
  /// comment for cross-device record. A read-only ASC key (or a live 403) disables editing.
  @Observable @MainActor
  final class AppStoreResponseController {
      /// Community-observed `responseBody` ceiling (Apple does not document it). We validate
      /// client-side and still handle 422/409 defensively (Task 3).
      static let maxBodyLength = 5970

      enum Mode: Equatable {
          case noResponse          // no developer response yet → "Submit"
          case hasResponse         // a response exists → "Edit" / "Delete"
          case disabledReadOnly    // read-only key or a 403 → panel shown but inert
      }

      enum SubmitError: Equatable {
          case tooLong(Int)        // associated value = chars over the limit
          case conflict            // 409
          case validation(String)  // 422
          case api(Int, String?)
          case network(String)
      }

      var draft: String = ""
      private(set) var isBusy = false
      private(set) var lastError: SubmitError?
      /// Set true once a live call returns 403 (read-only key discovered at write time).
      private(set) var discoveredReadOnly = false

      let reviewId: String
      let productID: UUID
      let issueNumber: Int
      let repoOwner: String
      let repoName: String

      private let client: any AppStoreConnectClientProtocol
      private let mirrorStore: AppStoreReviewMirrorStore
      private let commentPoster: GitHubCommentPoster
      private let tokenLoader: @Sendable () async -> String?
      private let initialReadOnly: Bool

      init(
          reviewId: String,
          productID: UUID,
          issueNumber: Int,
          repoOwner: String,
          repoName: String,
          client: any AppStoreConnectClientProtocol,
          mirrorStore: AppStoreReviewMirrorStore,
          commentPoster: GitHubCommentPoster,
          tokenLoader: @escaping @Sendable () async -> String?,
          readOnly: Bool
      ) {
          self.reviewId = reviewId
          self.productID = productID
          self.issueNumber = issueNumber
          self.repoOwner = repoOwner
          self.repoName = repoName
          self.client = client
          self.mirrorStore = mirrorStore
          self.commentPoster = commentPoster
          self.tokenLoader = tokenLoader
          self.initialReadOnly = readOnly
          // Seed the editor from any existing response state isn't possible from the mirror
          // (it stores id/state, not the body); the editor starts empty and the existing
          // response body, when present, is shown read-only beside the editor by the panel.
      }

      // MARK: Derived state

      private var existingResponseId: String? {
          mirrorStore.mirror(reviewId: reviewId)?.responseId
      }

      var responseState: String? {
          mirrorStore.mirror(reviewId: reviewId)?.responseState
      }

      var mode: Mode {
          if initialReadOnly || discoveredReadOnly { return .disabledReadOnly }
          return existingResponseId == nil ? .noResponse : .hasResponse
      }

      var trimmedDraft: String {
          draft.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      var remainingChars: Int { Self.maxBodyLength - draft.count }
      var overLimit: Bool { draft.count > Self.maxBodyLength }

      var canSubmit: Bool {
          guard mode != .disabledReadOnly, !isBusy else { return false }
          return !trimmedDraft.isEmpty && !overLimit
      }

      /// Delete is only meaningful when a response already exists and the key can write.
      var canDelete: Bool {
          mode == .hasResponse && !isBusy
      }
  }
  ```

- [ ] **Step 4: Run the four state tests — expect PASS.**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testRemainingCharsAndOverLimit -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testCannotSubmitEmptyDraft -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testCanSubmitValidDraft -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testReadOnlyKeyDisablesPanel
  ```
  Expected: 4 PASS.

- [ ] **Step 5: Commit.**
  ```
  git add AppFeedback/ViewModels/AppStoreResponseController.swift AppFeedbackTests/AppStoreResponseControllerTests.swift
  git commit -m "feat(app-store): response controller state + char-limit guard

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3: `AppStoreResponseController.submit()` / `delete()` — upsert, delete, mirror write-back, GitHub comment, error mapping

**Files:**
- Modify `AppFeedback/ViewModels/AppStoreResponseController.swift`
- Test `AppFeedbackTests/AppStoreResponseControllerTests.swift` (extend)

**Interfaces:**
- Consumes (Phase 3): `AppStoreConnectClientProtocol.createOrUpdateResponse(reviewId:body:) -> ASCResponse`, `deleteResponse(responseId:)`; `ASCResponse`.
- Consumes (Phase 3 Shared Contract): `protocol StatusCarryingError: Error { var statusCode: Int { get } }` and `enum AppStoreConnectError: StatusCarryingError` — `.forbidden`.statusCode == 403. **Phase 4 does NOT redefine `StatusCarryingError` (Phase 3 owns it); it imports and matches it.**
- Consumes (Phase 3): `AppStoreReviewMirrorStore.setResponse(reviewId:responseId:state:)`, `clearResponse(reviewId:)`.
- Consumes (existing): `GitHubCommentPoster.postComment(...)`, `GitHubCommentPoster.PostError.apiError(Int, message: String?)`.
- Produces:
  - `func submit() async`  *(upsert; client error 403 → `.disabledReadOnly`, 409 → `.conflict`, 422 → `.validation`)*
  - `func delete() async`

> Error mapping (belt-and-suspenders): the controller maps a 403 to read-only **two** ways — (1) any thrown `StatusCarryingError` whose `statusCode == 403` (this covers Phase 3's real `AppStoreConnectError.forbidden`, which conforms, AND any future status-carrying error), and (2) a **direct** `case AppStoreConnectError.forbidden` match. The direct match guarantees the read-only path fires even if the conformance is ever weakened. Any non-status error maps to `.network(...)` (safe default). The tests assert BOTH a stub `StatusCarryingError(statusCode: 403)` and the REAL `AppStoreConnectError.forbidden`.

- [ ] **Step 1: Write failing tests for submit/delete behaviour (driven by the fake client).**
  Append to `AppStoreResponseControllerTests.swift`:
  ```swift
  // A recording fake that can be told to throw a status-carrying error.
  private struct StubStatusError: StatusCarryingError { let statusCode: Int }

  private actor RecordingASCClient: AppStoreConnectClientProtocol {
      enum Call: Equatable { case upsert(reviewId: String, body: String); case delete(responseId: String) }
      private(set) var calls: [Call] = []
      var upsertResult: () throws -> ASCResponse = {
          ASCResponse(id: "resp-new", responseBody: "ok", state: "PENDING_PUBLISH", lastModifiedDate: Date())
      }
      var deleteError: Error?

      func setUpsert(_ block: @escaping @Sendable () throws -> ASCResponse) { upsertResult = block }
      func setDeleteError(_ e: Error?) { deleteError = e }
      func recordedCalls() -> [Call] { calls }

      func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
          ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)
      }
      func listApps() async throws -> [ASCApp] { [] }
      func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
          calls.append(.upsert(reviewId: reviewId, body: body))
          return try upsertResult()
      }
      func deleteResponse(responseId: String) async throws {
          calls.append(.delete(responseId: responseId))
          if let deleteError { throw deleteError }
      }
  }

  private func seededStore(reviewId: String, responseId: String?, state: String?,
                           productID: UUID, issueNumber: Int) throws -> AppStoreReviewMirrorStore {
      let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
      let context = ModelContext(container)
      context.insert(AppStoreReviewMirror(
          reviewId: reviewId, productID: productID, issueNumber: issueNumber,
          contentHash: "h", responseState: state, responseId: responseId))
      try context.save()
      return AppStoreReviewMirrorStore(context: context)
  }

  func testSubmitUpsertsAndStoresPendingState() async throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                  productID: pid, issueNumber: 1)
      let client = RecordingASCClient()
      let c = AppStoreResponseController(
          reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)   // nil token → comment post skipped, upsert still asserted
      c.draft = "Thanks for the review!"

      await c.submit()

      let calls = await client.recordedCalls()
      XCTAssertEqual(calls, [.upsert(reviewId: "rev-1", body: "Thanks for the review!")])
      XCTAssertEqual(store.mirror(reviewId: "rev-1")?.responseId, "resp-new")
      XCTAssertEqual(store.mirror(reviewId: "rev-1")?.responseState, "PENDING_PUBLISH")
      XCTAssertNil(c.lastError)
      XCTAssertEqual(c.mode, .hasResponse)
  }

  func testSubmit403DisablesPanel() async throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                  productID: pid, issueNumber: 1)
      let client = RecordingASCClient()
      await client.setUpsert { throw StubStatusError(statusCode: 403) }
      let c = AppStoreResponseController(
          reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      c.draft = "Thanks!"

      await c.submit()

      XCTAssertEqual(c.mode, .disabledReadOnly)
      XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseId)  // nothing persisted on 403
  }

  // Belt-and-suspenders: the REAL Phase-3 error must drive the same read-only disable,
  // both via its StatusCarryingError conformance and the direct `.forbidden` match.
  func testSubmitRealAppStoreConnectForbiddenDisablesPanel() async throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                  productID: pid, issueNumber: 1)
      let client = RecordingASCClient()
      await client.setUpsert { throw AppStoreConnectError.forbidden }
      let c = AppStoreResponseController(
          reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      c.draft = "Thanks!"

      await c.submit()

      XCTAssertEqual(c.mode, .disabledReadOnly)
      XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseId)  // nothing persisted on a real 403
  }

  func testSubmit422SurfacesValidationError() async throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                  productID: pid, issueNumber: 1)
      let client = RecordingASCClient()
      await client.setUpsert { throw StubStatusError(statusCode: 422) }
      let c = AppStoreResponseController(
          reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      c.draft = "Thanks!"

      await c.submit()

      if case .validation = c.lastError {} else { XCTFail("expected .validation, got \(String(describing: c.lastError))") }
  }

  func testSubmitOverLimitGuardsBeforeNetwork() async throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                  productID: pid, issueNumber: 1)
      let client = RecordingASCClient()
      let c = AppStoreResponseController(
          reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      c.draft = String(repeating: "x", count: AppStoreResponseController.maxBodyLength + 1)

      await c.submit()

      let calls = await client.recordedCalls()
      XCTAssertTrue(calls.isEmpty)  // never hits the network
      if case .tooLong(let over) = c.lastError { XCTAssertEqual(over, 1) }
      else { XCTFail("expected .tooLong") }
  }

  func testDeleteRemovesResponseAndClearsMirror() async throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-1", responseId: "resp-existing", state: "PUBLISHED",
                                  productID: pid, issueNumber: 1)
      let client = RecordingASCClient()
      let c = AppStoreResponseController(
          reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
          client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      XCTAssertEqual(c.mode, .hasResponse)

      await c.delete()

      let calls = await client.recordedCalls()
      XCTAssertEqual(calls, [.delete(responseId: "resp-existing")])
      XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseId)
      XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseState)
      XCTAssertEqual(c.mode, .noResponse)
  }
  ```

- [ ] **Step 2: Run — expect FAIL (no `submit`/`delete`).**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testSubmitUpsertsAndStoresPendingState
  ```
  Expected: compile failure / FAIL. *(`StatusCarryingError` and `AppStoreConnectError` already exist — they are Phase 3's; do not redefine them.)*

- [ ] **Step 3: Add `submit()`/`delete()` to the controller.**
  Append to `AppFeedback/ViewModels/AppStoreResponseController.swift` (consumes Phase 3's `StatusCarryingError`/`AppStoreConnectError` — does NOT redefine them):
  ```swift
  extension AppStoreResponseController {
      /// Submit (or edit — ASC has no PATCH, the POST is an upsert) the developer response.
      /// On success persists `responseId`/state to the mirror and drops a GitHub comment for
      /// cross-device record. Guards the char limit before any network call.
      func submit() async {
          guard mode != .disabledReadOnly else { return }
          lastError = nil
          let body = trimmedDraft
          guard !body.isEmpty else { return }
          if draft.count > Self.maxBodyLength {
              lastError = .tooLong(draft.count - Self.maxBodyLength)
              return
          }

          isBusy = true
          defer { isBusy = false }
          do {
              let response = try await client.createOrUpdateResponse(reviewId: reviewId, body: body)
              mirrorStore.setResponse(reviewId: reviewId, responseId: response.id, state: response.state)
              await postRecordComment(action: "Responded on App Store (pending)", body: body)
          } catch {
              applyWriteError(error)
          }
      }

      /// Delete the developer response and clear the mirror's response fields.
      func delete() async {
          guard mode == .hasResponse,
                let responseId = mirrorStore.mirror(reviewId: reviewId)?.responseId else { return }
          lastError = nil
          isBusy = true
          defer { isBusy = false }
          do {
              try await client.deleteResponse(responseId: responseId)
              mirrorStore.clearResponse(reviewId: reviewId)
              draft = ""
              await postRecordComment(action: "Deleted App Store response", body: nil)
          } catch {
              applyWriteError(error)
          }
      }

      /// Posts a record comment to the synthesized GitHub issue (best-effort; a missing token
      /// or a post failure never fails the write-back — the ASC change already landed).
      private func postRecordComment(action: String, body: String?) async {
          guard let token = await tokenLoader() else { return }
          let text: String = body.map { "\(action): \($0)" } ?? action
          _ = try? await commentPoster.postComment(
              owner: repoOwner, repo: repoName, issueNumber: issueNumber, body: text, token: token)
      }

      /// Maps an ASC write failure into the panel's error/disabled state. A 403 is matched
      /// two ways: a direct `AppStoreConnectError.forbidden` case (belt) AND any
      /// `StatusCarryingError` whose `statusCode == 403` (suspenders) — so the read-only
      /// disable fires for the real Phase-3 error and any other status-carrying error alike.
      private func applyWriteError(_ error: Error) {
          // Belt: the concrete Phase-3 forbidden case.
          if case AppStoreConnectError.forbidden = error {
              discoveredReadOnly = true                  // read-only key → disable the panel
              return
          }
          // Suspenders: any status-carrying error (incl. AppStoreConnectError via its conformance).
          if let coded = error as? StatusCarryingError {
              switch coded.statusCode {
              case 403: discoveredReadOnly = true        // read-only key → disable the panel
              case 409: lastError = .conflict
              case 422: lastError = .validation("App Store rejected the response text.")
              default:  lastError = .api(coded.statusCode, nil)
              }
              return
          }
          if let postError = error as? GitHubCommentPoster.PostError,
             case let .apiError(code, message) = postError {
              lastError = .api(code, message)
              return
          }
          lastError = .network((error as NSError).localizedDescription)
      }
  }
  ```

- [ ] **Step 4: Run all controller tests — expect PASS.**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests
  ```
  Expected: all `AppStoreResponseControllerTests` PASS (state, extractor, submit/delete, error mapping).

- [ ] **Step 5: Commit.**
  ```
  git add AppFeedback/ViewModels/AppStoreResponseController.swift AppFeedbackTests/AppStoreResponseControllerTests.swift
  git commit -m "feat(app-store): submit/edit/delete developer response with mirror + comment

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4: `AppStoreResponsePanel` view + per-issue controller cache + wiring

**Files:**
- Create `AppFeedback/Views/Issues/AppStoreResponsePanel.swift`
- Modify `AppFeedback/Views/Issues/IssueCardView.swift` (render the panel; accept a pre-built controller)
- Modify `AppFeedback/Views/Issues/IssueListView.swift` (own the per-`issue.number` controller cache; build/reuse + pass down)
- Modify `AppFeedback/App/RootView.swift` (inject Phase 3's mirror store + `responderContext` closure)

**Interfaces:**
- Consumes (Tasks 2/3): `AppStoreResponseController` (incl. `draft`, `canSubmit`, `canDelete`, `mode`, `remainingChars`, `overLimit`, `lastError`, `isBusy`, `submit()`, `delete()`, `Mode`, `SubmitError`).
- Consumes (Phase 3 Shared Contract): `AppStoreReviewMirrorStore`; `AppStoreReviewCoordinatorRegistry.responderContext(productID:) -> AppStoreResponderContext?`; `struct AppStoreResponderContext { let client: any AppStoreConnectClientProtocol; let isReadOnly: Bool; let owner: String; let repo: String }`. **Phase 4 consumes `AppStoreResponderContext`; it does NOT define it.**
- Consumes (Task 1): `AppStoreReviewIdExtractor.reviewId(fromBody:)`.
- Consumes (existing): `IssueCardView` stored props (`issue`, `repoOwner`, `repoName`, `appColor`); `FeedbackIssue.source` (Phase 1) and `FeedbackIssue.rawBody`/`number`; `KeychainService.load(for:)`; `GitHubCommentPoster()`.
- Produces (the panel + the wiring; no later phase depends on these names, but they must compile cleanly):
  - `struct AppStoreResponsePanel: View` with `init(controller: AppStoreResponseController, accent: Color)` + `enum AppStoreResponsePanelModel` label helper.
  - New `IssueCardView` member: `var responseController: AppStoreResponseController? = nil` (the card renders the panel iff this is non-nil and `issue.source == .appStore`).
  - New `IssueListView` members: `var mirrorStore: AppStoreReviewMirrorStore? = nil` and `var appStoreResponder: ((UUID) -> AppStoreResponderContext?)? = nil`, plus an `@State private var responseControllers: [Int: AppStoreResponseController]` cache keyed on `issue.number`.

> **Why the controller is cached (Fix I):** building `AppStoreResponseController` inside a SwiftUI `body` would throw away the user's in-progress draft on every re-render — and the card re-renders whenever `mirrorStore.version` bumps (a CloudKit import flipping PENDING→PUBLISHED on another device). So `IssueListView` keeps an `@State` dictionary `[issue.number: AppStoreResponseController]` and reuses the cached instance across renders; the controller is constructed at most once per issue.
>
> **Resolving the responder context (Phase 3):** `IssueListView` resolves the product + client + read-only flag via the injected `appStoreResponder` closure, which `RootView` backs with `AppStoreReviewCoordinatorRegistry.responderContext(productID:)`. When a product has no App Store source the closure returns nil and the panel simply isn't shown (graceful nil — not a "type defined nowhere" fallback). The owner/repo for the record comment come from `AppStoreResponderContext` (NOT from a reconstructed config).

> NOTE on the Phase-0 rename: this plan was written against the current `RepoConfig`/`RepoStore`/`store.repos` names. If Phase 0 has already renamed them to `ProductConfig`/`ProductStore`/`store.products`, substitute those names in the `RootView` edit below (the `KeychainService.load(for:)` keying is unchanged because `owner/repo` are preserved verbatim).

- [ ] **Step 1: Add a pure logic test for the panel's primary-button label (red→green helper).**
  This is the one extractable bit of view logic. Append to `AppStoreResponseControllerTests.swift`:
  ```swift
  func testPrimaryButtonTitleReflectsMode() throws {
      let cNew = try makeController()
      XCTAssertEqual(AppStoreResponsePanelModel.primaryTitle(for: cNew.mode), "Submit Response")

      let pid = UUID()
      let store = try seededStore(reviewId: "rev-x", responseId: "r", state: "PUBLISHED",
                                  productID: pid, issueNumber: 9)
      let cExisting = AppStoreResponseController(
          reviewId: "rev-x", productID: pid, issueNumber: 9, repoOwner: "o", repoName: "r",
          client: FakeASCClient(), mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      XCTAssertEqual(AppStoreResponsePanelModel.primaryTitle(for: cExisting.mode), "Update Response")

      let cReadOnly = try makeController(readOnly: true)
      XCTAssertEqual(AppStoreResponsePanelModel.primaryTitle(for: cReadOnly.mode), "Submit Response")
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`AppStoreResponsePanelModel` undefined).**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testPrimaryButtonTitleReflectsMode
  ```
  Expected: FAIL.

- [ ] **Step 3: Create the panel view + its pure label helper.**
  Create `AppFeedback/Views/Issues/AppStoreResponsePanel.swift`:
  ```swift
  import SwiftUI

  /// Pure, testable helpers for the App Store response panel (button titles, status text) —
  /// separated from the View so the label logic is unit-testable without UI rendering.
  enum AppStoreResponsePanelModel {
      static func primaryTitle(for mode: AppStoreResponseController.Mode) -> String {
          switch mode {
          case .noResponse, .disabledReadOnly: return "Submit Response"
          case .hasResponse:                    return "Update Response"
          }
      }

      static func errorText(_ error: AppStoreResponseController.SubmitError?) -> String? {
          switch error {
          case .none: return nil
          case .tooLong(let over): return "Response is \(over) character\(over == 1 ? "" : "s") over the limit."
          case .conflict: return "A response is already being processed. Try again in a moment."
          case .validation(let message): return message
          case .api(let code, let message?): return "App Store error \(code): \(message)"
          case .api(let code, nil): return "App Store error \(code)."
          case .network(let message): return "Couldn't reach App Store Connect: \(message)"
          }
      }

      static func stateLabel(_ state: String?) -> String? {
          switch state {
          case "PENDING_PUBLISH": return "Pending publish"
          case "PUBLISHED": return "Published"
          default: return nil
          }
      }
  }

  /// The "Respond on App Store" panel rendered inside a feedback card whose source is the
  /// App Store. A text editor with a live character counter, a Submit/Update button, and (when
  /// a response already exists) a Delete button. A read-only ASC key shows an explanatory note
  /// instead of the editor controls.
  struct AppStoreResponsePanel: View {
      @State var controller: AppStoreResponseController
      var accent: Color = .accentColor

      init(controller: AppStoreResponseController, accent: Color = .accentColor) {
          self._controller = State(initialValue: controller)
          self.accent = accent
      }

      var body: some View {
          VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 6) {
                  Image(systemName: "apple.logo").font(.system(size: 11, weight: .semibold))
                  Text("Respond on App Store").font(.system(size: 12, weight: .semibold))
                  if let state = AppStoreResponsePanelModel.stateLabel(controller.responseState) {
                      Text(state)
                          .font(.system(size: 10, weight: .semibold))
                          .padding(.horizontal, 6).padding(.vertical, 2)
                          .background(accent.opacity(0.15), in: Capsule())
                          .foregroundStyle(accent)
                  }
                  Spacer()
              }
              .foregroundStyle(.secondary)

              if controller.mode == .disabledReadOnly {
                  Text("This App Store Connect key is read-only. Use an Admin, App Manager, or Customer Support key to post developer responses.")
                      .font(.system(size: 11))
                      .foregroundStyle(.tertiary)
                      .fixedSize(horizontal: false, vertical: true)
              } else {
                  TextEditor(text: $controller.draft)
                      .font(.system(size: 12))
                      .frame(minHeight: 64, maxHeight: 140)
                      .padding(6)
                      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                      .overlay(RoundedRectangle(cornerRadius: 8)
                          .stroke(controller.overLimit ? Color.red.opacity(0.6) : accent.opacity(0.25), lineWidth: 1))

                  HStack {
                      Text("\(controller.remainingChars)")
                          .font(.system(size: 10, weight: .medium).monospacedDigit())
                          .foregroundStyle(controller.overLimit ? .red : .tertiary)
                      Spacer()
                      if controller.canDelete {
                          Button(role: .destructive) {
                              Task { await controller.delete() }
                          } label: { Text("Delete").font(.system(size: 11, weight: .semibold)) }
                          .buttonStyle(.bordered)
                          .disabled(controller.isBusy)
                      }
                      Button {
                          Task { await controller.submit() }
                      } label: {
                          if controller.isBusy {
                              ProgressView().controlSize(.small)
                          } else {
                              Text(AppStoreResponsePanelModel.primaryTitle(for: controller.mode))
                                  .font(.system(size: 11, weight: .semibold))
                          }
                      }
                      .buttonStyle(.borderedProminent)
                      .tint(accent)
                      .disabled(!controller.canSubmit)
                  }

                  if let error = AppStoreResponsePanelModel.errorText(controller.lastError) {
                      Text(error).font(.system(size: 11)).foregroundStyle(.red)
                          .fixedSize(horizontal: false, vertical: true)
                  }
              }
          }
          .padding(10)
          .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
          .padding(.top, 8)
      }
  }
  ```

- [ ] **Step 4: Run the label test — expect PASS.**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testPrimaryButtonTitleReflectsMode
  ```
  Expected: PASS.

- [ ] **Step 5: Add the pre-built-controller member to `IssueCardView` and render the panel.**
  `IssueCardView` does NOT build the controller (that would run in `body` and lose the draft on re-render — see Fix I). It accepts a controller built and cached by `IssueListView`. Add the stored member right after `var onRemoveTask: ((TaskItem) -> Void)? = nil` in `AppFeedback/Views/Issues/IssueCardView.swift`:
  ```swift
  /// The App Store response controller for this card, built and cached once per issue by
  /// `IssueListView` (nil for SDK/email items or when App Store source isn't configured).
  /// Passing it in — rather than constructing it in `body` — keeps the draft alive across
  /// re-renders (e.g. when `mirrorStore.version` bumps on a CloudKit import).
  var responseController: AppStoreResponseController? = nil
  ```
  Then render the panel immediately after the `if !threads.isEmpty { … }` block (around line 380, before the `#if canImport(SwiftMail)` inline-composer loop), inside the card's main `VStack`:
  ```swift
  if issue.source == .appStore, let responseController {
      AppStoreResponsePanel(controller: responseController, accent: appColor)
  }
  ```

- [ ] **Step 6: Own the per-issue controller cache in `IssueListView` and build/reuse controllers.**
  In `AppFeedback/Views/Issues/IssueListView.swift`, add stored members + init params:
  ```swift
  /// Phase 3's CloudKit-synced mirror store (read response state, persist write-back).
  var mirrorStore: AppStoreReviewMirrorStore? = nil
  /// Resolves the App Store responder context (client + read-only + owner/repo) for a product;
  /// nil ⇒ that product has no App Store source. Backed by Phase 3's registry.
  var appStoreResponder: ((UUID) -> AppStoreResponderContext?)? = nil
  ```
  Add both to the explicit `init(...)` signature and assign them (`self.mirrorStore = mirrorStore`, `self.appStoreResponder = appStoreResponder`), defaulting both to `nil` so existing call sites still compile.

  Add the cache (so a re-render reuses the SAME controller and the draft survives):
  ```swift
  /// One response controller per App Store feedback (keyed on issue number). Cached so the
  /// editor draft survives re-renders triggered by `mirrorStore.version` bumps. Built lazily.
  @State private var responseControllers: [Int: AppStoreResponseController] = [:]
  ```
  Add the lookup-or-build helper:
  ```swift
  /// Returns the cached controller for an App Store issue, building it once. Returns nil for
  /// SDK/email items, when the mirror/responder deps are absent, when the reviewId marker is
  /// missing, or when the product has no App Store source (graceful nil — the panel hides).
  private func responseController(for issue: FeedbackIssue) -> AppStoreResponseController? {
      guard issue.source == .appStore else { return nil }
      if let cached = responseControllers[issue.number] { return cached }
      guard let mirrorStore,
            let responder = appStoreResponder,
            let reviewId = AppStoreReviewIdExtractor.reviewId(fromBody: issue.rawBody),
            // productID lives on the synced mirror row for this review.
            let productID = mirrorStore.mirror(reviewId: reviewId)?.productID,
            let context = responder(productID) else { return nil }
      let controller = AppStoreResponseController(
          reviewId: reviewId,
          productID: productID,
          issueNumber: issue.number,
          repoOwner: context.owner,                 // owner/repo from Phase 3's responder context
          repoName: context.repo,
          client: context.client,
          mirrorStore: mirrorStore,
          commentPoster: GitHubCommentPoster(),
          tokenLoader: { [owner = context.owner, repo = context.repo] in
              await KeychainService.load(for: RepoConfig(displayName: repo, owner: owner, repo: repo))
          },
          readOnly: context.isReadOnly)
      responseControllers[issue.number] = controller
      return controller
  }
  ```
  *(The `tokenLoader` keys the Keychain on `owner/repo` exactly as `KeychainService.load(for:)` does — only `owner`/`repo` feed `accountKey(for:)`, `displayName` is ignored. If Phase 0 renamed `RepoConfig` → `ProductConfig`, use `ProductConfig` here.)*

  Pass the controller into the `IssueCardView(...)` call in `issueCard(for:)`, right after the existing `onRemoveTask:` argument:
  ```swift
          onRemoveTask: onRemoveTaskFromFeedback.map { remove in { task in remove(task.number, issue.number) } },
          responseController: responseController(for: issue)
      )
  ```

- [ ] **Step 7: Inject Phase 3's mirror store + responder closure in `RootView` and pass to `IssueListView`.**
  `RootView` already owns the SwiftData context (`cacheContext`) and constructs the other `@Observable` stores. Phase 3 owns and exposes the `AppStoreReviewMirrorStore` and the `AppStoreReviewCoordinatorRegistry`; this phase consumes them. Pass them into the `IssueListView(...)` in the `detail:` closure, immediately after `summaryCollapseKey: "\(owner)/\(name)"`:
  ```swift
                      summaryCollapseKey: "\(owner)/\(name)",
                      mirrorStore: appStoreReviewMirrorStore,
                      appStoreResponder: { productID in
                          // Phase 3 owns the per-product client + read-only flag + owner/repo via
                          // the AppStoreReviewCoordinatorRegistry; resolve through it. When the
                          // product has no App Store source, this returns nil and the panel hides.
                          appStoreCoordinatorRegistry?.responderContext(productID: productID)
                      }
  ```
  `appStoreReviewMirrorStore` and `appStoreCoordinatorRegistry` are the Phase-3-owned dependencies threaded into `RootView` (env or stored property — match however Phase 3 surfaces them; both are `@MainActor`). If, at integration time, Phase 3's `responderContext(productID:)` accessor is not yet present, pass `appStoreResponder: nil` — the panel simply won't render until Phase 3 is wired, keeping Phase 4 independently shippable. Add a `// TODO(phase3-wiring)` comment if so.

- [ ] **Step 9: Build both platforms — expect SUCCEEDED.**
  ```
  xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
  ```
  Then iOS via zcode (the IDE API runs the iOS destination): build the `AppFeedback_iOS` scheme through the zcode skill and confirm a clean build. Expected: both build SUCCEEDED. Ignore SourceKit per-file "Cannot find type" diagnostics — trust the xcodebuild result.

- [ ] **Step 10: Run the full controller test class once more — expect PASS (no regressions).**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests
  ```
  Expected: all PASS. *(Phase 3's `AppStoreReviewMirrorStoreTests` is a separate class owned by Phase 3 — don't add to it here.)*

- [ ] **Step 11: Commit (stage only the panel + the three modified view/wiring files `IssueCardView`/`IssueListView`/`RootView` + the test).**
  ```
  git add AppFeedback/Views/Issues/AppStoreResponsePanel.swift AppFeedback/Views/Issues/IssueCardView.swift AppFeedback/Views/Issues/IssueListView.swift AppFeedback/App/RootView.swift AppFeedbackTests/AppStoreResponseControllerTests.swift
  git commit -m "feat(app-store): Respond on App Store panel in the feedback card

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5: PENDING_PUBLISH → PUBLISHED reflected from poll refresh (controller observation)

**Files:**
- Test `AppFeedbackTests/AppStoreResponseControllerTests.swift` (extend) — this phase's OWN test class; it does NOT add to Phase 3's `AppStoreReviewMirrorStoreTests`.

**Interfaces:**
- Consumes (Phase 3): `AppStoreReviewMirrorStore.setResponse(reviewId:responseId:state:)` (this is also how Phase 3's poll writes the refreshed `responseState`/`responseId` from each review's `ASCResponse.state` during its `include=response` refresh). Phase 4 only verifies that the controller — which the panel reads — observes the change.

> The panel re-renders because `AppStoreResponsePanel` reads `controller.responseState`, which reads the mirror live, and the card observes `mirrorStore.version` (Phase 3's store bumps it on remote-change + cloudKitImportSucceeded). This task adds a regression test proving a state flip written through the store is visible through `controller.responseState`, documenting the (already-correct) observation path. No production change is required if Tasks 2 + 4 are correct.

- [ ] **Step 1: Add a regression test for the state transition surfacing through the controller.**
  Append to `AppStoreResponseControllerTests.swift` (reusing the `seededStore`/`FakeASCClient` helpers from earlier tasks):
  ```swift
  func testPollRefreshStateTransitionSurfacesThroughController() throws {
      let pid = UUID()
      let store = try seededStore(reviewId: "rev-3", responseId: "resp-7", state: "PENDING_PUBLISH",
                                  productID: pid, issueNumber: 11)
      let c = AppStoreResponseController(
          reviewId: "rev-3", productID: pid, issueNumber: 11, repoOwner: "o", repoName: "r",
          client: FakeASCClient(), mirrorStore: store, commentPoster: GitHubCommentPoster(),
          tokenLoader: { nil }, readOnly: false)
      XCTAssertEqual(c.responseState, "PENDING_PUBLISH")

      // Simulate a Phase-3 poll refresh writing the published state through the same store API.
      store.setResponse(reviewId: "rev-3", responseId: "resp-7", state: "PUBLISHED")

      XCTAssertEqual(c.responseState, "PUBLISHED")   // the panel reads this live
      XCTAssertEqual(c.mode, .hasResponse)
  }
  ```

- [ ] **Step 2: Run — expect PASS (no production change needed; verifies the observation path).**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/AppStoreResponseControllerTests/testPollRefreshStateTransitionSurfacesThroughController
  ```
  Expected: PASS.

- [ ] **Step 3: Commit.**
  ```
  git add AppFeedbackTests/AppStoreResponseControllerTests.swift
  git commit -m "test(app-store): PENDING_PUBLISH→PUBLISHED surfaces through the response controller

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6: Full-suite regression check

**Files:** none (verification only).

- [ ] **Step 1: Run the whole macOS test target.**
  ```
  xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS
  ```
  Expected: all tests pass EXCEPT the ~11 pre-existing Keychain failures (`KeychainServicePerAccountTests` + `GitHubAccountStoreTests`) which are NOT regressions (no Keychain in the test host). Confirm no NEW failures and no hard crash (read the xcodebuild tail, not a zcode summary).

- [ ] **Step 2: If any new failure appears, debug with superpowers:systematic-debugging before proceeding; otherwise the phase is complete.**
