# Phase 5 — Email Feedback Source (feedback-inbox role + MailToFeedbackMirror) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated email feedback source so each inbound email to a product's feedback inbox becomes a synthesized GitHub issue (replies fold in as comments), configured via a cross-platform `EmailSourceForm` and ingested by a role-aware `MailSyncCoordinator` that runs a new `MailToFeedbackMirror`.

**Architecture:** A feedback inbox is a `MailAccount` whose `feedbackProductID` is set (derived "role"), referenced by `Product.feedbackInboxAccountID`; it reuses the existing `MailAccount`/`IMAPClientProvider`/Keychain/`Preset` stack and the `MailThreadStore` dedup+thread-match path. `MailSyncCoordinator.pollOnce()` becomes role-aware — feedback inboxes ingest ALL inbound (no `outboundRecipients()` FROM filter), apply the default-on `InboundNoiseFilter` to the full `ParsedInboundMessage` BEFORE `recordInbound` (so bounces and auto-replies are dropped while their `Return-Path`/`Auto-Submitted`/`Precedence` headers are still present and never reach the store), and spawn a detached `MailToFeedbackMirror` Task parallel to `MailToGitHubMirror`. `MailToFeedbackMirror` turns the already-clean stored thread roots into new GitHub issues (markers `source`/`fromAddress`/`messageId`, label `source:email`, attachments via the existing mail-attachment path) and replies into comments; it does NOT re-filter (the coordinator is the single filtering point).

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
@MainActor @Observable final class ProductStore {   // renamed from RepoStore
    private(set) var repos: [ProductConfig]          // stored name kept (least churn)
    var products: [ProductConfig] { repos }          // alias — PREFER `products` in all new code
    func add(_ config: ProductConfig); func update(_ config: ProductConfig)   // carry the 4 new fields
    // Test seam: built via `init(context:hiddenAppStore:)` against an in-memory ModelContainer, then
    // seeded with `add(ProductConfig(...))` — see the `seededProductStore(...)` helper used in this phase's tests.
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
// Noise filtering runs in the COORDINATOR on the full ParsedInboundMessage BEFORE recordInbound (so Return-Path /
//   Auto-Submitted / Precedence headers are available); InboundNoiseFilter.isNoise(_ msg: ParsedInboundMessage) -> Bool
//   is unit-tested directly. The in-mirror path does NOT re-filter on a rebuilt message (those headers would be nil).
```

---

## Phase dependencies (what this plan Consumes from earlier phases)

> These names are **not re-implemented here**. They are produced by Phases 0–1 and consumed verbatim. If a name does not yet exist in the tree when this phase is executed, the executing agent must rebase on the merged Phase 0+1 work first.

- **Phase 0:** `Product` `@Model` with `var feedbackInboxAccountID: UUID?`; `ProductConfig` struct (renamed `RepoConfig`, fields `id/displayName/owner/repo/mirrorEmailsToGitHub/redactEmailAddresses/connectedRepoOwner/connectedRepoName/colorHex` + the four new ones); `ProductStore` `@Observable` (renamed `RepoStore`) exposing `var products: [ProductConfig]`, `func add(_:)`, `func update(_:)`; `MailAccount` gains stored `var feedbackProductID: UUID?` (default `nil`). *(Today the tree still has `Repo`/`RepoConfig`/`RepoStore`/`repos`; this plan is written against the post-Phase-0 names. Where a step touches `MailToGitHubMirror`/`AppFeedbackApp`, use whichever names the merged tree presents — the structure is identical.)*
- **Phase 1:** SDK `BodyMarker` vocabulary extended with the exact marker keys `"source"`, `"fromAddress"`, `"messageId"`; GitHub label string `"source:email"`; `IssueBodyParser` widened to populate `CachedIssue.source`/`rating`. The mirror in this phase only *writes* these markers/labels and relies on Phase 1's parser to read them back — no parser work here.

**Confirmed existing signatures (read from the live tree, used verbatim below):**
- `GitHubIssueWriter` (actor): `func createIssue(owner: String, repo: String, title: String, body: String, labels: [String], milestoneNumber: Int?, token: String) async throws -> Int`; nested `enum WriteError: LocalizedError { case apiError(Int, message: String?) }`.
- `GitHubCommentPoster` (actor): `func postComment(owner: String, repo: String, issueNumber: Int, body: String, token: String) async throws -> Int`.
- `MailThreadStore` (`@MainActor @Observable`): `func recordInbound(message: ParsedInboundMessage, accountID: UUID? = nil) -> MailMessage?` (Message-ID dedup + thread match; returns `nil` on duplicate); `MailMessage.thread: MailThread?`; `MailThread.issueNumber: Int` (0 = unlinked), `issueRepoOwner`, `issueRepoName`, `messageIDRoot`.
- `MailMessage` fields used: `messageID`, `fromAddress`, `fromName`, `subject`, `bodyPlain`, `bodyHTML`, `date`, `direction`/`directionRaw`, `githubCommentID`, `attachments: [MailAttachment]?`, `thread: MailThread?`.
- `ParsedInboundMessage` (struct, Sendable, Equatable): `uid, folder, uidValidity, messageID, inReplyTo: String?, references: [String], fromAddress, fromName: String?, toAddresses, ccAddresses, date, subject, bodyPlain, bodyHTML: String?, attachments: [ParsedAttachmentMeta]`. (No `headers` map — see Task 2 for how bounce/auto-reply markers are surfaced.)
- `HTMLSanitizer.plainText(from:) -> String` and `HTMLSanitizer.stripQuotedReply(_:) -> StrippedBody { cleaned, full }`.
- `MailToGitHubMirror.redact(_:) -> String` (static; `a***@host.tld`).
- `MailAccountStore` (`@MainActor @Observable`): `var accounts: [MailAccount]`, `func account(id:) -> MailAccount?`, `func add(_:) -> MailAccount`, `func update(id:_:)`, `func deleteWithCredentials(_:) async`.
- `MailSyncCoordinator` (actor) init params: `client, accountID, threadStore, accountStore, settingsStore, localState, activityLog, mirror: MailToGitHubMirror? = nil, notificationService:, knownIssueTitlesProvider:, clock:`. Internal `private func pollOnce()` already spawns `Task.detached { await mirror.mirrorPendingInbound() }` after a healthy inbox poll.
- `MailSyncCoordinator.pollOnce()` reads the FROM filter via `let fromAddresses = await MainActor.run { self.threadStore.outboundRecipients() }`.
- `ActivityLog.start(kind: ActivityLogEntry.Kind, title:) -> UUID`, `.finish(_:status:detail:)`; `Kind` cases include `.fetchMail`, `.postComment`. (No `.createIssue` case — Task 4 adds one.)
- `IMAPClientProtocol.testConnection() async throws`; `IMAPClientProvider(accountStore:accountID:)`.
- `KeychainService.saveIMAPPassword(_:for:) async -> Bool`, `.loadIMAPPassword(for:) async -> String?`, `.deleteIMAPPassword(for:) async`, `.saveSMTPPassword(_:for:)`, `.deleteSMTPPassword(for:)`.
- `KeychainService.load(for: ProductConfig) async -> String?` (Phase 0 renames the param type from `RepoConfig`; the Keychain key string `owner/repo` is unchanged) — the GitHub token loader used by `MailToFeedbackMirror`'s convenience init.
- `ProductStore` (`@Observable @MainActor`, Phase 0): `init(context: ModelContext, hiddenAppStore: HiddenAppStore? = nil)`, `private(set) var repos: [ProductConfig]`, alias `var products: [ProductConfig] { repos }`, `func add(_ config: ProductConfig)`, `func update(_ config: ProductConfig)`. Phase 0 ships NO bespoke test factory — tests construct it against an in-memory container and seed via `add(_:)`. This phase's test files define one shared helper (verbatim below) and reuse it everywhere a seeded store is needed:
  ```swift
  /// Shared test seed: an in-memory ProductStore with exactly one product
  /// (owner "acme", repo "app", redactEmailAddresses == true) whose feedback inbox is `inboxID`.
  /// Returns the store; read the inbox id back via `store.products[0].feedbackInboxAccountID!`.
  @MainActor
  func seededProductStore(_ ctx: ModelContext, inboxID: UUID = UUID()) -> ProductStore {
      let store = ProductStore(context: ctx)
      store.add(ProductConfig(
          displayName: "Acme",
          owner: "acme",
          repo: "app",
          mirrorEmailsToGitHub: true,
          redactEmailAddresses: true,
          feedbackInboxAccountID: inboxID
      ))
      return store
  }
  ```
  > The store's container must include `Product.self`. The `makeContainer()` used by these tests therefore lists `Product.self` alongside the Mail models (see each test's `makeContainer()`).

---

## File Structure

### Create
- `AppFeedback/Services/Mail/MailToFeedbackMirror.swift` — `@MainActor @Observable final class MailToFeedbackMirror`: turns the already-noise-filtered, stored feedback-inbox threads into GitHub issues (root→create) / comments (reply→known thread); injected issue writer + comment poster + token loader. Does NOT itself filter noise (the coordinator does that pre-store — see Task 6). Plus `MailToFeedbackMirrorHolder` (mirrors `MailToGitHubMirrorHolder`).
- `AppFeedback/Services/Mail/InboundNoiseFilter.swift` — pure `enum InboundNoiseFilter` with `static func isNoise(_ message: ParsedInboundMessage) -> Bool` and the per-header predicates (bounce / auto-reply), driven off fields surfaced on `ParsedInboundMessage`.
- `AppFeedback/Views/Settings/EmailSourceForm.swift` — `#if os(macOS)` cross-reused-on-iOS SwiftUI form that creates/edits the feedback-inbox `MailAccount` (`feedbackProductID == product.id`) and writes `Product.feedbackInboxAccountID`; "Test Connection"; Off / Configured / Remove. Includes an extracted, testable `EmailSourceFormModel` (pure logic) used by both platforms.
- `AppFeedback/Views/Settings/IOSEmailSourceForm.swift` — `#if os(iOS)` `Form`-in-`NavigationStack` variant sharing `EmailSourceFormModel`.
- `AppFeedbackTests/InboundNoiseFilterTests.swift` — unit tests for bounce / auto-reply / clean classification.
- `AppFeedbackTests/MailToFeedbackMirrorTests.swift` — fixture tests: root→create, reply→comment, bounce/auto-reply→skip, redaction applied; sync store-level assertions only.
- `AppFeedbackTests/EmailSourceFormModelTests.swift` — pure-logic tests for the form model (create vs edit resolution, IMAP host/port defaults, validation).

### Modify
- `AppFeedback/Services/Mail/ParsedInboundMessage.swift` — add `returnPath: String?`, `autoSubmitted: String?`, `precedence: String?` (defaulted in the memberwise init) so the noise filter has its inputs without changing every call site.
- `AppFeedback/Services/Mail/IMAPClient.swift` (`#if canImport(SwiftMail)`) — populate the three new `ParsedInboundMessage` header fields when parsing an inbox message.
- `AppFeedback/Services/Mail/MailSyncCoordinator.swift` — make `pollOnce()` role-aware: read the account's `feedbackProductID`; when set, skip the `outboundRecipients()` FROM filter (pass `[]`-bypass → fetch all inbound) and spawn `Task.detached { await feedbackMirror.mirrorPendingFeedbackInbound(accountID:) }` parallel to the existing `MailToGitHubMirror` Task. Add an injected `feedbackMirror: MailToFeedbackMirror?` init param.
- `AppFeedback/Services/Mail/IMAPClientProtocol.swift` — add an `ingestAll` parameter to `listInbox` (or a sibling) so a feedback inbox fetches all inbound regardless of FROM. (Chosen approach: add `func listAllInbox(sinceUID:expectedUIDValidity:) async throws -> InboxPollResult` — see Task 5.)
- `AppFeedback/Services/Mail/IMAPClientProvider.swift` — forward the new `listAllInbox`.
- `AppFeedback/Services/ActivityLog.swift` — add `case createIssue` to `ActivityLogEntry.Kind`.
- `AppFeedback/App/AppFeedbackApp.swift` — build a `MailToFeedbackMirror`, stash it in a holder, and pass it into the `MailSyncCoordinator` factory; cascade-remove the feedback-inbox account + Keychain when a product's email source is removed (wired from `EmailSourceForm`).

---

## Tasks

### Task 1: Add bounce/auto-reply header fields to `ParsedInboundMessage`

**Files:**
- Modify: `AppFeedback/Services/Mail/ParsedInboundMessage.swift`
- Test: covered indirectly by Task 2's `InboundNoiseFilterTests` (this task is a pure struct change; verified by build).

**Interfaces:**
- Consumes: existing `struct ParsedInboundMessage: Sendable, Equatable` (15 stored fields).
- Produces: `ParsedInboundMessage.returnPath: String?`, `.autoSubmitted: String?`, `.precedence: String?` — consumed by Task 2 (`InboundNoiseFilter`).

- [ ] **Step 1: Add three optional header fields + a defaulted memberwise init.** Edit `ParsedInboundMessage.swift`. The struct currently has no explicit `init` (memberwise synthesized). Add an explicit `init` defaulting the three new fields to `nil` so existing call sites (tests, `IMAPClient`) keep compiling unchanged:
  ```swift
  struct ParsedInboundMessage: Sendable, Equatable {
      let uid: UInt32
      let folder: String
      let uidValidity: UInt32
      let messageID: String
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
      let attachments: [ParsedAttachmentMeta]
      /// Raw `Return-Path:` header value (angle brackets stripped). Empty ("<>") on bounces.
      let returnPath: String?
      /// Raw `Auto-Submitted:` header value, lowercased. e.g. "auto-replied".
      let autoSubmitted: String?
      /// Raw `Precedence:` header value, lowercased. e.g. "bulk" / "list".
      let precedence: String?

      init(
          uid: UInt32, folder: String, uidValidity: UInt32, messageID: String,
          inReplyTo: String?, references: [String],
          fromAddress: String, fromName: String?,
          toAddresses: [String], ccAddresses: [String],
          date: Date, subject: String, bodyPlain: String, bodyHTML: String?,
          attachments: [ParsedAttachmentMeta],
          returnPath: String? = nil, autoSubmitted: String? = nil, precedence: String? = nil
      ) {
          self.uid = uid; self.folder = folder; self.uidValidity = uidValidity
          self.messageID = messageID; self.inReplyTo = inReplyTo; self.references = references
          self.fromAddress = fromAddress; self.fromName = fromName
          self.toAddresses = toAddresses; self.ccAddresses = ccAddresses
          self.date = date; self.subject = subject
          self.bodyPlain = bodyPlain; self.bodyHTML = bodyHTML
          self.attachments = attachments
          self.returnPath = returnPath; self.autoSubmitted = autoSubmitted; self.precedence = precedence
      }
  }
  ```
- [ ] **Step 2: Build to confirm no call sites broke.** Run:
  `xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -20`
  Expected: **BUILD SUCCEEDED** (the defaulted init keeps every existing `ParsedInboundMessage(...)` call valid).
- [ ] **Step 3: Commit.**
  `git add AppFeedback/Services/Mail/ParsedInboundMessage.swift`
  `git commit -m "feat(mail): carry Return-Path/Auto-Submitted/Precedence on ParsedInboundMessage" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 2: `InboundNoiseFilter` (skip bounces + auto-replies)

**Files:**
- Create: `AppFeedback/Services/Mail/InboundNoiseFilter.swift`
- Test: `AppFeedbackTests/InboundNoiseFilterTests.swift`

**Interfaces:**
- Consumes: `ParsedInboundMessage.fromAddress`, `.returnPath`, `.autoSubmitted`, `.precedence` (Task 1).
- Produces: `InboundNoiseFilter.isNoise(_ message: ParsedInboundMessage) -> Bool` — consumed by Task 6 (`MailSyncCoordinator.pollOnce()`, applied pre-store on the full `ParsedInboundMessage`). NOT consumed by the mirror.

- [ ] **Step 1: Write the failing test file.** Create `AppFeedbackTests/InboundNoiseFilterTests.swift`:
  ```swift
  import XCTest
  @testable import AppFeedback

