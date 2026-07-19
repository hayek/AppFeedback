# "All Products" aggregate feedback view — design

- **Date:** 2026-06-24
- **Status:** Approved (pending written-spec review)
- **Author:** Amir Hayek (with Claude)

## Problem & goal

The app is a multi-product feedback aggregator. The sidebar lists one row per
product; selecting a product shows that product's feedback, Tasks & Versions,
filters, AI summary, etc. There is no way to see feedback from **all** products
together.

Add an **"All"** entry pinned to the top of the products list. Selecting it shows
a single, merged view spanning every product with **full feature parity** to a
single-product view — one combined feedback feed plus a unified Tasks & Versions
panel — with two deliberate exceptions (AI summary hidden; product-scoped actions
gain a product picker). See Decisions.

## Decisions (from brainstorming)

1. **Scope: full parity.** The All view behaves like a normal product view —
   merged feedback feed, all filters, search, unread, per-issue "open on GitHub",
   App Store reply, translation, **and** a unified Tasks & Versions panel.
2. **AI summary: hidden in All mode.** The summary card only renders for a
   single-product selection (there is no single repo to cache the digest against,
   and a cross-product digest would be noisy).
3. **Default selection: All, but remember last.** Persist the current selection
   across launches and restore it. First-ever launch (nothing saved) → All. A
   saved product that no longer exists → fall back to All.
4. **Unified Tasks & Versions = flat list + per-product tag + product filter.**
   One flat newest-first list of all products' tasks/versions, each row carrying a
   product tag (accent + name). A product filter narrows the list to one or more
   products. **Create Task / Create Version / Release** present a product picker
   first, then run the existing per-product flow.
5. **Cross-product task→feedback attach is blocked.** A GitHub feedback ref is
   repo-local, so a task in repo A cannot reference feedback in repo B. Dropping a
   task onto a feedback from a different product is rejected with a brief
   explanation, and the drag shows the system "not allowed" cursor while hovering
   an incompatible target. Same-product attach is unchanged.

## Non-goals

- Merging issues that genuinely live in different GitHub repos into one entity.
- Cross-product task↔feedback linking (explicitly blocked, per Decision 5).
- A combined AI digest across products (explicitly hidden, per Decision 2).
- Changing single-product behavior in any way (the aggregate path is additive;
  single-product mode must be byte-for-byte unchanged in behavior).

## Architecture (Approach A — "aggregate-aware components")

Generalize the existing components to operate on a merged, **product-tagged**
dataset, rather than building a parallel All view (which would duplicate
filtering/search/translation logic and drift) or a composite of per-product view
models (heavy fan-out plumbing, two code paths).

The enabling primitive is **per-issue product identity**: once each
`FeedbackIssue` in the merged feed knows its owning product, every per-product
operation (unread/seen, links, translation cache, attach) can route by the
issue's own product instead of a single ambient `owner/repo`. Single-product mode
leaves the new identity fields nil and keeps its existing single-scope path
untouched.

### Why number-keying forces this

