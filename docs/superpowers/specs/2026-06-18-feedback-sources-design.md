# Feedback sources: App Store reviews + email, and Products

**Date:** 2026-06-18
**Status:** Approved (design)

## Problem

Today the app has exactly **one feedback source** (the AppFeedback SDK, which
writes GitHub issues) and **one backend** (GitHub Issues). There is no `Source`,
`Backend`, or `origin` type anywhere — GitHub is welded into the model: a `Repo`
*is* a GitHub repo, `CachedIssue`'s entire identity is
`(repoOwner, repoName, number)`, and email is already mirrored *into* GitHub
issues. Tasks, versions, milestones, seen-state, and filters are all keyed to
GitHub issue numbers.

The user wants a product (renamed from "Repo") to accept feedback from **multiple
sources**, adding two new ones beyond the SDK:

1. **App Store reviews** — pulled via the App Store Connect API (Issuer ID + Key
   ID + a `.p8` key file), shown in the feedback list alongside everything else,
   *and* the user can post/edit/delete the developer **response** from inside the
   app.
2. **Email** — a dedicated feedback-only inbox where each inbound email becomes a
   feedback item (and replies fold into the same item).

Backends (writing feedback *out* to systems other than GitHub) are explicitly
**deferred** — GitHub remains the only backend for now.

## Decisions (from brainstorming)

These were settled with the user before this spec and drive every choice below:

1. **GitHub stays the universal sink.** New sources are *ingestion adapters* that
   synthesize GitHub issues into the product's repo; `IssueLoader` picks them up
   as normal `CachedIssue`s. **No new feedback model.** Consequence (accepted):
   every product requires a GitHub repo + issue-write token, and the repo accrues
   synthesized issues.
2. **One source of each type per product** (not a list) → flat config on `Product`.
3. **Email threads collapse into one issue** — thread root → new issue, replies →
   comments (reuse existing `MailThread` matching).
4. **App Store source is read *and* write** — developer responses are in scope now.
5. **Full `Repo` → `Product` type rename**, with a CloudKit migration shim.
6. **Source is visible & filterable** — a row badge + a "Source" filter facet;
   source survives the GitHub round-trip via a body marker + label.
7. **Both iOS and macOS** for all configuration (this lifts mail config to iOS).
8. **Review edits update the existing issue** via a stable `reviewId → issueNumber`
   map.
9. Sub-decisions: deleted reviews → close issue + `review-deleted` label + comment
   (never hard-delete); email noise filtering on by default (skip bounces /
   auto-replies); "Respond on App Store" lives in the inspector; App Store rows
   show inline star rating; the existing global `.email` reply-mirror tab stays
   distinct from per-product feedback inboxes.

## Goals

1. Rename `Repo` → `Product` end to end (type + UI + DTO) without losing
   CloudKit-synced data.
2. A **Product Settings** screen (master-detail in a "Products" settings tab, and
   reachable via sidebar right-click / long-press "Settings…") that manages the
   product's sources, on both platforms.
3. An **App Store review source**: poll reviews → synthesized GitHub issues, with
   edit/delete handling and in-app developer responses.
4. An **Email feedback source**: a dedicated IMAP inbox → synthesized GitHub
   issues, replies folded in as comments.
5. **Source badges** in the list and a persisted **Source filter facet**.

## Non-goals

- No generalized `Backend` abstraction (deferred). GitHub-issue creation stays as
  the sink. The only "write-back" is the App-Store-specific developer response.
- No aggregate star-rating ingestion — the ASC API does **not** return
  rating-only reviews (no text), so those cannot appear (Apple limitation).
- No merging of the existing global `.email` reply-mirror accounts into per-product
  feedback inboxes (working feature; out of scope).
- No multi-source-of-same-type (e.g. two App Store apps under one product).

## Architecture overview

