# Settings Sidebar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS Settings window's broken toolbar-tab layout with a single System Settings-style sidebar (Products section + icon rows for Email/Intelligence/Notifications).

**Architecture:** One `NavigationSplitView` in `SettingsView.macBody`, driven by a new `SettingsSelection` enum on `SettingsNavigation`. The inner Products master-detail (`ProductsSettingsTab`) and the AppKit toolbar bridge (`SettingsTabBar`) are deleted; their behavior (product detail, `+` sheet, selection fallback) moves into the unified sidebar.

**Tech Stack:** SwiftUI (macOS path only; iOS body untouched), Swift Testing for unit tests.

**Spec:** `docs/superpowers/specs/2026-07-21-settings-sidebar-redesign-design.md`

**Spec correction (verified against code):** the spec kept `selectedProductID` "for the iOS body" — but neither the iOS body nor any other caller reads it (its only consumer was `ProductsSettingsTab`, which this plan deletes; `RootView.swift:308` calls `focus(productID:)`, not the property). Both `SettingsTab` and `selectedProductID` are deleted entirely.

## Global Constraints

- iOS must keep compiling unchanged — all new/removed macOS UI stays behind the existing `#if os(macOS)` fences; `SettingsSelection` itself is unfenced (plain `Hashable` enum, harmless on iOS).
- Deep links preserved exactly: `focus(productID:)` → `.product(id)` (RootView "Settings…"), and `ComposeFormCore.swift:127` (`settingsNavigation.selectedTab = .email`) → `settingsNavigation.selection = .email`.
- Notifications row/pane only when `notificationService != nil` (same condition as the old tab).
- Fallback rule: invalid or nil selection → first product, else `.email`.
- Test target `AppFeedbackTests_macOS`. Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/<ClassName> 2>&1 | tail -20` (xcodebuild is ground truth; do not use zcode's /api/test). Known pre-existing Keychain-suite failures on some full runs are not regressions.
- After creating/deleting source files, run `xcodegen generate` — check `git status` FIRST (xcodegen discards uncommitted .xcscheme edits and globs untracked files).
- Commits: stage only your files; end messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: SettingsSelection navigation model + deep links

**Files:**
- Modify: `AppFeedback/Views/Settings/SettingsView.swift` (replace `SettingsTab`/`SettingsNavigation` at lines 6-25, plus the interim `macBody`/`tabContent` edits in Step 3 that keep the file compiling until Task 2 rewrites them)
- Modify: `AppFeedback/Views/Settings/ProductsSettingsTab.swift` (interim: read the product id off `selection` — file is deleted in Task 2)
- Modify: `AppFeedback/Views/Mail/ComposeFormCore.swift:127`
- Delete: `AppFeedback/Views/Settings/SettingsTabBar.swift` (nothing references `SettingsToolbarAccessor` once the interim `macBody` drops it)
- Test: `AppFeedbackTests/SettingsNavigationTests.swift` (create)

**Interfaces:**
- Produces: `enum SettingsSelection: Hashable { case product(UUID), email, intelligence, notifications }` with `var productID: UUID?`; `SettingsNavigation.selection: SettingsSelection?`; `focus(productID:)` setting `.product(id)`; `normalizedSelection(productIDs: [UUID]) -> SettingsSelection` implementing the fallback rule. `SettingsTab` and `selectedProductID` no longer exist.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AppFeedback

@MainActor
struct SettingsNavigationTests {
    @Test func focusSelectsProduct() {
        let nav = SettingsNavigation()
        let id = UUID()
        nav.focus(productID: id)
        #expect(nav.selection == .product(id))
    }

    @Test func normalizedKeepsValidProductSelection() {
        let nav = SettingsNavigation()
        let id = UUID()
        nav.selection = .product(id)
        #expect(nav.normalizedSelection(productIDs: [id, UUID()]) == .product(id))
    }

    @Test func normalizedKeepsNonProductSelections() {
        let nav = SettingsNavigation()
        for sel in [SettingsSelection.email, .intelligence, .notifications] {
            nav.selection = sel
            #expect(nav.normalizedSelection(productIDs: []) == sel)
        }
    }

    @Test func missingProductFallsBackToFirstProduct() {
        let nav = SettingsNavigation()
        let first = UUID()
        nav.selection = .product(UUID())   // deleted product
        #expect(nav.normalizedSelection(productIDs: [first]) == .product(first))
    }

    @Test func nilSelectionFallsBackToFirstProductThenEmail() {
        let nav = SettingsNavigation()
        let first = UUID()
        #expect(nav.normalizedSelection(productIDs: [first]) == .product(first))
        #expect(nav.normalizedSelection(productIDs: []) == .email)
    }

    @Test func missingProductWithNoProductsFallsBackToEmail() {
        let nav = SettingsNavigation()
        nav.selection = .product(UUID())
        #expect(nav.normalizedSelection(productIDs: []) == .email)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate` (git status first), then the test command with `-only-testing:AppFeedbackTests_macOS/SettingsNavigationTests`.
