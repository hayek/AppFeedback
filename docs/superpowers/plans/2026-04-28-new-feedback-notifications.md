# New Feedback Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify the user via local notifications when new GitHub issues arrive, on iOS and macOS, with no backend.

**Architecture:** A `NotificationService` owns permission, posting, and tap routing. A `NotifiedIssueStore` tracks already-notified issues per device (UserDefaults, capped FIFO). Two thin platform-specific drivers (`iOSBackgroundRefreshDriver` using `BGAppRefreshTask`, `MacBackgroundRefreshDriver` using `NSBackgroundActivityScheduler`) wake periodically, run the existing per-repo `IssueLoader` for every saved repo, and call `NotificationService.diffAndNotify`. A first-launch permission prompt and a Settings toggle gate the whole feature.

**Tech Stack:** Swift 5.9, SwiftUI, `UserNotifications`, `BackgroundTasks` (iOS), `Foundation.NSBackgroundActivityScheduler` (macOS), `UserDefaults`, existing `IssueLoader` / `RepoStore` / `KeychainService`.

**Spec:** `docs/superpowers/specs/2026-04-28-new-feedback-notifications-design.md`

## File Structure

**Created:**
- `AppFeedback/Services/Notifications/NotifiedIssueStore.swift` — UserDefaults-backed Set<String> with FIFO cap; composite keys `"owner/repo#number"`.
- `AppFeedback/Services/Notifications/NotificationSettings.swift` — UserDefaults-backed `isEnabled` and `hasRequestedAuthorization` flags.
- `AppFeedback/Services/Notifications/NotificationRouter.swift` — `@Observable` holder for the most recent tapped issue ID, consumed by the UI.
- `AppFeedback/Services/Notifications/UserNotificationCenterProtocol.swift` — narrow protocol over `UNUserNotificationCenter` so tests can mock.
- `AppFeedback/Services/Notifications/NotificationService.swift` — permission, diff-and-notify, delegate.
- `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift` — `#if os(iOS)`, BGTaskScheduler glue.
- `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift` — `#if os(macOS)`, NSBackgroundActivityScheduler glue.
- `AppFeedback/Views/Settings/NotificationsSettingsView.swift` — Settings tab/section with the toggle.
- `AppFeedbackTests/MockUserNotificationCenter.swift`
- `AppFeedbackTests/NotifiedIssueStoreTests.swift`
- `AppFeedbackTests/NotificationSettingsTests.swift`
- `AppFeedbackTests/NotificationServiceTests.swift`

**Modified:**
- `project.yml` — add `UIBackgroundModes: ["fetch"]` and `BGTaskSchedulerPermittedIdentifiers: ["com.amirhayek.AppFeedback.refresh"]` to the iOS Info plist.
- `AppFeedback/App/AppFeedbackApp.swift` — instantiate `NotificationService`, drivers, router; inject into environment; trigger first-launch permission.
- `AppFeedback/App/RootView.swift` — observe `NotificationRouter`; when an issue ID arrives, select it via the existing list path.
- `AppFeedback/Views/Settings/SettingsView.swift` — host `NotificationsSettingsView` (a new tab on macOS, a new section on iOS — match existing convention).

---

### Task 1: NotifiedIssueStore

**Files:**
- Create: `AppFeedback/Services/Notifications/NotifiedIssueStore.swift`
- Test: `AppFeedbackTests/NotifiedIssueStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/NotifiedIssueStoreTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class NotifiedIssueStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "NotifiedIssueStoreTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_contains_returnsFalseForUnknown() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 100)
        XCTAssertFalse(store.contains("foo/bar#1"))
    }

    func test_insert_thenContains_returnsTrue() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 100)
        store.insert(["foo/bar#1", "foo/bar#2"])
        XCTAssertTrue(store.contains("foo/bar#1"))
        XCTAssertTrue(store.contains("foo/bar#2"))
        XCTAssertFalse(store.contains("foo/bar#3"))
    }

    func test_insert_persistsAcrossInstances() {
        NotifiedIssueStore(defaults: defaults, cap: 100).insert(["x/y#1"])
        XCTAssertTrue(NotifiedIssueStore(defaults: defaults, cap: 100).contains("x/y#1"))
    }

    func test_insert_evictsOldestWhenOverCap() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 3)
        store.insert(["a#1", "a#2", "a#3"])
        store.insert(["a#4"])
        XCTAssertFalse(store.contains("a#1"))
        XCTAssertTrue(store.contains("a#2"))
        XCTAssertTrue(store.contains("a#3"))
        XCTAssertTrue(store.contains("a#4"))
    }

    func test_snapshot_marksAllProvidedIDsAsNotified() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 100)
        store.snapshot(["a#1", "a#2"])
        XCTAssertTrue(store.contains("a#1"))
        XCTAssertTrue(store.contains("a#2"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run via the zcode skill: build target tests; expect compilation failure (`NotifiedIssueStore` not found).

- [ ] **Step 3: Implement `NotifiedIssueStore`**

Create `AppFeedback/Services/Notifications/NotifiedIssueStore.swift`:

```swift
import Foundation

