# Phase 2 — Product Settings (master-detail tab + sidebar Settings…) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `repos` settings tab to `products`, rework it into a master-detail Product Settings screen (product list ▸ `ProductSettingsView` detail) on both macOS and iOS, add a "Settings…" item to the sidebar product context menu that opens the same detail, and scaffold the App Store / Email source sub-forms as compiling placeholders that Phases 3 & 5 fill in.

**Architecture:** A shared `SettingsTab.products` case drives the macOS NSToolbar settings window and the iOS settings sheet. `ProductSettingsView` (evolved from `AddEditRepoView`) renders a **General** section (GitHub connection + mirror/redact toggles) and a **Sources** section listing SDK (always-on, informational), App Store (Off/Configured → `AppStoreSourceForm` stub), and Email (Off/Configured → `EmailSourceForm` stub). Product selection is held in `SettingsNavigation.selectedProductID` so the macOS Settings window (a standalone `Window` scene) and the sidebar "Settings…" item both focus the same product; iOS presents the detail in a `NavigationStack`/sheet.

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

## Scope notes (read before starting)

This phase **consumes** the Phase 0 rename (`Repo`→`Product`, `RepoConfig`→`ProductConfig`, `RepoStore`→`ProductStore` with the four new source fields). Phase 0 ships before this phase, so by the time these tasks run, the codebase already uses `ProductStore`/`ProductConfig`/`Product`. All code below references `ProductStore`/`ProductConfig` — never `RepoStore`/`RepoConfig`. The signatures consumed from Phase 0 are listed under each task's **Interfaces → Consumes**.

This phase **scaffolds but does not implement** the App Store and Email source sub-forms. `AppStoreSourceForm` and `EmailSourceForm` are created as compiling placeholder views that render a short "configured in a later update" notice plus an Off/Configured status derived from the consumed `ProductConfig` fields. Their actual credential fields, file/Files pickers, and **Test** buttons belong to **Phase 3** (App Store) and **Phase 5** (Email) respectively — each task that touches them says so explicitly. The "enable/disable / Remove" controls in those forms are also deferred to Phases 3 & 5; this phase only wires the **navigation entry points** and the status rows.

The add-flow stays minimal: the existing "+" / "Add Repository" path (now "Add Product") is preserved verbatim except for label/type renames; sources are configured afterward inside `ProductSettingsView`.

---

## File Structure

### Create
- `AppFeedback/Views/Settings/ProductSettingsView.swift` — the master-detail **detail** pane: General section (GitHub connection + mirror/redact) and Sources section (SDK / App Store / Email rows), evolved from `AddEditRepoView`.
- `AppFeedback/Views/Settings/ProductsSettingsTab.swift` — the master-detail **container** for the macOS `.products` tab (product list sidebar + `ProductSettingsView` detail bound to `SettingsNavigation.selectedProductID`).
- `AppFeedback/Views/Settings/Sources/SourceStatus.swift` — pure helper enum `SourceStatus { case off, configured }` + a `ProductConfig`→status mapper for App Store and Email; the unit-testable core of the Sources rows.
- `AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift` — **stub** form (compiling placeholder; Phase 3 fills in fields/Test).
- `AppFeedback/Views/Settings/Sources/EmailSourceForm.swift` — **stub** form (compiling placeholder; Phase 5 fills in fields/Test).
- `AppFeedbackTests/SourceStatusTests.swift` — logic tests for `SourceStatus` mapping.
- `AppFeedbackTests/SettingsNavigationTests.swift` — logic tests for `SettingsNavigation` product-selection state + tab defaults.
- `AppFeedbackTests/ProductContextMenuTests.swift` — logic test that the sidebar context-menu model exposes a "Settings…" action.

### Modify
- `AppFeedback/Views/Settings/SettingsView.swift` — rename `SettingsTab.repos`→`.products`, default tab, `tabContent()` arm, swap the repos tab body for `ProductsSettingsTab` (macOS) and rework the iOS products section to push `ProductSettingsView`; rename `editTarget`/labels.
- `AppFeedback/Views/Settings/SettingsTabBar.swift` — `allTabIdentifiers()` uses `.products`; `displayName`/`systemImageName` add the `.products` case ("Products" / "shippingbox").
- `AppFeedback/Views/Sidebar/RepoSectionView.swift` — add a leading **Settings…** item to the context menu (macOS right-click / iOS long-press) that focuses/opens `ProductSettingsView` for this product; surface an `onOpenSettings` closure + (iOS) a presented sheet.
- `AppFeedback/Views/Sidebar/SidebarView.swift` — thread an `onOpenProductSettings: (UUID) -> Void` callback down to each `RepoSectionView`.
- `AppFeedback/App/RootView.swift` — provide `onOpenProductSettings` to `SidebarView`: on macOS set `SettingsNavigation.selectedProductID` + `selectedTab = .products` then `openWindow(id: "settings")`; on iOS present a `ProductSettingsView` sheet.

---

## Tasks

### Task 1: Rename `SettingsTab.repos` → `.products` (enum + default + macOS toolbar identifiers/labels)

**Files:**
- Modify `AppFeedback/Views/Settings/SettingsView.swift:6` (enum) and `:15` (default)
- Modify `AppFeedback/Views/Settings/SettingsTabBar.swift:93` (`allTabIdentifiers`), `:146` (`displayName`), `:156` (`systemImageName`)
- Test `AppFeedbackTests/SettingsNavigationTests.swift`

**Interfaces:**
- Consumes: none new.
- Produces: `enum SettingsTab { case products; case email; case intelligence; case notifications }`, `SettingsNavigation.selectedTab: SettingsTab = .products`.

