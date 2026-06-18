# Phase 1 — Source contract, CachedIssue source/rating, badges + Source filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `FeedbackSource` (sdk/app-store/email) that survives the GitHub round-trip via new body markers + labels, populate additive `CachedIssue.source/rating` and `FeedbackIssue.source/rating`, render a leading source badge (App Store inline star rating + envelope/SDK glyphs) in the feedback row, and add a persisted default-all-on Source filter facet — all shippable with SDK-only data (everything badges as SDK).

**Architecture:** The SDK package (`../AppFeedbackCore`) owns the wire contract: `BodyMarker` gains the new marker key strings, `IssueBodyFormatter` gains a `sourceMetadataBlock(...)` emitter (an HTML-comment block mirroring the existing `<!-- attachments-v1 -->` block), and `IssueBodyParser`/`ParsedFeedbackBody` widen to read it. The app-side `IssueBodyParser` shim and `IssueLoader.decodePage` thread `source`/`rating` into `FeedbackIssue`; `CachedIssue` persists them as additive optional columns. The list row badge and the Source filter facet (in `IssueListViewModel.ActiveFilters` + `PersistedFeedbackFilters`, surfaced by `FilterBarView` via the existing `MultiSelectFilterChip`) are derived purely from `FeedbackIssue.source/rating`, defaulting absent source to `.sdk`.

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
- `../AppFeedbackSDK/Tests/AppFeedbackCoreTests/SourceMetadataRoundtripTests.swift` — SDK formatter↔parser round-trip for the new source-metadata block (mirrors `RoundtripTests`).
- `AppFeedback/Models/FeedbackSource.swift` — the `FeedbackSource` enum (rawValue + display name + SF Symbol).
- `AppFeedback/Views/Issues/SourceBadgeView.swift` — leading row badge: App Store (Apple mark + inline `★★★☆☆`), Email (envelope), SDK (wrench/SDK glyph); derived from `FeedbackIssue.source`/`rating`.
- `AppFeedbackTests/FeedbackSourceTests.swift` — enum rawValue/displayName/symbol + `from(label:)`/`label` mapping.
- `AppFeedbackTests/SourceBadgeViewTests.swift` — pure-helper logic test (`SourceBadge.descriptor(for:)`) + compile-check.
- `AppFeedbackTests/SourceContractTests.swift` — app-side shim + `CachedIssue`/`FeedbackIssue` source/rating round-trip; legacy-default-to-sdk.

### Modify
- `../AppFeedbackSDK/Sources/AppFeedbackCore/BodyMarkers.swift` — add the eight new marker key strings + the source-metadata block fences.
- `../AppFeedbackSDK/Sources/AppFeedbackCore/IssueBodyFormatter.swift` — add `sourceMetadataBlock(...)` emitter.
- `../AppFeedbackSDK/Sources/AppFeedbackCore/IssueBodyParser.swift` — add `source`/`rating`/`reviewerNickname`/`territory`/`reviewId`/`reviewCreatedAt`/`fromAddress`/`messageId` to `ParsedFeedbackBody`; parse the block.
- `AppFeedback/Services/IssueBodyParser.swift` — widen `ParsedBody` with `source`/`rating` (+ the carried marker values) and map them through the shim.
- `AppFeedback/Models/FeedbackIssue.swift` — add `var source: FeedbackSource` + `var rating: Int?` to `FeedbackIssue` (init defaults `source: .sdk`, `rating: nil`).
- `AppFeedback/Models/CachedIssue.swift` — add additive `var source: String?` + `var rating: Int?`; thread through `init`/`from`/`toFeedbackIssue`/`updateFromRemote`.
- `AppFeedback/Services/IssueLoader.swift` — pass `parsed.source`/`parsed.rating` (with label fallback) into `FeedbackIssue` in `decodePage`.
- `AppFeedback/ViewModels/IssueListViewModel.swift` — add `sources: Set<FeedbackSource>` to `ActiveFilters` (default all cases), filter `visibleIssues` by it, derive `uniqueSources`, thread through `persistedFeedbackFilters`/`applyFeedbackFilters`/`clearFilters`/`isEmpty`.
- `AppFeedback/Services/FilterPreferenceStore.swift` — add `sources: Set<FeedbackSource>` to `PersistedFeedbackFilters` (default all cases) via `[String]` codable backing.
- `AppFeedback/Views/Issues/FilterBarView.swift` — add a "Source" `MultiSelectFilterChip`.
- `AppFeedback/Views/Issues/IssueCardView.swift` — render `SourceBadgeView` leading the title row of the card.

---

## Tasks

### Task 1: SDK marker vocabulary + source-metadata fences

**Files:**
- Modify: `../AppFeedbackSDK/Sources/AppFeedbackCore/BodyMarkers.swift`
- Test: covered indirectly by Task 3 (`SourceMetadataRoundtripTests`); this task is a compile-only delivery of the constants.

**Interfaces:**
- Consumes: nothing.
- Produces: `BodyMarker.sourceMetaOpen` = `"<!-- source-meta-v1 -->"`, `BodyMarker.sourceMetaClose` = `"<!-- /source-meta-v1 -->"`, and `BodyMarker.sourceKey` = `"source"`, `BodyMarker.ratingKey` = `"rating"`, `BodyMarker.reviewerNicknameKey` = `"reviewerNickname"`, `BodyMarker.territoryKey` = `"territory"`, `BodyMarker.reviewIdKey` = `"reviewId"`, `BodyMarker.reviewCreatedAtKey` = `"reviewCreatedAt"`, `BodyMarker.fromAddressKey` = `"fromAddress"`, `BodyMarker.messageIdKey` = `"messageId"`.

Steps:

