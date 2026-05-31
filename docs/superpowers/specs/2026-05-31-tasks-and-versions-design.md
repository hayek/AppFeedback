# Tasks & Versions — Design Spec

**Date:** 2026-05-31
**Status:** Implemented (feature/tasks-and-versions)
**Author:** Amir Hayek (with Claude)

## 1. Goal

Let the developer turn **feedbacks** into **tasks**, group tasks into **versions**, and — when a version is released — send a confirmed, personalized email to the end-users whose feedback was fixed. GitHub is the backend: feedbacks and tasks are issues, versions are milestones (+ optional releases). Tasks and versions are surfaced in a collapsible right-side **inspector panel** scoped to the selected project.

## 2. Definitions

- **Feedback** — an existing GitHub issue parsed for end-user email, app, version, device, etc. (`FeedbackIssue`).
- **Task** — a GitHub issue carrying the reserved label `appfeedback:task`. It addresses one or more feedbacks and may be attached to a version.
- **Version** — a GitHub **Milestone** (always) plus an **optional GitHub Release**. Holds a manually-written changelog / "what's new". Lifecycle: **new → wip → released**.
- **Project** — a GitHub repo. (One repo = one project; the previous multi-app-per-repo concept is removed — see §10.)
- **Release notification** — an email sent to an end-user when a version that fixed their feedback is released.

## 3. Locked decisions (from brainstorming)

| # | Decision | Choice |
|---|---|---|
| 1 | Version → GitHub | **Milestone (always) + Release (optional)** |
| 2 | Task ↔ Feedback link | **Cross-references in the task issue body** (`Addresses: #12, #15`), many-to-many, cached locally |
| 3 | Project scoping | **One repo per project** (multi-app-per-repo UI removed) |
| 4 | Task vs Feedback disambiguation | **Dedicated label** `appfeedback:task` |
| 5 | Email body | **Editable template each time** (placeholders, edit before send) |
| 6 | Delivery | **One reply per person into one feedback thread, body lists all their feedbacks** |
| 7 | Recipient list | **All pre-checked, deduped by person, no-email feedbacks hidden** |
| 8 | Resend rules | **Track sent; a new version = a new notify run; already-sent rows unchecked** |
| 9 | Task status | **status:todo / in-progress / done + priority:low / med / high** (labels) |
| 10 | Version authoring | **Created in-app; changelog written manually** |
| 11 | Multi-app | **Fully remove the multi-app-per-repo UI** |
| 12 | Panel | **Native SwiftUI `.inspector()`** |
| 13 | Task creation | **Multi-select feedbacks → Create Task** |
| 14 | Version state | **Derived (new/wip) + manual Release action** |
| 15 | Offline writes | **Require online; clear errors; no write queue** |
| 16 | Release target | **Milestone always; GitHub Release optional; optional per-project "connected code repo" as the release target** |
| 17 | Notify scope | **Only feedbacks of completed (closed/done) tasks** |
| 18 | Opt-out | **No opt-out handling** — no STOP line, no persistent do-not-contact list (see §11.1) |

## 4. GitHub mapping

| Concept | GitHub backing | Notes |
|---|---|---|
| Feedback | Issue *(existing)* | parsed for email/app/version |
| Task | Issue + label `appfeedback:task` | filtered out of the feedback list |
| Task ↔ Feedback | cross-refs in task body (`Addresses: #12, #15`) | many-to-many, GitHub auto-backlinks, cached locally |
| Task status | labels `status:todo / in-progress / done` | `done` ⇒ issue closed |
| Task priority | labels `priority:low / med / high` | panel ordering |
| Version | Milestone *(always)* + Release *(optional)* | milestone groups tasks |
| Task ↔ Version | native milestone assignment | |
| Changelog / what's-new | milestone description + release body | manually written; our model canonical |
| Released | milestone closed (+ release published if used) | manual Release action |
| Connected code repo | optional per-project setting | if set, the Release publishes there; milestone/tasks stay in the feedback repo |

## 5. Data model

### 5.1 New CloudKit-synced SwiftData models (follow `Repo` / `MailThread` pattern)

**`ProjectVersion`**
- `id: UUID`
- `repoOwner: String`, `repoName: String` (project reference)
- `name: String` — e.g. `1.2.0`; used for milestone title, release name, tag base
- `changelog: String` — manually-written "what's new" (canonical copy)
- `milestoneNumber: Int?` — GitHub milestone number once created
- `releaseTag: String?` — git tag once a Release is published
- `releasePublished: Bool`
- `releasedAt: Date?`
- `createdAt: Date`
- `connectedRepoOwner: String?`, `connectedRepoName: String?` — release target override
- Derived `state` (computed, not stored): `released` if `releasePublished` or milestone closed; else `wip` if any task in progress/done; else `new`.

**`SentReleaseNotification`**
- `id: UUID`
- `repoOwner: String`, `repoName: String`
- `versionName: String` (and/or `releaseTag`)
- `recipientEmail: String`
- `feedbackNumbers: [Int]` — the addressed feedbacks listed in the email
- `threadIssueNumber: Int` — the feedback thread the reply landed in
- `sentAt: Date`
- `status: String` — `sent` / `failed` (+ optional error detail)

Drives both the "track sent" guard and the **sent-replies list** in the panel.

### 5.2 Not stored as new persistent models

- **Tasks** are GitHub issues. They are fetched through the (extended) issue infrastructure and parsed into a lightweight in-memory `TaskItem`:
  `number, title, body, feedbackRefs: [Int], status, priority, versionMilestoneNumber?, state(open/closed)`.
- **Feedback ↔ task links** live in the task issue body (source of truth) and are cached locally for fast lookups (e.g. an extension of the existing issue cache or a small derived index). The cache is rebuilt from issue bodies on fetch.