  final class InboundNoiseFilterTests: XCTestCase {
      private func msg(
          from: String = "alice@example.com",
          returnPath: String? = "alice@example.com",
          autoSubmitted: String? = nil,
          precedence: String? = nil
      ) -> ParsedInboundMessage {
          ParsedInboundMessage(
              uid: 1, folder: "INBOX", uidValidity: 1, messageID: "<m1@x>",
              inReplyTo: nil, references: [],
              fromAddress: from, fromName: nil,
              toAddresses: ["inbox@dev.com"], ccAddresses: [],
              date: Date(), subject: "Hi", bodyPlain: "feedback", bodyHTML: nil,
              attachments: [],
              returnPath: returnPath, autoSubmitted: autoSubmitted, precedence: precedence
          )
      }

      func test_cleanMessage_isNotNoise() {
          XCTAssertFalse(InboundNoiseFilter.isNoise(msg()))
      }

      func test_mailerDaemonSender_isNoise() {
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(from: "MAILER-DAEMON@mail.google.com")))
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(from: "postmaster@example.com")))
      }

      func test_emptyReturnPath_isNoise() {
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(returnPath: "")))
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(returnPath: "<>")))
      }

      func test_autoSubmittedAuto_isNoise_butNotNo() {
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(autoSubmitted: "auto-replied")))
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(autoSubmitted: "auto-generated")))
          // "no" is the explicit human-sent value and must NOT be filtered.
          XCTAssertFalse(InboundNoiseFilter.isNoise(msg(autoSubmitted: "no")))
      }

      func test_precedenceBulkOrList_isNoise() {
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(precedence: "bulk")))
          XCTAssertTrue(InboundNoiseFilter.isNoise(msg(precedence: "list")))
          XCTAssertFalse(InboundNoiseFilter.isNoise(msg(precedence: "normal")))
      }
  }
  ```
- [ ] **Step 2: Run the test (expect FAIL — `InboundNoiseFilter` doesn't exist).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/InboundNoiseFilterTests 2>&1 | tail -25`
  Expected: compile failure (`Cannot find 'InboundNoiseFilter' in scope`).
- [ ] **Step 3: Create the filter.** Create `AppFeedback/Services/Mail/InboundNoiseFilter.swift`:
  ```swift
  import Foundation

  /// Default-on filter that drops non-feedback inbound mail from a feedback inbox:
  /// delivery-failure bounces and machine-generated auto-replies. Pure & Sendable so it
  /// is trivially testable and callable from any actor.
  enum InboundNoiseFilter {

      /// True ⇒ the message is noise and must NOT become a feedback issue/comment.
      static func isNoise(_ message: ParsedInboundMessage) -> Bool {
          isBounce(message) || isAutoReply(message)
      }

      // MARK: - Bounces

      private static let daemonLocalParts: Set<String> = [
          "mailer-daemon", "postmaster"
      ]

      private static func isBounce(_ message: ParsedInboundMessage) -> Bool {
          // Empty Return-Path ("" or "<>") is the canonical bounce envelope.
          if let rp = message.returnPath {
              let trimmed = rp.trimmingCharacters(in: .whitespaces)
              if trimmed.isEmpty || trimmed == "<>" { return true }
          }
          // mailer-daemon / postmaster sender local-parts.
          let local = message.fromAddress
              .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
              .first
              .map { $0.lowercased() } ?? message.fromAddress.lowercased()
          return daemonLocalParts.contains(local)
      }

      // MARK: - Auto-replies

      private static func isAutoReply(_ message: ParsedInboundMessage) -> Bool {
          // RFC 3834: Auto-Submitted: auto-* (auto-replied / auto-generated / auto-notified).
          // The only non-auto value is "no", which is an explicit human-sent marker.
          if let auto = message.autoSubmitted?.trimmingCharacters(in: .whitespaces).lowercased(),
             auto.hasPrefix("auto-") {
              return true
          }
          // Legacy Precedence: bulk | list marks mailing-list / bulk traffic.
          if let prec = message.precedence?.trimmingCharacters(in: .whitespaces).lowercased(),
             prec == "bulk" || prec == "list" {
              return true
          }
          return false
      }
  }
  ```
- [ ] **Step 4: Run the test (expect PASS).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/InboundNoiseFilterTests 2>&1 | tail -25`
  Expected: all 5 tests pass.
- [ ] **Step 5: Commit.**
  `git add AppFeedback/Services/Mail/InboundNoiseFilter.swift AppFeedbackTests/InboundNoiseFilterTests.swift`
  `git commit -m "feat(mail): InboundNoiseFilter skips bounces and auto-replies" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 3: `MailToFeedbackMirror` body + label builders (pure, testable)

**Files:**
- Create: `AppFeedback/Services/Mail/MailToFeedbackMirror.swift` (first pass: pure static builders only)
- Test: `AppFeedbackTests/MailToFeedbackMirrorTests.swift` (first methods)

**Interfaces:**
- Consumes: `BodyMarker` marker keys `"source"`, `"fromAddress"`, `"messageId"` and the label `"source:email"` (Phase 1); `HTMLSanitizer.plainText(from:)`; `MailToGitHubMirror.redact(_:)`.
- Produces: `MailToFeedbackMirror.issueTitle(subject:) -> String`, `MailToFeedbackMirror.issueBody(message:redactEmail:) -> String`, `MailToFeedbackMirror.sourceEmailLabel` (`= "source:email"`), `MailToFeedbackMirror.preferredBodyText(message:) -> String` — consumed by Task 4 (the live mirror) and Task 7 (tests).

> **Marker shape (matches `IssueBodyFormatter`'s `extraFields` convention so Phase 1's parser reads it back):** each marker is rendered as `\n\n**<Key>:**\n<Value>`. The keys used are exactly `source`, `fromAddress`, `messageId` (the strings Phase 1 added to `BodyMarker`). We write them with that literal casing.

