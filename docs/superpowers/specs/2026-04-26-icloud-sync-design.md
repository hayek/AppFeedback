# iCloud Sync — Design Spec

**Date:** 2026-04-26
**Status:** Approved (design)
**Scope:** Sync existing user data (repos, hidden apps, GitHub OAuth tokens) across the user's Macs, iPads, and iPhones.

## Goals

- A user signed into iCloud sees the same repos and hidden-app preferences on every device running AppFeedback.
- GitHub OAuth tokens follow the user, so adding a repo on one device does not require re-authenticating on another.
- The app remains fully functional when iCloud is unavailable (signed out, iCloud disabled). State of sync is visible but never blocking.

## Non-Goals

- Migration from the existing `UserDefaults`-backed store. The app is not live; there is no production data to migrate.
- Schema or sync for future features (per-app todos, releases, scheduled replies). Each will be designed separately when it is built.
- Multi-user / shared-database collaboration. Private database only.
- Manual conflict-resolution UI. Last-writer-wins is acceptable for single-user data.
- Background push subscriptions and custom CloudKit retry logic. SwiftData's CloudKit mirroring handles this.

## Backend Decision

**SwiftData + CloudKit (private database).**

Rejected alternatives:
- `NSUbiquitousKeyValueStore` — fits today's data but caps at 1 MB and forces blob-merge semantics; future entities (todos, releases, replies) would not fit.
- Hand-rolled CloudKit (`CKRecord`) — more code, no schema ergonomics; SwiftData gives us the same backend with declarative `@Model` types.

Deployment targets (iOS 17 / macOS 14) match SwiftData's minimum exactly.

## Architecture

### Storage layers

| Layer | Stores | Mechanism |
| --- | --- | --- |
| SwiftData + CloudKit private DB | `Repo` entities (incl. hidden app names) | `ModelContainer` with `cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")` |
| iCloud Keychain | Per-repo OAuth tokens | `KeychainService` items with `kSecAttrSynchronizable = true` |
| `UserDefaults` | (retired for synced data) | n/a |

### Entitlements (`AppFeedback.entitlements`)

Add:
- `com.apple.developer.icloud-container-identifiers` → `["iCloud.com.amirhayek.AppFeedback"]`
- `com.apple.developer.icloud-services` → `["CloudKit"]`

The existing `keychain-access-groups` entry is sufficient for iCloud Keychain sync; no change needed.

### Sync status surface

A `CloudSyncStatus` observable service watches `CKContainer.default().accountStatus()` and reacts to `CKAccountChanged` / `NSUbiquityIdentityDidChange` notifications. Its public state:

```swift
enum SyncState {
    case syncing
    case unavailable(reason: UnavailableReason)
    case error(message: String)
}

enum UnavailableReason { case notSignedIn, restricted, temporarilyUnavailable }
```

`SettingsView` adds a status row at the top showing icon + short status text. When `unavailable`, it includes a small "Open System Settings" / "Open Settings" button that deep-links to iCloud preferences.

The app remains usable in every state — the local SwiftData store works without the cloud mirror.

## Data Model

CloudKit imposes constraints on SwiftData schemas: every property must be optional or have a default; no unique constraints; all relationships optional.

```swift
@Model
final class Repo {
    var id: UUID = UUID()
    var displayName: String = ""
    var owner: String = ""
    var repo: String = ""
    var hiddenAppNames: [String] = []
    var createdAt: Date = Date()

    init(displayName: String, owner: String, repo: String) {
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
    }
}
```

### Why `hiddenAppNames` is a property, not a child entity

The set is small (a handful of app names per repo), and the user action is always "toggle hide on app X." Same-second concurrent edits across a single user's devices are vanishingly rare, so CloudKit's last-writer-wins on the array is acceptable. A child entity would buy fine-grained merge we do not need.

### `RepoConfig` value type

Kept as a `Codable, Sendable` snapshot for views and sheets that prefer value semantics (`AddEditRepoView`'s `existing:` parameter, `SidebarSelection`'s `repoId`, previews, tests). Views read `Repo` via `@Query`, edit through a `RepoConfig` snapshot, then commit the change back to the model.

### `RepoStore` retired

`RepoStore` is removed. Its responsibilities are split:
- **Read:** views use `@Query var repos: [Repo]` directly.
- **Mutation:** a small `RepoMutator` helper takes `ModelContext` and exposes `add(_:)`, `update(_:)`, `remove(id:)`, `hideApp(_:in:)`, `unhideAllApps(in:)`.

### `KeychainService`

Keyed by `repo.id.uuidString` (already is). Each query dictionary (add, load, delete) gains:

```swift
kSecAttrSynchronizable as String: kCFBooleanTrue!
```

No interface change for callers. Tokens propagate via iCloud Keychain when the user has it enabled; if not, tokens stay device-local and the existing "no token" UI in `SettingsView` already covers the gap.

## Container Setup

In `AppFeedbackApp`:

```swift
let schema = Schema([Repo.self])
let config = ModelConfiguration(
    schema: schema,
    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
)
let container = try ModelContainer(for: schema, configurations: config)
```

Container is injected via `.modelContainer(container)`. SwiftData merges remote changes into `@Query` results automatically.

## Error Handling

- CloudKit errors are surfaced **passively** through the `CloudSyncStatus` row. They never block the UI. SwiftData retries automatically.
- `ModelContainer` init failure (corrupt local store) is the only fatal case: `assertionFailure` in debug, `fatalError` in release with a logged reason.
- Keychain sync needs no special handling — the OS propagates items when iCloud Keychain is on. If it is off, tokens are device-local; nothing breaks.

## Testing

- All unit tests use an in-memory `ModelContainer`:
  ```swift
  ModelConfiguration(isStoredInMemoryOnly: true)
  ```
  No CloudKit, no disk I/O.
- `CloudSyncStatus` is protocol-fronted (`CloudSyncStatusProviding`) so views can be previewed and tested with stub statuses.
- Tests follow the existing `pfw-testing` patterns; no new test infrastructure.
- **Manual verification only:** real CloudKit round-trip on two devices (one Mac + one iPad) before sign-off — sufficient for first cut.

## Out of Scope

- Migration from `UserDefaults`.
- Background refresh / custom push subscriptions.
- Conflict-resolution UI.
- Schema for future todos / releases / scheduled replies.
- Sharing / multi-user CloudKit databases.

## Open Risks

- **iCloud container provisioning:** the identifier `iCloud.com.amirhayek.AppFeedback` must be created in Apple Developer portal before the entitlement resolves. Implementation plan must include this step.
- **First-run on second device:** SwiftData+CloudKit's initial sync can take seconds to minutes depending on network. The status row covers this — user sees "Syncing via iCloud" until data arrives.