- [ ] **Step 1: Add the source-metadata constants to `BodyMarker`.** Insert below the `attachmentsHeader` line (after line 21) in `../AppFeedbackSDK/Sources/AppFeedbackCore/BodyMarkers.swift`:
```swift
    /// HTML-comment fences wrapping the machine-readable source metadata block.
    /// Mirrors the attachments-v1 block: invisible in rendered Markdown, survives
    /// the GitHub round-trip, and is parsed back by ``IssueBodyParser``. Each line
    /// inside is `key: value` using the `*Key` constants below.
    static let sourceMetaOpen = "<!-- source-meta-v1 -->"
    static let sourceMetaClose = "<!-- /source-meta-v1 -->"

    /// Keys written inside the `source-meta-v1` block, one `key: value` per line.
    /// `source` is always present; the rest are populated per source type.
    static let sourceKey = "source"
    static let ratingKey = "rating"
    static let reviewerNicknameKey = "reviewerNickname"
    static let territoryKey = "territory"
    static let reviewIdKey = "reviewId"
    static let reviewCreatedAtKey = "reviewCreatedAt"
    static let fromAddressKey = "fromAddress"
    static let messageIdKey = "messageId"
```
- [ ] **Step 2: Build the SDK package to confirm it compiles.** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED (the app target compiles the SDK as a local package).
- [ ] **Step 3: Commit.** Stage only the one file:
```
git add ../AppFeedbackSDK/Sources/AppFeedbackCore/BodyMarkers.swift
git commit -m "feat(sdk): add source-meta-v1 marker vocabulary to BodyMarker

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: SDK parser reads the source-metadata block

**Files:**
- Modify: `../AppFeedbackSDK/Sources/AppFeedbackCore/IssueBodyParser.swift`
- Test: `../AppFeedbackSDK/Tests/AppFeedbackCoreTests/SourceMetadataRoundtripTests.swift` (created in Task 3; assertions for parse arrive there)

**Interfaces:**
- Consumes: `BodyMarker.sourceMetaOpen/Close` + the `*Key` constants (Task 1); `ParsedFeedbackBody` (existing); `asciiWhitespace` (file-private, existing).
- Produces: widened `public struct ParsedFeedbackBody` with `public var source: String?`, `public var rating: Int?`, `public var reviewerNickname: String?`, `public var territory: String?`, `public var reviewId: String?`, `public var reviewCreatedAt: String?`, `public var fromAddress: String?`, `public var messageId: String?`; `IssueBodyParser.parse(_:)` populates them.

Steps:

- [ ] **Step 1: Widen `ParsedFeedbackBody` storage.** In `IssueBodyParser.swift`, after the `attachments` stored property (line 60), add:
```swift
    /// Machine-readable source metadata from the `source-meta-v1` block.
    /// `source` is the originating feedback source ("sdk" | "app-store" | "email");
    /// nil when the block is absent (legacy SDK issues) — callers default to "sdk".
    public var source: String?
    /// App Store star rating (1…5) when `source == "app-store"`, else nil.
    public var rating: Int?
    public var reviewerNickname: String?
    public var territory: String?
    public var reviewId: String?
    public var reviewCreatedAt: String?
    public var fromAddress: String?
    public var messageId: String?
```
- [ ] **Step 2: Extend the memberwise initializer.** Replace the `public init(...)` signature + body (lines 64–80) to thread the new fields with `nil` defaults. New version:
```swift
    public init(
        description: String = "",
        appName: String? = nil,
        appVersion: String? = nil,
        device: String? = nil,
        osVersion: String? = nil,
        email: String? = nil,
        attachments: [ParsedAttachment] = [],
        source: String? = nil,
        rating: Int? = nil,
        reviewerNickname: String? = nil,
        territory: String? = nil,
        reviewId: String? = nil,
        reviewCreatedAt: String? = nil,
        fromAddress: String? = nil,
        messageId: String? = nil
    ) {
        self.description = description
        self.appName = appName
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.email = email
        self.attachments = attachments
        self.source = source
        self.rating = rating
        self.reviewerNickname = reviewerNickname
        self.territory = territory
        self.reviewId = reviewId
        self.reviewCreatedAt = reviewCreatedAt
        self.fromAddress = fromAddress
        self.messageId = messageId
    }
```
- [ ] **Step 3: Parse the block in `parse(_:)`.** In `parse(_:)`, immediately after `result.attachments = parseAttachments(in: normalized)` (line 175), add:
```swift
        applySourceMetadata(in: normalized, to: &result)
```
- [ ] **Step 4: Add the block parser as a file-scope function.** After the `parseAttachmentLine(_:)` function (after line 240, before the `extension IssueBodyParser` at line 242), add:
```swift
private func applySourceMetadata(in raw: String, to result: inout ParsedFeedbackBody) {
    guard let openRange = raw.range(of: BodyMarker.sourceMetaOpen) else { return }
    let afterOpen = openRange.upperBound
    let end = raw.range(of: BodyMarker.sourceMetaClose, range: afterOpen..<raw.endIndex)?.lowerBound ?? raw.endIndex
    let block = raw[afterOpen..<end]

    for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: asciiWhitespace)
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).trimmingCharacters(in: asciiWhitespace)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: asciiWhitespace)
        guard !value.isEmpty else { continue }
        switch key {
        case BodyMarker.sourceKey:            result.source = value
        case BodyMarker.ratingKey:            result.rating = Int(value)
        case BodyMarker.reviewerNicknameKey:  result.reviewerNickname = value
        case BodyMarker.territoryKey:         result.territory = value
        case BodyMarker.reviewIdKey:          result.reviewId = value
        case BodyMarker.reviewCreatedAtKey:   result.reviewCreatedAt = value
        case BodyMarker.fromAddressKey:       result.fromAddress = value
        case BodyMarker.messageIdKey:         result.messageId = value
        default:                              break
        }
    }
}
```
- [ ] **Step 5: Build the app target (compiles the SDK).** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 6: Commit.** Stage only the one file:
```
git add ../AppFeedbackSDK/Sources/AppFeedbackCore/IssueBodyParser.swift
git commit -m "feat(sdk): parse source-meta-v1 block into ParsedFeedbackBody

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: SDK formatter emits the block + round-trip test

**Files:**
- Modify: `../AppFeedbackSDK/Sources/AppFeedbackCore/IssueBodyFormatter.swift`
- Create/Test: `../AppFeedbackSDK/Tests/AppFeedbackCoreTests/SourceMetadataRoundtripTests.swift`

**Interfaces:**
- Consumes: `BodyMarker.sourceMetaOpen/Close` + `*Key` constants (Task 1); `ParsedFeedbackBody` widened fields (Task 2); `IssueBodyParser.parse(_:)`.
- Produces: `IssueBodyFormatter.sourceMetadataBlock(source:rating:reviewerNickname:territory:reviewId:reviewCreatedAt:fromAddress:messageId:) -> String`.

Steps:

