# Renaming releases

**Status:** approved, ready for implementation plan
**Date:** 2026-07-12

## Goal

Open a release from the project inspector and edit its fields — including the version
number — rather than only its title and changelog. Today `VersionDetailView` renders
`version.name` as a read-only `Text` (`VersionDetailView.swift:81`); there is no rename
path anywhere in the app.

## Why this isn't a text-field binding

`ProjectVersion.name` (e.g. `1.2.0`) is not a display string. It is the **foreign key** that
joins a version to everything else, because the app never learns a milestone's *number* for an
issue — `IssueLoader` selects only `milestone { title }` (`IssueLoader.swift:202`). So
`TaskItem` carries a `milestoneTitle: String?` and no version id, and every join is string
equality on the name:

| Join | Site |
|---|---|
| tasks in a version | `ProjectInspectorModel.swift:390` — `tasks.filter { $0.milestoneTitle == name }` |
| derived new/wip/released state | `ProjectInspectorModel.swift:394` |
| release-email recipients | `ReleaseRecipientCalculator.swift:18` |
| version-scope task filter | `ProjectInspectorModel.swift:357-359` |
| per-version state map | `RootView.swift:487` — `[String: VersionState]` |

The name is also denormalized into four persisted places: `SentReleaseNotification.versionName`
(CloudKit-synced), `CachedIssue.milestoneTitle` (local SwiftData), the
`VersionScope.versions(Set<String>)` inside `RepoFilterPreference.taskFiltersData`
(CloudKit-synced JSON), and the GitHub milestone title itself.

A naive rename therefore detaches every task from its version, empties the sent-email history,
resets the "already emailed" dedup guard so a second release pass **re-mails real users**, and
leaves a saved filter pinned to a name that no longer exists.

## Design

Rename is a first-class cascading operation, not a field edit. `VersionDetailView` becomes a
full editor (name, release title, changelog) committed by the existing Apply button.

### Ordering: GitHub first, local second

Today `VersionService.updateDetails` (`VersionService.swift:38-47`) writes locally, *then*
PATCHes GitHub, and ignores the result. That is fine for a changelog. For a rename it would
strand a local name that disagrees with the milestone title on any failure — and since
`TaskItem.milestoneTitle` is sourced *from* GitHub, the next sync would pull the old title back
and silently revert the rename while orphaning the tasks.

So `VersionService.rename(repo:version:to:)` inverts the order:

1. **Validate.** Trim; reject empty; reject a case-insensitive collision with another version in
   the same product (excluding self). A collision is not cosmetic — two versions sharing a name
   would merge each other's task lists and clobber `versionStates` (`RootView.swift:487`,
   last-writer-wins). CloudKit forbids `@Attribute(.unique)`, so this must be an explicit
   pre-check; GitHub's 422 on a duplicate milestone title stays as the backstop.
2. **PATCH the milestone title** — `updateMilestone(title:)` already exists and is called by
   nobody (`GitHubMilestoneReleaseClient.swift:45-48`). Skip when `milestoneNumber == nil` (a
   version whose milestone was never provisioned), which makes that case a pure local edit.
   Issues stay attached across the PATCH because GitHub links them by milestone *number*, which
   does not change.
3. **Cascade the local copies** in one save, then `store.saveAndReload()`.
4. **Surface failures.** Rename keeps the sheet up with a spinner and reports errors in the
   `errorMessage` label the view already has (`VersionDetailView.swift:39-42`) — it must *not*
   reuse `applyDetails()`'s dismiss-then-write-then-swallow-with-`try?` pattern
   (`VersionDetailView.swift:199-204`), which would make a failed rename invisible.

### The cascade

Because GitHub is already correct after step 2 and we know `oldName → newName`, the local fixup
is deterministic and needs **no network reconcile**:

| Target | Action |
|---|---|
| `ProjectVersion.name` | set to the new name |
| `CachedIssue.milestoneTitle` | rewrite rows matching `oldName` (persisted issue mirror) |
| in-memory `TaskItem`s | rewrite via the existing `ProjectInspectorModel.applyOptimistic(milestone:)` |
| `SentReleaseNotification` | see below |
| `VersionScope.versions(Set<String>)` | rewrite the in-memory set and the persisted `taskFiltersData`, for the renamed version's product only |

`versionStates` needs no action — `RootView` recomputes it from the versions on each pass.

All rewrites are scoped by `(repoOwner, repoName)` as well as by name: a version called `1.2.0`
in a *different* product must be left alone.

### Sent-email history gets a real foreign key

Rewriting `SentReleaseNotification.versionName` in the cascade would work but stays fragile: a
CloudKit peer that syncs a sent-notification row carrying the *old* name after the rename lands
would resurrect an orphan, and the "already emailed" guard
(`VersionStore.alreadyNotifiedEmails`, `VersionStore.swift:48-52`) would silently under-count —
which means re-emailing users.

So: add `versionID: UUID?` to `SentReleaseNotification`, with `versionName` retained for display.
`ReleaseNotificationService.recordSent` stamps it on every new row.

**Lookup.** The property is nullable because CloudKit requires it, so existing rows arrive with
`versionID == nil`. `VersionStore` resolves a version's notifications with a **pure** matcher:

> a row belongs to a version if `row.versionID == version.id` — or, when the row has no
> `versionID` at all, if `(repoOwner, repoName, versionName)` matches.

The name-based half only ever applies to rows *unclaimed* by a UUID, so a rename can never make a
stamped row invisible. `alreadyNotifiedEmails` and `sentNotifications` both go through it.

**Stamping happens on write, never on read.** `recordSent` stamps `versionID` on every new row,
and `rename` stamps it on the rows it rewrites — so after a version is renamed once, all of its
rows are UUID-keyed. The matcher must stay side-effect-free because `VersionDetailView` calls
`sentNotifications` from a computed property *during view body evaluation*; mutating models and
saving there would be a SwiftUI re-entrancy hazard.

A rename also rewrites `versionName` on the matching rows, so legacy rows stay attached and the
display string stays truthful.

Residual gap, accepted: a row synced from an *un-upgraded peer* after a rename carries the old
name and no `versionID`, so it would be orphaned. That is inherent to running mixed app versions,
and it is strictly better than today, where every rename orphans every row.

### Lifecycle gate

Rename is disabled once `version.releasePublished`. At that point the git tag (`v1.2.0`) and the
release emails are public facts. The tag cannot be safely renamed — deleting and recreating a
published tag breaks anyone who fetched it — and the GitHub Release name cannot even be PATCHed
today, because `updateRelease` accepts only `body` and `draft`
(`GitHubMilestoneReleaseClient.swift:72-79`) and the created Release's id is discarded at
`VersionService.swift:73`. Renaming a published release would permanently desync milestone title
/ Release name / git tag, so it is blocked rather than half-supported.

Rename remains available in `new` and `wip`.

### UI

The header `Text(version.name)` (`VersionDetailView.swift:81`) becomes a `TextField`, folded
into the existing `dirty` computed property (`VersionDetailView.swift:27`) so Apply lights up.
This is the same in-house idiom `TaskDetailView` already uses for an editable name
(`TaskDetailView.swift:92-96`), so it introduces no new pattern and works identically on macOS
and iOS. (There is no `.alert` + `TextField` idiom anywhere in this codebase; a rename alert
would be novel. Route through the existing sheet instead.)

When `releasePublished`, the field reverts to read-only `Text`.

## Also fixed here: silent milestone clear (pre-existing)

`TaskDetailView.apply()` resolves the milestone by name:

```swift
// TaskDetailView.swift:192
let milestoneNumber = versions.first { $0.name == versionName }?.milestoneNumber
```

`versionName` is seeded from `task.milestoneTitle` (`TaskDetailView.swift:65`). On a lookup miss
this is `nil`, which flows to `applyEdits(milestoneNumber: nil)` → `TaskService.swift:85`
`.some(nil)` → `GitHubIssueWriter.swift:62-63` `payload["milestone"] = NSNull()` — **clearing the
task's milestone on GitHub**. It fires on *any* Apply, including one that only changed priority.

This is a live bug today, independent of renaming: `ProjectVersion` is CloudKit-synced while
tasks come from GitHub, so on a fresh device where issues have loaded but versions have not yet
synced, `versions` is empty and every task Apply clears its milestone.

Renaming widens the window on it, so it is fixed as part of this work: a failed name lookup must
mean "don't touch the milestone" (`milestoneNumber: nil` as the outer optional), never "clear
it". Only an explicit user choice of "None" may send `.some(nil)`.

## Testing

XCTest throughout (the suite is 100% XCTest; no swift-testing). Note `VersionService`'s methods
all open with `KeychainService.loadSync`, which fails in the test host — so name validation is
extracted into a pure, token-free `VersionNameValidator` shared by create and rename, and tested
directly.

- **`VersionNameValidator`** — trims; rejects empty; rejects case-insensitive collision within a
  product; allows renaming a version to its own current name (no-op).
- **`VersionStore.rename`** — persists the new name; rewrites `SentReleaseNotification` rows;
  stays scoped to one product (a same-named version in another product is untouched);
  `alreadyNotifiedEmails` still returns the recipient after the rename, and the pre-rename name
  returns nothing.
- **Legacy sent-notification backfill** — a row with `versionID == nil` matching by name is
  resolved, stamped with the version's id, and still resolved after a subsequent rename (the
  regression this FK exists to prevent: the "already emailed" guard must not reset).
- **`GitHubMilestoneReleaseClient.updateMilestone(title:)`** — the first test for this method;
  asserts the PATCH body carries `title`.
- **Filter migration** — a persisted `.versions(["1.2.0"])` scope becomes `.versions(["1.3.0"])`.
- **`TaskDetailView` milestone regression** — a task whose `milestoneTitle` matches no known
  version does not send `milestone: NSNull()` on Apply.

## Out of scope

- Renaming a published release (blocked by design, above).
- Re-keying identity off the name entirely — fetching `milestone { number }`, joining tasks to
  versions on the number, and holding version ids in `VersionScope`. This is the durable end
  state and would make rename a one-line operation with no cascade, but it needs a `CachedIssue`
  schema migration and touches roughly eight test files. The `versionID` FK on
  `SentReleaseNotification` in this spec is a deliberate first step toward it.