```
Product (renamed Repo, @Model + CloudKit)
  ├─ owner/repo + GitHub token (Keychain)              ── the sink + implicit SDK source
  ├─ appStoreIssuerID/KeyID/AppAppleID  (.p8 in Keychain)
  └─ feedbackInboxAccountID → MailAccount{feedbackProductID} (IMAP creds in Keychain)

Ingestion (extends existing background drivers; failure-isolated per source)
  AppStoreReviewCoordinator ─┐                          ┌─ GitHubIssueWriter ─► GitHub repo
  MailSyncCoordinator(role)  ─┼─ FeedbackSourceIngestor ┤   (labels source:*, rating:*)
  ASC responses (write-back) ◄┘   (+ idempotency)        └─ body markers ✚ source/rating
                                                              │
                              IssueLoader poll ───────────────┴─► CachedIssue ─► list/inspector
                                                                   badge + Source filter facet
```

The single `FeedbackSourceIngestor` protocol is a thin seam so a future source is
a well-defined task; it is implemented by per-source coordinators that follow the
proven `MailSyncCoordinator` / `IssueLoader` grain and are scheduled by *extending*
the existing `MacBackgroundRefreshDriver` (NSBackgroundActivityScheduler, 15 min)
and `iOSBackgroundRefreshDriver` (BGTaskScheduler).

## Design

### 1. Data model

**`Product`** (renamed from `Repo`, `@Model`, CloudKit-synced). Keep every
existing field (`id`, `displayName`, `owner`, `repo`, `hiddenAppNames`,
`appColors`, `colorHex`, `createdAt`, `mirrorEmailsToGitHub`,
`redactEmailAddresses`, …) and add flat source config:

```swift
@Model final class Product {            // was Repo
  // …existing fields; id + owner/repo preserved verbatim…
  // App Store source (the .p8 lives in Keychain, never here / never in CloudKit):
  var appStoreIssuerID: String?
  var appStoreKeyID: String?
  var appStoreAppAppleID: String?       // opaque ASC app id (numeric); nil ⇒ source off
  // Email source:
  var feedbackInboxAccountID: UUID?     // → MailAccount with feedbackProductID set; nil ⇒ off
}
```

`RepoConfig` DTO → `ProductConfig`, with the same new fields; `RepoStore` →
`ProductStore` converts both ways. The **SDK source needs no new config** — it
*is* the GitHub connection every product already has; it's the default origin for
any issue our adapters did not synthesize.

`Issuer ID`, `Key ID`, and `Apple app id` are **not secret** and live on the
synced model; the **`.p8` is secret** → Keychain only.

**`MailAccount`** gains one field — `feedbackProductID: UUID?` (nil = a legacy
reply-mirror account; non-nil = the feedback inbox for that product). The
inbox/reply-mirror **`role` is *derived* from this field**, not stored separately.
The IMAP password keeps its existing per-account Keychain key.

**Rename scope (precise).** The type rename + CloudKit migration is scoped to the
`Repo` `@Model` itself plus its non-persisted companions (`RepoConfig` →
`ProductConfig`, `RepoStore` → `ProductStore`). Other persisted `Repo*`-prefixed
types — `RepoFilterPreference`, `RepoFetchState` — **keep their type names** so they
do not incur their own CloudKit record-type migrations; only user-facing strings
change. (They reference products by the preserved `owner/repo` / `id`, so nothing
breaks.)

**`AppStoreReviewMirror`** (new `@Model`, **CloudKit-synced** for cross-device
dedup):

```swift
@Model final class AppStoreReviewMirror {
  var reviewId: String          // ASC customerReviews id
  var productID: UUID
  var issueNumber: Int          // the synthesized GitHub issue
  var contentHash: String       // SHA-256 of rating+title+body → edit detection
  var responseState: String?    // nil | PENDING_PUBLISH | PUBLISHED
  var responseId: String?       // customerReviewResponses id (for DELETE)
}
```

**`CachedIssue`** (local-schema cache) gains two additive columns so the list
renders badges without re-parsing bodies:

```swift
var source: String?   // "sdk" | "app-store" | "email"; nil ⇒ treated as sdk (legacy)
var rating: Int?       // 1…5 for App Store reviews
```

`AppStoreReviewMirror` and `Product` register in **both** the test-host container
and `cloudSchema` (`AppFeedbackApp.init()`); the `CachedIssue` columns are an
additive change to the existing local schema. Any new store **must bump its
`version` on `NSPersistentStoreRemoteChange` + `cloudKitImportSucceeded`** (not
just local writes) or cross-device data stays invisible until relaunch.

### 2. `Repo` → `Product` migration