- [ ] **Step 1: Write the failing round-trip test first.** Create `../AppFeedbackSDK/Tests/AppFeedbackCoreTests/SourceMetadataRoundtripTests.swift`:
```swift
import XCTest
@testable import AppFeedbackCore

/// The source-metadata block (`source-meta-v1`) is the contract that lets a
/// synthesized App Store / email issue carry its origin through GitHub and back.
/// These tests prove what `IssueBodyFormatter.sourceMetadataBlock` writes is
/// exactly what `IssueBodyParser` reads.
final class SourceMetadataRoundtripTests: XCTestCase {

    func test_app_store_metadata_roundtrips() {
        let block = IssueBodyFormatter.sourceMetadataBlock(
            source: "app-store",
            rating: 4,
            reviewerNickname: "Jane",
            territory: "USA",
            reviewId: "rv-123",
            reviewCreatedAt: "2026-06-18T10:00:00Z",
            fromAddress: nil,
            messageId: nil
        )
        let body = "Loved the new update!\n\n" + block
        let parsed = IssueBodyParser.parse(body)

        XCTAssertEqual(parsed.description, "Loved the new update!")
        XCTAssertEqual(parsed.source, "app-store")
        XCTAssertEqual(parsed.rating, 4)
        XCTAssertEqual(parsed.reviewerNickname, "Jane")
        XCTAssertEqual(parsed.territory, "USA")
        XCTAssertEqual(parsed.reviewId, "rv-123")
        XCTAssertEqual(parsed.reviewCreatedAt, "2026-06-18T10:00:00Z")
        XCTAssertNil(parsed.fromAddress)
        XCTAssertNil(parsed.messageId)
    }

    func test_email_metadata_roundtrips() {
        let block = IssueBodyFormatter.sourceMetadataBlock(
            source: "email",
            rating: nil,
            reviewerNickname: nil,
            territory: nil,
            reviewId: nil,
            reviewCreatedAt: nil,
            fromAddress: "user@example.com",
            messageId: "<abc@mail>"
        )
        let parsed = IssueBodyParser.parse("Hi there\n\n" + block)
        XCTAssertEqual(parsed.source, "email")
        XCTAssertEqual(parsed.fromAddress, "user@example.com")
        XCTAssertEqual(parsed.messageId, "<abc@mail>")
        XCTAssertNil(parsed.rating)
    }

    func test_absent_block_leaves_source_nil() {
        let parsed = IssueBodyParser.parse("Just a plain SDK body.\n\n---\n👍 Votes: 0")
        XCTAssertNil(parsed.source)
        XCTAssertNil(parsed.rating)
    }

    func test_block_survives_CRLF_normalization() {
        let block = IssueBodyFormatter.sourceMetadataBlock(
            source: "app-store", rating: 5, reviewerNickname: nil, territory: "GBR",
            reviewId: "r9", reviewCreatedAt: nil, fromAddress: nil, messageId: nil
        )
        let crlf = ("Body\n\n" + block).replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = IssueBodyParser.parse(crlf)
        XCTAssertEqual(parsed.source, "app-store")
        XCTAssertEqual(parsed.rating, 5)
        XCTAssertEqual(parsed.territory, "GBR")
        XCTAssertEqual(parsed.reviewId, "r9")
    }
}
```
- [ ] **Step 2: Run the SDK test target — expect FAIL (no `sourceMetadataBlock` symbol).** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD FAILED with "type 'IssueBodyFormatter' has no member 'sourceMetadataBlock'".
- [ ] **Step 3: Add the emitter to `IssueBodyFormatter`.** Before the closing brace of `public enum IssueBodyFormatter` (after the `labels(for:)` method, line 103), add:
```swift
    /// Renders the machine-readable `source-meta-v1` block that carries a
    /// synthesized issue's origin through GitHub and back into ``IssueBodyParser``.
    /// Emits one `key: value` line per non-nil field (always at least `source`).
    /// The block is HTML-comment-fenced so it's invisible in rendered Markdown.
    ///
    /// - Parameter source: the feedback source raw value ("sdk" | "app-store" | "email").
    public static func sourceMetadataBlock(
        source: String,
        rating: Int? = nil,
        reviewerNickname: String? = nil,
        territory: String? = nil,
        reviewId: String? = nil,
        reviewCreatedAt: String? = nil,
        fromAddress: String? = nil,
        messageId: String? = nil
    ) -> String {
        var lines = ["\(BodyMarker.sourceKey): \(source)"]
        if let rating { lines.append("\(BodyMarker.ratingKey): \(rating)") }
        if let reviewerNickname { lines.append("\(BodyMarker.reviewerNicknameKey): \(reviewerNickname)") }
        if let territory { lines.append("\(BodyMarker.territoryKey): \(territory)") }
        if let reviewId { lines.append("\(BodyMarker.reviewIdKey): \(reviewId)") }
        if let reviewCreatedAt { lines.append("\(BodyMarker.reviewCreatedAtKey): \(reviewCreatedAt)") }
        if let fromAddress { lines.append("\(BodyMarker.fromAddressKey): \(fromAddress)") }
        if let messageId { lines.append("\(BodyMarker.messageIdKey): \(messageId)") }
        return "\(BodyMarker.sourceMetaOpen)\n" + lines.joined(separator: "\n") + "\n\(BodyMarker.sourceMetaClose)"
    }
```
- [ ] **Step 4: Run the SDK round-trip test — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackCoreTests/SourceMetadataRoundtripTests 2>&1 | tail -25
```
Expected: all four tests PASS (` Test Suite 'SourceMetadataRoundtripTests' passed`). If the SDK package tests are not reachable from the app scheme, run instead from the package: `xcodebuild test -scheme AppFeedbackCore -destination 'platform=macOS' -only-testing:AppFeedbackCoreTests/SourceMetadataRoundtripTests` (resolve the correct SDK test scheme by `xcodebuild -list -project ../AppFeedbackSDK` first).
- [ ] **Step 5: Commit.** Stage only SDK files:
```
git add ../AppFeedbackSDK/Sources/AppFeedbackCore/IssueBodyFormatter.swift ../AppFeedbackSDK/Tests/AppFeedbackCoreTests/SourceMetadataRoundtripTests.swift
git commit -m "feat(sdk): emit source-meta-v1 block + formatter↔parser round-trip test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `FeedbackSource` enum (rawValue, display, symbol, label mapping)

**Files:**
- Create: `AppFeedback/Models/FeedbackSource.swift`
- Test: `AppFeedbackTests/FeedbackSourceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum FeedbackSource: String, Codable, CaseIterable, Sendable { case sdk = "sdk"; case appStore = "app-store"; case email = "email" }` with `var displayName: String`, `var systemImageName: String`, `var githubLabel: String?`, `static func from(label: String) -> FeedbackSource?`.

Steps:

- [ ] **Step 1: Write the failing test first.** Create `AppFeedbackTests/FeedbackSourceTests.swift`:
```swift
import XCTest
@testable import AppFeedback

final class FeedbackSourceTests: XCTestCase {
    func test_rawValues_match_contract() {
        XCTAssertEqual(FeedbackSource.sdk.rawValue, "sdk")
        XCTAssertEqual(FeedbackSource.appStore.rawValue, "app-store")
        XCTAssertEqual(FeedbackSource.email.rawValue, "email")
    }

    func test_allCases_order() {
        XCTAssertEqual(FeedbackSource.allCases, [.sdk, .appStore, .email])
    }

    func test_displayNames() {
        XCTAssertEqual(FeedbackSource.sdk.displayName, "SDK")
        XCTAssertEqual(FeedbackSource.appStore.displayName, "App Store")
        XCTAssertEqual(FeedbackSource.email.displayName, "Email")
    }

    func test_github_label_mapping() {
        XCTAssertNil(FeedbackSource.sdk.githubLabel)          // SDK is implicit; no label
        XCTAssertEqual(FeedbackSource.appStore.githubLabel, "source:app-store")
        XCTAssertEqual(FeedbackSource.email.githubLabel, "source:email")
    }

    func test_from_label() {
        XCTAssertEqual(FeedbackSource.from(label: "source:app-store"), .appStore)
        XCTAssertEqual(FeedbackSource.from(label: "source:email"), .email)
        XCTAssertNil(FeedbackSource.from(label: "rating:5"))
        XCTAssertNil(FeedbackSource.from(label: "user-submitted"))
    }

    func test_symbols_are_nonempty() {
        for source in FeedbackSource.allCases {
            XCTAssertFalse(source.systemImageName.isEmpty)
        }
    }
}
```
- [ ] **Step 2: Run — expect FAIL (no `FeedbackSource`).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/FeedbackSourceTests 2>&1 | tail -20
```
Expected: BUILD FAILED — "cannot find 'FeedbackSource' in scope".
- [ ] **Step 3: Create the enum.** Write `AppFeedback/Models/FeedbackSource.swift`:
```swift
import Foundation