final class NotifiedIssueStore {
    static func issueKey(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }

    private let defaults: UserDefaults
    private let cap: Int
    private let key = "appfeedback.notifiedIssueIDs"

    init(defaults: UserDefaults = .standard, cap: Int = 5_000) {
        self.defaults = defaults
        self.cap = cap
    }

    func contains(_ id: String) -> Bool {
        loadOrdered().contains(id)
    }

    func insert(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var ordered = loadOrdered()
        let existing = Set(ordered)
        for id in ids where !existing.contains(id) {
            ordered.append(id)
        }
        if ordered.count > cap {
            ordered.removeFirst(ordered.count - cap)
        }
        defaults.set(ordered, forKey: key)
    }

    func snapshot(_ ids: [String]) {
        insert(ids)
    }

    private func loadOrdered() -> [String] {
        defaults.array(forKey: key) as? [String] ?? []
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run via zcode skill: tests target. Expect all 5 `NotifiedIssueStoreTests` to pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Notifications/NotifiedIssueStore.swift AppFeedbackTests/NotifiedIssueStoreTests.swift
git commit -m "feat(notifications): add NotifiedIssueStore with FIFO cap"
```

---

### Task 2: NotificationSettings

**Files:**
- Create: `AppFeedback/Services/Notifications/NotificationSettings.swift`
- Test: `AppFeedbackTests/NotificationSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/NotificationSettingsTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class NotificationSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "NotificationSettingsTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_default_isDisabledAndNotPrompted() {
        let s = NotificationSettings(defaults: defaults)
        XCTAssertFalse(s.isEnabled)
        XCTAssertFalse(s.hasRequestedAuthorization)
    }

    func test_setIsEnabled_persists() {
        NotificationSettings(defaults: defaults).isEnabled = true
        XCTAssertTrue(NotificationSettings(defaults: defaults).isEnabled)
    }