Expected: BUILD FAILURE — `SettingsSelection` not found.

- [ ] **Step 3: Implement**

Replace `SettingsView.swift` lines 6-25 (`SettingsTab` + `SettingsNavigation`) with:

```swift
/// One selected pane in the macOS Settings window's unified sidebar.
/// Unfenced: a plain Hashable enum is harmless on iOS, which doesn't use it.
enum SettingsSelection: Hashable {
    case product(UUID)
    case email
    case intelligence
    case notifications

    var productID: UUID? {
        if case .product(let id) = self { return id }
        return nil
    }
}

@Observable
final class SettingsNavigation {
    /// The unified sidebar selection (macOS). nil ⇒ resolve via `normalizedSelection`.
    var selection: SettingsSelection?

    /// Focus the Settings window on a specific product (used by the sidebar
    /// "Settings…" item, which shares this object via the environment).
    func focus(productID: UUID) {
        selection = .product(productID)
    }

    /// The selection to actually show for the given products: a valid product or
    /// non-product selection is kept; a deleted/nil product selection falls back
    /// to the first product, else Email.
    func normalizedSelection(productIDs: [UUID]) -> SettingsSelection {
        if let selection {
            if let id = selection.productID {
                if productIDs.contains(id) { return selection }
            } else {
                return selection
            }
        }
        if let first = productIDs.first { return .product(first) }
        return .email
    }
}
```

Keep-compiling edits required in the same commit (Task 2 rewrites these properly; here they are the minimal mechanical fixes for the removed symbols):

- `SettingsView.swift` `macBody` (lines 53-68): replace the body with a temporary passthrough so the file compiles without `SettingsTab`/`SettingsToolbarAccessor` changes leaking into this task — NO: `SettingsToolbarAccessor` takes `$nav.selectedTab` which no longer exists. Instead replace `macBody` and `tabContent` with this minimal interim version (Task 2 replaces it wholesale):

```swift
    #if os(macOS)
    private var macBody: some View {
        tabContent(selection: navigation.selection ?? .email)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(
                minWidth: 480, idealWidth: 720, maxWidth: .infinity,
                minHeight: 320, idealHeight: 620, maxHeight: .infinity
            )
    }

    @ViewBuilder
    private func tabContent(selection: SettingsSelection) -> some View {
        switch selection {
        case .product:
            ProductsSettingsTab(store: store, navigation: navigation)
        case .email:
            EmailSettingsView()
        case .intelligence:
            IntelligenceSettingsSection(
                settings: intelligenceSettings,
                availability: intelligenceService.availability,
                onOpenSystemSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligenceSettings") {
                        NSWorkspace.shared.open(url)
                    }
                },
                triageSettings: triageSettings
            )
        case .notifications:
            if let notificationService {
                NotificationsSettingsView(settings: notificationSettings, service: notificationService)
            }
        }
    }
    #endif
```

- `ProductsSettingsTab.swift`: it reads `navigation.selectedProductID` (lines 19-20, 26-27, 45-49). Interim fix so it compiles: replace those reads/writes with the selection's product id:
  - line 19-21: `store.products.first(where: { $0.id == navigation.selection?.productID }) ?? store.products.first`
  - lines 25-28 binding: `get: { selectedProduct?.id }`, `set: { if let id = $0 { navigation.selection = .product(id) } }`
  - lines 45-50 `.onAppear` guard: `if navigation.selection?.productID == nil || !store.products.contains(where: { $0.id == navigation.selection?.productID }) { if let first = store.products.first { navigation.selection = .product(first.id) } }`