- [ ] **Step 1: Write the failing test for the enum case + default.** Create `AppFeedbackTests/SettingsNavigationTests.swift`:
```swift
import XCTest
@testable import AppFeedback

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func test_defaultTab_isProducts() {
        let nav = SettingsNavigation()
        XCTAssertEqual(nav.selectedTab, .products)
    }

    func test_settingsTab_hasProductsCase_notRepos() {
        // .products replaces the old .repos; rawValue stays "products".
        XCTAssertEqual(SettingsTab(rawValue: "products"), .products)
        XCTAssertNil(SettingsTab(rawValue: "repos"))
    }
}
```
- [ ] **Step 2: Run the test (expect FAIL — `.products` does not exist).** zcode: build the `AppFeedbackTests_macOS` test target and run `SettingsNavigationTests`. Expect a compile failure (`type 'SettingsTab' has no member 'products'`).
- [ ] **Step 3: Rename the enum case.** In `AppFeedback/Views/Settings/SettingsView.swift`, change the enum at line 6:
```swift
enum SettingsTab: String, Hashable, CaseIterable {
    case products
    case email
    case intelligence
    case notifications
}
```
- [ ] **Step 4: Update the default selected tab.** In the same file, change `SettingsNavigation`:
```swift
@Observable
final class SettingsNavigation {
    var selectedTab: SettingsTab = .products
}
```
- [ ] **Step 5: Update the macOS toolbar identifier list.** In `AppFeedback/Views/Settings/SettingsTabBar.swift`, change `allTabIdentifiers()` (line ~92) so the first identifier is `.products`:
```swift
private func allTabIdentifiers() -> [NSToolbarItem.Identifier] {
    var ids: [NSToolbarItem.Identifier] = [
        identifier(for: .products),
        identifier(for: .email),
        identifier(for: .intelligence),
    ]
    if parent.hasNotifications {
        ids.append(identifier(for: .notifications))
    }
    return ids
}
```
- [ ] **Step 6: Update the toolbar label + symbol.** In `AppFeedback/Views/Settings/SettingsTabBar.swift`, change the `private extension SettingsTab` (lines ~145-163):
```swift
private extension SettingsTab {
    var displayName: String {
        switch self {
        case .products:      return "Products"
        case .email:         return "Email"
        case .intelligence:  return "Intelligence"
        case .notifications: return "Notifications"
        }
    }

    var systemImageName: String {
        switch self {
        case .products:      return "shippingbox"
        case .email:         return "envelope"
        case .intelligence:  return "sparkles"
        case .notifications: return "bell"
        }
    }
}
```
- [ ] **Step 7: Fix the `tabContent()` switch arm name (temporary, keeps it compiling).** In `SettingsView.swift` `tabContent(selection:)` (line ~67), rename `case .repos:` to `case .products:` (its body still calls `reposTab` for now — replaced in Task 5):
```swift
        switch selection {
        case .products:
            reposTab
        case .email:
```
- [ ] **Step 8: Run the test (expect PASS).** zcode: run `SettingsNavigationTests`. Both tests pass; the macOS build still compiles (`reposTab` still exists).
- [ ] **Step 9: Commit.**
```
git add AppFeedback/Views/Settings/SettingsView.swift AppFeedback/Views/Settings/SettingsTabBar.swift AppFeedbackTests/SettingsNavigationTests.swift
git commit -m "feat(settings): rename repos tab to products (enum + macOS toolbar)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `SettingsNavigation.selectedProductID` for cross-window product focus

**Files:**
- Modify `AppFeedback/Views/Settings/SettingsView.swift:13` (the `SettingsNavigation` class)
- Test `AppFeedbackTests/SettingsNavigationTests.swift`

**Interfaces:**
- Consumes: `enum SettingsTab` (Task 1).
- Produces: `SettingsNavigation.selectedProductID: UUID?`; `SettingsNavigation.focus(productID:)` which sets both `selectedTab = .products` and `selectedProductID`.

- [ ] **Step 1: Write the failing test.** Append to `AppFeedbackTests/SettingsNavigationTests.swift`:
```swift
extension SettingsNavigationTests {
    func test_focus_setsTabAndProduct() {
        let nav = SettingsNavigation()
        let id = UUID()
        nav.selectedTab = .email          // start elsewhere
        nav.focus(productID: id)
        XCTAssertEqual(nav.selectedTab, .products)
        XCTAssertEqual(nav.selectedProductID, id)
    }

    func test_selectedProductID_defaultsNil() {
        XCTAssertNil(SettingsNavigation().selectedProductID)
    }
}
```
- [ ] **Step 2: Run the test (expect FAIL — `focus`/`selectedProductID` missing).** zcode: run `SettingsNavigationTests`. Expect compile failure.
- [ ] **Step 3: Extend `SettingsNavigation`.** In `AppFeedback/Views/Settings/SettingsView.swift`:
```swift
@Observable
final class SettingsNavigation {
    var selectedTab: SettingsTab = .products
    /// The product whose detail the Products tab should focus. nil ⇒ no/first selection.
    var selectedProductID: UUID?

    /// Focus the Products tab on a specific product (used by the sidebar "Settings…" item
    /// and the macOS Settings window, which share this object via the environment).
    func focus(productID: UUID) {
        selectedTab = .products
        selectedProductID = productID
    }
}
```
- [ ] **Step 4: Run the test (expect PASS).** zcode: run `SettingsNavigationTests` — all four tests pass.
- [ ] **Step 5: Commit.**
```
git add AppFeedback/Views/Settings/SettingsView.swift AppFeedbackTests/SettingsNavigationTests.swift
git commit -m "feat(settings): SettingsNavigation gains selectedProductID + focus(productID:)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `SourceStatus` helper (pure, testable Off/Configured mapping)

**Files:**
- Create `AppFeedback/Views/Settings/Sources/SourceStatus.swift`
- Test `AppFeedbackTests/SourceStatusTests.swift`

**Interfaces:**
- Consumes (Phase 0 / Shared Contracts) — `ProductConfig` with: `var appStoreIssuerID: String?`, `var appStoreKeyID: String?`, `var appStoreAppAppleID: String?`, `var feedbackInboxAccountID: UUID?`.
- Produces: `enum SourceStatus: Equatable { case off; case configured }`; `extension ProductConfig { var appStoreSourceStatus: SourceStatus; var emailSourceStatus: SourceStatus }`.