    func test_setHasRequestedAuthorization_persists() {
        NotificationSettings(defaults: defaults).hasRequestedAuthorization = true
        XCTAssertTrue(NotificationSettings(defaults: defaults).hasRequestedAuthorization)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run tests via zcode. Expect compilation failure.

- [ ] **Step 3: Implement `NotificationSettings`**

Create `AppFeedback/Services/Notifications/NotificationSettings.swift`:

```swift
import Foundation
import Observation

@Observable
final class NotificationSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabledKey = "appfeedback.notifications.isEnabled"
    @ObservationIgnored private let promptedKey = "appfeedback.notifications.hasRequestedAuthorization"

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: enabledKey) }
    }
    var hasRequestedAuthorization: Bool {
        didSet { defaults.set(hasRequestedAuthorization, forKey: promptedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: enabledKey)
        self.hasRequestedAuthorization = defaults.bool(forKey: promptedKey)
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Notifications/NotificationSettings.swift AppFeedbackTests/NotificationSettingsTests.swift
git commit -m "feat(notifications): add NotificationSettings persistence"
```

---

### Task 3: NotificationRouter

**Files:**
- Create: `AppFeedback/Services/Notifications/NotificationRouter.swift`

(No tests — trivial observable holder.)

- [ ] **Step 1: Implement**

Create `AppFeedback/Services/Notifications/NotificationRouter.swift`:

```swift
import Foundation
import Observation

@Observable @MainActor
final class NotificationRouter {
    /// Composite issue key, e.g. `"owner/repo#42"`. Set by NotificationService when a
    /// notification is tapped. UI observes this and selects the matching issue.
    var pendingIssueKey: String?

    func consume() -> String? {
        defer { pendingIssueKey = nil }
        return pendingIssueKey
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add AppFeedback/Services/Notifications/NotificationRouter.swift
git commit -m "feat(notifications): add NotificationRouter for tap deep-links"
```

---

### Task 4: UserNotificationCenter protocol + mock

**Files:**
- Create: `AppFeedback/Services/Notifications/UserNotificationCenterProtocol.swift`
- Create: `AppFeedbackTests/MockUserNotificationCenter.swift`

- [ ] **Step 1: Implement the protocol**

Create `AppFeedback/Services/Notifications/UserNotificationCenterProtocol.swift`:

```swift
import Foundation
import UserNotifications

protocol UserNotificationCenterProtocol: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationSettings() async -> UNNotificationSettings
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol {}
```

- [ ] **Step 2: Implement the mock**

Create `AppFeedbackTests/MockUserNotificationCenter.swift`:

```swift
import Foundation
import UserNotifications
@testable import AppFeedback

final class MockUserNotificationCenter: UserNotificationCenterProtocol {
    var addedRequests: [UNNotificationRequest] = []
    var authorizationGranted: Bool = true
    var requestedOptions: UNAuthorizationOptions?

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        return authorizationGranted
    }
    func notificationSettings() async -> UNNotificationSettings {
        // Not used by current tests; would need a stub via NSCoder if needed later.
        fatalError("not implemented for tests that need it")
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Notifications/UserNotificationCenterProtocol.swift AppFeedbackTests/MockUserNotificationCenter.swift
git commit -m "feat(notifications): protocol + mock around UNUserNotificationCenter"
```

---

### Task 5: NotificationService — diff and notify (≤3 path)

**Files:**
- Create: `AppFeedback/Services/Notifications/NotificationService.swift`
- Test: `AppFeedbackTests/NotificationServiceTests.swift`

- [ ] **Step 1: Write the failing tests for the ≤3 path**

Create `AppFeedbackTests/NotificationServiceTests.swift`:

```swift
import XCTest
import UserNotifications
@testable import AppFeedback

@MainActor
final class NotificationServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var center: MockUserNotificationCenter!
    private var notified: NotifiedIssueStore!
    private let suiteName = "NotificationServiceTests"

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        center = MockUserNotificationCenter()
        notified = NotifiedIssueStore(defaults: defaults, cap: 1_000)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func service() -> NotificationService {
        NotificationService(
            center: center,
            notifiedStore: notified,
            settings: { let s = NotificationSettings(defaults: defaults); s.isEnabled = true; return s }(),
            router: NotificationRouter()
        )
    }

    private func issue(_ n: Int, title: String = "title") -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: title, createdAt: Date(),
            rawBody: "", appName: nil, appVersion: nil, device: nil,
            osVersion: nil, email: nil, description: "", labels: []
        )
    }

    func test_diffAndNotify_postsZeroWhenNoNew() async {
        notified.snapshot(["foo/bar#1"])
        await service().diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_diffAndNotify_postsOnePerIssueWhenAtMostThree() async {
        await service().diffAndNotify(loadedByRepo: [
            ("foo", "bar", [issue(1, title: "Crash"), issue(2, title: "Slow"), issue(3, title: "Bug")])
        ])
        XCTAssertEqual(center.addedRequests.count, 3)
        let titles = center.addedRequests.map(\.content.title)
        XCTAssertEqual(Set(titles), ["Crash", "Slow", "Bug"])
        XCTAssertTrue(center.addedRequests.allSatisfy { $0.content.subtitle == "foo/bar" })
        XCTAssertEqual(center.addedRequests.first?.content.userInfo["issueKey"] as? String, "foo/bar#1")
    }

    func test_diffAndNotify_doesNotRenotifyOnSecondCall() async {
        let svc = service()
        await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        XCTAssertEqual(center.addedRequests.count, 1)
    }

    func test_diffAndNotify_doesNothingWhenSettingsDisabled() async {
        let settings = NotificationSettings(defaults: defaults)
        settings.isEnabled = false
        let svc = NotificationService(
            center: center,
            notifiedStore: notified,
            settings: settings,
            router: NotificationRouter()
        )
        await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        XCTAssertEqual(center.addedRequests.count, 0)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement minimum to pass (≤3 path only)**

Create `AppFeedback/Services/Notifications/NotificationService.swift`:

```swift
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject {
    private let center: UserNotificationCenterProtocol
    private let notifiedStore: NotifiedIssueStore
    private let settings: NotificationSettings
    private let router: NotificationRouter

    init(
        center: UserNotificationCenterProtocol,
        notifiedStore: NotifiedIssueStore,
        settings: NotificationSettings,
        router: NotificationRouter
    ) {
        self.center = center
        self.notifiedStore = notifiedStore
        self.settings = settings
        self.router = router
    }

    /// Group of issues currently loaded for one repo.
    typealias RepoIssues = (owner: String, repo: String, issues: [FeedbackIssue])

    func diffAndNotify(loadedByRepo: [RepoIssues]) async {
        guard settings.isEnabled else { return }

        var newOnes: [(repoOwner: String, repoName: String, issue: FeedbackIssue, key: String)] = []
        for group in loadedByRepo {
            for issue in group.issues {
                let key = NotifiedIssueStore.issueKey(
                    owner: group.owner, repo: group.repo, number: issue.number
                )
                if !notifiedStore.contains(key) {
                    newOnes.append((group.owner, group.repo, issue, key))
                }
            }
        }
        guard !newOnes.isEmpty else { return }

        if newOnes.count <= 3 {
            for entry in newOnes {
                await postSingle(owner: entry.repoOwner, repo: entry.repoName, issue: entry.issue, key: entry.key)
            }
        } else {
            await postSummary(count: newOnes.count)
        }

        notifiedStore.insert(newOnes.map(\.key))
    }

    private func postSingle(owner: String, repo: String, issue: FeedbackIssue, key: String) async {
        let content = UNMutableNotificationContent()
        content.title = issue.title
        content.subtitle = "\(owner)/\(repo)"
        content.userInfo = ["issueKey": key]
        content.threadIdentifier = "appfeedback.newissue"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "appfeedback.\(key)", content: content, trigger: nil)
        try? await center.add(req)
    }

    private func postSummary(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(count) new issues"
        content.threadIdentifier = "appfeedback.newissue"
        content.sound = .default
        let id = "appfeedback.summary.\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(req)
    }
}
```

- [ ] **Step 4: Run tests, expect pass for the ≤3 path tests**

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Notifications/NotificationService.swift AppFeedbackTests/NotificationServiceTests.swift
git commit -m "feat(notifications): NotificationService diff-and-notify (single path)"
```

---

### Task 6: NotificationService — summary (>3) path

**Files:**
- Modify: `AppFeedbackTests/NotificationServiceTests.swift`

(Implementation already covers the summary path from Task 5; we just add explicit tests.)

- [ ] **Step 1: Append summary tests**

Add to `NotificationServiceTests`:

```swift
func test_diffAndNotify_postsSummaryWhenMoreThanThree() async {
    let issues = (1...4).map { issue($0, title: "t\($0)") }
    await service().diffAndNotify(loadedByRepo: [("foo", "bar", issues)])
    XCTAssertEqual(center.addedRequests.count, 1)
    let req = center.addedRequests[0]
    XCTAssertEqual(req.content.title, "4 new issues")
    XCTAssertNil(req.content.userInfo["issueKey"])
    XCTAssertEqual(req.content.threadIdentifier, "appfeedback.newissue")
}

func test_diffAndNotify_summaryCountsAcrossRepos() async {
    let svc = service()
    await svc.diffAndNotify(loadedByRepo: [
        ("a", "b", [issue(1), issue(2), issue(3)]),
        ("c", "d", [issue(1), issue(2)])
    ])
    XCTAssertEqual(center.addedRequests.count, 1)
    XCTAssertEqual(center.addedRequests[0].content.title, "5 new issues")
}
```

- [ ] **Step 2: Run tests, expect pass**

- [ ] **Step 3: Commit**

```bash
git add AppFeedbackTests/NotificationServiceTests.swift
git commit -m "test(notifications): cover summary (>3) notification path"
```

---

### Task 7: NotificationService — permission, snapshot, delegate

**Files:**
- Modify: `AppFeedback/Services/Notifications/NotificationService.swift`
- Modify: `AppFeedbackTests/NotificationServiceTests.swift`

- [ ] **Step 1: Add tests for permission + snapshot**

Append to `NotificationServiceTests`:

```swift
func test_requestAuthorizationIfNeeded_promptsOnceAndMarksFlag() async {
    let settings = NotificationSettings(defaults: defaults)
    let svc = NotificationService(
        center: center, notifiedStore: notified, settings: settings, router: NotificationRouter()
    )
    center.authorizationGranted = true
    await svc.requestAuthorizationIfNeeded()
    XCTAssertTrue(settings.hasRequestedAuthorization)
    XCTAssertTrue(settings.isEnabled)
    XCTAssertEqual(center.requestedOptions, [.alert, .sound])

    // Second call should be a no-op.
    center.requestedOptions = nil
    await svc.requestAuthorizationIfNeeded()
    XCTAssertNil(center.requestedOptions)
}

func test_requestAuthorizationIfNeeded_deniedKeepsDisabled() async {
    let settings = NotificationSettings(defaults: defaults)
    let svc = NotificationService(
        center: center, notifiedStore: notified, settings: settings, router: NotificationRouter()
    )
    center.authorizationGranted = false
    await svc.requestAuthorizationIfNeeded()
    XCTAssertTrue(settings.hasRequestedAuthorization)
    XCTAssertFalse(settings.isEnabled)
}

func test_snapshotExistingIssues_marksAllAsNotifiedWithoutPosting() async {
    let svc = service()
    svc.snapshotExistingIssues(loadedByRepo: [("foo", "bar", [issue(1), issue(2)])])
    XCTAssertEqual(center.addedRequests.count, 0)
    await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1), issue(2)])])
    XCTAssertEqual(center.addedRequests.count, 0)
}
```

- [ ] **Step 2: Implement the new methods + delegate**

Append to `NotificationService.swift`:

```swift
import Foundation
import UserNotifications

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground: suppress banner — issue is already visible in the list.
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let key = response.notification.request.content.userInfo["issueKey"] as? String {
            Task { @MainActor in self.router.pendingIssueKey = key }
        }
        completionHandler()
    }
}

extension NotificationService {
    func requestAuthorizationIfNeeded() async {
        guard !settings.hasRequestedAuthorization else { return }
        settings.hasRequestedAuthorization = true
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        settings.isEnabled = granted
    }

    /// Mark all currently-loaded issues as already-notified, so the user isn't spammed
    /// with the existing backlog when notifications are first enabled.
    func snapshotExistingIssues(loadedByRepo: [RepoIssues]) {
        var keys: [String] = []
        for group in loadedByRepo {
            for issue in group.issues {
                keys.append(NotifiedIssueStore.issueKey(owner: group.owner, repo: group.repo, number: issue.number))
            }
        }
        notifiedStore.snapshot(keys)
    }
}
```

- [ ] **Step 3: Run tests, expect pass**

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Services/Notifications/NotificationService.swift AppFeedbackTests/NotificationServiceTests.swift
git commit -m "feat(notifications): permission flow, snapshot, delegate routing"
```

---

### Task 8: NotificationsSettingsView

**Files:**
- Create: `AppFeedback/Views/Settings/NotificationsSettingsView.swift`

(No unit tests — view glue.)

- [ ] **Step 1: Implement the view**

Create `AppFeedback/Views/Settings/NotificationsSettingsView.swift`:

```swift
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct NotificationsSettingsView: View {
    @Bindable var settings: NotificationSettings
    let service: NotificationService
    @State private var systemDenied: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new feedback", isOn: $settings.isEnabled)
                    .onChange(of: settings.isEnabled) { _, newValue in
                        if newValue {
                            Task { await ensureAuthorization() }
                        }
                    }
                if settings.isEnabled && systemDenied {
                    Text("Notifications are disabled in system settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") { openSystemSettings() }
                }
            } footer: {
                Text("Checks for new GitHub issues in the background and posts a local notification when new ones arrive.")
            }
        }
        .task { await refreshSystemStatus() }
    }

    private func ensureAuthorization() async {
        await service.requestAuthorizationIfNeeded()
        await refreshSystemStatus()
    }

    private func refreshSystemStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        systemDenied = (status == .denied)
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run via zcode skill: build app target on iOS and macOS. Expect success.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Settings/NotificationsSettingsView.swift
git commit -m "feat(notifications): add Notifications settings view"
```

---

### Task 9: Wire NotificationsSettingsView into SettingsView

**Files:**
- Modify: `AppFeedback/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Inspect existing SettingsView**