/// The origin of a feedback item. Survives the GitHub round-trip via the
/// `source-meta-v1` body marker (raw value) and, for non-SDK sources, a
/// `source:<rawValue>` label. SDK is the implicit default for any issue our
/// adapters did not synthesize.
enum FeedbackSource: String, Codable, CaseIterable, Sendable {
    case sdk = "sdk"
    case appStore = "app-store"
    case email = "email"

    var displayName: String {
        switch self {
        case .sdk: return "SDK"
        case .appStore: return "App Store"
        case .email: return "Email"
        }
    }

    /// SF Symbol shown in the filter menu and (for SDK/Email) the row badge.
    var systemImageName: String {
        switch self {
        case .sdk: return "wrench.and.screwdriver.fill"
        case .appStore: return "apple.logo"
        case .email: return "envelope.fill"
        }
    }

    /// GitHub label string for this source, or nil for `.sdk` (SDK is implicit —
    /// the absence of a `source:*` label / `source` marker means SDK).
    var githubLabel: String? {
        switch self {
        case .sdk: return nil
        case .appStore: return "source:app-store"
        case .email: return "source:email"
        }
    }

    /// Resolves a `source:<rawValue>` GitHub label back to a source, or nil if
    /// the label is not a source label.
    static func from(label: String) -> FeedbackSource? {
        guard label.hasPrefix("source:") else { return nil }
        return FeedbackSource(rawValue: String(label.dropFirst("source:".count)))
    }
}
```
- [ ] **Step 4: Run — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/FeedbackSourceTests 2>&1 | tail -20
```
Expected: `Test Suite 'FeedbackSourceTests' passed`.
- [ ] **Step 5: Commit.** Stage only the two files (NOT a broad add — xcodegen will pick the new files up on next generate):
```
git add AppFeedback/Models/FeedbackSource.swift AppFeedbackTests/FeedbackSourceTests.swift
git commit -m "feat: add FeedbackSource enum (sdk/app-store/email) with label mapping

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `FeedbackIssue` gains `source` + `rating`

**Files:**
- Modify: `AppFeedback/Models/FeedbackIssue.swift`
- Test: covered by Task 7 (`SourceContractTests`); this task is a compile-only widening with default-safe init.

**Interfaces:**
- Consumes: `FeedbackSource` (Task 4).
- Produces: `FeedbackIssue.source: FeedbackSource` (default `.sdk`), `FeedbackIssue.rating: Int?` (default `nil`); the existing `init` signature widened with trailing defaulted params.

Steps:

- [ ] **Step 1: Add stored properties.** In `AppFeedback/Models/FeedbackIssue.swift`, after the `attachments` property (line 64), add:
```swift
    var source: FeedbackSource = .sdk
    var rating: Int?
```
(`FeedbackIssue` is a `struct` with a memberwise-shadowing custom `init`; adding defaulted vars keeps `Codable` synthesis working.)
- [ ] **Step 2: Widen the initializer.** In the `init(...)` parameter list, after `attachments: [FeedbackAttachmentRef] = []` (line 87), add two params:
```swift
        source: FeedbackSource = .sdk,
        rating: Int? = nil,
```
and in the body, after `self.attachments = attachments` (line 107), add:
```swift
        self.source = source
        self.rating = rating
```
- [ ] **Step 3: Build — expect SUCCESS.** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED (all existing call sites still compile — both new params are defaulted).
- [ ] **Step 4: Commit.** Stage only the one file:
```
git add AppFeedback/Models/FeedbackIssue.swift
git commit -m "feat: add source/rating to FeedbackIssue (defaults sdk/nil)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `CachedIssue` additive `source`/`rating` columns

**Files:**
- Modify: `AppFeedback/Models/CachedIssue.swift`
- Test: `AppFeedbackTests/SourceContractTests.swift` (created in Task 7; cache-round-trip assertions live there)

**Interfaces:**
- Consumes: `FeedbackSource` (Task 4); `FeedbackIssue.source/rating` (Task 5).
- Produces: `CachedIssue.source: String?`, `CachedIssue.rating: Int?`; `from(_:)`/`updateFromRemote(_:)` write them; `toFeedbackIssue()` maps `FeedbackSource(rawValue: source ?? "") ?? .sdk`.

Steps:

- [ ] **Step 1: Add stored properties.** In `AppFeedback/Models/CachedIssue.swift`, after `var attachmentsJSON: String?` (line 28), add:
```swift
    /// Originating feedback source raw value ("sdk" | "app-store" | "email");
    /// nil for legacy issues cached before Phase 1 — treated as `.sdk` on read.
    var source: String?
    /// App Store star rating (1…5) for App Store reviews; nil otherwise.
    var rating: Int?
```
(Both optional → additive to the existing local schema, no migration needed.)
- [ ] **Step 2: Map source/rating in `toFeedbackIssue()`.** In `toFeedbackIssue()`, change the `FeedbackIssue(...)` construction to pass the two new trailing params. After `attachments: Self.decodeAttachments(attachmentsJSON)` (line 82), add (before the closing `)`):
```swift
            ,
            source: FeedbackSource(rawValue: source ?? "") ?? .sdk,
            rating: rating
```
(Resulting call ends `...attachments: Self.decodeAttachments(attachmentsJSON), source: FeedbackSource(rawValue: source ?? "") ?? .sdk, rating: rating)`.)
- [ ] **Step 3: Persist in `from(_:)`.** In `static func from(_:repoOwner:repoName:)`, after `cached.attachmentsJSON = Self.encodeAttachments(issue.attachments)` (line 105), add:
```swift
        cached.source = issue.source.rawValue
        cached.rating = issue.rating
```
- [ ] **Step 4: Persist in `updateFromRemote(_:)`.** In `func updateFromRemote(_:)`, after `self.attachmentsJSON = Self.encodeAttachments(issue.attachments)` (line 125), add:
```swift
        self.source = issue.source.rawValue
        self.rating = issue.rating
```
- [ ] **Step 5: Build — expect SUCCESS.** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 6: Commit.** Stage only the one file:
```
git add AppFeedback/Models/CachedIssue.swift
git commit -m "feat: additive CachedIssue.source/rating columns (legacy nil ⇒ sdk)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: App-side `IssueBodyParser` shim carries `source`/`rating` + contract round-trip test

**Files:**
- Modify: `AppFeedback/Services/IssueBodyParser.swift`
- Test: `AppFeedbackTests/SourceContractTests.swift`

**Interfaces:**
- Consumes: SDK `ParsedFeedbackBody.source/rating/...` (Task 2); SDK `IssueBodyFormatter.sourceMetadataBlock` (Task 3); `FeedbackSource` (Task 4); `FeedbackIssue.source/rating` (Task 5); `CachedIssue` source/rating (Task 6).
- Produces: app `ParsedBody.source: String?`, `ParsedBody.rating: Int?`, `ParsedBody.reviewId: String?`, `ParsedBody.fromAddress: String?`, `ParsedBody.messageId: String?` (the carried marker values later phases read); shim maps SDK fields → app `ParsedBody`.

Steps:

- [ ] **Step 1: Write the failing contract test first.** Create `AppFeedbackTests/SourceContractTests.swift`:
```swift
import XCTest
import AppFeedbackCore
@testable import AppFeedback