- `ComposeFormCore.swift:127`: `settingsNavigation.selectedTab = .email` → `settingsNavigation.selection = .email`
- Confirm `RootView.swift:308` (`settingsNavigation.focus(productID: id)`) still compiles unchanged (signature kept).
- Delete `AppFeedback/Views/Settings/SettingsTabBar.swift` (its `SettingsToolbarAccessor` still references the removed `SettingsTab`, and nothing references the accessor once the interim `macBody` above drops it). Run `xcodegen generate` (git status first).
- Grep check: `grep -rn "selectedTab\|selectedProductID\|SettingsTab\b" AppFeedback --include="*.swift"` must return nothing after the edits.

- [ ] **Step 4: Run to verify pass**

The `SettingsNavigationTests` class passes (6 tests), AND the full `AppFeedbackTests_macOS` suite runs with no new failures (this task touches shared navigation state), AND both schemes build:
`xcodebuild build -project AppFeedback.xcodeproj -scheme AppFeedback_iOS -destination 'generic/platform=iOS' 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Settings/SettingsView.swift AppFeedback/Views/Settings/ProductsSettingsTab.swift AppFeedback/Views/Mail/ComposeFormCore.swift AppFeedbackTests/SettingsNavigationTests.swift AppFeedback.xcodeproj
git rm AppFeedback/Views/Settings/SettingsTabBar.swift
git commit -m "refactor(settings): unify navigation on SettingsSelection, drop tab toolbar bridge"
```

