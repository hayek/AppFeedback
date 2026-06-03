# Persistent GitHub accounts — design

Status: draft
Date: 2026-06-03

## Problem

Adding a repository forces a full GitHub device-flow re-authorization **every
time**, even though the user authorized the app moments earlier for a different
repo. The OAuth token *is* persisted — but only under a per-repo Keychain key
(`owner/repo`), and the app has no concept of a "GitHub account." Every tap of
**Sign in with GitHub** runs `GitHubLoginView.startDeviceFlow()`, which
unconditionally requests a fresh device code (`GitHubLoginView.swift:171`) and
sends the user back to github.com to type a code — discarding the perfectly
valid `repo`-scoped token already in Keychain.

A single device-flow token has `repo` scope (`GitHubAuthService.swift:7`), so
one token already grants access to every repository that account can see across
all the user's orgs. The fix is to persist the OAuth token **once per GitHub
account** and reuse it: skip the device dance on subsequent adds and jump
straight to a repo picker, while allowing the user to connect, switch between,
and disconnect multiple GitHub accounts.

## Goals

- GitHub sign-in persists across Add Repository sessions and across the user's
  devices (iCloud, like repos and mail accounts already do).
- Support **multiple** connected GitHub accounts simultaneously.
- Add Repository presents repositories grouped into **one collapsible section
  per connected account**, each loaded live with that account's token, with a
  search field spanning all sections.
- Each account section offers **Disconnect** (and **Reconnect** when its token
  has expired/been revoked).
- A **Connect another account** action launches the device flow to add a new
  account.
- Manual personal-access-token (PAT) entry stays as a fallback for repos the
  API doesn't surface or users who prefer fine-grained PATs.
- Downstream services that read per-repo tokens keep working unchanged.

## Non-goals

- A separate "GitHub Account" management section in Settings → Repos. Account
  management lives in the Add Repository sheet (per the chosen UX).
- Auto-seeding accounts from the existing per-repo tokens of already-added
  repos. Tokens are opaque; we would have to probe `GET /user` per repo and
  reconcile shared tokens. The user connects once on the next Add and it sticks.
- Revoking tokens at GitHub on disconnect (we only forget them locally).
- Reordering / manual grouping of accounts beyond creation order.
- Changing the device-flow OAuth app, client ID, or scope.

## Data model

### `GitHubAccount` (new, `@Model`)

Mirrors `MailAccount`. CloudKit-synced (private database), so connected accounts
roam across the user's devices.

```
@Model
final class GitHubAccount {
    var id: UUID = UUID()
    var login: String = ""        // GitHub username, e.g. "hayek"
    var avatarURL: String? = nil  // owner.avatar_url, for the section header
    var createdAt: Date = Date()
}
```

The OAuth token is **not** stored on the model — it goes to Keychain (below),
keyed by `id`. This matches `MailAccount`, which keeps SMTP/IMAP passwords out
of the synced model and in iCloud Keychain.

Registered in `AppFeedbackApp` everywhere `MailAccount.self` appears: the
`cloudSchema`, and both `ModelContainer(for:)` argument lists (test +
production).

### `Repo` / `RepoConfig` (existing, unchanged)

No new field linking a repo to an account. The picker only needs the live
account list plus each account's live repo list; an added repo continues to
carry its own per-repo token copy in Keychain and is otherwise independent.

## Keychain

GitHub session tokens get a per-account slot, exactly mirroring the existing
SMTP/IMAP per-account helpers in `KeychainService`:

- Account key: `github.token.<accountUUID>`
- Service: existing `com.feedbackviewer.tokens`, `kSecAttrSynchronizable = true`

`KeychainService` gains (copied from the SMTP/IMAP per-account trio, which
already delegate to the shared `saveSynchronizablePassword` /
`loadSynchronizablePassword` / `deleteSynchronizablePassword` helpers):

- `saveGitHubToken(_ token: String, for accountID: UUID) async -> Bool`
- `loadGitHubToken(for accountID: UUID) async -> String?`
- `loadGitHubTokenSync(for accountID: UUID) -> String?` (synchronous variant,
  for non-`async` callers — parallels `loadSync(for:)`)