- [ ] **Step 1: Write the failing test (pure builders).** Create `AppFeedbackTests/MailToFeedbackMirrorTests.swift`:
  ```swift
  import XCTest
  @testable import AppFeedback

  @MainActor
  final class MailToFeedbackMirrorTests: XCTestCase {

      private func parsed(
          messageID: String = "<root@x>",
          from: String = "alice@example.com",
          subject: String = "App crashes on launch",
          bodyPlain: String = "It crashes every time I open the camera.",
          bodyHTML: String? = nil
      ) -> ParsedInboundMessage {
          ParsedInboundMessage(
              uid: 10, folder: "INBOX", uidValidity: 1, messageID: messageID,
              inReplyTo: nil, references: [],
              fromAddress: from, fromName: "Alice",
              toAddresses: ["feedback@dev.com"], ccAddresses: [],
              date: Date(timeIntervalSince1970: 1_714_477_200),
              subject: subject, bodyPlain: bodyPlain, bodyHTML: bodyHTML,
              attachments: []
          )
      }

      func test_issueTitle_usesSubject() {
          XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: "Bug here"), "Bug here")
      }

      func test_issueTitle_emptySubject_fallsBackToNoSubject() {
          XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: ""), "(no subject)")
          XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: "   "), "(no subject)")
      }

      func test_sourceEmailLabel_isExact() {
          XCTAssertEqual(MailToFeedbackMirror.sourceEmailLabel, "source:email")
      }

      func test_issueBody_carriesMarkersAndBody_redacted() {
          let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: true)
          XCTAssertTrue(body.contains("It crashes every time I open the camera."))
          XCTAssertTrue(body.contains("**source:**\nemail"))
          XCTAssertTrue(body.contains("**fromAddress:**\na***@example.com"))
          XCTAssertTrue(body.contains("**messageId:**\n<root@x>"))
          XCTAssertFalse(body.contains("alice@example.com"))
      }

      func test_issueBody_keepsAddressWhenNotRedacted() {
          let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: false)
          XCTAssertTrue(body.contains("**fromAddress:**\nalice@example.com"))
      }

      func test_preferredBodyText_prefersPlainThenStrippedHTML() {
          // plain present → plain wins
          XCTAssertEqual(
              MailToFeedbackMirror.preferredBodyText(message: parsed(bodyPlain: "PLAIN", bodyHTML: "<p>HTML</p>")),
              "PLAIN"
          )
          // plain empty → HTML stripped to plain text
          let stripped = MailToFeedbackMirror.preferredBodyText(
              message: parsed(bodyPlain: "  ", bodyHTML: "<p>Hello <b>there</b></p>")
          )
          XCTAssertTrue(stripped.contains("Hello"))
          XCTAssertTrue(stripped.contains("there"))
          XCTAssertFalse(stripped.contains("<p>"))
      }
  }
  ```
- [ ] **Step 2: Run the test (expect FAIL — type missing).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailToFeedbackMirrorTests 2>&1 | tail -25`
  Expected: `Cannot find 'MailToFeedbackMirror' in scope`.
- [ ] **Step 3: Create the file with pure builders only (no live deps yet).** Create `AppFeedback/Services/Mail/MailToFeedbackMirror.swift`:
  ```swift
  import Foundation
  import SwiftData
  import Observation

  /// Turns inbound mail arriving at a feedback-inbox account (a `MailAccount` whose
  /// `feedbackProductID != nil`) into synthesized GitHub issues and comments:
  ///   • thread ROOT  → create a new issue (label `source:email`, markers source/fromAddress/messageId)
  ///   • reply in a known thread → comment on that issue
  /// Runs as a detached Task from `MailSyncCoordinator.pollOnce()`, parallel to `MailToGitHubMirror`.
  /// Never throws to the caller; surfaces via `ActivityLog`. Dedup is free: `recordInbound` dedups by
  /// Message-ID, and a synthesized issue is recorded on the CloudKit-synced `MailThread.issueNumber`,
  /// so a re-poll (even cross-device) won't re-create.
  @MainActor
  @Observable
  final class MailToFeedbackMirror {

      // Live dependencies are wired in Task 4. The first pass is pure builders so the
      // marker/label/body contract is locked under test before the I/O lands.

      // MARK: - Contract constants

      /// The Phase-1 GitHub label string for email-sourced feedback.
      static let sourceEmailLabel = "source:email"

      // MARK: - Pure builders

      static func issueTitle(subject: String) -> String {
          let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? "(no subject)" : trimmed
      }

      /// Prefer `text/plain`; fall back to HTML stripped to plain text.
      static func preferredBodyText(message: ParsedInboundMessage) -> String {
          let plain = message.bodyPlain.trimmingCharacters(in: .whitespacesAndNewlines)
          if !plain.isEmpty { return message.bodyPlain }
          if let html = message.bodyHTML, !html.isEmpty {
              return HTMLSanitizer.plainText(from: html)
          }
          return ""
      }

      /// Builds the issue body: free text first, then the Phase-1 markers rendered in the
      /// `**Key:**\nValue` shape `IssueBodyFormatter` uses for extra fields (so the Phase-1
      /// parser reads them back). `fromAddress` is redacted per the product's preference.
      static func issueBody(message: ParsedInboundMessage, redactEmail: Bool) -> String {
          var body = preferredBodyText(message: message)
          let from = redactEmail ? MailToGitHubMirror.redact(message.fromAddress) : message.fromAddress
          body += "\n\n**source:**\nemail"
          body += "\n\n**fromAddress:**\n\(from)"
          body += "\n\n**messageId:**\n\(message.messageID)"
          return body
      }
  }

  @Observable
  final class MailToFeedbackMirrorHolder {
      let mirror: MailToFeedbackMirror?
      init(_ mirror: MailToFeedbackMirror?) { self.mirror = mirror }
  }
  ```
- [ ] **Step 4: Run the test (expect PASS).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailToFeedbackMirrorTests 2>&1 | tail -25`
  Expected: all 6 tests pass.
- [ ] **Step 5: Commit.**
  `git add AppFeedback/Services/Mail/MailToFeedbackMirror.swift AppFeedbackTests/MailToFeedbackMirrorTests.swift`
  `git commit -m "feat(mail): MailToFeedbackMirror body/label/title builders" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 4: `MailToFeedbackMirror` live ingestion (root→create, reply→comment, noise→skip)

**Files:**
- Modify: `AppFeedback/Services/ActivityLog.swift` (add `case createIssue`)
- Modify: `AppFeedback/Services/Mail/MailToFeedbackMirror.swift` (add live deps + `mirrorPendingFeedbackInbound`)
- Test: `AppFeedbackTests/MailToFeedbackMirrorTests.swift` (add ingestion tests + a fake issue writer)

**Interfaces:**
- Consumes: `MailThreadStore.recordInbound(message:accountID:) -> MailMessage?`; `MailMessage.thread`, `MailThread.issueNumber/issueRepoOwner/issueRepoName/messageIDRoot`; `GitHubIssueWriter.createIssue(...)`; `GitHubCommentPoster.postComment(...)`; `ProductConfig` (`owner/repo/redactEmailAddresses`) + `ProductStore.products` + the product's `feedbackInboxAccountID`; `MailMessage.githubCommentID`. (NOTE: `InboundNoiseFilter` is NOT consumed here — the coordinator is the single filtering point; see Task 6.)
- Produces: `MailToFeedbackMirror(context:productStore:activityLog:issueWriter:commentPoster:tokenLoader:)`; `func mirrorPendingFeedbackInbound(accountID: UUID) async` — consumed by Task 6 (coordinator wiring) and Task 5 (app wiring).

> **Identity of "the product for this inbox":** the feedback inbox is `accountID`; the owning product is the `ProductConfig` whose `feedbackInboxAccountID == accountID` (resolved by `product(forInbox:)` over `ProductStore.products`). Issues are synthesized into THAT product's `owner/repo`. The matcher is exercised by the root/reply ingestion tests below (the seeded store's single product owns `inboxID`).
>
> **Root vs reply:** after `recordInbound`, a brand-new thread has `issueNumber == 0` and `messageIDRoot == message.messageID` (root). A reply matched into an existing thread carries that thread's existing `issueNumber` (> 0 if already synthesized; 0 if the root hasn't been synthesized yet — orphan, retried next poll). So: `thread.issueNumber == 0 && thread.messageIDRoot == message.messageID` ⇒ create; `thread.issueNumber > 0` ⇒ comment; `thread.issueNumber == 0 && root ≠ this` ⇒ skip this pass (root not yet synthesized).

- [ ] **Step 1: Add the `createIssue` ActivityLog kind.** Edit `AppFeedback/Services/ActivityLog.swift`, in `enum Kind`:
  ```swift
  enum Kind: String, Codable, Sendable, CaseIterable {
      case fetchIssues
      case sendEmail
      case testConnection
      case fetchMail
      case downloadAttachment
      case postComment
      case createIssue
  }
  ```
- [ ] **Step 2: Add the fake issue writer + reply fixture to the test file.** Append to `MailToFeedbackMirrorTests.swift` (above the closing brace): a fake conforming to the same shape the mirror calls. Because `GitHubIssueWriter`/`GitHubCommentPoster` are concrete actors, the mirror takes **closures** for the two write ops (see Step 3) so tests inject fakes without a protocol:
  ```swift
  // Append inside the MailToFeedbackMirrorTests class.

  private func makeContainer() throws -> ModelContainer {
      let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      return try ModelContainer(
          for: Product.self,
              MailThread.self, MailMessage.self, MailAttachment.self,
              MailAttachmentLocal.self, MailAccountLocalState.self, MailAccount.self,
              MailSettings.self,
          configurations: config
      )
  }

  /// Shared test seed: an in-memory ProductStore with exactly one product
  /// (owner "acme", repo "app", redactEmailAddresses == true) whose feedback inbox is `inboxID`.
  private func seededProductStore(_ ctx: ModelContext, inboxID: UUID = UUID()) -> ProductStore {
      let store = ProductStore(context: ctx)
      store.add(ProductConfig(
          displayName: "Acme",
          owner: "acme",
          repo: "app",
          mirrorEmailsToGitHub: true,
          redactEmailAddresses: true,
          feedbackInboxAccountID: inboxID
      ))
      return store
  }

  /// Records create/comment calls so tests assert at the (sync) store level.
  private final class WriteRecorder: @unchecked Sendable {
      var createdTitles: [String] = []
      var createdBodies: [String] = []
      var createdLabels: [[String]] = []
      var comments: [(number: Int, body: String)] = []
      var nextIssueNumber = 42
  }

  func test_root_createsIssue_withEmailLabelAndMarkers() async throws {
      let container = try makeContainer()
      let ctx = ModelContext(container)
      let threadStore = MailThreadStore(context: ctx)
      let store = seededProductStore(ctx)
      let inboxID = store.products[0].feedbackInboxAccountID!
      let log = ActivityLog(persistenceURL: nil)
      let rec = WriteRecorder()

      let mirror = MailToFeedbackMirror(
          context: ctx,
          productStore: store,
          activityLog: log,
          createIssue: { owner, repo, title, body, labels, token in
              rec.createdTitles.append(title)
              rec.createdBodies.append(body)
              rec.createdLabels.append(labels)
              let n = rec.nextIssueNumber; rec.nextIssueNumber += 1
              return n
          },
          postComment: { owner, repo, number, body, token in
              rec.comments.append((number, body)); return 1
          },
          tokenLoader: { _ in "tok" }
      )

      // Ingest a root message.
      _ = threadStore.recordInbound(message: parsed(messageID: "<root@x>"), accountID: inboxID)
      await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)

      XCTAssertEqual(rec.createdTitles, ["App crashes on launch"])
      XCTAssertEqual(rec.createdLabels.first, ["source:email"])
      XCTAssertTrue(rec.createdBodies.first?.contains("**source:**\nemail") == true)
      XCTAssertTrue(rec.comments.isEmpty)

      // Sync store-level assertion: the thread now carries the synthesized issue number.
      let threads = (try ctx.fetch(FetchDescriptor<MailThread>()))
      let root = try XCTUnwrap(threads.first { $0.messageIDRoot == "<root@x>" })
      XCTAssertEqual(root.issueNumber, 42)
      XCTAssertEqual(root.issueRepoOwner, "acme")
      XCTAssertEqual(root.issueRepoName, "app")
  }

  func test_replyInKnownThread_postsComment_noNewIssue() async throws {
      let container = try makeContainer()
      let ctx = ModelContext(container)
      let threadStore = MailThreadStore(context: ctx)
      let store = seededProductStore(ctx)
      let inboxID = store.products[0].feedbackInboxAccountID!
      let rec = WriteRecorder()
      let mirror = MailToFeedbackMirror(
          context: ctx, productStore: store, activityLog: ActivityLog(persistenceURL: nil),
          createIssue: { _,_,t,b,l,_ in rec.createdTitles.append(t); rec.createdLabels.append(l); let n = rec.nextIssueNumber; rec.nextIssueNumber += 1; return n },
          postComment: { _,_,number,body,_ in rec.comments.append((number, body)); return 7 },
          tokenLoader: { _ in "tok" }
      )

      // Root → create.
      _ = threadStore.recordInbound(message: parsed(messageID: "<root@x>"), accountID: inboxID)
      await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)
      XCTAssertEqual(rec.createdTitles.count, 1)

      // Reply (inReplyTo root) → comment, no new issue.
      let reply = ParsedInboundMessage(
          uid: 11, folder: "INBOX", uidValidity: 1, messageID: "<reply@x>",
          inReplyTo: "<root@x>", references: ["<root@x>"],
          fromAddress: "alice@example.com", fromName: "Alice",
          toAddresses: ["feedback@dev.com"], ccAddresses: [],
          date: Date(timeIntervalSince1970: 1_714_480_000),
          subject: "Re: App crashes on launch", bodyPlain: "Still crashing on 2.1.", bodyHTML: nil,
          attachments: []
      )
      _ = threadStore.recordInbound(message: reply, accountID: inboxID)
      await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)

      XCTAssertEqual(rec.createdTitles.count, 1, "no second issue")
      XCTAssertEqual(rec.comments.count, 1)
      XCTAssertEqual(rec.comments.first?.number, 42)
      XCTAssertTrue(rec.comments.first?.body.contains("Still crashing on 2.1.") == true)
  }

  func test_onlyStoredThreads_areSynthesized_mirrorDoesNotReFilter() async throws {
      // The mirror runs AFTER the coordinator's pre-store noise filter (Task 6), so by the time it
      // sees a thread the noise is already gone — it never re-filters on a rebuilt message (whose
      // Return-Path/Auto-Submitted/Precedence are nil and so are uncatchable). This test pins that:
      // the mirror synthesizes exactly the threads present in the store and nothing more.
      let container = try makeContainer()
      let ctx = ModelContext(container)
      let threadStore = MailThreadStore(context: ctx)
      let store = seededProductStore(ctx)
      let inboxID = store.products[0].feedbackInboxAccountID!
      let rec = WriteRecorder()
      let mirror = MailToFeedbackMirror(
          context: ctx, productStore: store, activityLog: ActivityLog(persistenceURL: nil),
          createIssue: { _,_,t,_,l,_ in rec.createdTitles.append(t); rec.createdLabels.append(l); return 99 },
          postComment: { _,_,n,b,_ in rec.comments.append((n,b)); return 1 },
          tokenLoader: { _ in "tok" }
      )

      // Empty store → nothing to synthesize.
      await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)
      XCTAssertTrue(rec.createdTitles.isEmpty)

      // One clean root recorded (the coordinator would have filtered noise upstream) → one issue.
      _ = threadStore.recordInbound(message: parsed(messageID: "<clean@x>"), accountID: inboxID)
      await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)
      XCTAssertEqual(rec.createdTitles.count, 1)
      XCTAssertEqual(rec.createdLabels.first, ["source:email"])
  }
  ```
  > NOTE: bounce / auto-reply SKIPPING is asserted at the filtering point — `InboundNoiseFilterTests` (Task 2, the filter itself) and `MailSyncCoordinatorRoleTests.test_feedbackInbox_usesListAllInbox_andFiltersNoiseBeforeStore` (Task 6, the coordinator applying it BEFORE `recordInbound`). The mirror is deliberately NOT a filtering point, because it rebuilds a `ParsedInboundMessage` from the stored `MailMessage`, which does not persist `returnPath`/`autoSubmitted`/`precedence` — a vacation auto-reply could never be caught there. The `seededProductStore(_:)` helper (defined above in this file) supplies the one-product store (`owner == "acme"`, `repo == "app"`, `redactEmailAddresses == true`, `feedbackInboxAccountID == inboxID`).
- [ ] **Step 3: Run the ingestion tests (expect FAIL — init/method missing).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailToFeedbackMirrorTests 2>&1 | tail -30`
  Expected: compile failure on the new `MailToFeedbackMirror(...)` init.