Read `AppFeedback/Views/Settings/SettingsView.swift` to see whether it uses `TabView` (macOS) or sectioned form (iOS), and add a parallel entry for notifications. Pattern-match the existing tabs (e.g., `MailSettingsView`, `IntelligenceSettingsView`).

- [ ] **Step 2: Add the entry**

Inject `NotificationSettings` and `NotificationService` via `@Environment`. Add a tab/section that hosts:

```swift
NotificationsSettingsView(settings: notificationSettings, service: notificationService)
```

(Exact code depends on the file contents read in Step 1 — mirror the surrounding pattern.)

- [ ] **Step 3: Build, expect success**

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Settings/SettingsView.swift
git commit -m "feat(notifications): expose Notifications tab in Settings"
```

---

### Task 10: iOS background driver

**Files:**
- Create: `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift`

- [ ] **Step 1: Implement**

Create `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift`:

```swift
#if os(iOS)
import Foundation
import BackgroundTasks
import SwiftData

@MainActor
final class iOSBackgroundRefreshDriver {
    static let taskIdentifier = "com.amirhayek.AppFeedback.refresh"

    private let store: RepoStore
    private let cacheContext: ModelContext
    private let notificationService: NotificationService
    private let settings: NotificationSettings
    private let activityLog: ActivityLog

