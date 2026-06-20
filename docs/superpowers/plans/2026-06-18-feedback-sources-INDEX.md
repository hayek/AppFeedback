# Feedback Sources — Implementation Plan Index

> **For agentic workers:** This is the authoritative entry point for the feedback-sources work. Execute the phases in order. The **Shared Contracts** below override any drift in an individual phase file. Each phase file uses checkbox (`- [ ]`) steps; implement with superpowers:subagent-driven-development (recommended) or superpowers:executing-plans.

**Goal:** Let a Product accept feedback from multiple sources — the existing SDK plus App Store reviews (App Store Connect API, read + developer responses) and a dedicated email inbox — all synthesized into GitHub issues (the universal sink), with a Product Settings screen, source badges, and a Source filter.

**Spec:** `docs/superpowers/specs/2026-06-18-feedback-sources-design.md`

## Phase files (execution order)

| Phase | File | Ships |
|---|---|---|
| 0 | `2026-06-18-feedback-sources-phase0-product-rename.md` | `Repo`→`Product` rename + CloudKit data-copy migration; new source-config fields; `MailAccount.feedbackProductID`. No behavior change. |
| 1 | `2026-06-18-feedback-sources-phase1-source-contract.md` | Source markers/labels contract; `CachedIssue.source/rating`; `FeedbackSource`; row badge; Source filter facet. SDK-only data works. |
| 2 | `2026-06-18-feedback-sources-phase2-product-settings-ui.md` | Products settings tab (master-detail) + sidebar "Settings…"; Sources rows; **navigation stubs** to the App Store / Email forms (real forms land in Phases 3/5). |
| 3 | `2026-06-18-feedback-sources-phase3-app-store-read.md` | App Store auth/poll/synthesis/edit/delete + **the real `AppStoreSourceForm`** (incl. iOS `.p8` import + app picker) + per-source status. |
| 4 | `2026-06-18-feedback-sources-phase4-app-store-writeback.md` | Inspector "Respond on App Store" panel (consumes Phase 3's store/registry; does not redefine them). |
| 5 | `2026-06-18-feedback-sources-phase5-email-source.md` | Email feedback inbox: `EmailSourceForm` (both platforms) + role-aware `MailToFeedbackMirror`. |

Phases 0→1→2 are strictly sequential. Phase 3 may be developed against current names but **integrates after Phase 0** (it needs `Product` fields + Phase-1 markers to round-trip). Phase 4 depends on Phase 3; Phase 5 depends on Phases 0+1.

## Global Constraints

- iOS deployment floor **18.6**; macOS floor **15.0**. Single `AppFeedback` target → `AppFeedback_iOS` / `AppFeedback_macOS`.
- xcodegen-generated: new `.swift` files in any subfolder are auto-picked up; **never hand-edit the pbxproj**. Every `git add` stages explicit paths only — a broad `git add` sweeps the user's unrelated WIP + untracked files into the pbxproj.
- Build/test via the **zcode** skill; treat `xcodebuild` as ground truth (zcode `/api/test` can mask a hard crash). Test target `AppFeedbackTests_macOS`; **scheme `AppFeedback_macOS`** everywhere. Tests run in-memory (`cloudKitDatabase: .none`).
- ~11 pre-existing failures (`KeychainServicePerAccountTests` + `GitHubAccountStoreTests`) come from the test host having no Keychain — **not regressions**; do not "fix" them.
- New `@Model` types register in **both** the `isTesting` container **and** the right Schema half in `AppFeedbackApp.init()`: `cloudSchema` (CloudKit-synced) vs `localSchema` (device-only). The live container uses **two `ModelConfiguration`s and NO `migrationPlan:` argument** — do not add one.
- New `@Observable` stores bump `version` on `NSPersistentStoreRemoteChange` **and** `cloudKitImportSucceeded`, not only local saves.
- Do not assert a store's `version` across coordinator polls (async remote-change notifications); assert version only in synchronous store-level tests.
- Frequent commits; every message ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. DRY, YAGNI, TDD (red→green→commit).

## Shared Contracts (AUTHORITATIVE — overrides any phase file)

```swift
// ── Phase 0: rename + migration ───────────────────────────────────────────
@Model final class Product {            // renamed from Repo; SAME fields preserved (id, displayName, owner,
                                        // repo, hiddenAppNames, appColors, colorHex, createdAt,
                                        // mirrorEmailsToGitHub, redactEmailAddresses, connectedRepoOwner,
                                        // connectedRepoName) PLUS:
    var appStoreIssuerID: String?
    var appStoreKeyID: String?
    var appStoreAppAppleID: String?     // opaque ASC app id (numeric string); nil ⇒ App Store source off
    var feedbackInboxAccountID: UUID?   // → a MailAccount whose feedbackProductID == self.id; nil ⇒ email off
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
//   (inbox-vs-reply-mirror "role" is DERIVED from feedbackProductID != nil; do NOT add a stored role.)
// Migration: a single idempotent, AppStorage-gated `ProductMigration.run(context:defaults:)` invoked from
//   AppFeedbackApp.init() when not testing (like MailAccountMigration). It copies each legacy Repo → Product,
//   preserving id/owner/repo and all fields. A read-only legacy `Repo` @Model stays in the schema one release.
//   DO NOT ship a VersionedSchema/SchemaMigrationPlan — the container has no migrationPlan: and it would be dead code.
// Persisted Repo*-prefixed companions (RepoFilterPreference, RepoFetchState) KEEP their type names; only
//   user-facing strings say "Product".

// ── Phase 1: source contract + filters + badges ───────────────────────────
enum FeedbackSource: String, Codable, CaseIterable, Sendable { case sdk = "sdk"; case appStore = "app-store"; case email = "email" }
// Body-marker KEYS added to BodyMarker: "source","rating","reviewerNickname","territory","reviewId",
//   "reviewCreatedAt","fromAddress","messageId" (carried in a source-meta-v1 block between HTML-comment fence lines,
//   mirroring the existing attachments-v1 block — the key:value lines render VISIBLY in the issue, by design, like device-info).
// GitHub LABELS: "source:app-store","source:email","rating:1"…"rating:5".
// CachedIssue gains (local schema, additive): var source: String?  var rating: Int?   (nil source ⇒ .sdk)
// FeedbackIssue gains: var source: FeedbackSource  var rating: Int?
// RepoFilterPreference gains persisted `sources` ([String] ⇄ Set<FeedbackSource>), default = all cases.
// FeedbackSource.githubLabel produced here; the synthesizers (P3/P5) WRITE the labels, P1 only READS them.

// ── Phase 3: App Store read path (OWNS the mirror store + setup form) ──────
@Model final class AppStoreReviewMirror {            // CloudKit-synced (no unique constraint → dedup at read time)
    var reviewId: String; var productID: UUID; var issueNumber: Int
    var contentHash: String                          // SHA-256 hex of normalized rating+"\n"+title+"\n"+body
    var responseState: String?                       // nil | "PENDING_PUBLISH" | "PUBLISHED"
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
    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse  // POST upsert (no PATCH)
    func deleteResponse(responseId: String) async throws
}
struct ASCReviewPage: Sendable { let reviews: [ASCReview]; let nextCursor: String?; let rateRemaining: Int? }
struct ASCReview: Sendable { let id: String; let rating: Int; let title: String?; let body: String?; let reviewerNickname: String?; let createdDate: Date; let territory: String; let response: ASCResponse? }
struct ASCResponse: Sendable { let id: String; let responseBody: String; let state: String; let lastModifiedDate: Date }
struct ASCApp: Sendable { let id: String; let bundleId: String; let name: String }
actor AppStoreConnectAuth { init(issuerID: String, keyID: String, p8PEM: String); func token() async throws -> String }  // ES256, exp≤20m, cached ~15m
actor AppStoreReviewCoordinator {                    // poll loop: incremental + periodic FULL re-scan (edits/deletions)
    // exposes observable lastSuccessAt: Date? and lastError: String? for §8 per-source status
}
@MainActor final class AppStoreReviewCoordinatorRegistry {   // one coordinator per product-with-ASC; mirrors MailSyncCoordinatorRegistry
    func responderContext(productID: UUID) -> AppStoreResponderContext?   // Phase 4 consumes this
}
struct AppStoreResponderContext: Sendable {          // Phase 3 defines; Phase 4 consumes
    let client: any AppStoreConnectClientProtocol
    let isReadOnly: Bool                             // true after a 403 on a response write (read-only key)
    let owner: String; let repo: String              // for the GitHub "responded" record comment
}
protocol FeedbackSourceIngestor: Sendable { func poll() async throws }   // AppStoreReviewCoordinator conforms
// The REAL AppStoreSourceForm (Issuer/Key paste, .p8 import via .fileImporter on BOTH platforms incl. iOS Files,
//   Test, app picker via client.listApps(), save .p8→Keychain keyed by product id + IDs→Product, shows
//   lastSuccessAt/lastError) is implemented in PHASE 3, reachable from the Phase-2 Sources row.
// New KeychainService methods: saveASCKey(_:for:) / loadASCKey(for:) / loadASCKeySync(for:) / deleteASCKey(for:), keyed by product id.

// ── Phase 4: write-back (consumes Phase 3; defines NO store) ───────────────
// "Respond on App Store" panel shown when the selected feedback's source == .appStore. Reads reviewId from the
//   issue body markers. Uses client.createOrUpdateResponse / deleteResponse via registry.responderContext(productID:).
//   Updates the Phase-3 AppStoreReviewMirrorStore.setResponse/clearResponse. Posts a GitHubCommentPoster record comment.
//   403 (or AppStoreConnectError.forbidden / any StatusCarryingError statusCode==403) ⇒ disable panel, explanatory note.
//   The response controller is CACHED per issue.number (not rebuilt in `body`) so the draft survives re-renders.

// ── Phase 5: email feedback source ─────────────────────────────────────────
final class MailToFeedbackMirror { /* detached Task in MailSyncCoordinator.pollOnce(); gated on feedbackProductID != nil */ }
//   thread root → new issue (label source:email; markers source/fromAddress[redacted]/messageId); reply → comment.
// Noise filtering runs in the COORDINATOR on the full ParsedInboundMessage BEFORE recordInbound (so Return-Path /
//   Auto-Submitted / Precedence headers are available); InboundNoiseFilter.isNoise(_ msg: ParsedInboundMessage) -> Bool
//   is unit-tested directly. The in-mirror path does NOT re-filter on a rebuilt message (those headers would be nil).
```

## Cross-phase fixes applied (from the adversarial review)

1. **One `AppStoreReviewMirrorStore`** — defined only in Phase 3 (`Services/AppStore/`). Phase 4 consumes it; it does not redefine the type or duplicate the test class.
2. **`setResponse(reviewId:responseId:state:)`** is the canonical signature (reviewId is globally unique).
3. **App Store setup form / `.p8` import / app picker** is owned by **Phase 3** (both platforms, incl. iOS Files picker). Phase 2 ships only the navigation entry + status.
4. **No `ProductMigrationPlan`/`VersionedSchema`** — Phase 0 ships only the idempotent `ProductMigration.run` invoked from `init()`.
5. **`ProductStore.products`** alias exists; new code uses `products`.
6. **`AppStoreConnectError: StatusCarryingError`** so Phase 4's 403 read-only disable actually fires.
7. **`reconcileDuplicates`** groups mirror rows by `reviewId`, keeps the lowest `issueNumber`, closes the higher GitHub issue(s), and deletes the extra row(s) via `deleteByIssue` — never the kept row.
8. **Deletion preserves the rating badge** via the body marker (body not rewritten; marker is authoritative for `resolveRating`) — asserted by a regression test.
9. **Per-source status** (`lastSuccessAt`/`lastError`) surfaced in the App Store form; email reuses the mail status surface.
10. **Email noise filtering** runs pre-store in the coordinator on the full `ParsedInboundMessage`; the filter is unit-tested directly.
11. **`responderContext(productID:)`** on the App Store registry is the seam Phase 4 uses.

## Known accepted deviations

- Search-before-create is replaced by mirror-authority + duplicate-collapse reconcile (the app has no GitHub search API). 
- App Store items carry no version (ASC API limitation) → they fall under "Unassigned" in the version filter.
- Rating-only reviews (no text) are not returned by the API and cannot appear.
- `SettingsTab` raw value changes `repos`→`products`; a persisted tab selection resets to default once (no data loss).