- [ ] **Step 4: Add live deps + `mirrorPendingFeedbackInbound` to the mirror.** Edit `MailToFeedbackMirror.swift`: add stored deps + designated init using **closures** for the two GitHub writes (so production passes `GitHubIssueWriter`/`GitHubCommentPoster` and tests pass fakes), plus a convenience init that wires the real actors. Then implement the ingestion loop:
  ```swift
  // Add to the class (above the pure builders).

  typealias CreateIssue = @Sendable (_ owner: String, _ repo: String, _ title: String, _ body: String, _ labels: [String], _ token: String) async throws -> Int
  typealias PostComment = @Sendable (_ owner: String, _ repo: String, _ number: Int, _ body: String, _ token: String) async throws -> Int

  private let context: ModelContext
  private let productStore: ProductStore
  private let activityLog: ActivityLog
  private let createIssueOp: CreateIssue
  private let postCommentOp: PostComment
  private let tokenLoader: @Sendable (ProductConfig) async -> String?

  init(
      context: ModelContext,
      productStore: ProductStore,
      activityLog: ActivityLog,
      createIssue: @escaping CreateIssue,
      postComment: @escaping PostComment,
      tokenLoader: @Sendable @escaping (ProductConfig) async -> String?
  ) {
      self.context = context
      self.productStore = productStore
      self.activityLog = activityLog
      self.createIssueOp = createIssue
      self.postCommentOp = postComment
      self.tokenLoader = tokenLoader
  }

  /// Production convenience init: wires the real GitHub actors + Keychain.
  convenience init(
      context: ModelContext,
      productStore: ProductStore,
      activityLog: ActivityLog,
      issueWriter: GitHubIssueWriter = GitHubIssueWriter(),
      commentPoster: GitHubCommentPoster = GitHubCommentPoster(),
      tokenLoader: @Sendable @escaping (ProductConfig) async -> String? = { await KeychainService.load(for: $0) }
  ) {
      self.init(
          context: context,
          productStore: productStore,
          activityLog: activityLog,
          createIssue: { owner, repo, title, body, labels, token in
              try await issueWriter.createIssue(owner: owner, repo: repo, title: title, body: body, labels: labels, milestoneNumber: nil, token: token)
          },
          postComment: { owner, repo, number, body, token in
              try await commentPoster.postComment(owner: owner, repo: repo, issueNumber: number, body: body, token: token)
          },
          tokenLoader: tokenLoader
      )
  }

  // MARK: - Ingestion

  /// The product whose feedback inbox is `accountID`, or nil if none.
  func product(forInbox accountID: UUID) -> ProductConfig? {
      productStore.products.first(where: { $0.feedbackInboxAccountID == accountID })
  }

  /// Processes every not-yet-synthesized inbound message for this feedback inbox:
  /// thread root → create issue; reply in a synthesized thread → comment. Noise is skipped.
  /// Idempotent: a synthesized root sets `MailThread.issueNumber`, and a mirrored message sets
  /// `githubCommentID`, so re-entry on the next poll is safe.
  func mirrorPendingFeedbackInbound(accountID: UUID) async {
      guard let product = product(forInbox: accountID) else { return }
      guard let token = await tokenLoader(product), !token.isEmpty else { return }

      let inboundRaw = MailMessage.Direction.inbound.rawValue
      // Pending = inbound rows for this account not yet mirrored. Root creation is detected by
      // issueNumber==0 + messageIDRoot match; comments by githubCommentID==nil on a synthesized thread.
      let descriptor = FetchDescriptor<MailMessage>(
          predicate: #Predicate { $0.directionRaw == inboundRaw && $0.accountID == accountID },
          sortBy: [SortDescriptor(\.date, order: .forward)]
      )
      let pending = (try? context.fetch(descriptor)) ?? []

      for message in pending {
          guard let thread = message.thread else { continue }

          // ROOT (new thread, not yet synthesized): create an issue.
          if thread.issueNumber == 0 && thread.messageIDRoot == message.messageID {
              await createIssue(forRoot: message, thread: thread, product: product, token: token)
              continue
          }

          // REPLY into a synthesized thread: comment (once).
          if thread.issueNumber > 0, message.githubCommentID == nil {
              // The thread root itself is mirrored as the issue body, not as a comment.
              if thread.messageIDRoot == message.messageID { continue }
              await postComment(forReply: message, thread: thread, product: product, token: token)
              continue
          }
          // else: reply whose root isn't synthesized yet → wait for next poll.
      }
  }

  private func createIssue(forRoot message: MailMessage, thread: MailThread, product: ProductConfig, token: String) async {
      // Reconstruct a ParsedInboundMessage view ONLY to drive the body/title builders from the
      // stored row. Noise filtering is NOT done here: the coordinator already filtered bounces /
      // auto-replies on the full ParsedInboundMessage BEFORE recordInbound (Task 6), and a rebuilt
      // view has nil Return-Path/Auto-Submitted/Precedence, so re-filtering here is both redundant
      // and unable to catch a vacation auto-reply. Anything in the store is feedback by construction.
      let parsed = Self.parsedView(of: message)
      let title = Self.issueTitle(subject: message.subject)
      let body = Self.issueBody(message: parsed, redactEmail: product.redactEmailAddresses)
      let logID = activityLog.start(kind: .createIssue, title: "\(product.owner)/\(product.repo) ← email")
      do {
          let number = try await createIssueOp(product.owner, product.repo, title, body, [Self.sourceEmailLabel], token)
          thread.issueRepoOwner = product.owner
          thread.issueRepoName = product.repo
          thread.issueNumber = number
          message.githubCommentID = -1   // sentinel: root is the issue body, never a comment
          try? context.save()
          activityLog.finish(logID, status: .success, detail: "issue #\(number)")
      } catch {
          activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
      }
  }

  private func postComment(forReply message: MailMessage, thread: MailThread, product: ProductConfig, token: String) async {
      // No re-filtering here either (see createIssue(forRoot:) — the coordinator is the single
      // filtering point; the stored row's noise headers are nil).
      let commentBody = MailToGitHubMirror.buildCommentBody(message: message, redactEmail: product.redactEmailAddresses)
      let logID = activityLog.start(kind: .postComment, title: "\(product.owner)/\(product.repo)#\(thread.issueNumber)")
      do {
          let id = try await postCommentOp(product.owner, product.repo, thread.issueNumber, commentBody, token)
          message.githubCommentID = id
          try? context.save()
          activityLog.finish(logID, status: .success, detail: "comment #\(id)")
      } catch {
          activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
      }
  }

  /// Rebuilds the subset of ParsedInboundMessage the body/title builders read, from a stored
  /// MailMessage. The bounce/auto-reply header fields (returnPath/autoSubmitted/precedence) are
  /// NOT persisted on MailMessage, so they read as nil here — which is exactly why this rebuilt
  /// view is never the noise-filtering point. The coordinator filters the full ParsedInboundMessage
  /// BEFORE recordInbound (Task 6); this rebuild only powers issueBody / issueTitle.
  private static func parsedView(of message: MailMessage) -> ParsedInboundMessage {
      ParsedInboundMessage(
          uid: UInt32(max(0, message.uid)), folder: message.folder, uidValidity: UInt32(max(0, message.uidValidity)),
          messageID: message.messageID, inReplyTo: message.inReplyTo, references: [],
          fromAddress: message.fromAddress, fromName: message.fromName,
          toAddresses: message.toAddresses, ccAddresses: message.ccAddresses,
          date: message.date, subject: message.subject,
          bodyPlain: message.bodyPlain, bodyHTML: message.bodyHTML, attachments: []
      )
  }
  ```
  > NOTE: noise filtering happens in EXACTLY ONE place — the coordinator, on the full `ParsedInboundMessage` BEFORE `recordInbound` (Task 6) — because only there are `Return-Path`/`Auto-Submitted`/`Precedence` present. The mirror does NOT re-filter: by the time it runs, only feedback threads exist in the store, and a rebuilt view's noise headers are nil (so a vacation auto-reply could never be caught here anyway). `InboundNoiseFilter` is imported by the mirror file only transitively via the coordinator; the mirror itself does not call it. The `githubCommentID = -1` sentinel marks the root row as "is the issue body" so it is never re-posted as a comment.