## 6. GitHub sync layer

- **Extend `IssueLoader`** (GraphQL): also fetch each issue's `milestone` + labels, and **partition** results — issues with `appfeedback:task` become tasks; the rest remain feedbacks. The feedback list filters tasks out; the panel reads tasks from the same fetch.
- **`MilestoneReleaseLoader`** (REST): fetch milestones + releases so versions reconcile with GitHub. **GitHub is the source of truth for existence/state**; the local `ProjectVersion` holds the canonical changelog draft + app-only metadata. Reconcile by milestone number / tag. External edits on GitHub flow back on refresh.
- **`TaskService`**: create task (POST issue with task label + body refs + milestone), edit status/priority (label changes), attach/detach feedbacks (edit body refs), close/reopen (`done` ⇒ close).
- **`VersionService`**: create version (POST milestone + optional draft release), edit changelog (PATCH milestone description / release body), **release** (close milestone + publish release if used), reconcile from GitHub.
- **Label bootstrap**: ensure the `appfeedback:task`, `status:*`, `priority:*` labels exist in the repo on first use.
- All writes **require online**; on failure show a clear, actionable error. No background write queue.

## 7. UI

### 7.1 Inspector panel
- `.inspector()` on the detail view with a toolbar toggle; OS-native collapse/resize/persistence.
- Two sections: **Tasks** (selected project, filterable by status/priority) and **Versions** (rows show derived state + a progress indicator).

### 7.2 Create task
- Multi-select feedbacks in `IssueListView` → **Create Task** → sheet (title, optional version, status, priority, pre-filled feedback refs) → POSTs the issue. Attaching more feedbacks to an existing task edits the body refs.

### 7.3 Versions
- **New Version** → name + changelog editor (creates the milestone + an optional draft release).
- Version row → detail: its tasks, the changelog editor, a **Release** button, and the **sent-replies list** (from `SentReleaseNotification`: recipient, feedbacks, time, status, link to thread).

### 7.4 Release flow
- **Release** → **Recipient dialog**:
  - checklist of recipients, **select/deselect all**;
  - each row shows that person's addressed feedbacks;
  - already-sent recipients are listed but **unchecked** by default;
  - **editable template** with placeholders (`{appName} {version} {whatsNew} {theirFeedbacks}`).
  - **Send** → sequential send with per-recipient progress and isolated failures.
- After sending, publish the milestone close (+ release if used).

## 8. Email / notification engine

`ReleaseNotificationService`:
1. **Recipients** = feedbacks linked to **completed (closed/done) tasks** in the version → end-user emails, **deduped by person** (one row, listing all their feedbacks). Feedbacks with no email are hidden.
2. For each selected recipient: render the **editable template**; pick **one** of that person's feedback threads (the **most recently active**); **ensure that thread exists** (if the person has no thread yet, create one — it becomes a standalone email that also threads and mirrors to GitHub); send a **single reply into that one thread**; record a `SentReleaseNotification`.
3. Requires a configured `MailAccount` — if none, the release-email step is disabled with guidance.
4. Sends are sequential; individual failures are recorded and do not abort the run.

## 9. Implementation phasing

- **Phase 0** — remove the multi-app-per-repo UI; project = repo (§10).
- **Phase 1** — GitHub backend: labels, loader extension, milestone/release loader + writers, link parse/cache, models, services. Headless, TDD.
- **Phase 2** — inspector panel: display tasks + versions, task creation from multi-select, version + changelog editing, status/priority, derived state.
- **Phase 3** — release + email: recipient computation, recipient dialog, template, send + track-sent, sent-replies list.

## 10. Removing multi-app-per-repo

- Remove the app-name `DisclosureGroup` in `SidebarView`; simplify `SidebarSelection` to per-repo (drop the `.app` case).
- **No data migration** — `appName` is parsed from feedback bodies, not structural. Version/device filters remain; app-as-navigation is removed.
- This lands first because version/task scoping assumes project = repo.

## 11. Edge cases & considerations

1. **Opt-out (resolved contradiction):** Round 2 implied a persistent do-not-contact flag; Round 5 chose "no opt-out handling." Final: **no STOP line and no persistent do-not-contact list.** The operator manually unchecks people each send; the **track-sent** record still prevents accidental double-sends.
2. **Email deliverability:** personal SMTP (e.g. iCloud) has daily recipient caps; a large release could hit limits. Sends are sequential with progress and isolated failures.
3. **No-thread fallback:** "reply into thread" creates a thread when none exists yet (standalone email + GitHub mirror).
4. **Connected code repo (optional):** if set per project, the Release publishes there while milestone/tasks stay in the feedback repo; release notes reference feedbacks by full `owner/repo#n`.
5. **External GitHub edits** (task closed/relabeled, milestone edited) reconcile back on refresh.
6. **Privacy:** the recipient dialog shows real emails to send; the existing `redactEmailAddresses` setting applies to display elsewhere, not here.
7. **Deletion semantics:** deleting a version deletes the milestone (un-assigns its tasks) and optionally the draft release; closing a task ≠ deleting it.
8. **Release requires ≥1 commit** in the target repo (tag needs a commit). If neither the feedback repo nor a connected repo qualifies, releasing is milestone-only (no Release object).

## 12. Testing approach (TDD)

Unit tests for:
- task-body ↔ feedback-ref parsing/serialization (many-to-many round-trip);
- recipient computation + dedup + completed-task filtering;
- derived version state (new/wip/released);
- template rendering with placeholders;
- label ↔ status/priority mapping.

GitHub writers use the existing mockable URLSession pattern. Mail send reuses the already-tested `MailComposer`.
