# Local Notifications for New Feedback

**Status:** Approved
**Date:** 2026-04-28
**Platforms:** iOS 17+, macOS 14+

## Goal

Notify the user when new GitHub issues arrive in the repos they track. Client-only — no backend, no APNs server. Works on both iOS and macOS via local notifications driven by background refresh.

## Scope

### In scope (v1)
- Local notifications (`UNUserNotification`) for **newly-detected GitHub issues** only.
- Background refresh on iOS (`BGAppRefreshTask`) and macOS (`NSBackgroundActivityScheduler`), as fast as the OS permits.
- First-launch permission prompt + a Settings toggle to disable later.
- Hybrid grouping: ≤3 new → one notification per issue; >3 new → a single summary showing only the count.
- Tap deep-links to the specific issue (per-issue notifications) or opens the app (summary).

### Out of scope (v1)
- New comments on existing issues, mail notifications.
- Per-repo mute, quiet hours, custom sounds.
- App-icon badging.
- Real APNs / server push.
- Cross-device "already notified" sync (each device decides locally).

## Architecture

A new `NotificationService` (under `AppFeedback/Services/Notifications/`) owns:

- Permission request + cached authorization status.
- Posting `UNUserNotificationRequest`s (single + summary).
- A `NotifiedIssueStore` tracking which issue IDs have already triggered a notification on this device.
- Conforming to `UNUserNotificationCenterDelegate` to handle foreground presentation and tap routing.

Two thin platform-specific drivers reuse the existing `IssueLoader` and feed results to `NotificationService.diffAndNotify`:

- **iOS:** `iOSBackgroundRefreshDriver` — `BGAppRefreshTask` registered at launch, rescheduled after each run.
- **macOS:** `MacBackgroundRefreshDriver` — `NSBackgroundActivityScheduler` with `interval = 15 min`, `tolerance = 5 min`.

Both are created in `AppFeedbackApp` behind `#if os(...)` blocks.

## "New issue" detection

- New `NotifiedIssueStore`: UserDefaults-backed `Set<String>` of issue IDs, capped at 5,000 most-recent IDs (FIFO eviction by insertion order).
- **First enable** of notifications: snapshot all currently-loaded issue IDs into `NotifiedIssueStore` so the user is not spammed with the existing backlog.
- Every refresh:
  ```
  newIssues = loadedIssues.filter { !notifiedStore.contains($0.id) }
  notify(newIssues)
  notifiedStore.insert(newIssues.map(\.id))
  ```
- iCloud sync: `NotifiedIssueStore` is **device-local** (not synced via NSUbiquitousKeyValueStore / CloudKit). Each device decides for itself what is new.

## Notification content & grouping

Per-refresh-cycle hybrid by count of new issues:

- **≤ 3 new:** one `UNNotificationRequest` per issue.
  - `title`: issue title.
  - `subtitle`: `owner/repo`.
  - `userInfo`: `["issueID": "<id>"]` for deep-link routing.
  - `threadIdentifier`: `"appfeedback.newissue"` so the OS visually groups them.
- **> 3 new:** one summary request.
  - `title`: `"N new issues"` (count only — no repo breakdown).
  - No body, no `userInfo` deep-link → tap opens app to default view.
  - Same `threadIdentifier`.

Default sound, default interruption level. No badging in v1.

## Permission & Settings

- **First launch (one-time):** after `RootView` appears, call `UNUserNotificationCenter.requestAuthorization([.alert, .sound])` once. Persist a `hasRequestedNotificationAuthorization` flag in UserDefaults to avoid re-prompting.
- **Settings:** new `NotificationsSettingsView` containing one toggle: **"Notify me about new feedback"**.
  - Default `true` after first-launch grant; `false` if denied.
  - When the user toggles ON but system permission is denied, show an inline note with an "Open System Settings" button (`UIApplication.openSettingsURLString` on iOS, `NSWorkspace.open(...)` on macOS).
  - When OFF: drivers stop scheduling and existing scheduled tasks are cancelled.
- Storage: a new `NotificationSettings` (UserDefaults wrapper).

## Deep-link / tap routing

- `NotificationService` is the `UNUserNotificationCenterDelegate`.
- `userNotificationCenter(_:didReceive:withCompletionHandler:)`: read `userInfo["issueID"]`. If present, publish via a new `@Observable NotificationRouter`.
- `RootView` (or `IssueListViewModel`) observes the router and selects that issue using the same code path as a normal user tap. If the issue isn't currently loaded (e.g., filtered out, hidden repo), trigger a refresh first, then select.
- `userNotificationCenter(_:willPresent:)` returns `[]` when the app is foreground — the issue is already visible in the list, so suppress the banner.

## Background drivers

### iOS — `iOSBackgroundRefreshDriver`

- `project.yml` Info additions for the iOS target:
  - `BGTaskSchedulerPermittedIdentifiers`: `["com.amirhayek.AppFeedback.refresh"]`
  - `UIBackgroundModes`: `["fetch"]`
- At app launch:
  - `BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.amirhayek.AppFeedback.refresh", using: nil) { task in driver.handle(task) }`
  - Call `scheduleNextRefresh()`.
- `handle(_:)`:
  1. `task.expirationHandler` cancels the in-flight load.
  2. Run `IssueLoader.load`, then `NotificationService.diffAndNotify`.
  3. `task.setTaskCompleted(success:)`.
  4. `scheduleNextRefresh()` (`BGAppRefreshTaskRequest` with `earliestBeginDate = Date().addingTimeInterval(15 * 60)`).
- `scheduleNextRefresh()` is also called when the app moves to background (via scene phase).

### macOS — `MacBackgroundRefreshDriver`

- `NSBackgroundActivityScheduler(identifier: "com.amirhayek.AppFeedback.refresh")`
- `repeats = true`, `interval = 15 * 60`, `tolerance = 5 * 60`, `qualityOfService = .utility`.
- Each tick: `load` → `diffAndNotify` → `completion(.finished)`.
- Started by `NotificationSettings.isEnabled = true`, stopped (`invalidate()`) on disable.

Both drivers reuse the existing `IssueLoader` — no duplicated fetch logic.

## Testing

- `NotifiedIssueStoreTests`: first-enable snapshot, diff behavior, cap eviction.
- `NotificationServiceTests` (using a `MockUserNotificationCenter` protocol mirroring the `add(_:)` surface):
  - 0 new → no requests posted.
  - 1–3 new → exactly N per-issue requests with the expected title / subtitle / userInfo.
  - 4+ new → exactly 1 summary request with `"<N> new issues"` title and no `userInfo`.
  - Duplicates are not re-notified on subsequent calls.
- `NotificationSettingsTests`: toggle persistence and default behavior.
- Drivers are not unit-tested (glue around system schedulers). Manual verification:
  - iOS: Xcode "Simulate Background Fetch" / `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.amirhayek.AppFeedback.refresh"]`.
  - macOS: temporarily lower `interval` to a few seconds during dev.

## File layout

```
AppFeedback/Services/Notifications/
  NotificationService.swift
  NotifiedIssueStore.swift
  NotificationSettings.swift
  NotificationRouter.swift
  iOSBackgroundRefreshDriver.swift   # #if os(iOS)
  MacBackgroundRefreshDriver.swift   # #if os(macOS)
AppFeedback/Views/Settings/
  NotificationsSettingsView.swift

AppFeedbackTests/
  NotifiedIssueStoreTests.swift
  NotificationServiceTests.swift
  NotificationSettingsTests.swift
  MockUserNotificationCenter.swift
```

## Open questions

None at design time. Future iterations may add comments, mail, per-repo mute, badging.
