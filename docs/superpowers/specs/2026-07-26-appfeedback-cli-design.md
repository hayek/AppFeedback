# AppFeedback CLI + AI Skill — Design

**Date:** 2026-07-26
**Status:** Draft

## Summary

Ship a macOS command-line interface to the feedback inbox, plus a skill that
teaches an AI agent to use it. The agent normally runs from a *different* repo —
the code repo of the app whose feedback it is reading — so the CLI must be
self-describing and reachable from anywhere.

The CLI is the app binary. `@main` moves onto a dispatcher that runs a
subcommand and exits before SwiftUI is touched, so the CLI reads the stores
through the app's own `@Model` types — no duplicated schema, no drift, and no
separate codesigning or provisioning to maintain.

Reads open the app's stores **read-only** and answer from the local cache —
instant, offline, no GitHub rate limit. Writes are **delegated to the running
app** over a file-backed IPC channel: the app executes the identical call its
own UI makes, so behaviour cannot drift, CloudKit mirroring is undisturbed, and
the open UI reflects the change immediately.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Binary | CLI mode inside the app binary | Same `@Model` schema as the store it reads; nothing to keep in sync, nothing extra to sign |
| Read source | Local cache, read-only | Instant, offline, no rate limit; app refreshes every 15 min |
| Freshness | `--refresh` on every read command | Nudges the running app to poll, then reads |
| Write execution | Delegated to the running app | "The same function the UI calls"; keeps CloudKit and UI state coherent |
| Targeting | Explicit `--product`, discovered via `products` | No hidden state; works from any directory |
| Output | JSON on stdout by default | Agent-first; `--text` for humans |
| Reporter email | Redacted by default | `--include-emails` to opt in |
| Send approval | Skill-level, not CLI-level | Agent must show the drafted reply and get explicit user agreement |
| Name | `appfeedback`, from one constant | Product name is temporary; renaming must be a one-line change |

## Naming

`CLIBranding` holds the single source of truth:

```swift
enum CLIBranding {
    static let commandName = "appfeedback"          // binary symlink + skill folder
    static let skillFolderName = "appfeedback"
    static let ipcPrefix = "com.amirhayek.AppFeedback.cli"   // DNC notification names
}
```

Every user-visible string, symlink path and notification name derives from it.
Renaming the product later touches this file only (plus a re-install from
Settings).

## Architecture

### Entry point

`AppFeedbackApp` loses `@main`; a new `AppFeedback/App/AppFeedbackMain.swift`
gains it:

```swift
@main
enum AppFeedbackMain {
    static func main() {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let invocation = CLIInvocation.parse(CommandLine.arguments) {
            CLIEntry.run(invocation)          // never returns
        }
        #endif
        AppFeedbackApp.main()
    }
}
```

Rules, in order:

1. **XCTest bail-out first.** The macOS test host launches this binary with
   XCTest-controlled argv; a subcommand-shaped argument there must never divert
   into the CLI.
2. **Strict allowlist.** `CLIInvocation.parse` returns non-nil only when
   `argv[1]` is exactly one of the known nouns (`products`, `feedback`, `tasks`,
   `respond`) or `help`/`--help`/`version`/`--version`. Everything else —
   including Finder's `-psn_*` and Xcode's `-NSDocumentRevisionsDebugMode YES` —
   falls through to the GUI.
3. **iOS builds compile the dispatcher but never the CLI internals** (`#if
   os(macOS)`), so the shared source set still builds for both platforms.

`CLIEntry.run` starts the async work and then calls `RunLoop.main.run()` —
**not** `dispatchMain()`. Distributed-notification delivery rides a CFRunLoop
source on the registering thread; `dispatchMain()` parks the main thread without
running a run loop, so IPC replies would never arrive. Blocking the main thread
on a semaphore is equally wrong: `@MainActor` work would deadlock behind it. The
async task calls `exit(code)` when finished. A watchdog exits `7` after 60s so a
wedged path can never hang an agent forever.

### Read path

A purpose-built read-only data layer — **not** the app's stores. `ProductStore.reload()`
writes (it calls `HiddenAppStore.migrateLegacy`, `ProductStore.swift:202`), and app
init runs migrations (`AppFeedbackApp.swift:131-139`); on an `allowsSave: false`
container those fail noisily.

`CLIStore` opens two containers with plain `FetchDescriptor` access:

| Container | File | Entities read |
|---|---|---|
| local | `~/Library/Application Support/local.store` | `CachedIssue`, `TriageVerdictRecord`, `RepoFetchState` |
| cloud | `~/Library/Application Support/cloud.store` | `Product`, `HiddenApp`, `ProjectVersion`, `MailThread`/`MailMessage` |

Both use `allowsSave: false, cloudKitDatabase: .none` — no second CloudKit
syncer, no writes. Schemas match the split at `AppFeedbackApp.swift:98-105`.

Guards:

- `FileManager.fileExists` on each store **before** opening. A `ModelContainer`
  pointed at a missing file creates an empty one — a write, and it would mask
  the "no local data" condition. Missing store ⇒ exit `3` with "launch
  AppFeedback once first".
- A read-only open that fails (e.g. a dev binary with a newer schema reading the
  installed app's store) ⇒ exit `3` with a clear message, never a crash.
- **Snapshot fallback.** If the read-only open fails for any other reason, open
  the file with SQLite and `VACUUM INTO` a temp path, then point SwiftData at the
  snapshot. Copying `.store` + `-wal` + `-shm` by hand is not atomic against a
  live writer; `VACUUM INTO` is.

### Write path (IPC)

The CLI never writes to the stores and never talks to GitHub, SMTP or App Store
Connect itself. It delegates:

```
CLI                                  App (running)
───                                  ─────────────
write  <ipc>/req-<uuid>.json
post   …cli.request  ──────────────► CLIRequestResponder reads the file
                                     executes the identical UI call
wait on RunLoop  ◄───────────────── writes <ipc>/res-<uuid>.json
read + print res, exit               posts …cli.response
```

- **Transport.** `DistributedNotificationCenter`, correlation UUID in
  `userInfo`. Both ends **must** use `deliverImmediately` — AppKit suspends DNC
  delivery while an app is inactive, which it always is when an agent drives a
  terminal, so the default `.coalesce` behaviour would silently hang every call
  until the app next came forward. Observer registers with
  `suspensionBehavior: .deliverImmediately`; poster uses
  `postNotificationName(_:object:userInfo:deliverImmediately: true)`.
- **Payload on disk, not in userInfo.** Request/response bodies live in
  `~/Library/Application Support/AppFeedback/cli-ipc/`, and only the UUID travels
  in the notification. DNC payloads are plist/XPC-bounded; an email body is not.
  Files are deleted by the writer after the peer reads them, and any file older
  than 1h is swept on app launch.
- **Liveness.** The CLI checks
  `NSRunningApplication.runningApplications(withBundleIdentifier:)` up front;
  not running ⇒ exit `6`, `{"error":{"code":"app_not_running"}}`, with a hint to
  open the app. This works from a process that never starts `NSApplication`.
- **Registration.** `CLIRequestResponder` is created in `AppFeedbackApp.init`
  (not `onAppear`) so it is live regardless of window state, `#if os(macOS)`
  only.
- **Timeouts.** Default 30s (`--timeout`). A refresh that times out is not fatal:
  the CLI answers from cache with `"stale": true, "refreshTimedOut": true`. A
  *write* that times out exits `5` and says the outcome is unknown — the agent
  must not retry blindly.

## Command surface

Noun-verb; a bare noun means `list`. JSON to stdout by default; `--text` renders
a compact human table.

```
appfeedback products [--refresh]
appfeedback feedback [list] --product <p> [filters] [--limit 20] [--offset 0] [--refresh]
appfeedback feedback show <number> --product <p> [--raw] [--refresh]
appfeedback tasks [list] --product <p> [--status …] [--priority …] [--version …] [--search …] [--refresh]
appfeedback tasks show <number> --product <p> [--refresh]
appfeedback tasks create --product <p> --title <t> [--notes <n>] [--status …] [--priority …] [--version <v>] [--feedback 12,34]
appfeedback tasks link --product <p> --task <n> --feedback 12,34
appfeedback tasks unlink --product <p> --task <n> --feedback 12
appfeedback respond --product <p> --feedback <n> --body <text> [--template <title>] [--via auto|email|app-store|comment]
appfeedback help [<command>]
appfeedback version
```

### Product resolution

`--product` accepts a UUID, a display name (case-insensitive exact), or
`owner/repo`. Resolution order: UUID → display name → `owner/repo`. Ambiguity
exits `1` with the candidate list in the error payload.

Two of the user's products point at the same repo, and feedback, tasks, hidden
apps and tokens are **all** repo-scoped — so products sharing a repo return
identical feedback. `--app` is the real scoping knob, and the skill says so.

### Feedback filters

`--app <name>` (repeatable) · `--state open|closed|all` (default `open`) ·
`--source sdk|app-store|email` · `--type bug|feature-request` · `--label <name>`
(repeatable, exact) · `--search <text>` · `--since 7d|2026-07-01|ISO8601` ·
`--updated-since …` · `--min-rating N` · `--max-rating N` ·
`--app-version <v>` · `--has-task` / `--no-task` · `--include-hidden` ·
`--include-emails` · `--sort created|updated` (default `created`) ·
`--order desc|asc` (default `desc`).

`--search` matches case-insensitive substrings in title, description and
`appName`, mirroring `IssueListViewModel.swift:100`. Sort is stabilised by
issue number descending.

Combination rules, so nothing is left to interpretation:

- A **repeated** flag ORs its own values: `--app A --app B` means A or B; the
  same holds for `--label`, `--source`, `--type` and (on `tasks`) `--status`
  and `--priority`.
- **Different** flags AND together: `--app A --state open --type bug` means all
  three.
- `--min-rating` / `--max-rating` are inclusive; an item with no rating is
  excluded whenever either is given.
- `--since` / `--updated-since` are inclusive lower bounds. Relative forms
  (`7d`, `24h`) are measured from now; absolute forms accept `YYYY-MM-DD` (UTC
  midnight) or full ISO8601.
- `--limit` defaults to 20 and is capped at 200; a larger value exits 1 rather
  than silently clamping.
- `--has-task` / `--no-task` are mutually exclusive; giving both exits 1.

### Semantics that mirror the app

- **Feedback excludes tasks.** Issues labelled `appfeedback:task` are tasks;
  `feedback` returns the complement, `tasks` returns exactly those.
- **Hidden apps are filtered by default**, from `HiddenApp` rows keyed by
  `(repoOwner, repoName)` — not by product.
- **`asOf`** is `RepoFetchState.lastFetchedAt` for the product's repo; `stale`
  is true when it is older than the app's 15-minute poll interval.

## Output contract

Every successful response is an envelope:

```json
{
  "asOf": "2026-07-26T10:09:41Z",
  "stale": false,
  "product": { "id": "…", "displayName": "Usage for Claude", "repo": "hayek/FeedbackRepo" },
  "filters": { "state": "open", "app": ["Zcode"] },
  "page": { "limit": 20, "offset": 0, "total": 137, "hasMore": true },
  "items": [ … ]
}
```

`product` and `filters` echo what the CLI actually resolved — cheap
self-verification for an agent that guessed a flag value.

JSON is the stable contract. `--text` is a convenience rendering for humans and
its layout is explicitly **not** guaranteed; the skill tells agents never to
parse it.

### Feedback item

```json
{ "number": 559, "title": "iOS app displays incorrect data",
  "app": "Usage for Claude", "appVersion": "1.4.2",
  "source": "sdk", "type": "bug", "rating": null, "state": "open",
  "createdAt": "2026-07-25T18:02:11Z", "updatedAt": "2026-07-25T18:40:03Z",
  "device": "iPhone 16 Pro", "os": "iOS 18.6",
  "email": "a***@icloud.com",
  "description": "…truncated at 500 chars…", "truncated": true,
  "labels": ["bug", "user-submitted"],
  "tasks": [ { "number": 557, "title": "…", "status": "todo", "isClosed": false } ],
  "triage": { "state": "accepted", "kind": "bug", "signal": "…" },
  "url": "https://github.com/hayek/FeedbackRepo/issues/559" }
```

- `tasks` is expanded, not bare numbers — "is this already tracked?" is the
  question agents actually ask, and expanding it avoids an N+1 `tasks show`
  loop. Derived from a reverse index over cached task bodies via
  `FeedbackTaskRefParser.parse`; closed/done tasks are included.
- `type` is label-derived (`bug|feature-request`, `FeedbackIssue.swift:13-16`).
  `triage.kind` is the *local AI* vocabulary (`bug|featureRequest|usability`,
  `TriageModels.swift:8-11`) and is advice, not ground truth. The two must never
  be blurred.
- `email` is redacted to `a***@host.tld` unless `--include-emails`, matching the
  app's own `redactEmailAddresses` mirroring behaviour.
- Truncation applies to `description` only, in `list` output only, at 500
  characters on a character boundary, with `truncated: true` set. Titles are
  never truncated.
- `feedback show` returns the full description, attachments (with local paths
  when `FeedbackAttachmentLocal` has them), translations, and the mail-thread
  summary if one exists. `rawBody` only under `--raw` — it carries machine
  marker blocks that waste agent context.

### `products`

Each product carries everything needed to make the other commands' flags
discoverable without guessing:

```json
{ "id": "…", "displayName": "Usage for Claude",
  "repo": "hayek/FeedbackRepo",
  "connectedRepo": "hayek/UsageForClaude",
  "apps": [ { "name": "Zcode", "count": 5, "hidden": false } ],
  "versions": [ { "name": "1.4.0", "milestoneNumber": 12, "released": false } ],
  "sources": { "sdk": true, "appStore": true, "email": false },
  "feedbackCount": 499, "taskCount": 40,
  "lastFetchedAt": "2026-07-26T10:09:41Z" }
```

`connectedRepo` is the app's **code** repo (`Product.swift:20-21`). It is how the
skill picks a product deterministically: match `git remote get-url origin`
against it. `products --refresh` refreshes every product's issue cache.

### Closed-issue honesty

`--state closed|all` sets `"closedDataIncomplete": true` in the envelope. The
cache is open-centric: `IssueLoader.mergeToCache` skips closed issues it never
cached (`IssueLoader.swift:427-429`), and the daily full reconcile requests
**open only** and marks any missing cached-open row closed (`:433-439`) — so a
cached `closed` can also mean *deleted upstream*. The skill repeats this
warning. Open-state results are complete.

### Errors and exit codes

Errors are JSON on stdout (so a failed call is still parseable) plus a one-line
human message on stderr.

```json
{ "error": { "code": "product_ambiguous", "message": "…", "hint": "…",
             "candidates": ["…"] } }
```

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage / unknown flag / ambiguous product |
| 2 | Not found (product, feedback number, task number) |
| 3 | No local data (store missing or unreadable) |
| 4 | Auth (no GitHub token, no SMTP password, locked keychain) |
| 5 | Remote failure (GitHub, SMTP, App Store Connect) or write of unknown outcome |
| 6 | App not running (required for any write, and for `--refresh`) |
| 7 | Watchdog timeout |

Codes 4 and 5 arise inside the app during a delegated write; the responder
returns a typed failure and the CLI maps it to the exit code. Exit `4`
distinguishes a locked keychain from a missing token: synchronizable items
(`KeychainService.swift:17`) live in the data-protection keychain, which a pure
SSH session cannot unlock. The message says so.

## Write commands

All four are delegated. The responder in the app runs the same call the UI runs,
then returns the resulting object in full — the agent never needs a follow-up
read, which matters because a just-created task is not in the cache until the
next refresh.

### `tasks create`

App-side: `TaskService.createTask(repo:title:prose:feedbackRefs:status:priority:milestoneNumber:)`,
then `IssueLoaderRegistry.load(productID:)` so the new task appears in the UI at
once. Defaults: `--status todo`, `--priority med`.

`--version` resolves against `ProjectVersion.name` for the repo. If the version
exists but `milestoneNumber` is nil, **hard-error** (exit 2) — never collapse to
`.some(nil)`, which silently clears the milestone (`TaskService.swift:73-75`).

### `tasks link` / `tasks unlink`

The task body is the source of truth for task↔feedback links, so the app
**re-fetches the live issue from GitHub** before rewriting it: fetch → parse refs
with `FeedbackTaskRefParser` → union (link) or subtract (unlink) → `upsert` →
PATCH. Using the cached body would clobber any edit made since the last poll,
which is exactly what `TaskService.setFeedbackRefs` does today
(`TaskService.swift:55-59`).

This needs a new `GitHubIssueWriter.fetchIssue(owner:repo:number:token:)` — the
writer has create/update/delete only (`GitHubIssueWriter.swift:40-88`).

Unknown `--feedback` numbers **warn** rather than fail (`"warnings": [...]` in
the response) — they may be legitimately uncached closed issues.

### `respond`

Channel selection (`--via auto`, the default) follows the source:

| Source | Channel | The call |
|---|---|---|
| `app-store` | App Store developer response | `AppStoreResponseController.submit()` |
| `email`, or `sdk` with an address | Email reply | `ComposeMailViewModel.send()` |
| no address | error, exit 2, hint `--via comment` | — |

`--via comment` forces a GitHub issue comment (`GitHubCommentPoster`).

The email path reproduces the UI's request construction exactly:

- **Existing thread** (`MailThreadStore.threads(forIssue:)` non-empty) → reply
  into the newest message, mirroring `MailThreadView.beginReply`
  (`MailThreadView.swift:89-108`): `inReplyTo` built from the last message's
  `messageID`/`inReplyTo`/`references`, `subjectOverride:
  MailSubject.replyPrefixed(last.subject)`, `senderAccountID:
  resolvedSenderAccountID`.
- **No thread** → first email, mirroring `IssueCardView.replyToEmail`
  (`IssueCardView.swift:166-176`): `inReplyTo: nil`, `subjectOverride: nil`,
  `senderAccountID: nil` (falls back to `store.defaultSender`).

Then the VM is built exactly as `InlineReplyView.setupViewModel`
(`InlineReplyView.swift:174-195`) — including the `IMAPClientProvider`-backed
`sentAppender`, so providers that don't auto-file SMTP sends still get a Sent
copy — and `await vm.send()` runs. `ReleaseNotificationService.swift:97-116` is
the existing precedent for driving this VM headlessly.

`--template <title>` looks up a `ReplyTemplate` by title for the repo and passes
its body as `initialBody`, so placeholder substitution runs identically to the
UI's template replies.

The App Store path enforces the 5970-char cap client-side
(`AppStoreResponseController.maxBodyLength`) and surfaces 409/422/403 as exit 5
with the API message.

**There is no `--send` gate.** `respond` sends when called. The approval gate is
in the skill: the agent must show the user the exact drafted reply and get
explicit agreement first.

## Settings and installers

New Settings pane **CLI & AI Skill**:

- **Install CLI** — symlinks the app binary to `/usr/local/bin/appfeedback`, or
  `~/.local/bin/appfeedback` when `/usr/local/bin` is absent or not writable
  (common on Apple Silicon; the app cannot sudo). Shows the resulting path.
- **Install Skill for Claude Code** — symlinks
  `~/.claude/skills/appfeedback` → the skill folder in the app bundle. Status
  row shows *Installed*, *Not installed*, or *Broken link — reinstall*.
- **Show in Finder** — reveals the skill folder for manual install into any other
  AI tool.
- Both symlinks are re-pointed on every app launch, so a moved or reinstalled
  app self-heals.

**Symlink, never copy.** The restricted entitlements
(`AppFeedback.entitlements:5-8`) validate against the provisioning profile inside
the `.app`; a copied binary loses that and loses keychain access. Gatekeeper is a
non-issue for a locally built app executed from a shell.

Because `~/.local/bin` is usually not on `PATH`, the skill references the
**absolute** binary path, making `PATH` irrelevant.

## The skill

Canonical source at `AppFeedback/Resources/Skill/appfeedback/SKILL.md`,
version-controlled beside the CLI it documents and shipped as an app resource.

xcodegen gives `.md` files no build phase by default (`.json` does get one —
`AppleDevices.json` is in Resources), so `project.yml` must declare the folder
explicitly:

```yaml
- path: AppFeedback/Resources/Skill
  buildPhase: resources
  type: folder
```

The built `.app` must be verified to contain it before the Settings buttons are
wired.

Contents, in order:

1. **Targeting recipe.** Run `products` first. Match `connectedRepo` against
   `git remote get-url origin`. No match or several ⇒ ask the user. Never guess
   `--product`. Products sharing a repo return the same feedback; `--app` is how
   you scope.
2. **Duplicate-task protocol.** Before `tasks create`: (a) if the feedback item's
   `tasks` array is non-empty, use `tasks link`, not create; (b) run `tasks list
   --status todo --status in-progress` and scan for an existing task covering the
   same theme. Create only when both come up empty. `tasks create` writes to
   GitHub immediately.
3. **Reply approval.** `respond` sends to a real user and cannot be undone. Draft
   the reply, show it to the user in full, and send only after explicit
   agreement. Never send on your own initiative.
4. **Freshness rules.** Check `stale`/`asOf`. Add `--refresh` when the app is
   running. Exit 6 means "ask the user to open AppFeedback". A just-created task
   won't appear in list output until a refresh succeeds — trust the create
   response, don't re-query to verify.
5. **Vocabularies.** Exact values for status (`todo|in-progress|done`), priority
   (`low|med|high`), source (`sdk|app-store|email`), type
   (`bug|feature-request`); `triage` is local AI advice, not ground truth.
6. **Data honesty.** `--state closed|all` is incomplete; descriptions truncate at
   500 chars, use `feedback show`; paginate on `hasMore`.
7. **Invocation.** Absolute binary path, JSON default, one worked example per
   command — terse, in the style of `.claude/skills/zcode/SKILL.md`.

## Components

| File | Responsibility |
|---|---|
| `App/AppFeedbackMain.swift` | `@main` dispatch |
| `CLI/CLIBranding.swift` | Name constants |
| `CLI/CLIInvocation.swift` | Allowlist + argument grammar → typed command |
| `CLI/CLIRunner.swift` | Dispatch, exit codes, watchdog |
| `CLI/CLIStore.swift` | Read-only containers, existence guards, snapshot fallback |
| `CLI/FeedbackQuery.swift` | Filters, hidden apps, task index, pagination |
| `CLI/TaskQuery.swift` | Task list/show projections |
| `CLI/CLIOutput.swift` | JSON DTOs + `--text` renderer |
| `CLI/CLIRequestClient.swift` | Write/refresh requests, wait, timeout |
| `Services/CLIRequestResponder.swift` | App side: executes UI calls, replies |
| `Services/CLIInstaller.swift` | Symlinks, status, Finder reveal |
| `Views/Settings/CLISettingsView.swift` | Settings pane |
| `Resources/Skill/appfeedback/SKILL.md` | The skill |

Argument parsing, filtering and JSON encoding are pure functions over injected
`ModelContext`s, so tests never need the CLI process shape.

## Implementation phases

Each phase is independently useful and independently testable.

0. **Spike** — open both stores read-only from a second process while the GUI
   holds them, and confirm a `FetchDescriptor` fetch succeeds. Everything else
   depends on this; if it fails, the snapshot fallback moves from contingency to
   baseline.
1. **Entry point + reads** — dispatcher, invocation grammar, `CLIStore`,
   `products` / `feedback` / `tasks` list and show, JSON and `--text` output,
   error and exit-code mapping. Usable on its own with no app changes.
2. **IPC + `--refresh`** — request/response channel, responder registered in
   `AppFeedbackApp.init`, scoped refresh via `IssueLoaderRegistry.load(productID:)`.
3. **Writes** — `tasks create`, `tasks link`, `tasks unlink`, `respond`, plus
   `GitHubIssueWriter.fetchIssue`.
4. **Settings + skill** — installer, Settings pane, `SKILL.md`, `project.yml`
   resource declaration, bundle verification.

## Testing

In `AppFeedbackTests_macOS`:

- **Invocation.** Every subcommand parses; unknown flags, missing required
  flags and bad enum values exit 1; GUI argv (`-psn_*`,
  `-NSDocumentRevisionsDebugMode`) and XCTest argv return nil.
- **Query engine** over an in-memory container seeded with `CachedIssue` rows:
  each filter, hidden-app exclusion, task/feedback split, `--has-task`,
  pagination totals and `hasMore`, sort stability, `closedDataIncomplete`.
- **Output.** Envelope shape, ISO8601 dates, email redaction on/off, description
  truncation flag, expanded `tasks` array.
- **Product resolution.** UUID / name / `owner/repo`, ambiguity → exit 1 with
  candidates.
- **IPC.** Request/response round-trip through a temp directory; correlation-UUID
  matching; timeout produces stale-with-flag for reads and exit 5 for writes;
  app-not-running produces exit 6.
- **Write commands** against fakes: `tasks create` label/milestone construction,
  including the nil-`milestoneNumber` hard error; link/unlink ref-set maths
  (union, subtract, unknown-number warning) against a fake issue fetcher;
  `respond` channel selection per source and the thread-vs-first-email request
  construction.
- **Installer.** Symlink target selection when `/usr/local/bin` is unwritable;
  broken-link detection.

Then a real end-to-end run of the built binary against the live store, and a
`.app` bundle check that `SKILL.md` shipped.

## Risks

- **Read-only SwiftData open alongside the live GUI.** Verified working with a
  raw SQLite reader today; the SwiftData equivalent is spiked first, before
  anything else is built. `VACUUM INTO` is the fallback.
- **DNC suspension.** Mitigated by `deliverImmediately` on both ends; covered by
  a test that the responder is registered with the right suspension behaviour.
- **Two app instances** (dev build + installed) both answering a request. The
  correlation UUID dedupes; the CLI takes the first response and ignores late
  ones.
- **Dev/installed schema skew** surfaces as exit 3 with a clear message, never a
  crash.

## Out of scope

Live GitHub reads, mutation of feedback items themselves (close, label, hide),
mail thread browsing, triage control, and any iOS surface.