- `deleteGitHubToken(for accountID: UUID) async`

The existing per-**repo** token methods (`save/load/loadSync/delete(for:
RepoConfig)`) are untouched and remain the source of truth for downstream
services.

## Auth service

`GitHubAuthService` (existing actor) gains one method:

```
func fetchCurrentUser(token: String) async throws -> GitHubUser   // GET /user
```

`GitHubUser` (new, in `GitHubAuthModels.swift`):

```
struct GitHubUser: Decodable, Sendable {
    let login: String
    let avatarURL: String?   // "avatar_url"
}
```

`requestDeviceCode`, `pollForToken`, and `listRepos(token:)` are unchanged.
`listRepos` already throws `AuthError.apiError(code)` on non-2xx, which the UI
uses to detect a dead token (401/403).

## Store

### `GitHubAccountStore` (new, `@MainActor @Observable`)

Mirrors `MailAccountStore`.

```
@MainActor @Observable
final class GitHubAccountStore {
    private(set) var accounts: [GitHubAccount]   // sorted by createdAt

    func account(id: UUID) -> GitHubAccount?
    func token(for account: GitHubAccount) -> String?        // loadGitHubTokenSync
    func add(login: String, avatarURL: String?, token: String) async -> GitHubAccount
    func deleteWithCredentials(_ account: GitHubAccount) async  // model + Keychain token
    func reload()
}
```

- `add` upserts by `login` (case-insensitive): if an account with that login
  already exists, update its `avatarURL` and overwrite the Keychain token in
  place (this is also the **Reconnect** path); otherwise insert a new row. Then
  save the token to Keychain and `reload()`.
- `fetch` applies the same CloudKit **`coalesce`** dedup that `MailAccountStore`
  uses: collapse duplicate rows arriving from multi-device sync, keyed by
  `login` (case-insensitive), oldest row wins; drop empty-login rows when any
  non-empty row exists.

Created in `AppFeedbackApp` next to `RepoStore`, injected into the environment
the same way (a `@State` on the app + `.environment(...)`, matching how
`RepoStore`/`MailAccountStore` are provided).

## UI

### Connect flow — `GitHubLoginView` (refactored)

Trimmed to a single responsibility: **connect an account**.

- Keeps the device-flow states `requestingCode` → `waitingForUser` →
  (new) `finalizing`, and `failed`.
- Removes the `fetchingRepos` / `pickingRepo` states and `RepoPickerContent`
  (moves to the Add sheet).
- After `pollForToken` returns a token: call `fetchCurrentUser(token:)`, then
  `accountStore.add(login:avatarURL:token:)`, then call `onCompleted?()` and
  `dismiss()`. No repo is selected here.
- Takes a `GitHubAccountStore` (replaces the `RepoStore` dependency) and an
  optional `onCompleted` callback.

Reused for both first-time connect and **Connect another account**.

### Add Repository sheet — `AddEditRepoView` (rebuilt picker)

Edit mode is unchanged (manual fields only, as today). New-repo mode changes:

**No accounts connected (first-run / all disconnected):** the current empty
state — the prominent **Sign in with GitHub** button (now launching the connect
flow) above "or enter manually" and the manual fields. Visually identical to
today.

**One or more accounts connected:** a *Choose a repository* section:

- A search field spanning all accounts (filters `fullName`, case-insensitive),
  mirroring today's `RepoPickerContent` search.
- A list with **one `DisclosureGroup` per account**, sorted by `createdAt`:
  - **Header:** avatar (`AsyncImage` from `avatarURL`, SF-symbol fallback) +
    `@login` + a `⋯` menu containing **Disconnect** (always) and **Reconnect**
    (shown when the section is in the expired state). The first account starts
    expanded; others collapsed. Expansion state held in `@State`.
  - **Body:** that account's repositories, fetched lazily on first expansion via
    `listRepos(token:)` using `accountStore.token(for:)`. Per-account load
    state held in `@State` (`[UUID: AccountRepoState]` where state is
    `loading | loaded([GitHubRepo]) | failed(message) | expired`). A spinner
    while loading; an inline error + **Retry** on generic failure; the
    "Session expired — Reconnect" treatment when `listRepos` throws
    `apiError(401|403)`.
  - A repo already added to the app (matched by `owner/name` against
    `RepoStore.repos`) renders dimmed with an "Added" tag and is not selectable.
  - Selecting a repo sets the selection and prefills the display-name field.