SwiftData entity name == CloudKit record type, so a rename starts an empty
`CD_Product` type and orphans existing `CD_Repo` rows. Plan:

1. Define `SchemaV1{Repo}` → `SchemaV2{Product}`; keep a **read-only legacy `Repo`
   `@Model` in the schema for one release**.
2. A one-time, idempotent `ProductMigration` (run in `init()` when not testing,
   like the existing `MailAccountMigration`), gated by an `AppStorage` flag set
   only on success: for every `Repo` with no matching `Product`, create a
   `Product` with the **same `id`, `owner`, `repo`** and all fields, then retire
   the `Repo` row.
3. Because every foreign key is the `owner/repo` string pair (not `Repo.id`) and
   `SidebarSelection` uses `id` — both preserved — `CachedIssue`, `MailThread`,
   and filter preferences keep resolving. Remove the shim in a later release.

Migration failure keeps legacy `Repo` data intact and retries next launch (flag
only set on success).

### 3. GitHub synthesis contract (markers + labels)

Extend the SDK's existing `BodyMarkers` so origin survives the round-trip through
GitHub and back into `IssueBodyParser`:

- **Body markers**: `source: app-store|email|sdk`; for reviews `rating`,
  `reviewerNickname`, `territory`, `reviewId`, `reviewCreatedAt`; for email
  `fromAddress` (redacted per `redactEmailAddresses`), `messageId`. *(Reviews
  carry no app version — the ASC API does not expose it — so App Store items have
  no version and fall under "Unassigned" in the version filter.)*
- **Labels** (created-if-missing, idempotent): `source:app-store` / `source:email`,
  `rating:1`…`rating:5`.
- `IssueBodyParser` widens its vocabulary and populates the new `CachedIssue.source`
  / `rating` columns on upsert (exactly how `appName`/`appVersion` already work).
  Absent `source` marker ⇒ default `sdk` (legacy issues keep working).
- A formatter↔parser **round-trip test** mirrors the existing SDK one.

### 4. App Store review source

**Auth.** A new `AppStoreConnectAuth` actor mints an **ES256 JWT via CryptoKit**
(`P256.Signing.PrivateKey(pemRepresentation:)`, signature `.rawRepresentation`
= 64-byte r‖s — **not** DER; do not pre-hash), `aud = "appstoreconnect-v1"`,
`exp ≤ 20 min`, cached ~15 min. New `KeychainService` methods store/load/delete
the `.p8` PEM **keyed by product id** (synchronizable). Responding requires an
Admin / App-Manager / Customer-Support key; a read-only key yields 403 (handled
below).