final class SourceContractTests: XCTestCase {

    func test_shim_reads_app_store_source_and_rating() {
        let block = AppFeedbackCore.IssueBodyFormatter.sourceMetadataBlock(
            source: "app-store", rating: 3, reviewerNickname: "Sam", territory: "USA",
            reviewId: "rv-7", reviewCreatedAt: nil, fromAddress: nil, messageId: nil
        )
        let parsed = IssueBodyParser.parse("Great app\n\n" + block)
        XCTAssertEqual(parsed.source, "app-store")
        XCTAssertEqual(parsed.rating, 3)
        XCTAssertEqual(parsed.reviewId, "rv-7")
    }

    func test_shim_reads_email_source() {
        let block = AppFeedbackCore.IssueBodyFormatter.sourceMetadataBlock(
            source: "email", rating: nil, reviewerNickname: nil, territory: nil,
            reviewId: nil, reviewCreatedAt: nil, fromAddress: "a@b.com", messageId: "<m1>"
        )
        let parsed = IssueBodyParser.parse(block)
        XCTAssertEqual(parsed.source, "email")
        XCTAssertEqual(parsed.fromAddress, "a@b.com")
        XCTAssertEqual(parsed.messageId, "<m1>")
        XCTAssertNil(parsed.rating)
    }

    func test_legacy_body_has_nil_source() {
        let parsed = IssueBodyParser.parse("Plain SDK feedback.\n\n---\n👍 Votes: 0")
        XCTAssertNil(parsed.source)
        XCTAssertNil(parsed.rating)
    }

    func test_cachedIssue_roundtrips_source_rating() {
        let issue = FeedbackIssue(
            number: 1, title: "T", createdAt: Date(), rawBody: "b",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "d", labels: [], source: .appStore, rating: 5
        )
        let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
        XCTAssertEqual(cached.source, "app-store")
        XCTAssertEqual(cached.rating, 5)
        let back = cached.toFeedbackIssue()
        XCTAssertEqual(back.source, .appStore)
        XCTAssertEqual(back.rating, 5)
    }

    func test_cachedIssue_legacy_nil_source_maps_to_sdk() {
        let issue = FeedbackIssue(
            number: 2, title: "T", createdAt: Date(), rawBody: "b",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "d", labels: []
        )
        let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
        cached.source = nil          // simulate a legacy row cached before Phase 1
        cached.rating = nil
        XCTAssertEqual(cached.toFeedbackIssue().source, .sdk)
        XCTAssertNil(cached.toFeedbackIssue().rating)
    }
}
```
- [ ] **Step 2: Run — expect FAIL (`ParsedBody` has no `source`).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SourceContractTests 2>&1 | tail -25
```
Expected: BUILD FAILED — "value of type 'ParsedBody' has no member 'source'".
- [ ] **Step 3: Widen `ParsedBody` and the shim.** Replace the whole body of `AppFeedback/Services/IssueBodyParser.swift` below the `import` lines with:
```swift
struct ParsedBody: Sendable {
    var description: String = ""
    var app: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var attachments: [FeedbackAttachmentRef] = []
    /// Source-metadata marker values (`source-meta-v1` block). `source` is the
    /// raw value of the originating `FeedbackSource`; nil for legacy SDK issues.
    var source: String?
    var rating: Int?
    var reviewId: String?
    var fromAddress: String?
    var messageId: String?
}

/// Thin shim over `AppFeedbackCore.IssueBodyParser`. Adapts the SDK's field
/// names (`appName`) to this project's (`app`) so callers and tests don't have
/// to change. The SDK is the single source of truth for the parse logic — if
/// you find a body the inbox doesn't handle correctly, fix it in the SDK.
enum IssueBodyParser {
    static func parse(_ raw: String) -> ParsedBody {
        let p = AppFeedbackCore.IssueBodyParser.parse(raw)
        return ParsedBody(
            description: p.description,
            app: p.appName,
            appVersion: p.appVersion,
            device: p.device,
            osVersion: p.osVersion,
            email: p.email,
            attachments: p.attachments.map(FeedbackAttachmentRef.init),
            source: p.source,
            rating: p.rating,
            reviewId: p.reviewId,
            fromAddress: p.fromAddress,
            messageId: p.messageId
        )
    }
}
```
- [ ] **Step 4: Run — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SourceContractTests 2>&1 | tail -25
```
Expected: `Test Suite 'SourceContractTests' passed`.
- [ ] **Step 5: Commit.** Stage only the two files:
```
git add AppFeedback/Services/IssueBodyParser.swift AppFeedbackTests/SourceContractTests.swift
git commit -m "feat: thread source/rating through the IssueBodyParser shim + contract tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `IssueLoader` populates `FeedbackIssue.source`/`rating`

**Files:**
- Modify: `AppFeedback/Services/IssueLoader.swift`
- Test: `AppFeedbackTests/SourceContractTests.swift` (extend with a decode-path assertion)

**Interfaces:**
- Consumes: app `ParsedBody.source/rating` (Task 7); `FeedbackSource.from(label:)` (Task 4); `FeedbackIssue.source/rating` (Task 5); existing `IssueLoader` GraphQL `Node`/`Label` shapes.
- Produces: `decodePage` builds each `FeedbackIssue` with `source:` (marker first, then `source:*` label fallback, else `.sdk`) and `rating:` (marker first, then `rating:N` label fallback).

Steps:

- [ ] **Step 1: Add a failing assertion to `SourceContractTests`.** This proves the *resolution rule* (marker wins; label fallback; default `.sdk`) as a pure helper. Add to `AppFeedbackTests/SourceContractTests.swift`:
```swift
    func test_source_resolution_marker_wins_then_label_then_sdk() {
        // marker present
        XCTAssertEqual(
            IssueLoader.resolveSource(markerSource: "email", labels: ["source:app-store"]),
            .email
        )
        // no marker → label fallback
        XCTAssertEqual(
            IssueLoader.resolveSource(markerSource: nil, labels: ["source:app-store"]),
            .appStore
        )
        // neither → sdk
        XCTAssertEqual(IssueLoader.resolveSource(markerSource: nil, labels: ["bug"]), .sdk)
    }

    func test_rating_resolution_marker_wins_then_label() {
        XCTAssertEqual(IssueLoader.resolveRating(markerRating: 4, labels: ["rating:2"]), 4)
        XCTAssertEqual(IssueLoader.resolveRating(markerRating: nil, labels: ["rating:2"]), 2)
        XCTAssertNil(IssueLoader.resolveRating(markerRating: nil, labels: ["bug"]))
    }
```
- [ ] **Step 2: Run — expect FAIL (`IssueLoader.resolveSource` missing).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SourceContractTests 2>&1 | tail -25
```
Expected: BUILD FAILED — "type 'IssueLoader' has no member 'resolveSource'".
- [ ] **Step 3: Add the static resolvers to `IssueLoader`.** Add inside `IssueLoader` (near `decodePage`, e.g. just before `private static func decodePage` at line 256):
```swift
    /// Resolves a feedback source from the parsed `source` marker (authoritative)
    /// with a `source:*` GitHub label as fallback, defaulting to `.sdk`.
    static func resolveSource(markerSource: String?, labels: [String]) -> FeedbackSource {
        if let markerSource, let s = FeedbackSource(rawValue: markerSource) { return s }
        for label in labels {
            if let s = FeedbackSource.from(label: label) { return s }
        }
        return .sdk
    }

    /// Resolves a star rating from the parsed `rating` marker (authoritative)
    /// with a `rating:N` GitHub label as fallback; nil when neither is present.
    static func resolveRating(markerRating: Int?, labels: [String]) -> Int? {
        if let markerRating { return markerRating }
        for label in labels where label.hasPrefix("rating:") {
            if let n = Int(label.dropFirst("rating:".count)) { return n }
        }
        return nil
    }