- [ ] **Step 5: Run the ingestion tests (expect PASS).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailToFeedbackMirrorTests 2>&1 | tail -30`
  Expected: all tests (builders + 3 ingestion) pass.
- [ ] **Step 6: Commit.**
  `git add AppFeedback/Services/ActivityLog.swift AppFeedback/Services/Mail/MailToFeedbackMirror.swift AppFeedbackTests/MailToFeedbackMirrorTests.swift`
  `git commit -m "feat(mail): MailToFeedbackMirror ingests inbound email → issues/comments" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 5: `listAllInbox` on the IMAP seam (feedback inboxes ingest ALL inbound)

**Files:**
- Modify: `AppFeedback/Services/Mail/IMAPClientProtocol.swift`
- Modify: `AppFeedback/Services/Mail/IMAPClientProvider.swift`
- Modify: `AppFeedback/Services/Mail/IMAPClient.swift` (`#if canImport(SwiftMail)` — real impl + populate the three header fields from Task 1)
- Test: `AppFeedbackTests/MailSyncCoordinatorTests.swift` (extend `MockIMAPClient` to conform; no behavioral test here — covered by Task 6)

**Interfaces:**
- Consumes: existing `InboxPollResult`; `ParsedInboundMessage` header fields (Task 1).
- Produces: `IMAPClientProtocol.listAllInbox(sinceUID: UInt32, expectedUIDValidity: UInt32) async throws -> InboxPollResult` — consumed by Task 6.

- [ ] **Step 1: Add the protocol requirement.** Edit `IMAPClientProtocol.swift`, add after `listInbox`:
  ```swift
      /// Like `listInbox` but WITHOUT the FROM filter — returns every INBOX message with UID
      /// strictly greater than `sinceUID`. Used by feedback inboxes, where any sender may be a
      /// reporter (not only people we previously wrote to). Same UIDVALIDITY semantics as `listInbox`.
      func listAllInbox(sinceUID: UInt32, expectedUIDValidity: UInt32) async throws -> InboxPollResult
  ```
- [ ] **Step 2: Forward it in `IMAPClientProvider`.** Edit `IMAPClientProvider.swift`, add after `listInbox`:
  ```swift
      func listAllInbox(sinceUID: UInt32, expectedUIDValidity: UInt32) async throws -> InboxPollResult {
          let client = try await makeClient()
          return try await client.listAllInbox(sinceUID: sinceUID, expectedUIDValidity: expectedUIDValidity)
      }
  ```
- [ ] **Step 3: Implement `listAllInbox` in `IMAPClient` + populate the three header fields.** Edit `IMAPClient.swift`. The live `listInbox` (read it — lines 64-152) does NOT use a generic header map: it derives `messageID`/`inReplyTo`/`references`/`from`/`to`/`cc`/`date`/`subject` from SwiftMail's typed `MessageInfo` struct inside the `static func parse(info:folder:uidValidity:bodyPlain:bodyHTML:attachments:)` helper (lines 505-540), and pulls the body via the per-message `fetchStructure`/`fetchPart` path in `fetchAndParse` (lines 367-420). `MessageInfo` exposes NO `Return-Path`/`Auto-Submitted`/`Precedence` accessor — those are full-header fields, so they are only reachable from the complete `Message` value returned by `server.fetchMessage(from:)` (see the pre-flight notes at lines 27-29: `let msg: Message = try await server.fetchMessage(from: MessageInfo)`). Therefore `listAllInbox` must:
  1. Run the SAME UID-range discovery as `listInbox` but WITHOUT the FROM SEARCH — instead of one `server.search(criteria:[.from(addr)])` per recipient, fetch the unseen UID range directly. Concretely, after `selectMailbox`/effectiveSinceUID handling (copy that block verbatim), enumerate unseen UIDs via `server.fetchMessageInfos(uidRange: UID(effectiveSinceUID + 1)...UID.latest)` (the pre-flight-verified UID-range fetch, lines 23-25) and keep those with `uid > effectiveSinceUID`.
  2. For each resulting `MessageInfo`, reuse the existing `fetchAndParse(server:info:folder:uidValidity:)` to get the body/attachments `ParsedInboundMessage`, THEN enrich it with the three header fields read from the full `Message`:
     ```swift
     let base = try await fetchAndParse(server: server, info: info, folder: folder, uidValidity: uidValidity)
     let full = try? await server.fetchMessage(from: info)          // full headers (Return-Path etc.)
     let enriched = Self.withNoiseHeaders(base, from: full)
     results.append(enriched)
     ```
  3. Add a static helper that reads the three headers off the full `Message` using SwiftMail's header accessor and returns a copy of the `ParsedInboundMessage` with them populated (Return-Path: strip surrounding `<>`/whitespace; the other two: lowercase). Because `ParsedInboundMessage` is a value type with the defaulted init from Task 1, this is a plain re-construction:
     ```swift
     private static func withNoiseHeaders(_ base: ParsedInboundMessage, from message: SwiftMail.Message?) -> ParsedInboundMessage {
         guard let message else { return base }      // headers unavailable ⇒ leave nil (treated as not-noise)
         func header(_ name: String) -> String? { message.header(named: name) }   // ← confirm exact accessor (Step 3a)
         let rp = header("Return-Path").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
         var copy = base
         copy = ParsedInboundMessage(
             uid: base.uid, folder: base.folder, uidValidity: base.uidValidity, messageID: base.messageID,
             inReplyTo: base.inReplyTo, references: base.references,
             fromAddress: base.fromAddress, fromName: base.fromName,
             toAddresses: base.toAddresses, ccAddresses: base.ccAddresses,
             date: base.date, subject: base.subject, bodyPlain: base.bodyPlain, bodyHTML: base.bodyHTML,
             attachments: base.attachments,
             returnPath: rp,
             autoSubmitted: header("Auto-Submitted")?.lowercased(),
             precedence: header("Precedence")?.lowercased()
         )
         return copy
     }
     ```
  - [ ] **Step 3a: Confirm the SwiftMail full-header accessor before writing `withNoiseHeaders`.** `Message.header(named:)` above is the EXPECTED shape; the executing agent MUST grep the SwiftMail source for the real accessor on `Message` (e.g. `rg -n "func header|var headers|allHeaders|headerValue|struct Message" <SwiftMail-checkout>/Sources/SwiftMail/IMAP`) and use that exact API. If SwiftMail exposes headers as a `[String: String]`/`[Header]` collection instead of a `header(named:)` method, read from that collection case-insensitively. Do NOT invent an accessor — this is the only signature not confirmable from the app tree. If the full `Message` genuinely exposes no header access, fall back to leaving the three fields nil (bounces are still caught by the `mailer-daemon`/`postmaster` sender local-part check in `InboundNoiseFilter`, which needs only `fromAddress`), and note the limitation in the commit message.
  > The non-`#if canImport(SwiftMail)` stub of `IMAPClient` (if one exists for the test target) needs a matching `listAllInbox` returning an empty `InboxPollResult` so both build configs compile.
- [ ] **Step 4: Conform BOTH mock clients in the test target.** `AppFeedbackTests/MailSyncCoordinatorTests.swift` defines TWO `IMAPClientProtocol` conformers — `final class MockIMAPClient` (line ~7) and `actor SlowMockIMAPClient` (line ~494). Adding a protocol requirement breaks compilation until BOTH implement it.
  - Add to `MockIMAPClient`:
    ```swift
        var allInboxResponses: [Result<[ParsedInboundMessage], Error>] = []
        var allInboxCallCount = 0

        func listAllInbox(sinceUID: UInt32, expectedUIDValidity: UInt32) async throws -> InboxPollResult {
            allInboxCallCount += 1
            guard !allInboxResponses.isEmpty else { return InboxPollResult(messages: [], uidValidity: 0) }
            switch allInboxResponses.removeFirst() {
            case .success(let msgs): return InboxPollResult(messages: msgs, uidValidity: 0)
            case .failure(let err): throw err
            }
        }
    ```
  - Add to `actor SlowMockIMAPClient` (it gates `listInbox` at a continuation; the feedback path is irrelevant to its tests, so a trivial impl is enough):
    ```swift
        func listAllInbox(sinceUID: UInt32, expectedUIDValidity: UInt32) async throws -> InboxPollResult {
            InboxPollResult(messages: [], uidValidity: 0)
        }
    ```
- [ ] **Step 5: Build (macOS + iOS-compile) to confirm conformance.** Run:
  `xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -15`
  then `xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
  Expected: both **BUILD SUCCEEDED** (every `IMAPClientProtocol` conformer now implements `listAllInbox`).
- [ ] **Step 6: Commit.**
  `git add AppFeedback/Services/Mail/IMAPClientProtocol.swift AppFeedback/Services/Mail/IMAPClientProvider.swift AppFeedback/Services/Mail/IMAPClient.swift AppFeedbackTests/MailSyncCoordinatorTests.swift`
  `git commit -m "feat(mail): IMAP listAllInbox seam for feedback inboxes (no FROM filter)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 6: Make `MailSyncCoordinator.pollOnce()` role-aware