(If `git rm` complains the file is already staged via xcodegen's pbxproj update, plain `rm` + `git add -u` on that path is fine — but never `git add -A`.)

---

### Task 2: Unified sidebar UI

**Files:**
- Create: `AppFeedback/Views/Settings/SettingsIconRow.swift`
- Modify: `AppFeedback/Views/Settings/SettingsView.swift` (`macBody` + `tabContent` → sidebar + `detailContent`)
- Delete: `AppFeedback/Views/Settings/ProductsSettingsTab.swift`
- Test: `AppFeedbackTests/SettingsIconRowSmokeTests.swift` (create)

**Interfaces:**
- Consumes: `SettingsSelection`, `SettingsNavigation.selection` / `normalizedSelection(productIDs:)` (Task 1); existing `ProductSettingsView(store:product:)`, `EmailSettingsView()`, `IntelligenceSettingsSection(settings:availability:onOpenSystemSettings:triageSettings:)`, `NotificationsSettingsView(settings:service:)`, `AddEditRepoView(store:)`, `ColorPalette.color(for:in:)`, the existing `showAdd` @State.
- Produces: `SettingsIconRow(title:systemImage:tileColor:)` (macOS-fenced view). Final UI; nothing later depends on this task.

**Note on the spec's smoke test:** the spec asked for a smoke test "instantiating the new sidebar/detail". `SettingsView.body` cannot be evaluated outside a render host (it reads half a dozen `@Environment` objects and would crash), so the honest scope is: smoke-test `SettingsIconRow` (environment-free, same `.body`-evaluation pattern as `AttachmentStripViewSmokeTests`), with the sidebar's logic covered by Task 1's unit tests and the build.

- [ ] **Step 1: Write the failing smoke test**

```swift
import Testing
import SwiftUI
@testable import AppFeedback

#if os(macOS)
@MainActor
struct SettingsIconRowSmokeTests {
    @Test func iconRowRenders() {
        let row = SettingsIconRow(title: "Email", systemImage: "envelope.fill", tileColor: .blue)
        _ = row.body
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:AppFeedbackTests_macOS/SettingsIconRowSmokeTests`, BUILD FAILURE (`SettingsIconRow` not found).

- [ ] **Step 3: Implement**

`AppFeedback/Views/Settings/SettingsIconRow.swift`:

```swift
#if os(macOS)
import SwiftUI

/// System Settings-style sidebar row: an SF Symbol centered on a small colored
/// rounded-rect tile, followed by the pane title.
struct SettingsIconRow: View {
    let title: String
    let systemImage: String
    let tileColor: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tileColor.gradient)
                    .frame(width: 24, height: 24)
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(title)
        }
        .padding(.vertical, 1)
    }
}
#endif
```

In `SettingsView.swift`, replace the interim `macBody` + `tabContent` from Task 1 with:

```swift
    #if os(macOS)
    private var macBody: some View {
        @Bindable var nav = navigation
        return NavigationSplitView {
            List(selection: $nav.selection) {
                Section {
                    ForEach(store.products) { product in
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
                        .tag(SettingsSelection.product(product.id))
                    }
                } header: {
                    HStack {
                        Text("Products")
                        Spacer()
                        Button { showAdd = true } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add Product")
                    }
                }

                Section {
                    SettingsIconRow(title: "Email", systemImage: "envelope.fill", tileColor: .blue)
                        .tag(SettingsSelection.email)
                    SettingsIconRow(title: "Intelligence", systemImage: "sparkles", tileColor: .purple)
                        .tag(SettingsSelection.intelligence)
                    if notificationService != nil {
                        SettingsIconRow(title: "Notifications", systemImage: "bell.badge.fill", tileColor: .red)
                            .tag(SettingsSelection.notifications)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .onAppear {
                navigation.selection = navigation.normalizedSelection(productIDs: store.products.map(\.id))
            }
            .onChange(of: store.products.map(\.id)) { _, ids in
                navigation.selection = navigation.normalizedSelection(productIDs: ids)
            }
            .sheet(isPresented: $showAdd) {
                AddEditRepoView(store: store)
            }
        } detail: {
            detailContent(selection: navigation.selection)
        }
        .frame(
            minWidth: 480, idealWidth: 720, maxWidth: .infinity,
            minHeight: 320, idealHeight: 620, maxHeight: .infinity
        )
    }

    @ViewBuilder
    private func detailContent(selection: SettingsSelection?) -> some View {
        switch selection {
        case .product(let id):
            if let product = store.products.first(where: { $0.id == id }) {
                NavigationStack {
                    ProductSettingsView(store: store, product: product)
                }
                .id(product.id)   // rebuild the detail when the selected product changes
            } else {
                noProductsView
            }
        case .email:
            EmailSettingsView()
        case .intelligence:
            IntelligenceSettingsSection(
                settings: intelligenceSettings,
                availability: intelligenceService.availability,
                onOpenSystemSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligenceSettings") {
                        NSWorkspace.shared.open(url)
                    }
                },
                triageSettings: triageSettings
            )
        case .notifications:
            if let notificationService {
                NotificationsSettingsView(settings: notificationSettings, service: notificationService)
            }
        case nil:
            noProductsView
        }
    }

    private var noProductsView: some View {
        ContentUnavailableView("No Products", systemImage: "shippingbox",
            description: Text("Add a product to configure its feedback sources."))
    }
    #endif
```

Delete `AppFeedback/Views/Settings/ProductsSettingsTab.swift` (its master-detail, `+` toolbar, sheet, and `.onAppear` fallback are all absorbed above). Run `xcodegen generate` (git status first).

- [ ] **Step 4: Verify**

- `SettingsIconRowSmokeTests` + `SettingsNavigationTests` pass.
- Full `AppFeedbackTests_macOS` suite: no new failures.
- Both schemes build (macOS + `-scheme AppFeedback_iOS -destination 'generic/platform=iOS'`).
- Grep check: `grep -rn "ProductsSettingsTab\|SettingsToolbarAccessor\|SettingsTab\b\|selectedProductID" AppFeedback --include="*.swift"` returns nothing.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Settings/SettingsIconRow.swift AppFeedback/Views/Settings/SettingsView.swift AppFeedbackTests/SettingsIconRowSmokeTests.swift AppFeedback.xcodeproj
git rm AppFeedback/Views/Settings/ProductsSettingsTab.swift
git commit -m "feat(settings): unified System Settings-style sidebar"
```

---

## Final verification

- [ ] Full macOS suite green (known Keychain flakes excepted); both schemes build.
- [ ] Manual: open Settings — sidebar shows Products (+ works), Email/Intelligence/Notifications rows switch the detail pane; "Settings…" on a product in the main window sidebar opens the window focused on that product; the mail composer's Edit jump lands on Email; deleting the selected product falls back to the first product.