`FeedbackIssue.id == number` and `IssueListViewModel` key unread/seen, highlight,
translation, and task-attach by the bare GitHub issue `number`. Numbers **collide
across repos** (issue #5 exists in many products). Aggregation therefore requires
a **composite identity** `(productID, number)` everywhere the merged feed is keyed.

## Detailed design

### 1. Selection model & persistence

`SidebarSelection` becomes:

```swift
enum SidebarSelection: Hashable, Sendable {
    case allProducts
    case product(repoId: UUID)   // renamed from .allIssues(repoId:)

    var repoId: UUID? {          // nil for .allProducts
        if case .product(let id) = self { return id }
        return nil
    }
}
```

- Rename `.allIssues(repoId:)` → `.product(repoId:)` across all call sites
  (`RootView`, `RepoSectionView`, tests). The old name is confusing next to
  `.allProducts`.
- `repoId` is now `UUID?`. Detail-view code branches on `.allProducts` vs
  `.product`. Sites that used `selection.repoId` as a non-optional dictionary key
  (`loaders[selection.repoId]`) move inside the `.product` branch.

**Persistence:** a small helper (e.g. `SidebarSelectionStore` over
`UserDefaults`) encodes the selection as a string: `"all"` or `"product:<uuid>"`.
- Saved on every selection change.
- Restored in `RootView.init` (replacing the current "seed to first product"
  seed). Resolution order: saved value → if `product:<uuid>` and that product
  still exists, use it; else `.allProducts`. Nothing saved → `.allProducts`.
- `autoSelectIfNeeded` falls back to `.allProducts` (not `repos.first`) when the
  selected product disappears.

### 2. Sidebar "All" row

- A single row pinned at the **top** of the `List`, above the `ForEach(store.repos)`
  product rows, tagged `.allProducts` and selectable like any product row.
- Reuses `AppRowView`: label **"All"**, an SF Symbol (e.g.
  `square.stack.3d.up` / `tray.full`), accent `.secondary` (or `.accentColor`).
- **Unread badge = sum of every product's unread**, computed with the exact
  per-repo unread logic `RepoSectionView.unreadCount` already uses (seen store ∖
  hidden apps ∖ tasks), summed across `store.repos`. Extract that per-repo
  computation into a reusable function so the All row and each product row share
  one definition.
- Hidden when there are zero products (the existing `ContentUnavailableView`
  empty state is unchanged).

### 3. `FeedbackIssue` product identity & aggregation

Add three **optional** fields to `FeedbackIssue` (default nil; Codable-safe for
old cached data):

```swift
var productID: UUID?
var productOwner: String?   // GitHub owner of the owning product
var productRepo: String?    // GitHub repo of the owning product
```

- Single-product mode never sets these → existing behavior preserved.
- Aggregate mode: `RootView` builds the merged feed by taking each loaded
  loader's `.loaded(issues, _)`, stamping every issue with its product's
  `id/owner/repo`, concatenating, and sorting newest-first. Tasks are split out
  exactly as the single-repo path does (`TaskItem.isTask`).
- **Composite identity:** add `var compositeKey: String { "\(productID?.uuidString ?? "")#\(number)" }`.
  Aggregate `ForEach` and scroll-to use `compositeKey`; single mode keeps using
  `number`.

### 4. Aggregate feedback list behavior

`IssueListView` / `IssueListViewModel` gain an explicit `isAggregate` flag (passed
from `RootView`). Behavior in aggregate mode:

- **Merged feed & filters:** `applyLoaded` accepts the merged, product-tagged
  array. App/source/version/device/type filters and search operate on the merged
  set unchanged (they already filter `allIssues`).
- **Unread/seen routing:** `isUnread`/`markSeen` route by the issue's own
  `productOwner/productRepo` when present; the session-unread set is keyed by
  `compositeKey` (not bare `number`) so same-numbered issues in different repos
  don't alias. Single mode keeps the single `seenOwner/seenRepo` scope and
  `Set<Int>`.
- **Per-issue "open on GitHub" / card identity:** `IssueCardView` receives the
  issue's own owner/repo (`issue.productOwner ?? repoOwner`, etc.) so links and
  copy actions target the right repo.
- **Product attribution:** each card shows the owning product's accent dot + name
  so rows from different products are distinguishable. (Accent resolved from
  `ProductStore.colorHexFor(repo:)`.)
- **Translation:** the cache write/read keys (`repoOwner/repoName/number`) use the
  issue's own product in aggregate mode; the in-flight queue is keyed by
  `compositeKey`. (Translation remains fully functional in All mode.)
- **App Store reply:** already resolves the product per-issue from the review
  marker via the mirror store → works in aggregate with no change.
- **AI summary:** the summary card and its `.task` are skipped entirely when
  `isAggregate` (Decision 2).
- **Highlight / deep-link:** `highlightedIssueNumber` becomes a composite-aware
  highlight target in aggregate mode (a `(productID, number)` pair), so a
  notification tap scrolls to the right row.

### 5. Unified Tasks & Versions

`RootView` builds the inspector dataset from **all products** when `.allProducts`:

- **Tasks:** concatenate every loader's task-issues (`TaskItem.isTask`), each
  tagged with its product. Versions: union of `versionStore.versions(owner:repo:)`
  across all products, each tagged with its product.
- **Presentation (`ProjectInspectorPanel`):** a flat newest-first list; each
  task/version row shows a **product tag** (accent + name). A **product filter**
  control (multi-select, e.g. chips or a menu) narrows the flat list to the chosen
  product(s). Single-product mode shows no tags/filter (unchanged).
- **Create Task / Create Version / Release:** in aggregate mode each first
  presents a **product picker** (the set of `store.repos`); on choice the existing
  per-product sheet/flow runs against that product. Single-product mode skips the
  picker (unchanged).
- **Attach task → feedback (drag):**
  - The drag payload from a task card changes from `"<number>"` to
    `"<productID>|<number>"` so the target can identify the task's product.
    (Backward-compatible parse: a payload without `|` is treated as the current
    product, preserving single-mode behavior.)
  - Aggregate feedback rows use a `DropDelegate` (cross-platform) whose
    `dropUpdated` returns `DropProposal(operation: .forbidden)` when the dragged
    task's `productID` ≠ the row's `productID` → the system shows the
    **"not allowed" cursor** (Decision 5). On `performDrop`, a cross-product drop
    is rejected and a brief, transient explanation is surfaced (reusing the
    existing `taskWriteError` alert channel or an inline message). Same-product
    drops attach exactly as today.

### 6. Edge cases

- **Zero / one product:** All row hidden at zero products. With one product, All
  shows that product's feed (degenerate but correct); attribution still renders.
- **A product still loading:** the merged feed includes only `.loaded` loaders;
  others contribute nothing until loaded (mirrors single-mode `updateViewModel`
  guarding on `.loaded`). A `.task`-driven refresh re-merges as loaders finish.
- **Removing the selected-in-All product:** rows for that product drop out of the
  merged feed on the next `store.repos` change; selection stays `.allProducts`.
- **Pull-to-refresh in All mode:** refreshes every loader (the existing
  `onRefresh` already loads all repos with `fullReconcile: true`).
- **Persisted filters:** per-product filter persistence is keyed by `owner/repo`.
  In All mode, filter persistence is **session-only** (not saved per a single
  repo) to avoid clobbering a product's saved filters; load/save guard on
  `.product`.

## Testing

Pure-logic units (the project's existing test target `AppFeedbackTests_macOS`,
xcodebuild for ground truth — `/api/test` masks trap crashes):

- **Selection persistence:** encode/decode round-trip; restore resolution
  (`all` → `.allProducts`; valid `product:<uuid>` → that product; stale uuid →
  `.allProducts`; empty → `.allProducts`).
- **Aggregation:** merge tags each issue with the right product; newest-first
  sort; tasks split out; attribution accent resolves.
- **Composite seen/unread:** two issues with the **same number** in different
  products have independent unread state; "All" unread badge == sum of per-product
  unread (with hidden apps / tasks excluded).
- **Cross-product attach guard:** drop proposal is `.forbidden` and `performDrop`
  is rejected when productIDs differ; same-product attach proceeds. Drag-payload
  parse handles both `"<id>|<number>"` and legacy `"<number>"`.
- **Aggregate inspector:** product filter narrows tasks/versions; create/release
  route to the chosen product.

## Rough file map

- `Models/SidebarSelection.swift` — new case + optional `repoId` (rename).
- `Models/FeedbackIssue.swift` — product identity fields + `compositeKey`.
- New `Services/SidebarSelectionStore.swift` — persistence helper (+ tests).
- `Views/Sidebar/SidebarView.swift` — pinned All row + shared unread helper.
- `Views/Sidebar/RepoSectionView.swift` — extract reusable per-repo unread count;
  `.product` rename.
- `App/RootView.swift` — selection restore/persist; `.allProducts` branch:
  merged feed, aggregate inspector dataset, product pickers, `isAggregate`
  plumbing, cross-product attach handling.
- `ViewModels/IssueListViewModel.swift` — `isAggregate`; composite-keyed
  seen/unread + translation queue; per-issue repo routing.
- `Views/Issues/IssueListView.swift` — `isAggregate` (hide summary; product
  attribution; per-issue owner/repo; `DropDelegate` for aggregate rows).
- `Views/Inspector/ProjectInspectorPanel.swift` + `ProjectInspectorModel.swift` —
  flat list product tags + product filter; product picker for create/release.
- `Views/Inspector/InspectorDesign.swift` — task drag payload `"<id>|<number>"`.
- Tests under `AppFeedbackTests/` for each unit above.
