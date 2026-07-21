# Settings Sidebar Redesign — Design

**Date:** 2026-07-21
**Status:** Approved

## Summary

Replace the macOS Settings window's four-tab layout (driven by an AppKit
`NSToolbar` bridge that no longer renders — the Products tab's inner
`NavigationSplitView` toolbar clobbers the injected toolbar) with a single
System Settings-style sidebar: a **Products** section listing the products
(with a `+` button in the section header), followed by icon rows for
**Email**, **Intelligence**, and **Notifications**. One selection model drives
one detail pane. iOS is untouched.

## Navigation model

- New `enum SettingsSelection: Hashable` (macOS):
  `case product(UUID)`, `case email`, `case intelligence`, `case notifications`.
- `SettingsNavigation` gains `var selection: SettingsSelection?` as the macOS
  source of truth. `selectedProductID: UUID?` STAYS (the iOS body and
  `focus(productID:)` callers use it); on macOS it is written through by
  `focus(productID:)` but the sidebar binds to `selection`. `selectedTab` is
  removed on macOS; if the iOS body references it, keep the enum fenced
  `#if os(iOS)` rather than expanding scope to iOS navigation.
- Deep links preserved:
  - `focus(productID:)` (RootView "Settings…" menu) sets
    `selection = .product(id)`.
  - `ComposeFormCore.swift:127` (`selectedTab = .email`) becomes
    `selection = .email`.
- Fallback rule (applied `.onAppear` and when the selected product no longer
  exists): first product if any, else `.email`.

## Sidebar

One `NavigationSplitView` in `SettingsView.macBody`; sidebar is a
`List(selection:)` with two sections:

1. **Products** — section header: "Products" text with a small borderless
   `+` button at the trailing edge (opens the existing `AddEditRepoView`
   sheet). Rows keep the current style: color dot
   (`ColorPalette.color(for:in:)`), display name, `owner/repo` caption.
   Row tag: `.product(id)`.
2. **Unlabeled settings section** — three rows using a new reusable
   `SettingsIconRow(title:systemImage:tileColor:)`: an SF Symbol centered on
   a small colored `RoundedRectangle` tile (System Settings look) plus label.
   - Email — `envelope`, blue tile
   - Intelligence — `sparkles`, purple tile
   - Notifications — `bell.badge`, red tile; row present only when
     `notificationService != nil` (same condition as the old tab)

## Detail pane

Switch on `selection`:

- `.product(id)` → `NavigationStack { ProductSettingsView(store:product:) }`
  with `.id(product.id)` (unchanged behavior from `ProductsSettingsTab`).
  Unknown id → fallback rule.
- `.email` → `EmailSettingsView()`
- `.intelligence` → `IntelligenceSettingsSection(...)` with its current
  parameters (settings, availability, onOpenSystemSettings, triageSettings)
- `.notifications` → `NotificationsSettingsView(settings:service:)`
- `nil` / no products → `ContentUnavailableView` ("No Products", existing copy)

## Deletions

- `ProductsSettingsTab.swift` (inner master-detail dissolves into the unified
  sidebar; its `.onAppear` fallback guard moves to the new sidebar)
- `SettingsTabBar.swift` (`SettingsTabBar` + `SettingsToolbarAccessor` — the
  AppKit toolbar bridge and the bug die together)
- `enum SettingsTab` (macOS usage; keep only if the iOS body genuinely still
  consumes it — the iOS `NavigationStack` body is out of scope and must keep
  compiling)

## Testing

- Unit tests for `SettingsNavigation`: `focus(productID:)` maps to
  `.product`, email deep link, fallback-on-missing-product rule.
- Smoke test instantiating the new sidebar/detail (repo's existing
  view-smoke-test pattern).
- Full macOS suite + both schemes build (iOS must compile unchanged).