```
- [ ] **Step 4: Wire the resolvers into `decodePage`.** In the `nodes` mapping (lines 266–288), the `labels` array is built at line 268. Pass the resolved values into the `FeedbackIssue(...)` initializer by appending two trailing arguments after `attachments: parsed.attachments` (line 286):
```swift
                attachments: parsed.attachments,
                source: IssueLoader.resolveSource(markerSource: parsed.source, labels: labels.map(\.name)),
                rating: IssueLoader.resolveRating(markerRating: parsed.rating, labels: labels.map(\.name))
```
(Replace the existing `attachments: parsed.attachments` line — which is the last argument — with the three lines above, keeping the closing `)`.)
- [ ] **Step 5: Run — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SourceContractTests 2>&1 | tail -25
```
Expected: `Test Suite 'SourceContractTests' passed`.
- [ ] **Step 6: Commit.** Stage only the two files:
```
git add AppFeedback/Services/IssueLoader.swift AppFeedbackTests/SourceContractTests.swift
git commit -m "feat: IssueLoader resolves source/rating (marker wins, label fallback, sdk default)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Source facet in `PersistedFeedbackFilters` (default all-on, `[String]` backing)

**Files:**
- Modify: `AppFeedback/Services/FilterPreferenceStore.swift`
- Test: `AppFeedbackTests/FilterPreferenceStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `FeedbackSource` (Task 4); existing `PersistedFeedbackFilters`, `FilterPreferenceStore.save/load`, `RepoFilterPreference`.
- Produces: `PersistedFeedbackFilters.sources: Set<FeedbackSource>` defaulting to `Set(FeedbackSource.allCases)`, Codable via a `[String]` backing so absent JSON keys decode to all-on.

Steps:

- [ ] **Step 1: Inspect the existing store test to mirror its style.** Run:
```
sed -n '1,60p' AppFeedbackTests/FilterPreferenceStoreTests.swift
```
Note the in-memory `ModelContainer` setup it uses (the store needs a `ModelContext`).
- [ ] **Step 2: Write the failing test first.** Append to `AppFeedbackTests/FilterPreferenceStoreTests.swift` (inside the existing test class — reuse its in-memory context helper; if it builds its container inline, mirror that exact setup):
```swift
    func test_feedback_sources_default_to_all_when_absent() throws {
        // A bundle encoded WITHOUT the sources field (legacy JSON) must decode to all-on.
        let legacyJSON = #"{"appVersion":[],"device":[],"osVersion":[],"issueType":[],"appFilter":[]}"#
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedFeedbackFilters.self, from: data)
        XCTAssertEqual(decoded.sources, Set(FeedbackSource.allCases))
    }

    func test_default_feedback_filters_have_all_sources() {
        XCTAssertEqual(PersistedFeedbackFilters().sources, Set(FeedbackSource.allCases))
    }

    func test_sources_roundtrip_through_codable() throws {
        var f = PersistedFeedbackFilters()
        f.sources = [.appStore]
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(PersistedFeedbackFilters.self, from: data)
        XCTAssertEqual(back.sources, [.appStore])
    }
```
- [ ] **Step 3: Run — expect FAIL (`sources` missing).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/FilterPreferenceStoreTests 2>&1 | tail -25
```
Expected: BUILD FAILED — "value of type 'PersistedFeedbackFilters' has no member 'sources'".
- [ ] **Step 4: Add `sources` with custom Codable defaulting.** Replace the `PersistedFeedbackFilters` struct (lines 16–22 of `FilterPreferenceStore.swift`) with:
```swift
struct PersistedFeedbackFilters: Codable, Equatable {
    var appVersion: Set<String> = []
    var device: Set<String> = []
    var osVersion: Set<String> = []
    var issueType: Set<IssueType> = []
    var appFilter: Set<String> = []
    /// Selected feedback sources. Default = all-on (every case). Persisted as a
    /// `[String]` of raw values so it stays CloudKit/JSON-friendly; an absent key
    /// in legacy JSON decodes back to all-on (so existing rows keep all sources).
    var sources: Set<FeedbackSource> = Set(FeedbackSource.allCases)

    enum CodingKeys: String, CodingKey {
        case appVersion, device, osVersion, issueType, appFilter, sources
    }

