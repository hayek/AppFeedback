# Multi-account mail — design

Status: draft
Date: 2026-05-12

## Problem

The Email settings screen still asks for a provider preset even after an
account has been saved, because the screen is a single inline form bound to
one `MailAccount` row. The user can only configure one address; fetching and
sending are tied to that single row.

This design generalises the app to multiple email accounts. One account is
the default sender (used for outbound replies); all accounts are used for
inbound fetching; the user can override the sender per-reply from a
right-click menu.

## Goals

- A list of configured email accounts in Settings → Email, with an "Add
  account" action.
- Provider/preset picker only appears when adding or editing a specific
  account, never floating above a saved one.
- Exactly one account is the default sender. Default replies use it. The
  user can override via right-click → "Reply from ▸ …".
- Fetching runs in parallel across all configured accounts.
- Existing single-account setups migrate cleanly without losing credentials,
  threads, or templates.

## Non-goals

- Per-account custom signatures distinct from the shared header/footer.
- Send-as aliases inside a single Gmail account (treated as separate
  accounts if the user wants them).
- Reordering or grouping the accounts list beyond creation order.
- iOS-specific UX beyond plumbing the `senderAccountID` through to compose.

## Data model

### `MailAccount` (existing, modified)

- Add `isDefaultSender: Bool` (default `false`). The store enforces that
  exactly one row has it `true` whenever at least one account exists.
- Remove these fields (moved to `MailSettings`):
  - `templateHeaderHTML`
  - `templateFooterHTML`
  - `attachmentFolderBookmark`
  - `pollIntervalSeconds`
- Keep `pollingEnabled` on the account so the user can pause one account
  while keeping others active.

### `MailSettings` (new, singleton @Model)

```
@Model
final class MailSettings {
    var templateHeaderHTML: String = ""
    var templateFooterHTML: String = ""
    var attachmentFolderBookmark: Data? = nil
    var pollIntervalSeconds: Int = 300
}
```

Backed by a new `MailSettingsStore` with `settings` accessor and `update {…}`.
The store fetches the first row sorted by creation time and inserts one if
missing.

### `MailAccountLocalState` (existing, no change)

Already keyed by `accountID: UUID`. Per-account fetch state is already
isolated.

### `MailThread` / `MailMessage` (existing, modified)

- Add `accountID: UUID?` to each. Set by the receiving/sending account.
- Older rows (`nil`) fall back to the global default sender at reply time.

## Keychain

Current state stores SMTP/IMAP passwords under fixed accounts
`smtp.password` and `imap.password`, synchronizable via iCloud Keychain.

New scheme: per-account slots.

- `smtp.password.<accountUUID>`
- `imap.password.<accountUUID>`

Both still synchronizable. `KeychainService` gains:

- `saveSMTPPassword(_ password: String, for accountID: UUID) async -> Bool`
- `loadSMTPPassword(for accountID: UUID) async -> String?`
- `deleteSMTPPassword(for accountID: UUID) async`
- the same trio for IMAP

The legacy fixed-slot **read** methods stay only for the migration path,
then are removed. A legacy **delete** (one-shot, both SMTP and IMAP) is
kept and called on every launch so a device that briefly downgrades and
re-writes the legacy slot doesn't resurrect stale credentials.

## Stores and services

### `MailAccountStore`

- `accounts: [MailAccount]` (sorted by `createdAt`).
- `defaultSender: MailAccount?`.
- `add() -> MailAccount` — creates a new row, assigns `isDefaultSender=true`
  if this is the first account.
- `delete(_ account: MailAccount)` — also reassigns default sender to the
  oldest remaining account if the deleted one was default.
- `setDefaultSender(_ account: MailAccount)` — flips flags so exactly one
  row is default.
- `update(id: UUID, _ mutate: (MailAccount) -> Void)` — replaces the
  current `upsert` API.
- Remove the single-account `account: MailAccount?` accessor; all call
  sites are updated to use `accounts` / `defaultSender` / `account(id:)`.

### `MailSyncCoordinatorRegistry` (new)

Owns one `MailSyncCoordinator` per `MailAccount`.

- On launch: spin one coordinator per account.
- On `accounts` change (add/remove): create/tear down coordinators to
  match.
- On credential change for an account: restart that one coordinator.
- `pollNow()` fans out to all coordinators.
- `stop()` stops all.

Replaces the current `MailSyncCoordinatorHolder` injection. Views poll
via the registry, not a single coordinator.

### `MailSyncCoordinator`

- Constructor takes an `accountID: UUID`.
- All `accountStore.account` references become
  `accountStore.account(id: accountID)`.
- Backfill, local state lookup, and activity log titles include the
  account's email address so the activity log distinguishes accounts.
- One account's `authFailed` stops only its own loop, never the others'.

### `IMAPClientProvider`

- Instantiated per account; constructor takes `accountID: UUID`.
- Reads credentials from `accountStore.account(id:)` and the
  per-account Keychain slot.

### `MailToGitHubMirror`, `OutboundFailureStore`, `OutboundSendTracker`

Unchanged. They key on `messageID`, which is unique across accounts.

## Compose flow

`ComposeMailViewModel` gains:

- `senderAccountID: UUID` (initialiser parameter, required).
- `currentCredentials()` resolves from
  `store.account(id: senderAccountID)`.
- `passwordLoader` defaults to
  `{ await KeychainService.loadSMTPPassword(for: senderAccountID) }`.

