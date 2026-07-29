---
name: appfeedback
description: Read and act on real user feedback for the developer's apps — bug reports, feature requests, App Store reviews and support emails — plus the tasks tracking them. Use when asked what users are reporting, whether something is already tracked, what to build next, or to reply to a reporter.
---

The `appfeedback` CLI reads the AppFeedback inbox: user feedback from the in-app SDK,
App Store reviews and support email, plus the tasks that track them.

Output is JSON on stdout by default. `--text` is for humans — never parse it.
Every command needs `--product`, so **always start with `products`**.

If `appfeedback` isn't on PATH, use the full path shown in the app's
Settings → CLI & AI Skill pane (usually `~/.local/bin/appfeedback`).

## 1. Pick the product

    appfeedback products

Match the `connectedRepo` field against the current repo:

    git remote get-url origin

If nothing matches, or several do, **ask the user which product** — never guess.
Each product is one app backed by one repo; products that share a `repo` return identical
feedback, so pick by `id` when two of them do.

## 2. Read feedback

    appfeedback feedback --product "Usage for Claude" --limit 20
    appfeedback feedback --product "Usage for Claude" --type bug --since 14d
    appfeedback feedback --product "Usage for Claude" --source app-store --max-rating 2
    appfeedback feedback --product "Usage for Claude" --search "crash" --no-task
    appfeedback feedback show 559 --product "Usage for Claude"

Filters: `--state open|closed|all` `--source sdk|app-store|email`
`--type bug|feature-request` `--label` `--search` `--since 7d|YYYY-MM-DD` `--updated-since`
`--min-rating` `--max-rating` `--app-version` `--has-task` `--no-task`
`--sort created|updated` `--order desc|asc` `--limit` (max 200) `--offset`.

Repeating a flag ORs its values (`--label A --label B`); different flags AND together.

`list` truncates `description` at 500 characters and sets `"truncated": true` — use
`feedback show` for the full text. Keep paging while `page.hasMore` is true.

## 3. Read tasks

    appfeedback tasks --product "Usage for Claude" --status todo --status in-progress
    appfeedback tasks show 557 --product "Usage for Claude"

Every feedback item carries a `tasks` array — the tasks already addressing it, with status.
That is the fastest way to answer "is this being worked on?".

## 4. Before creating a task

Duplicates are the main failure mode here. Both checks are required:

1. If the feedback item's `tasks` array is **not empty**, use `tasks link` — do not create.
2. Run `tasks list --status todo --status in-progress` and scan for an existing task covering
   the same theme. If one exists, link to it.

Only when both come up empty:

    appfeedback tasks create --product "Usage for Claude" --title "Fix crash on launch" \
        --notes "Several reports on 1.4.2" --priority high --feedback 559,560

    appfeedback tasks link   --product "Usage for Claude" --task 557 --feedback 561
    appfeedback tasks unlink --product "Usage for Claude" --task 557 --feedback 561

`tasks create` writes to GitHub immediately. `--version` must name a version that already has
a GitHub milestone (see `products`).

## 5. Replying — always ask first

    appfeedback respond --product "Usage for Claude" --feedback 559 --body "Fixed in 1.4.3."

**`respond` sends immediately and cannot be undone.** It reaches a real user by email, or
posts a public App Store developer response.

Before every call: draft the reply, **show the user the exact text you intend to send, and
send only after they explicitly agree.** Never send on your own initiative, and never send a
reply you have not shown them.

`--via auto` (the default) picks the channel: App Store reviews get a developer response,
anything with an email address gets an email reply. `--via comment` posts a GitHub comment on
the feedback issue instead — that one is internal and does not reach the user.

`--template <title>` uses one of the saved reply templates instead of `--body`.

## 6. Freshness

Every response carries `asOf` and `stale`. Data comes from the app's local cache, which
refreshes every 15 minutes while AppFeedback is running.

- Add `--refresh` to any read command to make the app poll GitHub first.
- Exit code 6 means AppFeedback isn't running — ask the user to open it. Writes and
  `--refresh` both need it; plain reads work without it.
- After `tasks create`, the new task will **not** appear in `tasks list` until a refresh
  succeeds. Trust the create response — don't re-query to "verify" it.

## 7. Data honesty

- `--state closed` and `--state all` set `"closedDataIncomplete": true`. The cache is
  open-issue-centric: issues closed before the app ever saw them were never cached, and a
  cached `closed` can also mean *deleted upstream*. Open-state results are complete.
- `triage` is the app's own local AI advice, not ground truth. Its `kind` vocabulary
  (`bug|featureRequest|usability`) is **different** from the label-derived `type`
  (`bug|feature-request`). Don't conflate them.
- Reporter emails are redacted (`a***@icloud.com`). `--include-emails` returns them in full;
  only use it when the user has asked you to contact someone.

## Vocabularies

| Field | Values |
|---|---|
| status | `todo` `in-progress` `done` |
| priority | `low` `med` `high` |
| source | `sdk` `app-store` `email` |
| type | `bug` `feature-request` |
| state | `open` `closed` `all` |

## Exit codes

`0` ok · `1` usage · `2` not found · `3` no local data (launch the app once) ·
`4` auth · `5` remote failure · `6` app not running · `7` timeout.

Errors are JSON on stdout too, so the output parses either way. Exit 4 may mean the Mac's
screen is locked rather than a missing token — these credentials sync via iCloud Keychain and
can't be read while locked. Read the `hint` field before acting on any error.