    init(
        appVersion: Set<String> = [],
        device: Set<String> = [],
        osVersion: Set<String> = [],
        issueType: Set<IssueType> = [],
        appFilter: Set<String> = [],
        sources: Set<FeedbackSource> = Set(FeedbackSource.allCases)
    ) {
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.issueType = issueType
        self.appFilter = appFilter
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decodeIfPresent(Set<String>.self, forKey: .appVersion) ?? []
        device = try c.decodeIfPresent(Set<String>.self, forKey: .device) ?? []
        osVersion = try c.decodeIfPresent(Set<String>.self, forKey: .osVersion) ?? []
        issueType = try c.decodeIfPresent(Set<IssueType>.self, forKey: .issueType) ?? []
        appFilter = try c.decodeIfPresent(Set<String>.self, forKey: .appFilter) ?? []
        let raw = try c.decodeIfPresent([String].self, forKey: .sources)
        if let raw {
            sources = Set(raw.compactMap(FeedbackSource.init(rawValue:)))
        } else {
            sources = Set(FeedbackSource.allCases)   // legacy JSON ⇒ all-on
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(device, forKey: .device)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(issueType, forKey: .issueType)
        try c.encode(appFilter, forKey: .appFilter)
        try c.encode(sources.map(\.rawValue).sorted(), forKey: .sources)
    }
}
```
- [ ] **Step 5: Run — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/FilterPreferenceStoreTests 2>&1 | tail -25
```
Expected: `Test Suite 'FilterPreferenceStoreTests' passed`.
- [ ] **Step 6: Commit.** Stage only the two files:
```
git add AppFeedback/Services/FilterPreferenceStore.swift AppFeedbackTests/FilterPreferenceStoreTests.swift
git commit -m "feat: persist Source filter facet (default all-on, legacy JSON ⇒ all-on)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `IssueListViewModel` Source filter (visibleIssues + persistence)

**Files:**
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift`
- Test: `AppFeedbackTests/IssueListViewModelTests.swift` (extend)

**Interfaces:**
- Consumes: `FeedbackSource` (Task 4); `FeedbackIssue.source` (Task 5); `PersistedFeedbackFilters.sources` (Task 9).
- Produces: `IssueListViewModel.ActiveFilters.sources: Set<FeedbackSource>` (default all cases); `visibleIssues` filters by it (skips filtering when all-on/empty); `uniqueSources: [FeedbackSource]`; `persistedFeedbackFilters.sources`/`applyFeedbackFilters` thread it; `ActiveFilters.isEmpty` treats all-on as "no source filter"; `clearFilters` resets sources to all cases.

Steps:

- [ ] **Step 1: Write the failing test first.** Append to `AppFeedbackTests/IssueListViewModelTests.swift` (mirror its existing `@MainActor` style and `FeedbackIssue` factory; if the file has a helper that builds `FeedbackIssue`, extend it with `source`):
```swift
    @MainActor
    func test_source_filter_narrows_visible_issues() {
        let vm = IssueListViewModel()
        let sdk = FeedbackIssue(number: 1, title: "a", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [], source: .sdk)
        let review = FeedbackIssue(number: 2, title: "b", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [], source: .appStore, rating: 5)
        vm.allIssues = [sdk, review]

        // Default all-on: both visible.
        XCTAssertEqual(Set(vm.visibleIssues.map(\.number)), [1, 2])

        // Narrow to App Store only.
        vm.filters.sources = [.appStore]
        XCTAssertEqual(vm.visibleIssues.map(\.number), [2])
    }

    @MainActor
    func test_source_filter_persists_and_applies() {
        let vm = IssueListViewModel()
        vm.filters.sources = [.email]
        XCTAssertEqual(vm.persistedFeedbackFilters.sources, [.email])

        let vm2 = IssueListViewModel()
        vm2.applyFeedbackFilters(PersistedFeedbackFilters(sources: [.appStore, .sdk]))
        XCTAssertEqual(vm2.filters.sources, [.appStore, .sdk])
    }

    @MainActor
    func test_clearFilters_restores_all_sources() {
        let vm = IssueListViewModel()
        vm.filters.sources = [.email]
        vm.clearFilters()
        XCTAssertEqual(vm.filters.sources, Set(FeedbackSource.allCases))
    }

    @MainActor
    func test_activeFilters_allOn_sources_is_empty() {
        var f = IssueListViewModel.ActiveFilters()
        XCTAssertTrue(f.isEmpty)                 // default all-on ⇒ no active source filter
        f.sources = [.appStore]
        XCTAssertFalse(f.isEmpty)
    }
```
- [ ] **Step 2: Run — expect FAIL (`ActiveFilters` has no `sources`).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests 2>&1 | tail -25
```
Expected: BUILD FAILED — "value of type 'IssueListViewModel.ActiveFilters' has no member 'sources'".
- [ ] **Step 3: Add `sources` to `ActiveFilters`.** Replace the `ActiveFilters` struct (lines 53–60 of `IssueListViewModel.swift`) with:
```swift
    struct ActiveFilters: Equatable {
        var appVersion: Set<String> = []
        var device: Set<String> = []
        var osVersion: Set<String> = []
        var issueType: Set<IssueType> = []
        /// Selected sources. Default = all-on. A full set (all cases) means "no
        /// source filter" — equivalent to empty for `isEmpty`/`visibleIssues`.
        var sources: Set<FeedbackSource> = Set(FeedbackSource.allCases)

        /// True when no facet is narrowing the list. Sources count as inactive
        /// when all-on (the default) so the row count / "Clear All" pill match
        /// the other facets' empty-means-all semantics.
        private var sourcesActive: Bool {
            !sources.isEmpty && sources != Set(FeedbackSource.allCases)
        }

