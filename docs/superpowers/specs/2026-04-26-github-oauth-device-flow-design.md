# GitHub OAuth Device Flow — Design Spec

**Date:** 2026-04-26
**Status:** Approved

## Overview

Replace manual token + repo entry with a GitHub OAuth Device Flow login. Users click "Sign in with GitHub", authorize in a browser, then pick their repo from a searchable list. Manual entry remains as a secondary fallback.

---

## Architecture

### New: `GitHubAuthService` (actor, `Services/`)

Owns the entire device flow lifecycle.

```
requestDeviceCode()         POST github.com/login/device/code
                            → DeviceCodeResponse (user_code, device_code, verification_uri, expires_in, interval)

pollForToken(deviceCode:interval:)
                            Polls github.com/login/device/token every `interval` seconds
                            Handles: authorization_pending, slow_down (+5s), access_denied, expired_token
                            → access_token string on success

listRepos(token:)           GET /user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100
                            Paginated (same pattern as IssueLoader)
                            → [GitHubRepo]
```

**Constants:**
- `clientID`: string literal registered GitHub OAuth App client_id (safe in binary — no client_secret used)
- `scope`: `"repo"` (covers public and private)

### New: `GitHubRepo` (model, `Models/`)

```swift
struct GitHubRepo: Decodable, Identifiable {
    let id: Int
    let name: String          // short name
    let fullName: String      // "owner/repo"
    let isPrivate: Bool
    struct Owner: Decodable { let login: String }
    let owner: Owner
}
```

### New: `GitHubLoginView` (view, `Views/Settings/`)

Drives an `AuthState` enum:

```
idle → requestingCode → waitingForUser(DeviceCodeResponse) → fetchingRepos → pickingRepo([GitHubRepo]) → done
```

Cancelled `Task` on dismiss to stop polling.

### Modified: `AddEditRepoView`

New-repo path gains a "Sign in with GitHub" button at the top that presents `GitHubLoginView` as a sheet. Existing manual fields remain below an "or enter manually" divider. Edit-existing path is unchanged.

---

## UX Flow

### Step 1 — Device Code Screen
- GitHub mark + headline: "Connect your GitHub account"
- Large monospaced code badge: e.g. `ABCD-1234`
- "Open GitHub" button → `openURL(verificationUri)`
- Subtle animated indicator (polling in progress)
- Cancel button top-right

### Step 2 — Repo Picker (auto-advances after token arrives)
- `List` with inline search bar
- Each row: full name (`owner/repo`) + lock icon for private repos
- Repos sorted by most recently pushed

### Step 3 — Display Name (inline, not a new screen)
- Appears at the bottom of the picker after a repo is tapped
- Pre-filled text field with the repo's short name
- "Add" button → saves `RepoConfig` + token to Keychain → dismisses entire flow

---

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Code expired (15 min) | "Code expired" message + "Try again" restarts from step 1 |
| Network error | Inline error message + retry button |
| `access_denied` | "Access denied on GitHub" + retry |
| `slow_down` | Increase poll interval by 5s, continue |
| No repos returned | Empty state: "No repos found — check permissions" |

---

## Data & Storage

- Token stored via existing `KeychainService.save(token:for:)` — no changes to `KeychainService`
- OAuth token is functionally identical to a PAT from `IssueLoader`'s perspective
- `RepoConfig` fields: `owner` = `repo.owner.login`, `repo` = `repo.name`, `displayName` = user-editable (defaults to `repo.name`)

---

## Out of Scope

- Token refresh (GitHub OAuth tokens don't expire unless revoked)
- Multi-account support
- Revoking access from within the app