    init(
        store: RepoStore,
        cacheContext: ModelContext,
        notificationService: NotificationService,
        settings: NotificationSettings,
        activityLog: ActivityLog
    ) {
        self.store = store
        self.cacheContext = cacheContext
        self.notificationService = notificationService
        self.settings = settings
        self.activityLog = activityLog
    }

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            self.handle(refresh)
        }
    }

    func scheduleNextRefresh() {
        guard settings.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated func handle(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            await self.runRefresh()
            task.setTaskCompleted(success: true)
            self.scheduleNextRefresh()
        }
        task.expirationHandler = { work.cancel() }
    }

    private func runRefresh() async {
        guard settings.isEnabled else { return }
        var loaded: [NotificationService.RepoIssues] = []
        for repo in store.repos {
            guard let token = await KeychainService.load(for: repo) else { continue }
            let loader = IssueLoader(
                config: repo, activityLog: activityLog, cacheContext: cacheContext
            )
            await loader.load(token: token)
            if case .loaded(let issues, _) = loader.state {
                loaded.append((repo.owner, repo.repo, issues))
            }
        }
        await notificationService.diffAndNotify(loadedByRepo: loaded)
    }
}
#endif
```

- [ ] **Step 2: Build iOS target**

Run via zcode skill: build app for iOS Simulator. Expect success.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift
git commit -m "feat(notifications): iOS BGAppRefreshTask driver"
```