`ComposeMailView` shows the resolved sender address in a "From:" row at
the top of the form, above "To:".

`MailThreadView.beginReply` resolves the sender account in this order:

1. The `accountID` on the last message in the thread.
2. The global default sender.
3. `nil` → show the missing-credentials banner already in the compose view.

`ReplyBadgeButton` gains a context menu (right-click on macOS, long-press
on iOS):

- Default `Reply` tap still uses the resolved default.
- `Reply from ▸` submenu lists every configured account by address;
  selecting one opens compose with that `senderAccountID`.
- When only one account is configured, the submenu is hidden.

## Settings UI — macOS

The Email tab becomes master/detail with two sections.

### Accounts section

Left pane: a `List` of accounts, each row showing email address, provider
icon, and a "Default" pill on the default sender. Below the list:
`+ Add account`.

Right pane: the editor for the selected account, scoped to per-account
fields only:

- Provider preset (Gmail / iCloud / Outlook / Custom)
- Email address
- Password (with paste button and Gmail-specific app-password hint)
- Sender display name
- Auto-fetch toggle
- Advanced disclosure (SMTP/IMAP host/port, separate IMAP credentials)
- Action row: `Test connection`, `Set as default`, `Refresh now`,
  `Remove account…`

`Set as default` is hidden when the account is already default.
`Remove account…` confirms with a destructive alert.

### Add account sheet

A modal sheet:

1. Provider preset picker.
2. Email + password (Gmail app-password hint shown for Gmail).
3. `Test & save` button. On success: closes the sheet and selects the
   new account in the list. On failure: keeps the sheet open with the
   error inline.

### Mail templates & defaults section (below the accounts section)

A second grouped section on the same screen:

- Header text editor
- Footer text editor
- Attachments folder picker
- Poll interval stepper
- Placeholders hint grid (unchanged)

These map to the new `MailSettings` row.

## Settings UI — iOS

Same shape, adapted to a `NavigationStack`:

- Account list at top level with an `Add account` row.
- Tapping a row pushes the per-account editor.
- `Mail templates & defaults` is a separate row that pushes its own
  editor.

## Migration (`MailAccountMigration` v2)

Triggered once via UserDefaults flag
`mail.multiaccount.migration.v1.completed`. Steps, in order:

1. Read the legacy single `MailAccount` row, if any. Mark
   `isDefaultSender = true`.
2. Create `MailSettings` if missing. Copy
   `templateHeaderHTML`, `templateFooterHTML`,
   `attachmentFolderBookmark`, `pollIntervalSeconds` from the legacy
   account into it. Clear those fields on the account (kept around at
   the SwiftData layer until the next schema cleanup if removing fields
   triggers a migration we want to avoid; either way they're no longer
   read).
3. Read `smtp.password` / `imap.password` from the legacy Keychain
   slots. If present, save them under
   `smtp.password.<accountUUID>` / `imap.password.<accountUUID>`,
   then delete the legacy slots.
4. Backfill `MailMessage.accountID` and `MailThread.accountID` on
   existing rows with the default sender's UUID (only one account
   existed, so this is unambiguous).
5. Set the migration flag.

The legacy v1 migration (UserDefaults → MailAccount) stays in place and
runs before this v2 step, so a user who upgrades from a very old build
still gets a clean migration.

## Tests

New / updated suites:

- `MailAccountStoreTests` — add/delete/default-sender invariants:
  - first account becomes default automatically
  - deleting the default reassigns to oldest remaining
  - exactly one default at all times
  - update mutates the right row
- `KeychainServiceTests` — extend with per-account
  save/load/delete cases and a round-trip test for the v1→v2 Keychain
  migration.
- `MailSettingsStoreTests` — create, update, singleton invariant.
- `MailSyncCoordinatorRegistryTests`:
  - spins up one coordinator per account on launch
  - adds a coordinator when an account is added
  - tears down on delete and clears local state
  - one account's authFailed does not stop others
  - `pollNow()` fans out
- `ComposeMailViewModelTests` — extend to verify
  `senderAccountID`-specific credentials and password loader are used.
- `MailThreadViewTests` (or a small headless equivalent) —
  resolution order for the reply-from account.
- `MailAccountMigrationTests` — v2 migration covering the legacy
  Keychain → per-UUID slots, the `MailSettings` extraction, the
  `isDefaultSender` flip, and the message/thread `accountID` backfill.

Existing tests using the single-account `store.account` accessor are
updated to use `accounts.first` / `defaultSender`.

## Risks / open items

- **CloudKit schema migration**: introducing `MailSettings` as a new
  `@Model` is a CloudKit schema change. Field removal on `MailAccount`
  is also a schema change. The plan stage should confirm whether to
  keep the legacy fields on `MailAccount` indefinitely (read-once,
  ignored thereafter) to avoid the schema removal, or push the
  removal through SwiftData's lightweight migration.
- **iCloud Keychain merges**: a device on the old build still writes
  to the legacy fixed-slot, which would resurrect post-migration.
  Mitigation: after v2 migration, never write to legacy slots; on
  every launch, opportunistically delete them. Document that the user
  must update all devices for the migration to fully settle.
- **Multiple coordinators and rate limits**: parallel polls hit Gmail
  / iCloud IMAP simultaneously. Existing per-account exponential
  backoff already isolates failures, so this is acceptable; revisit
  only if users report throttling.