**Setup form** (`AppStoreSourceForm`, both platforms): paste Issuer ID + Key ID,
import `.p8` (macOS file panel / iOS Files picker), **Test**. On a valid key, call
`GET /v1/apps` and show an **app picker** (a team key sees all the team's apps),
falling back to manual numeric Apple-id entry. Shows last-poll status / error.

**Polling** — a per-product `AppStoreReviewCoordinator` actor + an
`AppStoreReviewCoordinatorRegistry` mirroring `MailSyncCoordinatorRegistry`
(lifecycle synced to the product list, exponential backoff with the existing
Double-clamped formula, MainActor config reads). Two modes:

- **Incremental** (frequent):
  `GET /v1/apps/{id}/customerReviews?sort=-createdDate&limit=200&include=response&fields[customerReviews]=rating,title,body,reviewerNickname,createdDate,territory&fields[customerReviewResponses]=responseBody,lastModifiedDate,state`,
  follow `links.next` until a `createdDate` older than last poll or a known
  `reviewId`.
- **Full re-scan** (periodic, ~daily): walk *all* pages — the only way to catch
  **edits** (reviews have no `updatedDate`; compare `contentHash`) and
  **deletions** (in mirror but absent from scan).
- Reads the `X-Rate-Limit` header (`user-hour-rem`) and backs off proactively;
  handles 429 `RATE_LIMIT_EXCEEDED` (3,500 req/hr rolling per key).
- Depends on an injectable `AppStoreConnectClientProtocol` (same testability
  pattern as `IMAPClientProtocol`).

**Review → issue.** New review → `GitHubIssueWriter` creates an issue (title =
review title, fallback synthesized from body/territory; body rendered with the
markers above + review text; labels `source:app-store`, `rating:N`), recorded in
`AppStoreReviewMirror`. Edit (hash changed) → update issue body/title + a "Review
edited `<date>`" note. Deletion → close the issue + `review-deleted` label +
comment (never hard-delete). Dedup is cross-device via the synced mirror, with a
**search-before-create** GitHub query on the `reviewId` marker as backstop and a
periodic reconcile that collapses any duplicate (keep lowest issue #, close the
other).

**Write-back (developer responses).** When the selected feedback has
`source == app-store`, the inspector shows a **"Respond on App Store"** panel: a
text editor with a ~5,970-char counter (community-observed limit; validate
client-side, handle 422/409 defensively), Submit / Edit / Delete. Submit/Edit =
`POST /v1/customerReviewResponses` (**upsert — there is no PATCH**) using the
issue's `reviewId` marker; Delete = `DELETE /v1/customerReviewResponses/{id}`. We
store `responseId` + `state` in the mirror and drop an issue comment "Responded on
App Store (pending): …" for cross-device record. Polls refresh
`PENDING_PUBLISH → PUBLISHED` (up to ~24h). A 403 (read-only key) disables the
panel with an explanatory note.

### 5. Email feedback source

**Setup** (`EmailSourceForm`, both platforms — this lifts mail config to iOS). A
dedicated feedback inbox is a `MailAccount` with `feedbackProductID` set,
referenced by `Product.feedbackInboxAccountID`. Reuses
`MailAccount`/`MailSettings`/`IMAPClient`/`IMAPClientProvider`/Keychain wholesale
(IMAP host/port/user/password + `Preset`, "Test Connection"). Distinct from
existing reply-mirror accounts (`feedbackProductID == nil`); a derived `role`
distinguishes the two.

**Ingestion** — reuse `MailSyncCoordinator`, made role-aware:

- Feedback inboxes ingest **all** inbound (no `outboundRecipients()` filter).
- A new `MailToFeedbackMirror` runs as a detached Task in `pollOnce()`, parallel to
  `MailToGitHubMirror`, gated on the feedback-inbox role.
- **Thread root → new GitHub issue** (title = subject / "(no subject)"; body =
  `source: email` + `fromAddress` [redacted] + `messageId` markers + body,
  preferring `text/plain` then stripped HTML; label `source:email`; attachments
  via the existing mail-attachment path). Sets `MailThread.issueNumber`.
- **Reply in a known thread → comment** on that issue (reuse the existing
  thread-match + comment path).
- Dedup is free — `recordInbound` dedups by `Message-ID` and `MailThread` is
  CloudKit-synced (cross-device safe). Out-of-order reply before its root → existing
  orphan handling (`issueNumber == 0`).
- **Noise filtering (default on)**: skip bounces (`mailer-daemon` / empty
  Return-Path) and auto-replies (`Auto-Submitted: auto-*`, `Precedence: bulk|list`).

### 6. Product Settings UI

`SettingsTab.repos` → **`.products`** ("Products"), reworked into **master-detail**:
product list on the left, the selected product's `ProductSettingsView` (evolved
from `AddEditRepoView`) on the right, with two sections:

- **General** — display name, color, GitHub connection (owner/repo/account/token),
  `mirrorEmailsToGitHub`, `redactEmailAddresses`, hidden app names.
- **Sources** — a row per type with status + configure:
  - **SDK** — informational/always-on ("Receiving issues from `owner/repo`").
  - **App Store** — Off / Configured → `AppStoreSourceForm`; enable/disable, Remove.
  - **Email** — Off / Configured → `EmailSourceForm`; enable/disable, Remove.

**Entry points:**

1. Settings → **Products** tab → pick a product → its detail (macOS: existing
   NSToolbar settings *window*; iOS: `NavigationStack`/`Form` in the settings sheet).
2. **Sidebar → right-click (macOS) / long-press (iOS) → "Settings…"** opens the
   *same* `ProductSettingsView` (macOS focuses the Settings window on the product;
   iOS presents a sheet). `RepoSectionView`'s context menu (today Color + Remove)
   gains a leading **Settings…** item.