---

### Task 11: macOS background driver

**Files:**
- Create: `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`

- [ ] **Step 1: Implement**

Create `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`:

```swift
#if os(macOS)
import Foundation
import SwiftData

@MainActor
final class MacBackgroundRefreshDriver {
    static let identifier = "com.amirhayek.AppFeedback.refresh"

    private let store: RepoStore
    private let cacheContext: ModelContext
    private let notificationService: NotificationService
    private let settings: NotificationSettings
    private let activityLog: ActivityLog
    private var scheduler: NSBackgroundActivityScheduler?

    init(
        store: RepoStore,
        cacheContext: ModelContext,
        notificationService: NotificationService,
        settings: NotificationSettings,
        activityLog: ActivityLog
    ) {
        self.store = store
        self.cacheContext = cacheContext
        self.notificationService = notificationService
        self.settings = settings
        self.activityLog = activityLog
    }

    func startIfEnabled() {
        guard settings.isEnabled, scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: Self.identifier)
        s.repeats = true
        s.interval = 15 * 60
        s.tolerance = 5 * 60
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.runRefresh()
                completion(.finished)
            }
        }
        scheduler = s
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }

    private func runRefresh() async {
        guard settings.isEnabled else { return }
        var loaded: [NotificationService.RepoIssues] = []
        for repo in store.repos {
            guard let token = await KeychainService.load(for: repo) else { continue }
            let loader = IssueLoader(
                config: repo, activityLog: activityLog, cacheContext: cacheContext
            )
            await loader.load(token: token)
            if case .loaded(let issues, _) = loader.state {
                loaded.append((repo.owner, repo.repo, issues))
            }
        }
        await notificationService.diffAndNotify(loadedByRepo: loaded)
    }
}
#endif
```

