# GitHub Issue Foreground Auto-Refresh

**Date:** 2026-07-19
**Status:** Approved

## Problem

GitHub issues only refresh at launch, via pull-to-refresh, or through the
notification-gated background drivers. With notifications disabled, an open app
never refreshes issue data. Mail and App Store reviews already poll continuously
while the app runs; GitHub issues do not.

Two structural defects compound this:

- `MacBackgroundRefreshDriver` and `iOSBackgroundRefreshDriver` fetch into
  **private** `IssueLoader` instances, so their refreshes never update the UI's
  loaders (`RootView.loaders`).
- On macOS the driver runs whenever the process is alive, so any foreground
  refresher added alongside it would duplicate the fetch pipeline (and the
  driver already double-polls the App Store registry on top of that registry's
  own loop).

## Decision

Add one unified 15-minute foreground refresh loop that updates the UI's own
loaders and feeds the notification differ, replacing `MacBackgroundRefreshDriver`
entirely. Approach chosen over (a) a minimal RootView-local timer, which would
keep the duplicate macOS pipeline and stop notifying when the last window
closes, and (b) injecting RootView's loaders into the existing drivers, which
couples view-owned state into service objects and keeps the notifications gate.

## Design

### IssueLoaderRegistry (new, `Services/`)

`@MainActor @Observable` class following the `MailSyncCoordinatorRegistry` /
`AppStoreReviewCoordinatorRegistry` pattern. Created once in `AppFeedbackApp`,
handed to `RootView`. Owns `loaders: [UUID: IssueLoader]`.

API:

- `syncWithProducts(_ repos: [ProductConfig])` — create loaders for new repos
  (dispatching their initial load), drop loaders for removed repos. Replaces
  `RootView.syncLoaders`.
- `loadAll(fullReconcile: Bool = false)` — fan-out load across all repos,
  absorbing `RootView.loadRepos` including its iCloud-Keychain two-attempt
  retry.
- `pollNow()` — manual fan-out.
- `pollIfStale()` — catch-up poll that runs only when the last successful
  refresh is older than the 15-minute interval; used on scene activation.
- `start()` — the 15-minute poll loop: sleep → `loadAll` →
  `notificationService.diffAndNotify(loadedGroups)`. Started in `onAppear`
  alongside the other registries, **not** gated on notifications.
- `loadedGroups: [NotificationService.RepoIssues]` — replaces
  `RootView.allLoadedRepoGroups`.

Tokens come from an injected `tokenProvider: (ProductConfig) async -> String?`
defaulting to `KeychainService.load`, because Keychain is unavailable in the
test host.

### RootView

Drops `@State loaders`; all reads go through the registry (`@Observable` keeps
SwiftUI observation working). `syncLoaders`, `loadRepos`, and
`allLoadedRepoGroups` become thin delegations or are deleted. Pull-to-refresh,
`retryStuckLoaders`, and `maybeSnapshotBacklog` behavior is unchanged.

### Drivers

- `MacBackgroundRefreshDriver`: **deleted**, with its `AppFeedbackApp` wiring
  (`@State` var, init block, notifications-toggle `onChange` start/stop). The
  registry loop covers everything it did, visible to the UI and without the
  notifications gate.
- `iOSBackgroundRefreshDriver`: keeps only the `BGTaskScheduler`
  register/schedule/cancel glue. `runRefresh` delegates to
  `registry.loadAll()` + `diffAndNotify(registry.loadedGroups)` instead of
  building private loaders. It keeps its explicit `appStoreRegistry.pollNow()`
  because the App Store loop's `Task.sleep` is suspended while backgrounded.

### Cadence and edge cases

- Fixed 15-minute interval (matches the removed driver and the App Store
  cadence). No new user setting.
- **24-hour phantom sweep**: once per 24 h the loop's refresh passes
  `fullReconcile: true` (precedent: `AppStoreReviewCoordinator.fullRescanInterval`).
  Incremental `since:` fetches never surface deletions; with automatic refresh,
  users may never pull-to-refresh again, so without this sweep deleted issues
  would linger in the cache forever.
- **iOS foregrounding**: `Task.sleep` stretches while the app is suspended, so
  on `scenePhase == .active` the app calls `registry.pollIfStale()`, joining
  the existing mail/App Store `pollNow()` calls in `AppFeedbackApp`. The
  registry owns the staleness state (last successful refresh time) and the
  15-minute threshold; the app-level handler is a bare delegation.

### Error handling

Per-repo failures remain in each loader's `.failed` state (already rendered by
the UI); the loop continues to the next tick with no backoff — 15 minutes is
already conservative, and `retryStuckLoaders` on scene activation covers
recovery. Overlap with manual pull-to-refresh is safe: `IssueLoader.load`
awaits an identical in-flight load rather than duplicating it.

### Notifications

Exact parity with today: same `diffAndNotify` differ, self-gated on
`settings.isEnabled`, deduped across the foreground loop and the iOS background
driver via `NotifiedIssueStore`. Backlog snapshotting on first enable
(`maybeSnapshotBacklog`) is untouched.

## Testing

Registry unit tests in `AppFeedbackTests_macOS`:

- `syncWithProducts`: loader creation for added repos (with initial load),
  removal for deleted repos, idempotence.
- `loadedGroups` shape from loader states.
- Staleness decision for the activation catch-up poll.
- 24-hour full-reconcile trigger.

Injected clock (the `MailSyncCoordinator` pattern) and stub token provider; the
loop body is exposed as a testable `refreshTick()` method rather than testing
real sleeps. No UI tests — `RootView` changes are mechanical delegation.