**Files:**
- Modify: `AppFeedback/Services/Mail/MailSyncCoordinator.swift`
- Test: `AppFeedbackTests/MailSyncCoordinatorRoleTests.swift` (new) — drives a feedback-inbox account through one poll with `MockIMAPClient`, asserts `listAllInbox` was used (not `listInbox`), noise was filtered pre-store, and a stored thread was created.

**Interfaces:**
- Consumes: `IMAPClientProtocol.listAllInbox(...)` (Task 5); `MailAccount.feedbackProductID`; `MailToFeedbackMirror.mirrorPendingFeedbackInbound(accountID:)` (Task 4); `InboundNoiseFilter.isNoise(_:)` (Task 2); `MailThreadStore.recordInbound(...)`.
- Produces: `MailSyncCoordinator(... feedbackMirror: MailToFeedbackMirror? = nil ...)` — consumed by Task 8 (app wiring).

> **Role detection:** add `feedbackProductID` to the `AccountSnapshot` value type the coordinator already snapshots from MainActor. When `feedbackProductID != nil`, the account is a feedback inbox.

- [ ] **Step 1: Write the failing role test.** Create `AppFeedbackTests/MailSyncCoordinatorRoleTests.swift`:
  ```swift
  import XCTest
  import SwiftData
  @testable import AppFeedback

  @MainActor
  final class MailSyncCoordinatorRoleTests: XCTestCase {

      private func makeContainer() throws -> ModelContainer {
          let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
          return try ModelContainer(
              for: MailThread.self, MailMessage.self, MailAttachment.self,
                  MailAttachmentLocal.self, MailAccountLocalState.self, MailAccount.self,
                  MailSettings.self,
              configurations: config
          )
      }

      func test_feedbackInbox_usesListAllInbox_andFiltersNoiseBeforeStore() async throws {
          let container = try makeContainer()
          let ctx = ModelContext(container)
          let threadStore = MailThreadStore(context: ctx)
          let accountStore = MailAccountStore(context: ctx)
          let settingsStore = MailSettingsStore(context: ctx)
          let localState = MailAccountLocalStateStore(context: ctx)
          let log = ActivityLog(persistenceURL: nil)

          let productID = UUID()
          let account = accountStore.add { acc in
              acc.imapHost = "imap.example.com"; acc.imapUsername = "feedback@dev.com"
              acc.smtpUsername = "feedback@dev.com"
              acc.backfillCompleted = true            // skip backfill path
              acc.feedbackProductID = productID       // ⇒ feedback-inbox role
          }

          let mock = MockIMAPClient()
          let clean = ParsedInboundMessage(
              uid: 5, folder: "INBOX", uidValidity: 1, messageID: "<c@x>",
              inReplyTo: nil, references: [], fromAddress: "user@somewhere.com", fromName: "U",
              toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
              subject: "Love it", bodyPlain: "great app", bodyHTML: nil, attachments: [])
          let bounce = ParsedInboundMessage(
              uid: 6, folder: "INBOX", uidValidity: 1, messageID: "<b@x>",
              inReplyTo: nil, references: [], fromAddress: "mailer-daemon@x.com", fromName: nil,
              toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
              subject: "failure", bodyPlain: "", bodyHTML: nil, attachments: [], returnPath: "<>")
          // The vacation auto-reply is the case the mirror could NEVER catch (its rebuilt view has
          // autoSubmitted == nil), so the coordinator MUST filter it pre-store on the full message.
          let vacation = ParsedInboundMessage(
              uid: 7, folder: "INBOX", uidValidity: 1, messageID: "<ooo@x>",
              inReplyTo: nil, references: [], fromAddress: "ceo@example.com", fromName: "CEO",
              toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
              subject: "Out of office", bodyPlain: "Away until Monday", bodyHTML: nil,
              attachments: [], autoSubmitted: "auto-replied")
          mock.allInboxResponses = [.success([clean, bounce, vacation])]

          let coord = MailSyncCoordinator(
              client: mock, accountID: account.id,
              threadStore: threadStore, accountStore: accountStore,
              settingsStore: settingsStore, localState: localState, activityLog: log,
              mirror: nil, feedbackMirror: nil, notificationService: nil,
              knownIssueTitlesProvider: { [] }
          )
          await coord.pollNow()

          XCTAssertEqual(mock.allInboxCallCount, 1, "feedback inbox must use listAllInbox")
          XCTAssertEqual(mock.inboxCallCount, 0, "must NOT use the FROM-filtered listInbox")

          // Sync store-level assertion: only the clean message became a thread; the bounce AND the
          // vacation auto-reply were filtered pre-store by the coordinator (never recorded).
          let threads = try ctx.fetch(FetchDescriptor<MailThread>())
          XCTAssertEqual(threads.count, 1)
          XCTAssertEqual(threads.first?.messageIDRoot, "<c@x>")
      }

      func test_replyMirrorAccount_stillUsesListInbox() async throws {
          let container = try makeContainer()
          let ctx = ModelContext(container)
          let accountStore = MailAccountStore(context: ctx)
          let account = accountStore.add { acc in
              acc.imapHost = "imap.example.com"; acc.imapUsername = "me@dev.com"
              acc.smtpUsername = "me@dev.com"; acc.backfillCompleted = true
              // feedbackProductID stays nil ⇒ legacy reply-mirror role
          }
          let mock = MockIMAPClient()
          mock.inboxResponses = [.success([])]
          let coord = MailSyncCoordinator(
              client: mock, accountID: account.id,
              threadStore: MailThreadStore(context: ctx), accountStore: accountStore,
              settingsStore: MailSettingsStore(context: ctx),
              localState: MailAccountLocalStateStore(context: ctx),
              activityLog: ActivityLog(persistenceURL: nil),
              mirror: nil, feedbackMirror: nil, notificationService: nil,
              knownIssueTitlesProvider: { [] }
          )
          await coord.pollNow()
          XCTAssertEqual(mock.inboxCallCount, 1)
          XCTAssertEqual(mock.allInboxCallCount, 0)
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL — `feedbackMirror:` param and role logic missing).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailSyncCoordinatorRoleTests 2>&1 | tail -30`
  Expected: compile failure on the unknown `feedbackMirror:` argument.
- [ ] **Step 3: Add the `feedbackMirror` dependency + `feedbackProductID` to the snapshot.** Edit `MailSyncCoordinator.swift`:
  - In `AccountSnapshot`, add `let feedbackProductID: UUID?`.
  - Add a stored `private let feedbackMirror: MailToFeedbackMirror?` and the init param `feedbackMirror: MailToFeedbackMirror? = nil` (place it right after `mirror:`); assign in the body.
  - In `pollOnce()`, where `AccountSnapshot` is built, add `feedbackProductID: acc.feedbackProductID`.
- [ ] **Step 4: Branch the fetch + recordInbound on role.** In `pollOnce()`, replace the FROM-filtered fetch + record block. The current code reads `let fromAddresses = await MainActor.run { self.threadStore.outboundRecipients() }` then `client.listInbox(...)`. Make it:
  ```swift
  let isFeedbackInbox = accountSnapshot.feedbackProductID != nil
  do {
      let pollResult: InboxPollResult
      if isFeedbackInbox {
          // Feedback inboxes ingest ALL inbound — any sender may be a reporter.
          pollResult = try await client.listAllInbox(
              sinceUID: localSnapshot.inboxLastUID,
              expectedUIDValidity: localSnapshot.inboxUIDValidity
          )
      } else {
          let fromAddresses = await MainActor.run { self.threadStore.outboundRecipients() }
          pollResult = try await client.listInbox(
              sinceUID: localSnapshot.inboxLastUID,
              expectedUIDValidity: localSnapshot.inboxUIDValidity,
              fromAddresses: fromAddresses
          )
      }
      let messages = pollResult.messages
      // … unchanged: observedUIDValidity / validityChanged …

      let accountID = self.accountID
      let inserted: [NotificationService.InboundReply] = await MainActor.run {
          var newOnes: [NotificationService.InboundReply] = []
          for msg in messages {
              // Default-on noise filter for feedback inboxes: bounces/auto-replies never stored.
              if isFeedbackInbox && InboundNoiseFilter.isNoise(msg) { continue }
              guard let stored = self.threadStore.recordInbound(message: msg, accountID: accountID) else { continue }
              // … unchanged issue-ref building + append …
          }
          return newOnes
      }
      // … unchanged notification + watermark-update + finish …
  ```
  Keep every other line of the existing `do` block (watermark update, activity finish, notification dispatch) exactly as-is.
- [ ] **Step 5: Spawn the feedback mirror parallel to the GitHub mirror.** Still in `pollOnce()`, find the existing detached GitHub-mirror Task:
  ```swift
  if let mirror {
      Task.detached { await mirror.mirrorPendingInbound() }
  }
  ```
  Add immediately after it:
  ```swift
  // Parallel to MailToGitHubMirror: synthesize feedback issues/comments for feedback inboxes.
  if isFeedbackInbox, let feedbackMirror {
      let accID = accountSnapshot.id
      Task.detached { await feedbackMirror.mirrorPendingFeedbackInbound(accountID: accID) }
  }
  ```
- [ ] **Step 6: Run the role tests (expect PASS).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailSyncCoordinatorRoleTests 2>&1 | tail -30`
  Expected: both tests pass (`allInboxCallCount == 1` for the feedback inbox; bounce filtered → 1 thread; legacy account still uses `listInbox`).
- [ ] **Step 7: Run the existing coordinator suite to confirm no regression.**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailSyncCoordinatorTests 2>&1 | tail -20`
  Expected: unchanged pass count (the legacy path is untouched).
