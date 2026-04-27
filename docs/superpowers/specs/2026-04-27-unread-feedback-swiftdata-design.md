# Unread Feedback Indicator + SwiftData Cache — Design

**Date:** 2026-04-27
**Status:** Approved (pending spec review)

## Goal

Show a blue "unread" indicator on feedback issues that are new since the user last saw them, with read-state synced across the user's devices via iCloud (so iOS reflects what was already read on macOS, and vice versa). At the same time, replace the existing per-repo JSON file cache used by `IssueLoader` with a SwiftData-backed local cache.

## Non-goals

- Syncing cached issue contents themselves through CloudKit (issues are re-fetched from GitHub on each device — only read-state crosses devices).
- A "Mark all as read" command, badge counts in the sidebar, push notifications, or unread filtering. Out of scope for this iteration.
- Migrating existing `Caches/AppFeedback/{owner}-{repo}.json` files into SwiftData. They are stale-tolerant and will be replaced on next successful refresh.

## Architecture

### Container & configurations

`AppFeedbackApp` builds one `ModelContainer` with **two** `ModelConfiguration`s:

1. **Cloud config** (CloudKit-synced, `iCloud.com.amirhayek.AppFeedback` private DB) — schema: `Repo`, `SeenIssue`.
2. **Local config** (`cloudKitDatabase: .none`) — schema: `CachedIssue`.

Both configs share one container so SwiftUI's `.modelContainer(...)` covers everything; queries are routed by entity type.

Under tests (`XCTestConfigurationFilePath` env var), both configurations use `isStoredInMemoryOnly: true` as today.

### New models

```swift
@Model
final class SeenIssue {
    // Composite natural key: (repoOwner, repoName, issueNumber).
    // No @Attribute(.unique) — CloudKit-synced models cannot be unique.
    var repoOwner: String = ""
    var repoName: String = ""
    var issueNumber: Int = 0
    var seenAt: Date = Date()

    init(repoOwner: String, repoName: String, issueNumber: Int, seenAt: Date = Date()) { ... }
}

@Model
final class CachedIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var number: Int = 0
    var title: String = ""
    var createdAt: Date = Date()
    var rawBody: String = ""
    var appName: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var issueDescription: String = ""

    init(...) { ... }

    func toFeedbackIssue() -> FeedbackIssue { ... }
    static func from(_ issue: FeedbackIssue, repoOwner: String, repoName: String) -> CachedIssue { ... }
}
```

All properties carry defaults — required for CloudKit (`SeenIssue`) and consistent with the existing `Repo` model. `CachedIssue` is local-only but follows the same convention for symmetry.

Duplicate prevention for `SeenIssue` is enforced at insert time by querying for an existing row with the same `(repoOwner, repoName, issueNumber)` first; CloudKit-synced models can't use unique constraints.

### Cache layer

`IssueLoader` is updated to:

- Accept a `ModelContext` (for the local config) in its initializer instead of computing `cacheURL`.
- `loadFromCache()` → `FetchDescriptor<CachedIssue>` filtered by `repoOwner == config.owner && repoName == config.repo`, mapped to `[FeedbackIssue]`. If non-empty, set `state = .loaded(issues, Date(timeIntervalSince1970: 0))` (preserving the existing "showing cached data" sentinel).
- `saveToCache(_:)` → delete all `CachedIssue` rows for this repo, then insert fresh rows from the new `[FeedbackIssue]`. Save context.
- The legacy `cacheURL` JSON file is no longer read or written. Any existing files are left alone (orphaned but harmless).

### Read-state layer

A new `Services/SeenIssueStore.swift` wraps the cloud `ModelContext` and provides:

```swift
@MainActor
final class SeenIssueStore {
    init(context: ModelContext)

    /// Returns the set of issue numbers already marked seen for this repo.
    func seenNumbers(owner: String, repo: String) -> Set<Int>

    /// Inserts a SeenIssue row if one doesn't already exist. Idempotent.
    func markSeen(owner: String, repo: String, issueNumber: Int)

    /// Bulk-marks every number in `issueNumbers` as seen. Skips duplicates.
    func markSeenBulk(owner: String, repo: String, issueNumbers: [Int])
}
```

`IssueListViewModel` gains:

- `private let seenStore: SeenIssueStore?`
- `private var sessionUnread: Set<Int>` — the unread set for this session (issues that were not in `seenNumbers(...)` when the latest `.loaded` arrived).
- `func isUnread(_ issue: FeedbackIssue) -> Bool { sessionUnread.contains(issue.number) }`
- `func markSeen(_ issue: FeedbackIssue)` — removes from `sessionUnread`, calls `seenStore.markSeen(...)`.
- A hook called from the owning view when `.loaded` transitions in `IssueLoader.state`:
  1. Snapshot `previouslySeen = seenStore.seenNumbers(owner, repo)`.
  2. `sessionUnread = Set(issues.map(\.number)).subtracting(previouslySeen)`.
  3. **Bulk-persist** every issue from the *previous* `.loaded` set as seen, so dots vanish on next launch. (We persist last-load's IDs on this load — that ensures the user gets one full session to see the dots even if they never interacted, but they're cleaned up by the time they relaunch.)

A small piece of state on the VM (`previouslyLoadedNumbers: Set<Int>`) tracks the last loaded-set so step 3 has something to flush.

### View wiring

**`IssueCardView`** gets:

- `var isUnread: Bool = false` — when true, render an 8pt blue circle (`Color.accentColor` or `.blue`) immediately before the `#123` number, vertically centered with the title baseline.
- `var onInteract: (() -> Void)? = nil` — called from any of: tapping the card surface (a `.contentShape(.rect).onTapGesture`), and from each existing `onToggleApp/AppVersion/Device/OSVersion/onTapEmail` callback before the existing logic runs.

**`IssueListView`** passes:

- `isUnread: viewModel.isUnread(issue)` per card.
- `onInteract: { viewModel.markSeen(issue) }`.

**`IssueListView`** also observes `loader.state` (e.g. via `.onChange(of: loader?.state)`) and on each `.loaded` transition calls a new `viewModel.applyLoaded(_ issues:)` that performs the snapshot/bulk-flush described above.

### App wiring

`AppFeedbackApp.init`:

```swift
let cloudConfig = ModelConfiguration(
    "cloud",
    schema: Schema([Repo.self, SeenIssue.self]),
    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
)
let localConfig = ModelConfiguration(
    "local",
    schema: Schema([CachedIssue.self]),
    cloudKitDatabase: .none
)
container = try ModelContainer(
    for: Repo.self, SeenIssue.self, CachedIssue.self,
    configurations: cloudConfig, localConfig
)
```

`SeenIssueStore` is constructed once with `ModelContext(container)` and passed into `IssueListViewModel`/wherever the list scene is built. `IssueLoader` is constructed with the same container's context (SwiftData routes `CachedIssue` to the local store automatically).

## Data flow

```
User opens app
   └─> ModelContainer (Cloud config + Local config)
   └─> IssueLoader.load()
        ├─ loadFromCache (SwiftData → CachedIssue rows for this repo)
        ├─ fetch GitHub
        └─ saveToCache (replace CachedIssue rows for this repo)
   └─> IssueListViewModel.applyLoaded(issues)
        ├─ previouslySeen = SeenIssueStore.seenNumbers(...)
        ├─ sessionUnread   = issues.numbers - previouslySeen
        └─ SeenIssueStore.markSeenBulk(previouslyLoadedNumbers)
   └─> IssueCardView renders blue dot when isUnread
        └─ tap card / badge / email → VM.markSeen → SeenIssueStore.markSeen → CloudKit sync
```

iOS receives `SeenIssue` rows through CloudKit on launch and applies them on its next `applyLoaded`.

## Error handling

- SwiftData failures during cache read return empty (current behavior — caller falls through to network fetch).
- SwiftData failures during cache write are logged via `assertionFailure` in DEBUG and silently ignored in release (current style elsewhere in the project).
- `SeenIssueStore.markSeen` swallows errors; failure to persist is non-fatal — the dot just reappears next session.

## Testing

- Unit-test `SeenIssueStore` with an in-memory container: `markSeen` is idempotent; `seenNumbers` returns expected set; `markSeenBulk` skips existing rows.
- Unit-test `IssueListViewModel.applyLoaded` flow with a stub `SeenIssueStore`: confirms `sessionUnread` excludes previously-seen, and that the *previous* loaded set is bulk-persisted on the next call.
- `IssueLoader` cache round-trip test: insert via `saveToCache`, fetch via `loadFromCache`, assert the issues match.

## Open questions

None blocking. Possible follow-ups (not in this spec):
- Pruning `CachedIssue` and `SeenIssue` rows for repos that have been deleted from the user's `Repo` list.
- Sidebar unread counts.
- An "unread only" filter chip in `FilterBarView`.