- A **+ Connect another account** row at the bottom of the list → presents the
  connect flow as a sheet; on completion the new section appears and auto-loads.
- Below the list: the existing **or enter manually** divider and manual fields
  (Display Name / owner / repo / GitHub Token), kept as a fallback.

**Add action.** When a repo is chosen from an account section, `save()` writes
that account's token under the repo's `owner/repo` per-repo Keychain key
(`KeychainService.save(token:for:)`) **before** `store.add` — preserving the
existing ordering that prevents `SettingsView` from briefly showing "no token"
(`AddEditRepoView.swift:275`). When the manual fields are used, behavior is
exactly as today (the typed token is saved per-repo). Either way, downstream
services keep reading per-repo tokens with **zero changes**.

### Components

- New `AccountRepoPicker` view (the searchable, multi-section list) extracted
  from `AddEditRepoView` to keep that file focused; it owns the per-account
  fetch/expansion state and reports a selected `(GitHubRepo, GitHubAccount)`
  plus display name back to the parent.
- The repo-row visuals reuse the styling from today's `RepoPickerContent`
  (private/lock label, checkmark on selection).

## Edge cases

- **Disconnect** removes the `GitHubAccount` row and its `github.token.<uuid>`
  Keychain slot only. Already-added repos retain their own per-repo token copies
  and keep working — disconnect never breaks existing repos.
- **Expired / revoked token**: detected when `listRepos` throws
  `apiError(401)` or `apiError(403)`. That section shows "Session expired —
  Reconnect"; Reconnect runs the device flow for that login and overwrites the
  token in place (the `add` upsert path), then reloads the section.
- **CloudKit duplicate accounts**: the same login synced from two devices is
  collapsed by `coalesce`, as in `MailAccountStore`.
- **Re-connecting an already-connected login**: `add` upserts rather than
  creating a second row; the token is refreshed.

## Migration

None required at the data layer. There is no legacy `GitHubAccount` data — the
store simply starts empty until the user connects. Existing repos keep their
per-repo Keychain tokens untouched and continue to work. (Auto-seeding accounts
from those tokens is an explicit non-goal.)

Adding `GitHubAccount` as a new `@Model` is a CloudKit schema addition; like the
`MailSettings` addition before it, it is additive and handled by SwiftData /
NSPersistentCloudKitContainer without a manual migration step.

## Tests

- `GitHubAuthTests` — extend with `fetchCurrentUser`: decodes `login` /
  `avatar_url`; throws `apiError` on non-2xx. (Uses the existing URLProtocol
  stub pattern in that suite.)
- `GitHubAccountStoreTests` (new), in-memory `ModelContainer`:
  - `add` inserts a row, persists the token, and `token(for:)` round-trips it.
  - `add` with an existing login upserts (no duplicate row) and refreshes the
    token (the Reconnect path).
  - `deleteWithCredentials` removes the row and clears the Keychain token.
  - `coalesce` collapses duplicate logins from simulated multi-device sync;
    oldest wins; empty-login rows dropped when a non-empty row exists.
- `KeychainServiceTests` — add GitHub per-account save/load/loadSync/delete
  round-trip cases (parallel to the existing SMTP/IMAP per-account cases).

The two existing repos and current device-flow tests remain green; no existing
test relies on `GitHubLoginView`'s repo-picking responsibility (it is UI-only).

## Risks / open items

- **CloudKit schema addition**: confirm at the plan stage that registering
  `GitHubAccount` in the synced schema deploys cleanly to the existing private
  database, consistent with how `MailSettings`/`ProjectVersion` were added.
- **Per-account repo fetch fan-out**: expanding several large accounts triggers
  parallel `GET /user/repos` paginated calls. Acceptable — fetch is lazy
  (on first expansion) and cached per session; revisit only if rate limits bite.
- **Avatar loading**: `avatarURL` is rendered via `AsyncImage` with an SF-symbol
  fallback; no caching beyond the system default. Fine for a small account list.