- [ ] **Step 8: Commit.**
  `git add AppFeedback/Services/Mail/MailSyncCoordinator.swift AppFeedbackTests/MailSyncCoordinatorRoleTests.swift`
  `git commit -m "feat(mail): role-aware MailSyncCoordinator runs MailToFeedbackMirror for feedback inboxes" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 7: `EmailSourceFormModel` (pure form logic) + tests

**Files:**
- Create: `AppFeedback/Views/Settings/EmailSourceForm.swift` (model + macOS view; the model first)
- Test: `AppFeedbackTests/EmailSourceFormModelTests.swift`

**Interfaces:**
- Consumes: `SMTPCredentials.Preset` (+ `.defaults(for:)`, `.displayName`, `.passwordPrompt`, `.help`, `.sanitize(password:)`); `MailAccountMigration.imapDefaults(for:) -> (host: String, port: Int)`; `MailAccount`; `ProductConfig.feedbackInboxAccountID`.
- Produces: `EmailSourceFormModel` (an `@Observable` view-model) with `func loadDefaults(preset:)`, `var canTest: Bool`, `func effectiveAccountValues() -> (presetRaw: String, imapHost: String, imapPort: Int, imapUsername: String, smtpUsername: String, senderName: String, feedbackProductID: UUID)` — consumed by Task 8 (the views).

> The form CREATES (or edits) a `MailAccount` configured purely as an IMAP feedback inbox: SMTP fields are set to the same host/user so the existing `IMAPClientProvider` (which reads `imapHost/imapPort/imapUsername` + the per-account IMAP Keychain password) works unchanged. `feedbackProductID` is stamped on the account; `Product.feedbackInboxAccountID` points back. The model is pure (no SwiftUI) so it's unit-testable.

- [ ] **Step 1: Write the failing model test.** Create `AppFeedbackTests/EmailSourceFormModelTests.swift`:
  ```swift
  import XCTest
  @testable import AppFeedback

  @MainActor
  final class EmailSourceFormModelTests: XCTestCase {

      func test_defaultsForPreset_fillsImapHostAndPort() {
          let m = EmailSourceFormModel(productID: UUID(), existingAccountID: nil)
          m.applyPresetDefaults(.icloud)
          XCTAssertEqual(m.imapHost, MailAccountMigration.imapDefaults(for: .icloud).host)
          XCTAssertEqual(m.imapPort, String(MailAccountMigration.imapDefaults(for: .icloud).port))
      }

      func test_canTest_requiresHostUserPassword() {
          let m = EmailSourceFormModel(productID: UUID(), existingAccountID: nil)
          XCTAssertFalse(m.canTest)
          m.username = "feedback@dev.com"
          m.applyPresetDefaults(.gmail)   // sets imapHost
          XCTAssertFalse(m.canTest)       // still no password
          m.password = "app-pw"
          XCTAssertTrue(m.canTest)
      }

      func test_isEditing_reflectsExistingAccountID() {
          XCTAssertFalse(EmailSourceFormModel(productID: UUID(), existingAccountID: nil).isEditing)
          XCTAssertTrue(EmailSourceFormModel(productID: UUID(), existingAccountID: UUID()).isEditing)
      }

      func test_effectiveAccountValues_mirrorsImapIntoSmtpAndStampsProduct() {
          let pid = UUID()
          let m = EmailSourceFormModel(productID: pid, existingAccountID: nil)
          m.username = "feedback@dev.com"
          m.senderName = "Acme Support"
          m.applyPresetDefaults(.gmail)
          let v = m.effectiveAccountValues()
          XCTAssertEqual(v.feedbackProductID, pid)
          XCTAssertEqual(v.imapUsername, "feedback@dev.com")
          XCTAssertEqual(v.smtpUsername, "feedback@dev.com")
          XCTAssertEqual(v.imapHost, MailAccountMigration.imapDefaults(for: .gmail).host)
          XCTAssertEqual(v.presetRaw, SMTPCredentials.Preset.gmail.rawValue)
      }
  }
  ```
- [ ] **Step 2: Run (expect FAIL — model missing).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/EmailSourceFormModelTests 2>&1 | tail -25`
  Expected: `Cannot find 'EmailSourceFormModel' in scope`.
- [ ] **Step 3: Create the model (in `EmailSourceForm.swift`, above the views, no `#if` guard so tests on macOS see it).** Create `AppFeedback/Views/Settings/EmailSourceForm.swift`:
  ```swift
  import Foundation
  import Observation

  /// Pure view-model for the email feedback-source form. Holds the editable fields and the
  /// create-vs-edit decision; SwiftUI views (macOS + iOS) bind to it. No I/O here — the views own
  /// store/Keychain writes so this stays unit-testable.
  @MainActor
  @Observable
  final class EmailSourceFormModel {
      let productID: UUID
      /// nil ⇒ creating a new feedback inbox; non-nil ⇒ editing the product's existing inbox account.
      let existingAccountID: UUID?

      var preset: SMTPCredentials.Preset = .gmail
      var username: String = ""            // doubles as IMAP login + From
      var password: String = ""
      var senderName: String = ""
      var imapHost: String = ""
      var imapPort: String = "993"
      var smtpHost: String = ""
      var smtpPort: String = "587"
      var pollingEnabled: Bool = true

      init(productID: UUID, existingAccountID: UUID?) {
          self.productID = productID
          self.existingAccountID = existingAccountID
          applyPresetDefaults(.gmail)
      }

      var isEditing: Bool { existingAccountID != nil }

      var canTest: Bool {
          !username.isEmpty && !imapHost.isEmpty && !password.isEmpty
      }

      func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
          preset = p
          let smtp = SMTPCredentials.defaults(for: p)
          smtpHost = smtp.host
          smtpPort = String(smtp.port)
          let imap = MailAccountMigration.imapDefaults(for: p)
          imapHost = imap.host
          imapPort = String(imap.port)
      }

      struct AccountValues {
          let presetRaw: String
          let imapHost: String
          let imapPort: Int
          let imapUsername: String
          let smtpHost: String
          let smtpPort: Int
          let smtpUsername: String
          let senderName: String
          let pollingEnabled: Bool
          let feedbackProductID: UUID
      }

      func effectiveAccountValues() -> AccountValues {
          AccountValues(
              presetRaw: preset.rawValue,
              imapHost: imapHost,
              imapPort: Int(imapPort) ?? 993,
              imapUsername: username,
              smtpHost: smtpHost,
              smtpPort: Int(smtpPort) ?? 587,
              smtpUsername: username,
              senderName: senderName,
              pollingEnabled: pollingEnabled,
              feedbackProductID: productID
          )
      }
  }
  ```
  > NOTE: `effectiveAccountValues()` returns an `AccountValues` struct; the test reads `.feedbackProductID/.imapUsername/.smtpUsername/.imapHost/.presetRaw` off it — matches the test's field accesses.
- [ ] **Step 4: Run (expect PASS).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/EmailSourceFormModelTests 2>&1 | tail -25`
  Expected: all 4 tests pass.
- [ ] **Step 5: Commit.**
  `git add AppFeedback/Views/Settings/EmailSourceForm.swift AppFeedbackTests/EmailSourceFormModelTests.swift`
  `git commit -m "feat(settings): EmailSourceFormModel (pure logic for feedback-inbox form)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 8: `EmailSourceForm` views (macOS + iOS) + create/edit/test/remove wiring