Wiring: new `SettingsTab.products` case + `tabContent()` arm + `allTabIdentifiers()`
+ `displayName`/`systemImageName`. **Add flow stays minimal** ("+" creates the
product with its GitHub connection; sources configured afterward in settings). The
existing global `.email` reply-mirror tab stays, labeled distinctly.

### 7. List badges + Source filter facet

- **Badge** (leading, derived from `CachedIssue.source`/`rating` via `FeedbackIssue`):
  SDK (wrench/SDK glyph), **App Store** (Apple mark + inline `★★★☆☆`), **Email**
  (envelope). Falls back to SDK when `source` is nil.
- **Filter facet**: a `FeedbackSource` enum (`.sdk / .appStore / .email`, each with
  display name + SF Symbol) added to `RepoFilterPreference` / `FilterPreferenceStore`
  as a persisted `sources: Set<FeedbackSource>`, surfaced in the existing filter
  sidebar as a **Source** section (checkboxes, default all-on) beside Version and
  Status, persisted per product and synced via the existing CloudKit container.

### 8. Error handling & failure isolation

Each source has its own coordinator, backoff, and **per-source status**
(`lastSuccessAt` / `lastError`) shown in its form — one source failing never blocks
the others or the normal GitHub issue load.

- **ASC**: 401 → auth-failed (prompt re-auth); 403 → disable write; 429 → back off
  per `X-Rate-Limit`; 5xx → exponential backoff.
- **GitHub synthesis** failure → simply don't record in the mirror; safely retried
  next poll (idempotent via mirror + search-before-create).
- **Read-only / missing GitHub token** → clear "sources need an issue-write token"
  message (synthesizing requires write scope).
- **Migration** failure → legacy data intact, retried next launch.
- **Lifecycle**: disabling a source stops polling, keeps existing issues; removing a
  product cascades (stop coordinators, drop mirror rows + Keychain `.p8` +
  feedback-inbox account) but never touches GitHub.

### 9. Testing

`AppFeedbackTests_macOS`, in-memory (`cloudKitDatabase: .none`); use **xcodebuild**
for ground truth (the `/api/test` summary masks hard crashes). The ~11 pre-existing
Keychain / GitHubAccount failures are **not** regressions.

- **JWT**: sign with an in-test CryptoKit EC key (no Keychain), assert
  header/payload/`exp` and a 64-byte raw signature verifiable by the public key.
- **ASC client**: a fake `AppStoreConnectClientProtocol` feeds canned JSON —
  pagination, `include=response`, edits (hash change), deletions, rating-only
  absence, 429 — asserting synthesis/mirror/edit/delete + backoff parsing.
- **Round-trips**: formatter↔`IssueBodyParser` for the new markers;
  `MailToFeedbackMirror` (root→create, reply→comment, noise→skip) with a fake issue
  writer, asserting at the sync store level (the async remote-change version-bump
  gotcha means do **not** assert version across coordinator polls).
- **Migration**: seed `SchemaV1{Repo}`, run `ProductMigration`, assert `Product`
  with same `id/owner/repo`, foreign keys still resolve, idempotent on re-run.
- **Filter/badge + reconcile**: source-facet filtering, badge from stored
  `source`/`rating`, legacy default to SDK, duplicate-collapse reconcile.

## Rollout — 6 independently shippable phases

0. `Repo → Product` rename + migration shim (no behavior change).
1. GitHub marker/label contract + `CachedIssue.source/rating` + badges + Source
   filter facet (works with SDK-only).
2. Product Settings master-detail + sidebar "Settings…" (both platforms).
3. App Store read path (auth, poll, synthesis, edit/delete).
4. App Store write-back (responses in the inspector).
5. Email feedback source (feedback-inbox role + `MailToFeedbackMirror`).

The legacy `Repo` shim is removed a release after Phase 0.

## Open implementation notes (verify during build)

- ASC `responseBody` max length is undocumented (5,970 is community-observed) —
  validate client-side and handle 422/409 defensively.
- No official figure for how long after posting a customer review appears in the
  API — don't treat "absent" as authoritative for very recent activity.
- `connectedRepoOwner/Name` on the old `Repo` appear unused — confirm before
  carrying them onto `Product` or dropping them.
- Exact ASC pagination/field-selection syntax to be re-verified against
  `developer.apple.com` during Phase 3.