- [ ] **Step 2: Build macOS target**

Run via zcode skill. Expect success.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift
git commit -m "feat(notifications): macOS NSBackgroundActivityScheduler driver"
```

---

### Task 12: project.yml — Info plist additions

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Read existing iOS target Info section**

Open `project.yml` and find the `AppFeedback` target (or its iOS-platform variant). Existing settings are under `settings.base`.

- [ ] **Step 2: Add Info plist entries (iOS only)**

Under the `AppFeedback` target, add an `info` block scoped to iOS using XcodeGen's per-platform Info plist support. If the project does not currently customize Info.plist (it uses `GENERATE_INFOPLIST_FILE: YES`), add these via `INFOPLIST_KEY_*` build settings, which is the simpler path:

```yaml
    settings:
      base:
        # ... existing settings ...
      configs:
        Debug:
          INFOPLIST_KEY_UIBackgroundModes: "fetch"
          INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers: "com.amirhayek.AppFeedback.refresh"
        Release:
          INFOPLIST_KEY_UIBackgroundModes: "fetch"
          INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers: "com.amirhayek.AppFeedback.refresh"
```

If the values cannot be expressed via `INFOPLIST_KEY_*` (Xcode rejects array values for `BGTaskSchedulerPermittedIdentifiers` via build settings in some toolchains), fall back to a hand-managed `AppFeedback/Info.plist` and set `INFOPLIST_FILE: AppFeedback/Info.plist`, `GENERATE_INFOPLIST_FILE: NO`. The Info.plist must contain:

```xml
<key>UIBackgroundModes</key>
<array><string>fetch</string></array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array><string>com.amirhayek.AppFeedback.refresh</string></array>
```

- [ ] **Step 3: Regenerate the Xcode project**

Run via zcode skill: regenerate Xcode project from `project.yml` (typically `xcodegen generate`).

- [ ] **Step 4: Build iOS target, verify Info.plist contains the keys**

- [ ] **Step 5: Commit**

```bash
git add project.yml AppFeedback.xcodeproj
git commit -m "chore(ios): add background fetch + BGTask identifier to Info plist"
```

If the fallback Info.plist path was used, also commit `AppFeedback/Info.plist`.

---

### Task 13: Wire everything in AppFeedbackApp

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Add notification state**

In `AppFeedbackApp`, add stored properties:

```swift
@State private var notificationSettings: NotificationSettings
@State private var notificationService: NotificationService
@State private var notificationRouter: NotificationRouter
#if os(iOS)
@State private var iosRefreshDriver: iOSBackgroundRefreshDriver
#elseif os(macOS)
@State private var macRefreshDriver: MacBackgroundRefreshDriver
#endif
```

- [ ] **Step 2: Initialize in `init()`**

Append to `init()` after the existing `_intelligenceService` line:

```swift
let settings = NotificationSettings()
let router = NotificationRouter()
let notifiedStore = NotifiedIssueStore()
let service = NotificationService(
    center: UNUserNotificationCenter.current(),
    notifiedStore: notifiedStore,
    settings: settings,
    router: router
)
UNUserNotificationCenter.current().delegate = service

_notificationSettings = State(initialValue: settings)
_notificationRouter = State(initialValue: router)
_notificationService = State(initialValue: service)

let activityLogValue = _activityLog.wrappedValue
#if os(iOS)
let driver = iOSBackgroundRefreshDriver(
    store: _store.wrappedValue,
    cacheContext: _cacheContext.wrappedValue,
    notificationService: service,
    settings: settings,
    activityLog: activityLogValue
)
driver.register()
driver.scheduleNextRefresh()
_iosRefreshDriver = State(initialValue: driver)
#elseif os(macOS)
let driver = MacBackgroundRefreshDriver(
    store: _store.wrappedValue,
    cacheContext: _cacheContext.wrappedValue,
    notificationService: service,
    settings: settings,
    activityLog: activityLogValue
)
driver.startIfEnabled()
_macRefreshDriver = State(initialValue: driver)
#endif
```

Add the import at the top of the file:

```swift
import UserNotifications
```

- [ ] **Step 3: Inject into environment**

In `body`, add to the `RootView` environment chain:

```swift
.environment(notificationSettings)
.environment(notificationService)
.environment(notificationRouter)
```

And mirror those three lines in the macOS `Settings { SettingsView(... ) ... }` chain.

- [ ] **Step 4: First-launch permission prompt**

Add a `.task` modifier to `RootView(...)`:

```swift
.task { await notificationService.requestAuthorizationIfNeeded() }
```

If the user grants permission, also snapshot the existing loaded issues so the backlog isn't notified. The simplest place: inside `RootView` itself, observe `IssueListViewModel`'s loaded state and call `service.snapshotExistingIssues(...)` exactly once after the first successful load if `hasRequestedAuthorization` was just flipped. (See Task 14.)

- [ ] **Step 5: React to settings toggle (macOS)**

Add an `.onChange(of: notificationSettings.isEnabled)` modifier to a top-level view in `body`:

```swift
.onChange(of: notificationSettings.isEnabled) { _, isOn in
    #if os(macOS)
    if isOn { macRefreshDriver.startIfEnabled() } else { macRefreshDriver.stop() }
    #else
    if isOn { iosRefreshDriver.scheduleNextRefresh() }
    #endif
}
```

- [ ] **Step 6: Build for both platforms, fix any compile errors**

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(notifications): wire service, drivers, environment in app entry"
```