**Files:**
- Modify: `AppFeedback/Views/Settings/EmailSourceForm.swift` (add `#if os(macOS) struct EmailSourceForm`)
- Create: `AppFeedback/Views/Settings/IOSEmailSourceForm.swift` (`#if os(iOS)`)
- Test: build + compile only (UI not unit-testable here; logic lives in Task 7's model).

**Interfaces:**
- Consumes: `EmailSourceFormModel` (Task 7); `MailAccountStore.add/update/deleteWithCredentials`; `KeychainService.saveIMAPPassword(_:for:)/saveSMTPPassword(_:for:)/deleteIMAPPassword(for:)/deleteSMTPPassword(for:)`; `IMAPClientProvider(accountStore:accountID:)` + `.testConnection()`; `ProductStore.update(_:)` (to set/clear `feedbackInboxAccountID`); `MailSyncCoordinatorRegistry.syncWithAccounts()`/`restart(accountID:)`; `ActivityLog.start/finish` (`.testConnection`).
- Produces: `EmailSourceForm(product:)` (macOS) and `IOSEmailSourceForm(product:)` (iOS) — surfaced by Phase 2's Product Settings "Sources → Email" row (this phase ships the form; Phase 2 hosts it).

> Both views share `EmailSourceFormModel`. On save: create the `MailAccount` (or update the existing one) via `MailAccountStore`, write the IMAP+SMTP Keychain passwords keyed by the account id, stamp the account's `feedbackProductID`, point `Product.feedbackInboxAccountID` at it via `ProductStore.update`, and `registry?.syncWithAccounts()` so the coordinator spins up. On remove: clear `Product.feedbackInboxAccountID`, `deleteWithCredentials`, resync.

- [ ] **Step 1: Add the macOS view.** Edit `EmailSourceForm.swift`, append below the model:
  ```swift
  #if os(macOS)
  import SwiftUI
  import AppKit

  /// Configures (or edits) a product's email feedback inbox: a MailAccount with
  /// `feedbackProductID == product.id`, referenced by `Product.feedbackInboxAccountID`.
  struct EmailSourceForm: View {
      let product: ProductConfig

      @Environment(MailAccountStore.self) private var accountStore
      @Environment(ProductStore.self) private var productStore
      @Environment(ActivityLog.self) private var activityLog
      @Environment(\.mailSyncCoordinatorRegistry) private var registry: MailSyncCoordinatorRegistry?
      @Environment(\.dismiss) private var dismiss

      @State private var model: EmailSourceFormModel
      @State private var testState: String = ""
      @State private var didLoad = false
      @State private var showRemoveConfirm = false

      init(product: ProductConfig) {
          self.product = product
          _model = State(initialValue: EmailSourceFormModel(
              productID: product.id,
              existingAccountID: product.feedbackInboxAccountID
          ))
      }

      var body: some View {
          Form {
              Section("Inbox") {
                  Picker("Service", selection: Binding(get: { model.preset }, set: { model.applyPresetDefaults($0) })) {
                      ForEach(SMTPCredentials.Preset.allCases) { Text($0.displayName).tag($0) }
                  }
                  TextField("Inbox address", text: Binding(get: { model.username }, set: { model.username = $0 }),
                            prompt: Text("feedback@yourapp.com"))
                  SanitizedPasswordField(
                      title: "Password",
                      prompt: Text(model.preset.passwordPrompt),
                      text: Binding(get: { model.password }, set: { model.password = model.preset.sanitize(password: $0) })
                  )
                  if let help = model.preset.help {
                      MailProviderHintCard(preset: model.preset, help: help,
                                           appPasswordURL: model.preset.appPasswordsURL(forEmail: model.username))
                  }
                  TextField("Sender display name", text: Binding(get: { model.senderName }, set: { model.senderName = $0 }))
              }
              if model.preset == .custom {
                  Section("Advanced") {
                      LabeledContent("IMAP host") { TextField("", text: Binding(get: { model.imapHost }, set: { model.imapHost = $0 })).multilineTextAlignment(.trailing) }
                      LabeledContent("IMAP port") { TextField("", text: Binding(get: { model.imapPort }, set: { model.imapPort = $0 })).multilineTextAlignment(.trailing) }
                  }
              }
              Section {
                  Button("Test Connection") { Task { await testConnection() } }
                      .disabled(!model.canTest)
                  if !testState.isEmpty { Text(testState).font(.caption).foregroundStyle(.secondary) }
                  Button("Save") { Task { await save() } }
                      .disabled(!model.canTest)
              }
              if model.isEditing {
                  Section {
                      Button("Remove Email Source", role: .destructive) { showRemoveConfirm = true }
                  }
              }
          }
          .formStyle(.grouped)
          .task { await load() }
          .alert("Remove this email source?", isPresented: $showRemoveConfirm) {
              Button("Cancel", role: .cancel) { }
              Button("Remove", role: .destructive) { Task { await remove() } }
          } message: {
              Text("Stops fetching this inbox and removes its credentials from this device. Existing feedback issues stay on GitHub.")
          }
      }

      private func load() async {
          guard !didLoad, let id = product.feedbackInboxAccountID, let acc = accountStore.account(id: id) else { didLoad = true; return }
          model.preset = acc.preset
          model.username = acc.imapUsername.isEmpty ? acc.smtpUsername : acc.imapUsername
          model.senderName = acc.senderName
          model.imapHost = acc.imapHost
          model.imapPort = String(acc.imapPort)
          model.smtpHost = acc.smtpHost
          model.smtpPort = String(acc.smtpPort)
          model.pollingEnabled = acc.pollingEnabled
          if let pw = await KeychainService.loadIMAPPassword(for: id) { model.password = pw }
          didLoad = true
      }

      @MainActor private func save() async {
          let v = model.effectiveAccountValues()
          let accountID: UUID
          if let existing = model.existingAccountID {
              accountStore.update(id: existing) { acc in apply(v, to: acc) }
              accountID = existing
          } else {
              let acc = accountStore.add { a in apply(v, to: a) }
              accountID = acc.id
          }
          _ = await KeychainService.saveIMAPPassword(model.password, for: accountID)
          _ = await KeychainService.saveSMTPPassword(model.password, for: accountID)
          // Point the product at the inbox account.
          var updated = product
          updated.feedbackInboxAccountID = accountID
          productStore.update(updated)
          registry?.syncWithAccounts()
          testState = "Saved."
          dismiss()
      }

      private func apply(_ v: EmailSourceFormModel.AccountValues, to acc: MailAccount) {
          acc.presetRaw = v.presetRaw
          acc.imapHost = v.imapHost; acc.imapPort = v.imapPort; acc.imapUsername = v.imapUsername
          acc.smtpHost = v.smtpHost; acc.smtpPort = v.smtpPort; acc.smtpUsername = v.smtpUsername
          acc.senderName = v.senderName
          acc.pollingEnabled = v.pollingEnabled
          acc.feedbackProductID = v.feedbackProductID
      }

      @MainActor private func testConnection() async {
          // Persist creds to a (possibly new) account first so IMAPClientProvider can read them.
          await save()
          guard let id = product.feedbackInboxAccountID ?? model.existingAccountID else { return }
          let logID = activityLog.start(kind: .testConnection, title: "\(model.imapHost):\(model.imapPort)")
          #if canImport(SwiftMail)
          do {
              let provider = IMAPClientProvider(accountStore: accountStore, accountID: id)
              try await provider.testConnection()
              activityLog.finish(logID, status: .success, detail: "Login OK")
              testState = "Connection OK."
          } catch {
              activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
              testState = "Failed: \(error.localizedDescription)"
          }
          #else
          activityLog.finish(logID, status: .failure, detail: "SwiftMail not available")
          testState = "SwiftMail not available."
          #endif
      }

      @MainActor private func remove() async {
          var updated = product
          updated.feedbackInboxAccountID = nil
          productStore.update(updated)
          if let id = model.existingAccountID, let acc = accountStore.account(id: id) {
              await accountStore.deleteWithCredentials(acc)
          }
          registry?.syncWithAccounts()
          dismiss()
      }
  }
  #endif
  ```
  > NOTE for the executing agent: confirm `ProductStore.update(_:)` takes a `ProductConfig` by value (Phase 0 renames `RepoStore.update(_:)` which today takes a `RepoConfig`). Confirm the `\.mailSyncCoordinatorRegistry` environment key exists (it's used by `EmailAccountEditor`). Confirm `SanitizedPasswordField` and `MailProviderHintCard` are in scope (both used by the existing editors).
- [ ] **Step 2: Add the iOS view.** Create `AppFeedback/Views/Settings/IOSEmailSourceForm.swift` mirroring the macOS form inside `#if os(iOS)`, wrapping the `Form` in a `NavigationStack` with a "Done"/"Cancel" toolbar, using `.keyboardType(.emailAddress)` + `.textInputAutocapitalization(.never)` on the address field (pattern copied verbatim from `IOSEmailAccountEditor`). Reuse `EmailSourceFormModel` and the identical `save()/load()/testConnection()/remove()` bodies (no AppKit `NSPasteboard`; drop the paste button).
- [ ] **Step 3: Build both platforms (compile check; UI not unit-tested).**
  `xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -15`
  `xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
  Expected: both **BUILD SUCCEEDED**.
- [ ] **Step 4: Re-run the form-model tests to confirm still green.**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/EmailSourceFormModelTests 2>&1 | tail -15`
  Expected: pass.
- [ ] **Step 5: Commit.**
  `git add AppFeedback/Views/Settings/EmailSourceForm.swift AppFeedback/Views/Settings/IOSEmailSourceForm.swift`
  `git commit -m "feat(settings): EmailSourceForm (macOS + iOS) creates/edits a product feedback inbox" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 9: Wire `MailToFeedbackMirror` into `AppFeedbackApp` + coordinator factory

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`
- Test: full-suite run (no new unit test; wiring is integration-only and exercised by Tasks 4/6).

**Interfaces:**
- Consumes: `MailToFeedbackMirror(context:productStore:activityLog:...)` (Task 4); `MailSyncCoordinator(... feedbackMirror:)` (Task 6); existing `MailToGitHubMirror` wiring pattern (`mirrorLocal`, `registryFactory`).
- Produces: a live `MailToFeedbackMirror` injected into every coordinator so feedback inboxes synthesize issues at runtime.

- [ ] **Step 1: Build the feedback mirror next to the GitHub mirror.** In `AppFeedbackApp.init()`, just after the existing `let mirrorLocal = MailToGitHubMirror(...)` / `_mirrorHolder = State(...)` block (around line 181-187), add:
  ```swift
  let feedbackMirrorLocal = MailToFeedbackMirror(
      context: ModelContext(container),
      productStore: _store.wrappedValue,
      activityLog: activityLogValue
  )
  _feedbackMirrorHolder = State(initialValue: MailToFeedbackMirrorHolder(feedbackMirrorLocal))
  ```
  and add the matching stored property near the other holders:
  ```swift
  @State private var feedbackMirrorHolder: MailToFeedbackMirrorHolder
  ```
  > NOTE: `_store` is the `ProductStore` post-Phase-0 (today `RepoStore`); use whatever the merged tree calls it. The `convenience init` of `MailToFeedbackMirror` defaults `issueWriter`/`commentPoster`/`tokenLoader`, so this two-line call is complete.
- [ ] **Step 2: Pass the feedback mirror into the factory.** In the `#if canImport(SwiftMail)` block, before `let registryFactory`, capture `let feedbackMirrorRef = feedbackMirrorLocal`. Then in the `MailSyncCoordinator(...)` construction inside `registryFactory`, add the argument right after `mirror: mirrorRef,`:
  ```swift
                  mirror: mirrorRef,
                  feedbackMirror: feedbackMirrorRef,
  ```
- [ ] **Step 3: Build both platforms.**
  `xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -15`
  `xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
  Expected: both **BUILD SUCCEEDED**.
- [ ] **Step 4: Run the full suite (ground truth) and confirm only the ~11 known Keychain/GitHubAccount failures remain.**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -40`
  Expected: the new `InboundNoiseFilterTests`, `MailToFeedbackMirrorTests`, `MailSyncCoordinatorRoleTests`, `EmailSourceFormModelTests` all pass; total failures == the documented ~11 pre-existing (KeychainServicePerAccountTests + GitHubAccountStoreTests) and no others.
- [ ] **Step 5: Commit.**
  `git add AppFeedback/App/AppFeedbackApp.swift`
  `git commit -m "feat(mail): wire MailToFeedbackMirror into the app + coordinator factory" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

### Task 10: Attachments via the existing mail-attachment path (verify + guard)

**Files:**
- Modify: `AppFeedbackTests/MailToFeedbackMirrorTests.swift` (one test asserting an attachment-bearing root still creates exactly one issue)
- (No production change expected — `recordInbound` already inserts `MailAttachment` rows for `message.attachments`; the existing `AttachmentDownloader` fetches their bytes. This task confirms the mirror doesn't choke on attachments and documents the path.)

**Interfaces:**
- Consumes: `MailThreadStore.recordInbound` (inserts `MailAttachment` per `ParsedAttachmentMeta`); existing `AttachmentDownloader` (untouched).
- Produces: a regression test pinning "attachment-bearing root → exactly one issue, attachments persisted as `MailAttachment` rows".

- [ ] **Step 1: Write the test.** Append to `MailToFeedbackMirrorTests.swift`:
  ```swift
  func test_rootWithAttachment_createsOneIssue_andPersistsAttachmentRow() async throws {
      let container = try makeContainer()
      let ctx = ModelContext(container)
      let threadStore = MailThreadStore(context: ctx)
      let store = seededProductStore(ctx)
      let inboxID = store.products[0].feedbackInboxAccountID!
      let rec = WriteRecorder()
      let mirror = MailToFeedbackMirror(
          context: ctx, productStore: store, activityLog: ActivityLog(persistenceURL: nil),
          createIssue: { _,_,t,_,l,_ in rec.createdTitles.append(t); rec.createdLabels.append(l); return 77 },
          postComment: { _,_,n,b,_ in rec.comments.append((n,b)); return 1 },
          tokenLoader: { _ in "tok" }
      )
      let withAttachment = ParsedInboundMessage(
          uid: 20, folder: "INBOX", uidValidity: 1, messageID: "<att@x>",
          inReplyTo: nil, references: [], fromAddress: "user@x.com", fromName: "U",
          toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
          subject: "Screenshot of bug", bodyPlain: "see attached", bodyHTML: nil,
          attachments: [ParsedAttachmentMeta(partID: "2", filename: "bug.png", mimeType: "image/png", sizeBytes: 1234)]
      )
      _ = threadStore.recordInbound(message: withAttachment, accountID: inboxID)
      await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)

      XCTAssertEqual(rec.createdTitles, ["Screenshot of bug"])
      let atts = try ctx.fetch(FetchDescriptor<MailAttachment>())
      XCTAssertEqual(atts.count, 1)
      XCTAssertEqual(atts.first?.filename, "bug.png")
  }
  ```
  > NOTE: `MailAttachment` has a `filename` field and is registered in `makeContainer()` (alongside `Product.self`, per this file's `makeContainer()`). The store comes from the shared `seededProductStore(_:)` helper defined earlier in this file.
- [ ] **Step 2: Run (expect PASS — no production change needed).**
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/MailToFeedbackMirrorTests 2>&1 | tail -25`
  Expected: all `MailToFeedbackMirrorTests` pass, including the new attachment test.
- [ ] **Step 3: Commit.**
  `git add AppFeedbackTests/MailToFeedbackMirrorTests.swift`
  `git commit -m "test(mail): feedback root with attachment creates one issue + persists attachment row" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

## Done criteria
- A product with an email feedback source configured (a `MailAccount` with `feedbackProductID == product.id`, referenced by `Product.feedbackInboxAccountID`) ingests ALL inbound (no FROM filter), turning thread roots into new GitHub issues (label `source:email`, markers `source`/`fromAddress`/`messageId`, body preferring text/plain then stripped HTML, address redacted per `redactEmailAddresses`) and replies into comments on the same issue.
- Bounces (`mailer-daemon`/`postmaster`/empty Return-Path) and auto-replies (`Auto-Submitted: auto-*`, `Precedence: bulk|list`) are skipped by default — never stored, never synthesized.
- `EmailSourceForm` (macOS) and `IOSEmailSourceForm` (iOS) create/edit/test/remove the feedback inbox, reusing `MailAccount`/`IMAPClientProvider`/Keychain/`Preset`.
- All four new test classes pass under `xcodebuild`; the only remaining failures are the documented ~11 pre-existing Keychain/GitHubAccount ones.