        var isEmpty: Bool {
            appVersion.isEmpty && device.isEmpty && osVersion.isEmpty
                && issueType.isEmpty && !sourcesActive
        }
    }
```
- [ ] **Step 4: Filter `visibleIssues` by source.** In `visibleIssues`, after the `filters.issueType` line (line 77), add:
```swift
        if !filters.sources.isEmpty && filters.sources != Set(FeedbackSource.allCases) {
            list = list.filter { filters.sources.contains($0.source) }
        }
```
- [ ] **Step 5: Add `uniqueSources` derived list.** After `uniqueVersions` (line 108), add:
```swift
    /// Distinct sources present among the visible issues, in canonical case order.
    var uniqueSources: [FeedbackSource] {
        let present = Set(visibleBase.map(\.source))
        return FeedbackSource.allCases.filter { present.contains($0) }
    }
```
- [ ] **Step 6: Reset sources in `clearFilters`.** `clearFilters()` already does `filters = ActiveFilters()` (line 117) — since the new default is all-on, this restores all sources automatically. No change needed; verify by reading the method.
- [ ] **Step 7: Thread sources through persistence.** Update `persistedFeedbackFilters` (lines 121–125) to pass `sources: filters.sources`:
```swift
    var persistedFeedbackFilters: PersistedFeedbackFilters {
        PersistedFeedbackFilters(appVersion: filters.appVersion, device: filters.device,
                                 osVersion: filters.osVersion, issueType: filters.issueType,
                                 appFilter: appFilter, sources: filters.sources)
    }
```
and `applyFeedbackFilters(_:)` (lines 127–133) to add:
```swift
        filters.sources = dto.sources
```
(after `appFilter = dto.appFilter`).
- [ ] **Step 8: Run — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests 2>&1 | tail -25
```
Expected: `Test Suite 'IssueListViewModelTests' passed`.
- [ ] **Step 9: Commit.** Stage only the two files:
```
git add AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat: Source filter facet in IssueListViewModel (default all-on)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Source chip in `FilterBarView`

**Files:**
- Modify: `AppFeedback/Views/Issues/FilterBarView.swift`
- Test: build/compile-check; logic already covered by Task 10 (`uniqueSources`, `filters.sources`).

**Interfaces:**
- Consumes: `IssueListViewModel.uniqueSources` + `filters.sources` (Task 10); `MultiSelectFilterChip<FeedbackSource>` (existing generic); `FeedbackSource.displayName/systemImageName` (Task 4).
- Produces: a "Source" chip in the feedback filter bar (renders only when `uniqueSources.count > 1`).

Steps:

- [ ] **Step 1: Add the Source chip.** In `FilterBarView.body`, after the "OS" `MultiSelectFilterChip` (lines 44–50) and before the `if hasAnyActiveFilter` block (line 52), add:
```swift
                if viewModel.uniqueSources.count > 1 {
                    MultiSelectFilterChip(
                        label: "Source",
                        values: viewModel.uniqueSources,
                        selection: Binding(
                            get: {
                                // All-on (the persisted default) reads as "none selected"
                                // so the chip shows "All" instead of every pill.
                                viewModel.filters.sources == Set(FeedbackSource.allCases)
                                    ? []
                                    : viewModel.filters.sources
                            },
                            set: { newValue in
                                viewModel.filters.sources = newValue.isEmpty
                                    ? Set(FeedbackSource.allCases)
                                    : newValue
                            }
                        ),
                        display: { $0.displayName },
                        symbol: { $0.systemImageName },
                        accent: accent
                    )
                }
```
- [ ] **Step 2: Confirm `hasAnyActiveFilter` reflects sources.** `hasAnyActiveFilter` (line 62) is `!viewModel.appFilter.isEmpty || !viewModel.filters.isEmpty`. Since `ActiveFilters.isEmpty` now treats all-on sources as empty and a narrowed source set as non-empty (Task 10 Step 3), the "Clear All" pill appears correctly. No change needed; read the property to confirm.
- [ ] **Step 3: Build — expect SUCCESS.** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Commit.** Stage only the one file:
```
git add AppFeedback/Views/Issues/FilterBarView.swift
git commit -m "feat: Source filter chip in the feedback filter bar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: `SourceBadgeView` + pure descriptor helper (with star rating)

**Files:**
- Create: `AppFeedback/Views/Issues/SourceBadgeView.swift`
- Test: `AppFeedbackTests/SourceBadgeViewTests.swift`

**Interfaces:**
- Consumes: `FeedbackSource` (Task 4); `FeedbackIssue.source/rating` (Task 5).
- Produces: `struct SourceBadgeView: View { let source: FeedbackSource; let rating: Int? }`; pure helper `enum SourceBadge { static func filledStars(rating: Int?) -> Int; static func showsStars(source: FeedbackSource, rating: Int?) -> Bool }`.

Steps:

- [ ] **Step 1: Write the failing test first.** Create `AppFeedbackTests/SourceBadgeViewTests.swift`:
```swift
import XCTest
@testable import AppFeedback

final class SourceBadgeViewTests: XCTestCase {
    func test_app_store_with_rating_shows_stars() {
        XCTAssertTrue(SourceBadge.showsStars(source: .appStore, rating: 3))
        XCTAssertEqual(SourceBadge.filledStars(rating: 3), 3)
    }

    func test_rating_is_clamped_1_to_5() {
        XCTAssertEqual(SourceBadge.filledStars(rating: 0), 0)
        XCTAssertEqual(SourceBadge.filledStars(rating: 7), 5)
        XCTAssertEqual(SourceBadge.filledStars(rating: nil), 0)
    }

    func test_app_store_without_rating_hides_stars() {
        XCTAssertFalse(SourceBadge.showsStars(source: .appStore, rating: nil))
    }

    func test_non_app_store_never_shows_stars() {
        XCTAssertFalse(SourceBadge.showsStars(source: .sdk, rating: 5))
        XCTAssertFalse(SourceBadge.showsStars(source: .email, rating: 5))
    }
}
```
- [ ] **Step 2: Run — expect FAIL (`SourceBadge` missing).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SourceBadgeViewTests 2>&1 | tail -25
```
Expected: BUILD FAILED — "cannot find 'SourceBadge' in scope".
- [ ] **Step 3: Create the view + helper.** Write `AppFeedback/Views/Issues/SourceBadgeView.swift`:
```swift
import SwiftUI

/// Pure presentation rules for the source badge — extracted so they're unit-testable
/// without rendering SwiftUI (which isn't unit-testable in this target).
enum SourceBadge {
    /// Number of filled stars to draw (App Store ratings are 1…5, clamped).
    static func filledStars(rating: Int?) -> Int {
        guard let rating else { return 0 }
        return max(0, min(5, rating))
    }

    /// Stars are shown only for App Store items that carry a rating.
    static func showsStars(source: FeedbackSource, rating: Int?) -> Bool {
        source == .appStore && rating != nil
    }
}

/// Leading badge on a feedback row showing its source: App Store (Apple mark + an
/// inline 5-star rating), Email (envelope), or SDK (wrench). Derived purely from
/// `FeedbackIssue.source`/`rating`; falls back to SDK when source is `.sdk`.
struct SourceBadgeView: View {
    let source: FeedbackSource
    let rating: Int?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.systemImageName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(source.displayName)
            if SourceBadge.showsStars(source: source, rating: rating) {
                starRow
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }

    private var starRow: some View {
        let filled = SourceBadge.filledStars(rating: rating)
        return HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < filled ? "star.fill" : "star")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(index < filled ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
        }
        .accessibilityLabel("\(filled) of 5 stars")
    }
}
```
- [ ] **Step 4: Run — expect PASS.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SourceBadgeViewTests 2>&1 | tail -25
```
Expected: `Test Suite 'SourceBadgeViewTests' passed`.
- [ ] **Step 5: Commit.** Stage only the two files:
```
git add AppFeedback/Views/Issues/SourceBadgeView.swift AppFeedbackTests/SourceBadgeViewTests.swift
git commit -m "feat: SourceBadgeView (Apple mark + inline stars / envelope / SDK glyph)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Render `SourceBadgeView` in the feedback row

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`
- Test: build/compile-check (view rendering isn't unit-testable here; badge logic is covered by Task 12).

**Interfaces:**
- Consumes: `SourceBadgeView` (Task 12); `FeedbackIssue.source/rating` (Task 5).
- Produces: a leading source badge on the card's title row.

Steps:

- [ ] **Step 1: Add the badge to the title row.** In `IssueCardView.body`, the title row is the `HStack(alignment: .top, spacing: 12)` at line 232. Insert the badge as the leading element of that HStack, before the `if !titleText.isEmpty` block (between line 232 and line 233):
```swift
                        SourceBadgeView(source: issue.source, rating: issue.rating)
                            .fixedSize()
```
(Resulting order inside the HStack: source badge, then the title text / spacer, then `metaColumn`.)
- [ ] **Step 2: Build — expect SUCCESS.** Run:
```
xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Build iOS too (badge uses no platform-specific API but verify the floor).** Run:
```
xcodebuild -scheme AppFeedback_iOS -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Commit.** Stage only the one file:
```
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat: show source badge leading the feedback row title

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Full-suite regression gate

**Files:**
- Test: entire `AppFeedbackTests_macOS` suite (no source changes).

**Interfaces:**
- Consumes: everything from Tasks 1–13.
- Produces: confidence that only the known ~11 Keychain/GitHubAccount pre-existing failures remain.

Steps:

- [ ] **Step 1: Run the full macOS test suite via xcodebuild (ground truth).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: only the pre-existing failures in `KeychainServicePerAccountTests` + `GitHubAccountStoreTests` (~11). All Phase-1 suites (`FeedbackSourceTests`, `SourceContractTests`, `SourceBadgeViewTests`, `FilterPreferenceStoreTests`, `IssueListViewModelTests`, plus SDK `SourceMetadataRoundtripTests`) PASS. No new failures.
- [ ] **Step 2: If any NON-Keychain suite fails, debug before proceeding.** Re-run only the failing suite with `-only-testing:AppFeedbackTests_macOS/<SuiteName>` and fix; do NOT touch the Keychain/GitHubAccount suites.
- [ ] **Step 3: No commit (verification-only task).** If a fix was required in Step 2, commit it narrowly with the co-author trailer, staging only the touched file(s).