---

### Task 14: First-launch backlog snapshot + tap routing in RootView

**Files:**
- Modify: `AppFeedback/App/RootView.swift`

- [ ] **Step 1: Read RootView**

Identify the location of issue selection (likely a `selection` binding on `IssueListViewModel`) and where the loaded list of all issues across repos can be enumerated as `(owner, repo, [issue])`.

- [ ] **Step 2: Add router observation**

Inject `NotificationRouter` and `NotificationService` via `@Environment`. Add:

```swift
.onChange(of: notificationRouter.pendingIssueKey) { _, newValue in
    guard let key = newValue else { return }
    notificationRouter.pendingIssueKey = nil
    selectIssue(byKey: key)
}
```

Implement `selectIssue(byKey:)`: parse `"owner/repo#number"` (split on `/` and `#`), find the matching loaded `FeedbackIssue` in the existing list, and assign it to the existing selection state. If not found in the currently-loaded list, trigger a refresh first, then retry once.

- [ ] **Step 3: One-time backlog snapshot**

After the *first* successful load following authorization being granted (i.e., `notificationSettings.hasRequestedAuthorization == true && notificationSettings.isEnabled == true && !backlogSnapshotted`), call:

```swift
notificationService.snapshotExistingIssues(loadedByRepo: currentLoadedGroups())
backlogSnapshotted = true
```

Persist `backlogSnapshotted` to UserDefaults under `appfeedback.notifications.backlogSnapshotted` so this fires only once across launches.

- [ ] **Step 4: Build, exercise the tap path manually if possible**

Build the app on macOS, manually trigger a notification by calling `notificationService.diffAndNotify(...)` with a stub group from a debug menu (optional during development), tap it, confirm the issue is selected.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/App/RootView.swift
git commit -m "feat(notifications): tap routing + first-load backlog snapshot"
```

---

### Task 15: Manual verification

- [ ] **Step 1: macOS — verify notifications fire**

Temporarily lower `MacBackgroundRefreshDriver.interval` to `30` seconds. Run the app. Add a new issue in one of the tracked GitHub repos. Within ~30s, observe a banner.

- [ ] **Step 2: macOS — verify tap routes**

Tap the banner. Confirm the app activates and the matching issue is selected in the list.

- [ ] **Step 3: macOS — verify summary path**

Add 4+ new issues quickly. On the next refresh, confirm a single `"4 new issues"` banner.

- [ ] **Step 4: macOS — verify settings toggle stops refresh**

Disable the toggle in Settings; observe scheduler stops (no further banners). Re-enable; observe banners resume.

- [ ] **Step 5: iOS — verify simulated background fetch**

In Xcode while the iOS app is suspended in the simulator, run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.amirhayek.AppFeedback.refresh"]
```

Add an issue, simulate the launch, confirm a banner.

- [ ] **Step 6: Restore production interval**

Revert the macOS interval to `15 * 60`.

- [ ] **Step 7: Commit if anything changed**

```bash
git add -A
git commit -m "chore(notifications): restore production refresh interval"
```

(Skip if no changes.)

---

## Out of scope (do not implement here)

- New comments, mail notifications.
- Per-repo mute, quiet hours, badging, custom sounds.
- Real APNs / server push.
- Cross-device "already notified" sync.