- [ ] **Step 1: Write the failing test.** Create `AppFeedbackTests/SourceStatusTests.swift`:
```swift
import XCTest
@testable import AppFeedback

final class SourceStatusTests: XCTestCase {
    private func config(
        appStoreAppAppleID: String? = nil,
        feedbackInboxAccountID: UUID? = nil
    ) -> ProductConfig {
        ProductConfig(
            displayName: "T", owner: "o", repo: "r",
            appStoreIssuerID: nil, appStoreKeyID: nil,
            appStoreAppAppleID: appStoreAppAppleID,
            feedbackInboxAccountID: feedbackInboxAccountID
        )
    }

    func test_appStore_off_whenAppAppleIDNil() {
        XCTAssertEqual(config().appStoreSourceStatus, .off)
    }

    func test_appStore_configured_whenAppAppleIDSet() {
        XCTAssertEqual(config(appStoreAppAppleID: "123456").appStoreSourceStatus, .configured)
    }

    func test_email_off_whenInboxAccountNil() {
        XCTAssertEqual(config().emailSourceStatus, .off)
    }

    func test_email_configured_whenInboxAccountSet() {
        XCTAssertEqual(config(feedbackInboxAccountID: UUID()).emailSourceStatus, .configured)
    }
}
```
> NOTE: this test pins the exact `ProductConfig` initializer Phase 0 produces (the four new fields are trailing args). If Phase 0's initializer signature differs, fix the call site here to match Phase 0 — do NOT change the field names, which are fixed by the Shared Contracts.
- [ ] **Step 2: Run the test (expect FAIL — `SourceStatus` / the computed properties don't exist).** zcode: run `SourceStatusTests`. Expect compile failure.
- [ ] **Step 3: Create the helper.** Create `AppFeedback/Views/Settings/Sources/SourceStatus.swift`:
```swift
import Foundation

/// Whether a per-product feedback source is configured. Derived purely from the
/// `ProductConfig` (which carries the App-Store ids and the feedback-inbox account id);
/// secrets (the .p8, the IMAP password) live in the Keychain and are not consulted here.
enum SourceStatus: Equatable {
    case off
    case configured
}

extension ProductConfig {
    /// App Store source is "configured" once an ASC app id is selected.
    /// (Issuer/Key id + the .p8 are gathered first, but the app id is the gate per the spec:
    /// `appStoreAppAppleID == nil ⇒ source off`.)
    var appStoreSourceStatus: SourceStatus {
        (appStoreAppAppleID?.isEmpty == false) ? .configured : .off
    }

    /// Email source is "configured" once a dedicated feedback-inbox MailAccount is linked.
    var emailSourceStatus: SourceStatus {
        feedbackInboxAccountID != nil ? .configured : .off
    }
}
```
- [ ] **Step 4: Run the test (expect PASS).** zcode: run `SourceStatusTests` — all four pass.
- [ ] **Step 5: Commit.**
```
git add AppFeedback/Views/Settings/Sources/SourceStatus.swift AppFeedbackTests/SourceStatusTests.swift
git commit -m "feat(settings): SourceStatus helper mapping ProductConfig to Off/Configured

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Scaffold `AppStoreSourceForm` and `EmailSourceForm` (compiling placeholders)

**Files:**
- Create `AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift`
- Create `AppFeedback/Views/Settings/Sources/EmailSourceForm.swift`

**Interfaces:**
- Consumes: `ProductConfig` (Phase 0); `SourceStatus` + `appStoreSourceStatus`/`emailSourceStatus` (Task 3); `@Observable final class ProductStore` (Phase 0).
- Produces: `struct AppStoreSourceForm: View { init(store: ProductStore, product: ProductConfig) }`, `struct EmailSourceForm: View { init(store: ProductStore, product: ProductConfig) }` — the navigation destinations the Sources rows push to. **Credential fields + Test belong to Phase 3 (App Store) / Phase 5 (Email); these are deliberately empty placeholders.**

- [ ] **Step 1: Create the App Store stub.** Create `AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift`:
```swift
import SwiftUI

/// SCAFFOLD (Phase 2). The real App Store Connect setup form — paste Issuer ID + Key ID,
/// import the .p8, "Test", app picker — is implemented in **Phase 3**. This placeholder only
/// establishes the navigation destination + the Off/Configured status surface so the Sources
/// section in `ProductSettingsView` compiles and routes here today.
struct AppStoreSourceForm: View {
    let store: ProductStore
    let product: ProductConfig

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(product.appStoreSourceStatus == .configured ? "Configured" : "Off")
                        .foregroundStyle(.secondary)
                }
                if product.appStoreSourceStatus == .configured,
                   let appID = product.appStoreAppAppleID {
                    LabeledContent("App ID") { Text(appID).foregroundStyle(.secondary) }
                }
            } header: {
                Text("App Store Reviews")
            } footer: {
                Text("App Store Connect setup (Issuer ID, Key ID, .p8 key, app selection) arrives in a later update.")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("App Store")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
```
- [ ] **Step 2: Create the Email stub.** Create `AppFeedback/Views/Settings/Sources/EmailSourceForm.swift`:
```swift
import SwiftUI

/// SCAFFOLD (Phase 2). The real feedback-inbox setup form — IMAP host/port/user/password +
/// Preset, "Test Connection", linking a MailAccount with feedbackProductID — is implemented in
/// **Phase 5**. This placeholder only establishes the navigation destination + the Off/Configured
/// status surface so the Sources section in `ProductSettingsView` compiles and routes here today.
struct EmailSourceForm: View {
    let store: ProductStore
    let product: ProductConfig

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(product.emailSourceStatus == .configured ? "Configured" : "Off")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Email Feedback Inbox")
            } footer: {
                Text("A dedicated IMAP feedback inbox (host, credentials, Test Connection) arrives in a later update.")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
```
- [ ] **Step 3: Build check (both platforms).** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS (no test yet — these are pure SwiftUI stubs gated only by the build; they consume only Task-3 + Phase-0 signatures).
- [ ] **Step 4: Commit.**
```
git add AppFeedback/Views/Settings/Sources/AppStoreSourceForm.swift AppFeedback/Views/Settings/Sources/EmailSourceForm.swift
git commit -m "feat(settings): scaffold AppStoreSourceForm + EmailSourceForm placeholders

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Build `ProductSettingsView` (General + Sources sections, both platforms)

**Files:**
- Create `AppFeedback/Views/Settings/ProductSettingsView.swift`
- Test `AppFeedbackTests/SourceStatusTests.swift` (reuse — no new logic surface beyond Task 3; this task is a SwiftUI view gated on a build + the existing `SourceStatusTests`)

**Interfaces:**
- Consumes: `@Observable final class ProductStore` with `repos: [ProductConfig]` (Phase-0 rename keeps the published array name `repos`; if Phase 0 renamed it to `products`, use that — confirm against the shipped `ProductStore`), `func update(_:)`; `ProductConfig` (Phase 0) incl. `displayName`, `owner`, `repo`, `mirrorEmailsToGitHub`, `redactEmailAddresses`, `colorHex`; `KeychainService.load(for: ProductConfig) async -> String?` and `KeychainService.save(token:for: ProductConfig) async`; `SourceStatus` + `appStoreSourceStatus`/`emailSourceStatus` (Task 3); `AppStoreSourceForm(store:product:)` / `EmailSourceForm(store:product:)` (Task 4).
- Produces: `struct ProductSettingsView: View { init(store: ProductStore, product: ProductConfig, embedInNavigation: Bool = false) }`.

> NOTE on `ProductStore.repos`: Phase 0 renames the type but the Shared Contracts do **not** rename the published array. Read the shipped `ProductStore` before this task; the existing `RepoStore` exposes `repos: [RepoConfig]`. Use whatever array name Phase 0 actually ships. All snippets below assume `store.products` is NOT introduced and the array stays `repos`; if Phase 0 renamed it, do a find-and-replace of `store.repos`→`store.products` in this file only.

- [ ] **Step 1: Create the view skeleton + General section.** Create `AppFeedback/Views/Settings/ProductSettingsView.swift`:
```swift
import SwiftUI

/// The detail pane of the Products settings tab (and the sheet opened from the sidebar
/// "Settings…" item). Evolved from `AddEditRepoView`: a **General** section (GitHub connection +
/// mirror/redact toggles) and a **Sources** section (SDK / App Store / Email).
struct ProductSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var store: ProductStore
    var product: ProductConfig
    var embedInNavigation: Bool = false

    @State private var displayName = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var token = ""
    @State private var mirrorEmailsToGitHub = true
    @State private var redactEmailAddresses = true
    @State private var isSaving = false

    var body: some View {
        platformContent
            .task { await populateFromExisting() }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(iOS)
        if embedInNavigation {
            NavigationStack { form }
        } else {
            form
        }
        #else
        form
        #endif
    }

    private var form: some View {
        Form {
            generalSection
            sourcesSection
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(displayName.isEmpty ? "Product" : displayName)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func populateFromExisting() async {
        displayName = product.displayName
        owner = product.owner
        repo = product.repo
        mirrorEmailsToGitHub = product.mirrorEmailsToGitHub
        redactEmailAddresses = product.redactEmailAddresses
        token = await KeychainService.load(for: product) ?? ""
    }
}
```
- [ ] **Step 2: Add the General section.** Append inside `ProductSettingsView` (before `body`'s `platformContent` is fine; add as a computed property):
```swift
    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            TextField("Display Name", text: $displayName)
            LabeledContent("Repository") {
                Text("\(owner)/\(repo)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            Toggle("Mirror emails to issue comments", isOn: $mirrorEmailsToGitHub)
            if mirrorEmailsToGitHub {
                Toggle("Redact sender email addresses", isOn: $redactEmailAddresses)
            }
            Button("Save Changes") { Task { await save() } }
                .disabled(isSaving)
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        var updated = product
        updated.displayName = displayName.trimmingCharacters(in: .whitespaces)
        updated.mirrorEmailsToGitHub = mirrorEmailsToGitHub
        updated.redactEmailAddresses = redactEmailAddresses
        if !token.isEmpty {
            await KeychainService.save(token: token.trimmingCharacters(in: .whitespaces), for: updated)
        }
        store.update(updated)
    }
```
> NOTE: `save()` mirrors `AddEditRepoView.save()` (line ~292) — Keychain write before `store.update`. The token field stays read-only-ish here (General focuses on the existing connection); a full GitHub re-connect flow is out of scope for this phase, so we keep the existing owner/repo immutable in the detail. The minimal **add** flow (Task 9) still creates products with their connection.
- [ ] **Step 3: Add the Sources section with NavigationLinks.** Append inside `ProductSettingsView`:
```swift
    @ViewBuilder
    private var sourcesSection: some View {
        Section {
            // SDK — always on, informational.
            HStack {
                Label("SDK", systemImage: "wrench.and.screwdriver")
                Spacer()
                Text("Receiving issues from \(owner)/\(repo)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // App Store — Off / Configured → AppStoreSourceForm (stub; Phase 3 fills in).
            NavigationLink {
                AppStoreSourceForm(store: store, product: product)
            } label: {
                sourceRow(
                    title: "App Store",
                    systemImage: "apple.logo",
                    status: product.appStoreSourceStatus
                )
            }

            // Email — Off / Configured → EmailSourceForm (stub; Phase 5 fills in).
            NavigationLink {
                EmailSourceForm(store: store, product: product)
            } label: {
                sourceRow(
                    title: "Email",
                    systemImage: "envelope",
                    status: product.emailSourceStatus
                )
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Feedback can arrive from the AppFeedback SDK, App Store reviews, and a dedicated email inbox. All sources are synthesized into this product's GitHub repository.")
        }
    }

    private func sourceRow(title: String, systemImage: String, status: SourceStatus) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status == .configured ? "Configured" : "Off")
                .font(.footnote)
                .foregroundStyle(status == .configured ? .green : .secondary)
        }
    }
```
> NOTE: `NavigationLink` requires an enclosing `NavigationStack`. The macOS container (Task 6) and the iOS push/sheet (Tasks 7-8) each provide one. On macOS, `Form` inside a `NavigationStack` renders the destination as a column push — acceptable for the settings window.
- [ ] **Step 4: Build check (both platforms).** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS. Run `SourceStatusTests` (still green — confirms the status mapping the rows display).
- [ ] **Step 5: Commit.**
```
git add AppFeedback/Views/Settings/ProductSettingsView.swift
git commit -m "feat(settings): ProductSettingsView with General + Sources sections

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: macOS master-detail container `ProductsSettingsTab` + wire into `tabContent()`

**Files:**
- Create `AppFeedback/Views/Settings/ProductsSettingsTab.swift`
- Modify `AppFeedback/Views/Settings/SettingsView.swift` (`tabContent()` arm at line ~68; add `@Environment(SettingsNavigation.self)` already present)

**Interfaces:**
- Consumes: `ProductStore` with `repos: [ProductConfig]` (Phase 0); `SettingsNavigation.selectedProductID` (Task 2); `ProductSettingsView(store:product:)` (Task 5); `ColorPalette.color(for:in:)` (existing, used by `SettingsView`).
- Produces: `struct ProductsSettingsTab: View { init(store: ProductStore, navigation: SettingsNavigation) }`.

- [ ] **Step 1: Create the container (macOS).** Create `AppFeedback/Views/Settings/ProductsSettingsTab.swift`:
```swift
#if os(macOS)
import SwiftUI

/// macOS master-detail for the Products settings tab: a product list on the left and the
/// selected product's `ProductSettingsView` on the right. Selection is bound to
/// `SettingsNavigation.selectedProductID` so the sidebar "Settings…" item can focus a product
/// in this (separate) Settings window.
struct ProductsSettingsTab: View {
    @Bindable var store: ProductStore
    @Bindable var navigation: SettingsNavigation

    private var allDisplayNames: [String] { store.repos.map(\.displayName).sorted() }

    private var selectedProduct: ProductConfig? {
        store.repos.first(where: { $0.id == navigation.selectedProductID })
            ?? store.repos.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedProduct?.id },
                set: { navigation.selectedProductID = $0 }
            )) {
                ForEach(store.repos) { product in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ColorPalette.color(for: product.displayName, in: allDisplayNames))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(product.displayName)
                            Text("\(product.owner)/\(product.repo)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(product.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if let product = selectedProduct {
                NavigationStack {
                    ProductSettingsView(store: store, product: product)
                }
                .id(product.id)   // rebuild the detail when the selected product changes
            } else {
                ContentUnavailableView("No Products", systemImage: "shippingbox",
                    description: Text("Add a product to configure its feedback sources."))
            }
        }
    }
}
#endif
```
> NOTE: `store.repos` — see the Task 5 note. If Phase 0 renamed the array to `products`, replace `store.repos` here. `@Bindable var navigation` requires `SettingsNavigation` to be `@Observable` (it is, Task 1/2).
- [ ] **Step 2: Wire the container into `tabContent()`.** In `AppFeedback/Views/Settings/SettingsView.swift` `tabContent(selection:)` (line ~67), replace the `reposTab` body for `.products` and pass the environment navigation. First, capture navigation in `macBody`/`tabContent`. Update the `.products` arm:
```swift
        switch selection {
        case .products:
            ProductsSettingsTab(store: store, navigation: navigation)
        case .email:
            EmailSettingsView()
```
- [ ] **Step 3: Make `store` the right type + pass `navigation`.** `SettingsView` currently declares `@Bindable var store: RepoStore`; after Phase 0 this is `ProductStore`. Confirm `@Environment(SettingsNavigation.self) private var navigation` is present (it is, line 28). `tabContent` is a method on `SettingsView`, so `navigation` and `store` are in scope. Remove the now-unused `reposTab`, `repoList`, `RepoRowView`, `addBar`, `emptyState`, `maskedToken`, `editTarget`, `hoveredId`, `showAdd`, `tokens`, `refreshTokens`, `allDisplayNames` from the **macOS** path (the iOS path keeps its own; see Task 8). Delete `reposTab` and its macOS-only helper subviews and the trailing `RepoRowView` struct.
- [ ] **Step 4: Build check (macOS).** zcode: build `AppFeedback_macOS`. Expect PASS. (If `reposTab` helpers are still referenced by the iOS path, leave the iOS ones; only the macOS `reposTab` chain is removed. The iOS body does not use `reposTab`/`RepoRowView`.)
- [ ] **Step 5: Commit.**
```
git add AppFeedback/Views/Settings/ProductsSettingsTab.swift AppFeedback/Views/Settings/SettingsView.swift
git commit -m "feat(settings): macOS Products master-detail tab bound to selectedProductID

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: macOS Settings window focuses `selectedProductID` (verify environment plumbing)

**Files:**
- Modify `AppFeedback/App/AppFeedbackApp.swift:362` (the `Window("Settings", id: "settings")` scene — confirm `settingsNavigation` is already injected; it is, line 373)

**Interfaces:**
- Consumes: `SettingsNavigation` (shared `@State` in `AppFeedbackApp`, injected into both the main `WindowGroup` and the Settings `Window`); `ProductsSettingsTab` (Task 6).
- Produces: no new symbols — this task confirms the macOS Settings window honors `navigation.selectedProductID` set from elsewhere (the sidebar item in Task 9).

- [ ] **Step 1: Confirm the shared `SettingsNavigation` is injected into the Settings window.** Read `AppFeedbackApp.swift` lines 362-383. The `Window("Settings", id: "settings")` already attaches `.environment(settingsNavigation)` (line 373) and the main `WindowGroup` attaches the same instance (line 294). No code change needed — the same object reference is shared, so setting `selectedProductID` on it (from the sidebar, RootView Task 9) is visible to `ProductsSettingsTab` after `openWindow(id: "settings")`.
- [ ] **Step 2: Add a focused-product default-open behavior.** In `ProductsSettingsTab` (Task 6) the `selectedProduct` computed property already falls back to `store.repos.first` when `selectedProductID` is nil and resolves the focused product when set — so no scene change is required. Add a `.onAppear` safety net so re-opening the window with a stale `selectedProductID` (product since removed) doesn't show an empty detail. In `ProductsSettingsTab.body`'s `List`, append after `.navigationSplitViewColumnWidth`:
```swift
            .onAppear {
                if navigation.selectedProductID == nil
                    || !store.repos.contains(where: { $0.id == navigation.selectedProductID }) {
                    navigation.selectedProductID = store.repos.first?.id
                }
            }
```
- [ ] **Step 3: Build check (macOS).** zcode: build `AppFeedback_macOS`. Expect PASS.
- [ ] **Step 4: Commit.**
```
git add AppFeedback/Views/Settings/ProductsSettingsTab.swift
git commit -m "feat(settings): Products tab resolves/falls back when focused product missing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: iOS — rework the Products section to push `ProductSettingsView`

**Files:**
- Modify `AppFeedback/Views/Settings/SettingsView.swift` (the `iosBody`, lines ~92-172; the repositories `Section`)

**Interfaces:**
- Consumes: `ProductStore` with `repos: [ProductConfig]`, `func remove(id:) async` (existing, Phase-0 renamed); `ProductSettingsView(store:product:embedInNavigation:)` (Task 5); the existing minimal add flow `AddEditRepoView` (renamed in Task 9 — keep as the add sheet until then).
- Produces: no new symbols — the iOS Products list now navigates to `ProductSettingsView` instead of `AddEditRepoView` for editing.

- [ ] **Step 1: Replace the edit `NavigationLink` destination.** In `AppFeedback/Views/Settings/SettingsView.swift` `iosBody`, the repositories section currently pushes `AddEditRepoView(store:existing:embedInNavigation:false)` for each repo (line ~101-105). Replace with `ProductSettingsView`:
```swift
                Section {
                    ForEach(store.repos) { product in
                        NavigationLink {
                            ProductSettingsView(store: store, product: product, embedInNavigation: false)
                        } label: {
                            iosRepoRow(product)
                        }
                    }
                    .onDelete { offsets in
                        Task {
                            for index in offsets {
                                await store.remove(id: store.repos[index].id)
                            }
                        }
                    }

                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Product", systemImage: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                } header: {
                    Text("Products")
                } footer: {
                    if !store.repos.isEmpty {
                        Text("Tap a product to configure its sources. Swipe left to remove.")
                    } else {
                        Text("Add a product to start browsing feedback.")
                    }
                }
```
> NOTE: `iosRepoRow(_:)` takes a `ProductConfig` after Phase 0; keep its body. The add sheet (`showAdd`) still presents `AddEditRepoView` until Task 9 renames it.
- [ ] **Step 2: Build check (iOS).** zcode: build `AppFeedback_iOS`. Expect PASS.
- [ ] **Step 3: Commit.**
```
git add AppFeedback/Views/Settings/SettingsView.swift
git commit -m "feat(settings): iOS Products list pushes ProductSettingsView for editing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Keep the minimal add flow — rename `AddEditRepoView` user strings to "Product"

**Files:**
- Modify `AppFeedback/Views/Settings/AddEditRepoView.swift` (titles/labels only — lines 71, 118, 208, 227-229; `RepoConfig`→`ProductConfig` already done by Phase 0)

**Interfaces:**
- Consumes: `ProductStore.add(_:)` (Phase 0), `ProductConfig` (Phase 0), `KeychainService` (existing).
- Produces: no new symbols. The add flow stays exactly as-is functionally; only user-facing "Repository" → "Product" strings change so the add sheet is consistent with the renamed tab. **No source configuration in the add flow** — sources are configured afterward in `ProductSettingsView`.

- [ ] **Step 1: Rename the navigation titles.** In `AddEditRepoView.swift`, the iOS form title (line ~71):
```swift
            .navigationTitle(isEditing ? "Edit Product" : "Add Product")
```
- [ ] **Step 2: Rename the iOS submit button (line ~208).**
```swift
                    Text(isEditing ? "Save" : "Add Product")
```
- [ ] **Step 3: Rename the macOS header (lines ~227-229).**
```swift
                Text(isEditing ? "Edit Product" : "Add Product")
                    .font(.system(size: 13, weight: .semibold))
                Text(isEditing ? "Update connection settings" : "Connect a GitHub repo to browse feedback")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
```
- [ ] **Step 4: Rename the iOS "Add Repository" label inside the form (line ~118 region).** The `Label("Add Repository", systemImage: "plus.circle.fill")` lives in `SettingsView.iosBody`, already changed to "Add Product" in Task 8 — no change here. Confirm no other "Repository"/"Repo" user-strings remain in `AddEditRepoView` (the comment at the keychain write may stay).
- [ ] **Step 5: Build check (both platforms).** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS.
- [ ] **Step 6: Commit.**
```
git add AppFeedback/Views/Settings/AddEditRepoView.swift
git commit -m "feat(settings): rename Add/Edit Repository flow strings to Product

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Sidebar context-menu "Settings…" — extract a testable menu model

**Files:**
- Create the menu-action model inside `AppFeedback/Views/Sidebar/RepoSectionView.swift` (a small `enum` at file scope)
- Test `AppFeedbackTests/ProductContextMenuTests.swift`

**Interfaces:**
- Consumes: none new.
- Produces: `enum ProductContextMenuAction: CaseIterable, Equatable { case settings; case color; case remove }` with `var title: String` + `var systemImage: String`, plus `static var ordered: [ProductContextMenuAction]` whose **first** element is `.settings`. This is the unit-testable surface proving the context menu exposes "Settings…" as the leading item (UI rendering itself isn't unit-testable here).

- [ ] **Step 1: Write the failing test.** Create `AppFeedbackTests/ProductContextMenuTests.swift`:
```swift
import XCTest
@testable import AppFeedback

final class ProductContextMenuTests: XCTestCase {
    func test_menu_exposesSettingsAsLeadingItem() {
        XCTAssertEqual(ProductContextMenuAction.ordered.first, .settings)
    }

    func test_menu_containsSettingsColorRemove() {
        XCTAssertEqual(Set(ProductContextMenuAction.ordered), [.settings, .color, .remove])
    }

    func test_settings_titleAndSymbol() {
        XCTAssertEqual(ProductContextMenuAction.settings.title, "Settings…")
        XCTAssertEqual(ProductContextMenuAction.settings.systemImage, "gearshape")
    }
}
```
- [ ] **Step 2: Run the test (expect FAIL — type missing).** zcode: run `ProductContextMenuTests`. Expect compile failure.
- [ ] **Step 3: Add the menu model.** In `AppFeedback/Views/Sidebar/RepoSectionView.swift`, add at file scope (above `struct RepoSectionView`):
```swift
/// The actions exposed by a product's sidebar context menu, in display order.
/// `.settings` is the leading item (opens `ProductSettingsView`), followed by the existing
/// Color submenu and Remove. Extracted so the leading-Settings ordering is unit-testable.
enum ProductContextMenuAction: CaseIterable, Equatable {
    case settings
    case color
    case remove

    static var ordered: [ProductContextMenuAction] { [.settings, .color, .remove] }

    var title: String {
        switch self {
        case .settings: return "Settings…"
        case .color:    return "Color"
        case .remove:   return "Remove Product"
        }
    }

    var systemImage: String {
        switch self {
        case .settings: return "gearshape"
        case .color:    return "paintpalette"
        case .remove:   return "trash"
        }
    }
}
```
- [ ] **Step 4: Run the test (expect PASS).** zcode: run `ProductContextMenuTests` — all three pass.
- [ ] **Step 5: Commit.**
```
git add AppFeedback/Views/Sidebar/RepoSectionView.swift AppFeedbackTests/ProductContextMenuTests.swift
git commit -m "feat(sidebar): ProductContextMenuAction model with leading Settings… item

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Add the "Settings…" item to `RepoSectionView`'s context menu + `onOpenSettings` callback

**Files:**
- Modify `AppFeedback/Views/Sidebar/RepoSectionView.swift` (the `.contextMenu` at lines 34-67; add the `onOpenSettings` parameter)

**Interfaces:**
- Consumes: `ProductConfig` (Phase 0); `ProductContextMenuAction` (Task 10); existing `store.setColor(_:forRepo:)`, `ColorPalette.swatches`, the existing confirmation-dialog remove path.
- Produces: `RepoSectionView` gains `var onOpenSettings: (UUID) -> Void` (called with `repo.id`). The leading menu item is the **Settings…** button.

- [ ] **Step 1: Add the `onOpenSettings` parameter.** In `RepoSectionView`, add a stored property near the other params (after `var seenStore: SeenIssueStore`):
```swift
    var onOpenSettings: (UUID) -> Void = { _ in }
```
- [ ] **Step 2: Insert the leading Settings… button into the context menu.** In the `.contextMenu` (currently starting at line 34 with `Menu { … } label: { Label("Color", …) }`), prepend a Settings button + Divider so the menu reads Settings… ▸ Color ▸ Remove:
```swift
        .contextMenu {
            Button {
                onOpenSettings(repo.id)
            } label: {
                Label(ProductContextMenuAction.settings.title,
                      systemImage: ProductContextMenuAction.settings.systemImage)
            }

            Divider()

            Menu {
                if repo.colorHex != nil {
                    Button {
                        store.setColor(nil, forRepo: repo.id)
                    } label: {
                        Label("Default", systemImage: "circle.dashed")
                    }
                    Divider()
                }
                ForEach(ColorPalette.swatches, id: \.self) { swatch in
                    Button {
                        store.setColor(swatch.hex, forRepo: repo.id)
                    } label: {
                        #if os(macOS)
                        Image(nsImage: ColorPalette.swatchImage(hex: swatch.hex))
                        #else
                        Circle().fill(Color(hex: swatch.hex))
                        #endif
                        Text(swatch.name)
                    }
                }
            } label: {
                Label(ProductContextMenuAction.color.title, systemImage: ProductContextMenuAction.color.systemImage)
            }

            Divider()

            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label(ProductContextMenuAction.remove.title, systemImage: ProductContextMenuAction.remove.systemImage)
            }
        }
```
> NOTE: this changes the destructive label from "Remove Repo" to "Remove Product" via `ProductContextMenuAction.remove.title`. The confirmation dialog message string ("…remove the repo from the sidebar…") should also read "product"; update it in Step 3.
- [ ] **Step 3: Update the confirmation dialog copy.** In the same file, the `.confirmationDialog` message (line ~78):
```swift
            Text("This will remove the product from the sidebar. Your GitHub data will not be affected.")
```
- [ ] **Step 4: Build check (both platforms).** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS. The iOS long-press surfaces the same `.contextMenu` automatically (SwiftUI maps `.contextMenu` to long-press on iOS). Re-run `ProductContextMenuTests` (green).
- [ ] **Step 5: Commit.**
```
git add AppFeedback/Views/Sidebar/RepoSectionView.swift
git commit -m "feat(sidebar): add Settings… as the leading context-menu item

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Thread `onOpenProductSettings` through `SidebarView`

**Files:**
- Modify `AppFeedback/Views/Sidebar/SidebarView.swift` (add the callback param; pass into each `RepoSectionView`)

**Interfaces:**
- Consumes: `RepoSectionView` with `onOpenSettings: (UUID) -> Void` (Task 11).
- Produces: `SidebarView` gains `var onOpenProductSettings: (UUID) -> Void = { _ in }`, forwarded to each row.

- [ ] **Step 1: Add the parameter.** In `SidebarView`, after `var onAddRepo: () -> Void = {}` (line 8):
```swift
    var onOpenProductSettings: (UUID) -> Void = { _ in }
```
- [ ] **Step 2: Forward it to `RepoSectionView`.** In the `ForEach(store.repos)` body (line ~26), pass the closure:
```swift
                        RepoSectionView(
                            repo: repo,
                            issues: issues,
                            allApps: apps,
                            selection: $selection,
                            store: store,
                            seenStore: seenStore,
                            onOpenSettings: onOpenProductSettings
                        )
```
- [ ] **Step 3: Build check (both platforms).** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS.
- [ ] **Step 4: Commit.**
```
git add AppFeedback/Views/Sidebar/SidebarView.swift
git commit -m "feat(sidebar): forward onOpenProductSettings to RepoSectionView rows

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: `RootView` wires "Settings…" → focus product (macOS window) / present sheet (iOS)

**Files:**
- Modify `AppFeedback/App/RootView.swift` (the `SidebarView(...)` call at line 76; add `@Environment(SettingsNavigation.self)`, an iOS sheet state, and the macOS open-window path)

**Interfaces:**
- Consumes: `SidebarView` with `onOpenProductSettings:` (Task 12); `SettingsNavigation.focus(productID:)` (Task 2); `ProductSettingsView(store:product:embedInNavigation:)` (Task 5); existing `@Environment(\.openWindow)` (macOS, line 66) and `ProductStore` (`store`).
- Produces: no new public symbols — `RootView` now opens the product's settings from the sidebar.

- [ ] **Step 1: Add the SettingsNavigation environment + iOS sheet state.** In `RootView`, near the other `@Environment`s (after line 64) add:
```swift
    @Environment(SettingsNavigation.self) private var settingsNavigation
```
And near the other `@State`s (after line 27, `showAddRepo`) add:
```swift
    #if os(iOS)
    @State private var productSettingsTarget: ProductConfig?
    #endif
```
- [ ] **Step 2: Add the `onOpenProductSettings` handler to `SidebarView`.** Replace the `SidebarView(...)` call (line 76) with:
```swift
            SidebarView(store: store, loaders: loaders, seenStore: seenStore, selection: $selection,
                        onAddRepo: { showAddRepo = true },
                        onOpenProductSettings: { id in openProductSettings(id) })
```
- [ ] **Step 3: Implement `openProductSettings`.** Add a method to `RootView`:
```swift
    private func openProductSettings(_ id: UUID) {
        #if os(macOS)
        settingsNavigation.focus(productID: id)
        openWindow(id: "settings")
        #else
        productSettingsTarget = store.repos.first(where: { $0.id == id })
        #endif
    }
```
- [ ] **Step 4: Present the iOS sheet.** Add a `.sheet(item:)` alongside the existing sheets (after the `.sheet(isPresented: $showAddRepo)` at line 149):
```swift
        #if os(iOS)
        .sheet(item: $productSettingsTarget) { product in
            NavigationStack {
                ProductSettingsView(store: store, product: product, embedInNavigation: false)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { productSettingsTarget = nil }
                        }
                    }
            }
        }
        #endif
```
> NOTE: `ProductConfig` is `Identifiable` (it carries `let id: UUID`), so `.sheet(item:)` works. The iOS sheet wraps `ProductSettingsView` in its own `NavigationStack` so the Sources `NavigationLink`s push correctly.
- [ ] **Step 5: Build check (both platforms).** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS. (`SettingsNavigation` is already injected into the main `WindowGroup` at `AppFeedbackApp.swift:294`, so the `@Environment` resolves at runtime.)
- [ ] **Step 6: Commit.**
```
git add AppFeedback/App/RootView.swift
git commit -m "feat(sidebar): Settings… focuses the product (macOS window) / sheet (iOS)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Full-suite regression run + scope check

**Files:**
- None (verification only)

**Interfaces:**
- Consumes: every symbol above.
- Produces: confidence the phase is complete and isolated.

- [ ] **Step 1: Run the whole test target via xcodebuild (ground truth).** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/SettingsNavigationTests -only-testing:AppFeedbackTests_macOS/SourceStatusTests -only-testing:AppFeedbackTests_macOS/ProductContextMenuTests
```
Expect: all tests PASS.
- [ ] **Step 2: Run the broader suite for regressions.** Run:
```
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expect: only the ~11 pre-existing `KeychainServicePerAccountTests` + `GitHubAccountStoreTests` failures (no-Keychain test host) — NOT regressions. Everything else PASS. If any non-Keychain test newly fails, fix it before proceeding.
- [ ] **Step 3: Build both app targets.** zcode: build `AppFeedback_macOS` and `AppFeedback_iOS`. Expect PASS.
- [ ] **Step 4: Scope check.** Confirm this phase did NOT implement: App Store auth/poll/synthesis (Phase 3), inspector "Respond on App Store" (Phase 4), feedback-inbox `MailToFeedbackMirror` (Phase 5). Confirm `AppStoreSourceForm`/`EmailSourceForm` remain compiling placeholders with the deferral footnotes intact. Confirm no `.swift` files were added outside the paths in this plan and that `git status` shows only this phase's files staged.
- [ ] **Step 5: Final commit (if any stray formatting).** Only if needed:
```
git add AppFeedback/Views/Settings AppFeedback/Views/Sidebar AppFeedback/App/RootView.swift AppFeedbackTests/SettingsNavigationTests.swift AppFeedbackTests/SourceStatusTests.swift AppFeedbackTests/ProductContextMenuTests.swift
git commit -m "chore(settings): finalize Phase 2 product settings UI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
