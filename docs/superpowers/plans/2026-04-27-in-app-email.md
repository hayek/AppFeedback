# In-App Email Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Mac user send email from inside AppFeedback using their own SMTP credentials, with a customizable HTML header/footer template, and surface all background activity (fetches, sends) in a new Activity window.

**Architecture:** Four new services (`MailSettings`, `MailComposer`, `MailSender`, `ActivityLog`) + three new views (`ComposeMailView`, `EmailSettingsView`, `ActivityWindow`) + a small `RichTextEditor` `NSViewRepresentable`. SMTP transport is delegated to the **Cocoanetics/SwiftMail** SPM package. UI is macOS-only (gated by `#if os(macOS)`); shared services compile on both iOS and macOS.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (NSTextView for rich editing), XCTest, XcodeGen, [Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail).

**Spec:** `docs/superpowers/specs/2026-04-27-in-app-email-design.md`.

---

## Conventions

- Tests use `XCTest` with `@testable import AppFeedback`. New test files follow the `<Subject>Tests.swift` pattern in `AppFeedbackTests/`.
- Project files are generated from `project.yml` by `xcodegen`. After editing `project.yml`, run `xcodegen` from the repo root to regenerate `AppFeedback.xcodeproj`.
- Build/test commands use the **zcode** skill, not raw `xcodebuild`. When this plan says "build" or "run tests", invoke `zcode`.
- macOS-only UI files live behind a top-level `#if os(macOS) ... #endif`. Service code compiles on both platforms (it just isn't called from iOS).
- Commit after every task — small, focused commits. Use the imperative mood, prefix with the area touched (`feat(mail):`, `feat(activity):`, etc.) following the repo's existing style.

---

## File Map

**New files:**

| Path | Purpose |
|------|---------|
| `AppFeedback/Services/ActivityLog.swift` | `@Observable` log of fetches and sends; persisted to JSON. |
| `AppFeedback/Services/Mail/MailSettings.swift` | SMTP credentials + template, persisted to Keychain + UserDefaults. |
| `AppFeedback/Services/Mail/MailComposer.swift` | Pure templating, HTML sanitization, `SwiftMail.Email` assembly. |
| `AppFeedback/Services/Mail/MailSender.swift` | `MailSending` protocol + `MailSender` actor wrapping SwiftMail. |
| `AppFeedback/Services/Mail/HTMLSanitizer.swift` | Allowlist-based HTML sanitizer used by `MailComposer`. |
| `AppFeedback/ViewModels/ComposeMailViewModel.swift` | Owns draft state and orchestrates send (macOS-only). |
| `AppFeedback/Views/Mail/ComposeMailView.swift` | Compose sheet (macOS-only). |
| `AppFeedback/Views/Mail/RichTextEditor.swift` | `NSViewRepresentable` wrapping `NSTextView` (macOS-only). |
| `AppFeedback/Views/Activity/ActivityWindow.swift` | List view + `Window` scene (macOS-only). |
| `AppFeedback/Views/Settings/EmailSettingsView.swift` | Email tab content (macOS-only). |
| `AppFeedbackTests/ActivityLogTests.swift` | TDD coverage of activity log. |
| `AppFeedbackTests/MailSettingsTests.swift` | Round-trip and preset tests. |
| `AppFeedbackTests/MailComposerTests.swift` | Placeholder, sanitizer, MIME assembly tests. |
| `AppFeedbackTests/HTMLSanitizerTests.swift` | Sanitizer allowlist tests. |
| `AppFeedbackTests/ComposeMailViewModelTests.swift` | VM-level send orchestration with a fake sender. |

**Modified files:**

| Path | What changes |
|------|--------------|
| `project.yml` | Add SwiftMail SPM dep (macOS only), add Application Support entitlement. |
| `AppFeedback/Services/IssueLoader.swift` | Wrap fetches with `activityLog.start/finish`. |
| `AppFeedback/Services/KeychainService.swift` | Add SMTP password accessors keyed by a fixed account string. |
| `AppFeedback/App/AppFeedbackApp.swift` | Construct `ActivityLog`, `MailSettings`, `MailSender`; add Activity `Window` scene + menu (macOS). |
| `AppFeedback/App/RootView.swift` | Inject the new services into the environment. |
| `AppFeedback/Views/Issues/IssueCardView.swift` | Replace the email `Link(mailto:)` with a callback-driven button on macOS. |
| `AppFeedback/Views/Issues/IssueListView.swift` | Hold compose-sheet state and present `ComposeMailView` on email tap. |
| `AppFeedback/Views/Settings/SettingsView.swift` | Wrap existing content in a `TabView` and add an "Email" tab. |

---

## Task 1: Add SwiftMail SPM dependency

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the package and dependency to `project.yml`**

Open `project.yml` and add a top-level `packages:` block (above `targets:`), and add a dependency under the `AppFeedback` target. The dep is restricted to macOS so the iOS variant doesn't pull in NIO source.

After editing, the relevant sections look like:

```yaml
packages:
  SwiftMail:
    url: https://github.com/Cocoanetics/SwiftMail
    from: 1.0.0

targets:
  AppFeedback:
    type: application
    platform: [iOS, macOS]
    deploymentTarget:
      iOS: "17.0"
      macOS: "14.0"
    sources:
      - path: AppFeedback
        createIntermediateGroups: true
    dependencies:
      - package: SwiftMail
        product: SwiftMail
        platforms: [macOS]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.amirhayek.AppFeedback
        SWIFT_VERSION: "5.9"
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_ENTITLEMENTS: AppFeedback/AppFeedback.entitlements
        CODE_SIGN_STYLE: Automatic
```

If the latest tag on github.com/Cocoanetics/SwiftMail is below `1.0.0`, use the actual highest tag (check via `gh api repos/Cocoanetics/SwiftMail/tags --jq '.[0].name'`) — replace `from: 1.0.0` with that exact version.

- [ ] **Step 2: Regenerate the Xcode project**

```bash
cd /Users/hayek/Developer/AppFeedback
xcodegen
```

Expected: `Created project at AppFeedback.xcodeproj` (or similar success line).

- [ ] **Step 3: Build the macOS scheme to verify the dep resolves**

Use the `zcode` skill to build the `AppFeedback_macOS` scheme.

Expected: build succeeds. SwiftMail's transitive deps (swift-nio, swift-nio-ssl, swift-nio-imap, swift-log, swift-collections) resolve and compile.

If the build fails on package resolution, double-check the version constraint, the package name, and that `dependencies` is a sibling of `sources` under the target (XcodeGen syntax).

- [ ] **Step 4: Build the iOS scheme to verify the dep was excluded**

Use `zcode` to build `AppFeedback_iOS`.

Expected: build succeeds without resolving SwiftMail (the `platforms: [macOS]` filter excludes it on iOS).

- [ ] **Step 5: Commit**

```bash
git add project.yml AppFeedback.xcodeproj
git commit -m "feat(mail): add SwiftMail SPM dependency for macOS"
```

---

## Task 2: ActivityLog types and in-memory operations (TDD)

**Files:**
- Create: `AppFeedback/Services/ActivityLog.swift`
- Test: `AppFeedbackTests/ActivityLogTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/ActivityLogTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class ActivityLogTests: XCTestCase {

    private func makeLog() -> ActivityLog {
        ActivityLog(persistenceURL: nil)
    }

    func test_start_appendsInProgressEntry() {
        let log = makeLog()
        let id = log.start(kind: .sendEmail, title: "to alice@example.com")

        XCTAssertEqual(log.entries.count, 1)
        let entry = log.entries[0]
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.kind, .sendEmail)
        XCTAssertEqual(entry.title, "to alice@example.com")
        XCTAssertEqual(entry.status, .inProgress)
        XCTAssertNil(entry.detail)
    }

    func test_finish_updatesStatusAndDetail() {
        let log = makeLog()
        let id = log.start(kind: .sendEmail, title: "to alice@example.com")
        log.finish(id, status: .success, detail: nil)

        XCTAssertEqual(log.entries[0].status, .success)
        XCTAssertNil(log.entries[0].detail)
    }

    func test_finish_failureCarriesDetail() {
        let log = makeLog()
        let id = log.start(kind: .fetchIssues, title: "owner/repo")
        log.finish(id, status: .failure, detail: "Server returned 503")

        XCTAssertEqual(log.entries[0].status, .failure)
        XCTAssertEqual(log.entries[0].detail, "Server returned 503")
    }

    func test_entries_orderedNewestFirst() {
        let log = makeLog()
        _ = log.start(kind: .fetchIssues, title: "first")
        _ = log.start(kind: .fetchIssues, title: "second")

        XCTAssertEqual(log.entries.first?.title, "second")
        XCTAssertEqual(log.entries.last?.title, "first")
    }

    func test_capEnforced_oldestDropped() {
        let log = ActivityLog(persistenceURL: nil, cap: 3)
        for i in 1...5 {
            _ = log.start(kind: .fetchIssues, title: "n=\(i)")
        }

        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.title), ["n=5", "n=4", "n=3"])
    }

    func test_clearAll_emptiesEntries() {
        let log = makeLog()
        _ = log.start(kind: .sendEmail, title: "a")
        _ = log.start(kind: .sendEmail, title: "b")
        log.clearAll()

        XCTAssertTrue(log.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Use `zcode` to run `AppFeedbackTests_macOS`. Expected: compilation failure (`ActivityLog` not found).

- [ ] **Step 3: Implement `ActivityLog`**

Create `AppFeedback/Services/ActivityLog.swift`:

```swift
import Foundation
import Observation

struct ActivityLogEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case fetchIssues
        case sendEmail
        case testConnection
    }

    enum Status: String, Codable, Sendable {
        case inProgress
        case success
        case failure
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    var title: String
    var status: Status
    var detail: String?
}

@MainActor
@Observable
final class ActivityLog {
    /// Newest first.
    private(set) var entries: [ActivityLogEntry] = []

    private let cap: Int
    private let persistenceURL: URL?

    init(persistenceURL: URL?, cap: Int = 500) {
        self.persistenceURL = persistenceURL
        self.cap = cap
    }

    @discardableResult
    func start(kind: ActivityLogEntry.Kind, title: String) -> UUID {
        let entry = ActivityLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            title: title,
            status: .inProgress,
            detail: nil
        )
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        return entry.id
    }

    func finish(_ id: UUID, status: ActivityLogEntry.Status, detail: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status
        entries[idx].detail = detail
    }

    func clearAll() {
        entries.removeAll()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Use `zcode` to run `AppFeedbackTests_macOS`.

Expected: all six tests in `ActivityLogTests` pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/ActivityLog.swift AppFeedbackTests/ActivityLogTests.swift
git commit -m "feat(activity): in-memory ActivityLog with capped entries"
```

---

## Task 3: ActivityLog JSON persistence (TDD)

**Files:**
- Modify: `AppFeedback/Services/ActivityLog.swift`
- Modify: `AppFeedbackTests/ActivityLogTests.swift`

- [ ] **Step 1: Add persistence tests**

Append to `AppFeedbackTests/ActivityLogTests.swift` inside the existing class:

```swift
    private func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.json")
    }

    func test_persistence_roundTrip() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = ActivityLog(persistenceURL: url)
        let id = log.start(kind: .sendEmail, title: "to bob@example.com")
        log.finish(id, status: .success, detail: "OK")
        try await log.flushForTesting()

        let log2 = ActivityLog(persistenceURL: url)
        try await log2.loadForTesting()

        XCTAssertEqual(log2.entries.count, 1)
        XCTAssertEqual(log2.entries[0].title, "to bob@example.com")
        XCTAssertEqual(log2.entries[0].status, .success)
        XCTAssertEqual(log2.entries[0].detail, "OK")
    }

    func test_clearAll_overwritesPersistedFile() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = ActivityLog(persistenceURL: url)
        _ = log.start(kind: .sendEmail, title: "a")
        try await log.flushForTesting()
        log.clearAll()
        try await log.flushForTesting()

        let log2 = ActivityLog(persistenceURL: url)
        try await log2.loadForTesting()
        XCTAssertTrue(log2.entries.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Use `zcode`. Expected: compile errors (`flushForTesting`, `loadForTesting` undefined).

- [ ] **Step 3: Add persistence to `ActivityLog`**

Replace the body of `ActivityLog` in `AppFeedback/Services/ActivityLog.swift` with this expanded version (keep the `ActivityLogEntry` struct above unchanged):

```swift
@MainActor
@Observable
final class ActivityLog {
    private(set) var entries: [ActivityLogEntry] = []

    private let cap: Int
    private let persistenceURL: URL?
    private var pendingFlush: Task<Void, Never>?

    init(persistenceURL: URL?, cap: Int = 500) {
        self.persistenceURL = persistenceURL
        self.cap = cap
        load()
    }

    @discardableResult
    func start(kind: ActivityLogEntry.Kind, title: String) -> UUID {
        let entry = ActivityLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            title: title,
            status: .inProgress,
            detail: nil
        )
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        scheduleFlush()
        return entry.id
    }

    func finish(_ id: UUID, status: ActivityLogEntry.Status, detail: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status
        entries[idx].detail = detail
        scheduleFlush()
    }

    func clearAll() {
        entries.removeAll()
        scheduleFlush()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601().decode([ActivityLogEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func scheduleFlush() {
        guard persistenceURL != nil else { return }
        pendingFlush?.cancel()
        let snapshot = entries
        let url = persistenceURL!
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await ActivityLog.write(snapshot, to: url)
            self?.pendingFlush = nil
        }
    }

    nonisolated private static func write(_ entries: [ActivityLogEntry], to url: URL) async {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder.iso8601().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Test hooks

    func flushForTesting() async throws {
        guard let url = persistenceURL else { return }
        pendingFlush?.cancel()
        pendingFlush = nil
        await Self.write(entries, to: url)
    }

    func loadForTesting() async throws {
        load()
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```

- [ ] **Step 4: Run all `ActivityLogTests` to verify they pass**

Use `zcode`. Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/ActivityLog.swift AppFeedbackTests/ActivityLogTests.swift
git commit -m "feat(activity): debounced JSON persistence for ActivityLog"
```

---

## Task 4: Construct ActivityLog at app startup

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`
- Modify: `AppFeedback/App/RootView.swift`

- [ ] **Step 1: Read current `AppFeedbackApp.swift`**

Read the file to find where existing services (`RepoStore`, `CloudSyncStatus`, etc.) are constructed and injected.

- [ ] **Step 2: Add `ActivityLog` construction**

In `AppFeedbackApp.swift`, alongside the existing service construction, add:

```swift
@State private var activityLog: ActivityLog = {
    let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("AppFeedback", isDirectory: true)
    let url = supportDir.appendingPathComponent("activity.json")
    return ActivityLog(persistenceURL: url)
}()
```

(If `AppFeedbackApp` already uses a different ownership pattern — e.g. `@State` on a struct field, or constructed in `init()` — match that pattern instead of introducing a new one.)

Inject it into the environment on the same view chain as the existing services:

```swift
RootView(...)
    .environment(activityLog)
```

- [ ] **Step 3: Build to verify compilation**

Use `zcode` to build `AppFeedback_macOS`. Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift AppFeedback/App/RootView.swift
git commit -m "feat(activity): wire ActivityLog into app environment"
```

---

## Task 5: Wire ActivityLog into IssueLoader

**Files:**
- Modify: `AppFeedback/Services/IssueLoader.swift`

- [ ] **Step 1: Read current `IssueLoader.swift`**

Identify the public load entry point (likely `func load() async`) and the failure paths.

- [ ] **Step 2: Inject `ActivityLog?` into `IssueLoader`**

Add an optional `ActivityLog?` to `IssueLoader`'s init (default `nil` to avoid breaking existing tests):

```swift
private let activityLog: ActivityLog?

init(repo: RepoConfig, /* existing params */, activityLog: ActivityLog? = nil) {
    // existing assignments
    self.activityLog = activityLog
}
```

- [ ] **Step 3: Wrap fetch with start/finish**

In the load method, wrap the network call:

```swift
let entryID = activityLog?.start(kind: .fetchIssues, title: "\(repo.owner)/\(repo.repo)")
do {
    // existing fetch logic
    if let entryID { activityLog?.finish(entryID, status: .success, detail: nil) }
} catch {
    if let entryID {
        activityLog?.finish(entryID, status: .failure, detail: error.localizedDescription)
    }
    throw error  // or whatever the existing error path does
}
```

Match the existing control flow exactly — don't change error semantics, just thread the log calls through.

- [ ] **Step 4: Update construction sites**

Wherever `IssueLoader(...)` is constructed (likely in a view or another VM), pass `activityLog` from the environment:

```swift
@Environment(ActivityLog.self) private var activityLog
// ...
IssueLoader(repo: repo, /* ... */, activityLog: activityLog)
```

- [ ] **Step 5: Run existing IssueLoader tests**

Use `zcode` to run `AppFeedbackTests_macOS`. Expected: all existing `IssueLoaderTests` still pass (the new param defaulted to `nil` shouldn't change behavior).

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/IssueLoader.swift AppFeedback/Views/ AppFeedback/ViewModels/
git commit -m "feat(activity): log issue fetches to ActivityLog"
```

---

## Task 6: ActivityWindow scene + menu (macOS-only)

**Files:**
- Create: `AppFeedback/Views/Activity/ActivityWindow.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Create `ActivityWindow.swift`**

```swift
#if os(macOS)
import SwiftUI

struct ActivityWindow: View {
    @Environment(ActivityLog.self) private var log
    @State private var filter: KindFilter = .all

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case fetches = "Fetches"
        case emails = "Emails"
        var id: String { rawValue }
    }

    private var filteredEntries: [ActivityLogEntry] {
        switch filter {
        case .all:     return log.entries
        case .fetches: return log.entries.filter { $0.kind == .fetchIssues }
        case .emails:  return log.entries.filter { $0.kind == .sendEmail || $0.kind == .testConnection }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)

            List(filteredEntries) { entry in
                ActivityRow(entry: entry)
            }

            Divider()

            HStack {
                Spacer()
                Button("Clear All", role: .destructive) {
                    log.clearAll()
                }
                .disabled(log.entries.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

private struct ActivityRow: View {
    let entry: ActivityLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13))
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.kind {
        case .fetchIssues:     return "arrow.down.circle"
        case .sendEmail:       return "paperplane"
        case .testConnection:  return "checkmark.shield"
        }
    }

    private var iconColor: Color {
        switch entry.status {
        case .inProgress: return .secondary
        case .success:    return .green
        case .failure:    return .red
        }
    }
}
#endif
```

- [ ] **Step 2: Register the Window scene**

In `AppFeedbackApp.swift`, add (inside the `Scene` body, alongside the existing `WindowGroup`):

```swift
#if os(macOS)
Window("Activity", id: "activity") {
    ActivityWindow()
        .environment(activityLog)
}
.commands {
    CommandGroup(after: .windowList) {
        Button("Activity") {
            NSApp.sendAction(
                Selector(("openWindow:")),
                to: nil,
                from: "activity"
            )
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
    }
}
#endif
```

(If `AppFeedbackApp.swift` already uses `@Environment(\.openWindow)` for other windows, prefer that pattern over `NSApp.sendAction`.)

- [ ] **Step 3: Build and smoke test**

Use `zcode` to build and run `AppFeedback_macOS`. Manually:

1. Open the app.
2. Choose Window → Activity (or ⌥⌘0).
3. Trigger an issue fetch (select a repo). Confirm an entry appears in Activity, transitions from "in progress" to "success" (or "failure").
4. Click "Clear All". Confirm the list empties.
5. Quit and relaunch. Trigger a fetch again. Confirm the new entry appears (and any persisted ones from before reload, if you didn't clear).

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Activity/ActivityWindow.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(activity): add Activity window with filters and Clear All"
```

---

## Task 7: KeychainService SMTP password helpers

**Files:**
- Modify: `AppFeedback/Services/KeychainService.swift`

- [ ] **Step 1: Add SMTP-specific helpers**

Append to `KeychainService.swift` inside the `enum KeychainService { ... }`:

```swift
    private static let smtpAccount = "smtp.password"

    static func saveSMTPPassword(_ password: String) async {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        smtpAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    static func loadSMTPPassword() async -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        smtpAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSMTPPassword() async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        smtpAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }
```

- [ ] **Step 2: Build to verify compilation**

Use `zcode` to build `AppFeedback_macOS`. Expected: success.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/KeychainService.swift
git commit -m "feat(keychain): add SMTP password helpers"
```

---

## Task 8: MailSettings types and storage (TDD)

**Files:**
- Create: `AppFeedback/Services/Mail/MailSettings.swift`
- Test: `AppFeedbackTests/MailSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/MailSettingsTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class MailSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "MailSettingsTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_credentials_roundTripThroughDefaults() {
        let defaults = makeDefaults()
        let settings = MailSettings(defaults: defaults)
        let creds = SMTPCredentials(
            preset: .gmail,
            host: "smtp.gmail.com",
            port: 587,
            useSTARTTLS: true,
            username: "alice@gmail.com",
            password: "ignored-here",
            senderName: "Alice"
        )

        settings.credentials = creds

        let reloaded = MailSettings(defaults: defaults)
        XCTAssertEqual(reloaded.credentials?.username, "alice@gmail.com")
        XCTAssertEqual(reloaded.credentials?.host, "smtp.gmail.com")
        XCTAssertEqual(reloaded.credentials?.port, 587)
        XCTAssertEqual(reloaded.credentials?.preset, .gmail)
    }

    func test_template_roundTrip() {
        let defaults = makeDefaults()
        let settings = MailSettings(defaults: defaults)
        settings.template = MailTemplate(headerHTML: "<p>Hi {{recipient_email}}</p>", footerHTML: "<p>Bye</p>")

        let reloaded = MailSettings(defaults: defaults)
        XCTAssertEqual(reloaded.template.headerHTML, "<p>Hi {{recipient_email}}</p>")
        XCTAssertEqual(reloaded.template.footerHTML, "<p>Bye</p>")
    }

    func test_presetDefaults_gmail() {
        XCTAssertEqual(SMTPCredentials.defaults(for: .gmail).host, "smtp.gmail.com")
        XCTAssertEqual(SMTPCredentials.defaults(for: .gmail).port, 587)
        XCTAssertTrue(SMTPCredentials.defaults(for: .gmail).useSTARTTLS)
    }

    func test_presetDefaults_icloud() {
        XCTAssertEqual(SMTPCredentials.defaults(for: .icloud).host, "smtp.mail.me.com")
        XCTAssertEqual(SMTPCredentials.defaults(for: .icloud).port, 587)
    }

    func test_presetDefaults_outlook() {
        XCTAssertEqual(SMTPCredentials.defaults(for: .outlook).host, "smtp-mail.outlook.com")
    }

    func test_credentials_clearedWhenSetToNil() {
        let defaults = makeDefaults()
        let settings = MailSettings(defaults: defaults)
        settings.credentials = SMTPCredentials.defaults(for: .gmail)
        settings.credentials = nil

        let reloaded = MailSettings(defaults: defaults)
        XCTAssertNil(reloaded.credentials)
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails to compile**

Use `zcode`. Expected: compile errors (`MailSettings`, `SMTPCredentials`, `MailTemplate` undefined).

- [ ] **Step 3: Implement `MailSettings`**

Create `AppFeedback/Services/Mail/MailSettings.swift`:

```swift
import Foundation
import Observation

struct SMTPCredentials: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case gmail
        case icloud
        case outlook
        case custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gmail:   return "Gmail"
            case .icloud:  return "iCloud"
            case .outlook: return "Outlook"
            case .custom:  return "Custom SMTP"
            }
        }
    }

    var preset: Preset
    var host: String
    var port: Int
    var useSTARTTLS: Bool
    var username: String   // doubles as the From address
    var password: String   // stored in Keychain, not in this struct's persisted form
    var senderName: String

    static func defaults(for preset: Preset) -> SMTPCredentials {
        switch preset {
        case .gmail:
            return SMTPCredentials(preset: .gmail, host: "smtp.gmail.com",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        case .icloud:
            return SMTPCredentials(preset: .icloud, host: "smtp.mail.me.com",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        case .outlook:
            return SMTPCredentials(preset: .outlook, host: "smtp-mail.outlook.com",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        case .custom:
            return SMTPCredentials(preset: .custom, host: "",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        }
    }
}

struct MailTemplate: Codable, Equatable, Sendable {
    var headerHTML: String
    var footerHTML: String

    static let empty = MailTemplate(headerHTML: "", footerHTML: "")
}

/// In-memory + UserDefaults-backed settings.
/// `credentials.password` is NOT persisted in UserDefaults — store/load via Keychain separately.
@MainActor
@Observable
final class MailSettings {
    var credentials: SMTPCredentials? {
        didSet { persistCredentials() }
    }
    var template: MailTemplate {
        didSet { persistTemplate() }
    }

    private let defaults: UserDefaults
    private static let credentialsKey = "mail.credentials"
    private static let templateKey = "mail.template"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.credentialsKey),
           let decoded = try? JSONDecoder().decode(SMTPCredentials.self, from: data) {
            self.credentials = decoded
        } else {
            self.credentials = nil
        }
        if let data = defaults.data(forKey: Self.templateKey),
           let decoded = try? JSONDecoder().decode(MailTemplate.self, from: data) {
            self.template = decoded
        } else {
            self.template = .empty
        }
    }

    private func persistCredentials() {
        if let credentials,
           let data = try? JSONEncoder().encode(redactingPassword(credentials)) {
            defaults.set(data, forKey: Self.credentialsKey)
        } else {
            defaults.removeObject(forKey: Self.credentialsKey)
        }
    }

    private func persistTemplate() {
        if let data = try? JSONEncoder().encode(template) {
            defaults.set(data, forKey: Self.templateKey)
        }
    }

    private func redactingPassword(_ creds: SMTPCredentials) -> SMTPCredentials {
        var copy = creds
        copy.password = ""  // password lives in Keychain
        return copy
    }
}
```

- [ ] **Step 4: Run all `MailSettingsTests`**

Use `zcode`. Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailSettings.swift AppFeedbackTests/MailSettingsTests.swift
git commit -m "feat(mail): MailSettings with preset SMTP defaults and persistence"
```

---

## Task 9: HTML allowlist sanitizer (TDD)

**Files:**
- Create: `AppFeedback/Services/Mail/HTMLSanitizer.swift`
- Test: `AppFeedbackTests/HTMLSanitizerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/HTMLSanitizerTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class HTMLSanitizerTests: XCTestCase {

    func test_keepsAllowedTags() {
        let input = "<p>Hello <strong>world</strong></p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(input), "<p>Hello <strong>world</strong></p>")
    }

    func test_dropsScriptTag() {
        let input = "<p>ok</p><script>alert(1)</script>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("<p>ok</p>"))
    }

    func test_dropsStyleTag() {
        let input = "<style>p { color: red }</style><p>x</p>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("<style"))
        XCTAssertFalse(out.contains("color: red"))
    }

    func test_dropsInlineEventHandlers() {
        let input = #"<p onclick="evil()">x</p>"#
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("onclick"))
        XCTAssertFalse(out.contains("evil"))
        XCTAssertTrue(out.contains("<p>x</p>"))
    }

    func test_keepsLinkHref() {
        let input = #"<a href="https://example.com">link</a>"#
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertTrue(out.contains("href=\"https://example.com\""))
    }

    func test_dropsJavascriptHref() {
        let input = #"<a href="javascript:alert(1)">x</a>"#
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("javascript:"))
    }

    func test_dropsUnknownTagButKeepsContent() {
        let input = "<p>Hi <marquee>scrolling</marquee> world</p>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("<marquee"))
        XCTAssertTrue(out.contains("scrolling"))
    }
}
```

- [ ] **Step 2: Run the tests, confirm compile failure**

Use `zcode`. Expected: `HTMLSanitizer` undefined.

- [ ] **Step 3: Implement the sanitizer**

Create `AppFeedback/Services/Mail/HTMLSanitizer.swift`:

```swift
import Foundation

enum HTMLSanitizer {
    private static let allowedTags: Set<String> = [
        "p", "br", "strong", "em", "u", "a",
        "ul", "ol", "li", "blockquote", "span"
    ]

    private static let allowedAttributesByTag: [String: Set<String>] = [
        "a": ["href"]
    ]

    static func sanitize(_ html: String) -> String {
        // Strip <script>...</script> and <style>...</style> blocks (including content).
        var s = html
        s = stripBlock(in: s, tag: "script")
        s = stripBlock(in: s, tag: "style")
        // Strip tags / attributes via element walk.
        return rewrite(s)
    }

    private static func stripBlock(in s: String, tag: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>",
            options: [.caseInsensitive]
        ) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    /// Walks through tag tokens and rebuilds the HTML, dropping disallowed tags
    /// (keeping their inner content) and stripping disallowed attributes.
    private static func rewrite(_ html: String) -> String {
        var result = ""
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<", let close = html[i...].firstIndex(of: ">") {
                let tagToken = String(html[i...close])
                let inner = tagToken.dropFirst().dropLast()
                let isClosing = inner.first == "/"
                let nameAndAttrs = isClosing ? inner.dropFirst() : inner
                let parts = nameAndAttrs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let rawName = parts.first.map(String.init) ?? ""
                let name = rawName.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if allowedTags.contains(name) {
                    if isClosing {
                        result += "</\(name)>"
                    } else {
                        let attrs = parts.count > 1 ? String(parts[1]) : ""
                        let cleaned = filterAttributes(tag: name, attrs: attrs)
                        result += cleaned.isEmpty ? "<\(name)>" : "<\(name) \(cleaned)>"
                    }
                }
                // else: drop the tag, keep walking — inner content survives.
                i = html.index(after: close)
            } else {
                result.append(html[i])
                i = html.index(after: i)
            }
        }
        return result
    }

    private static func filterAttributes(tag: String, attrs: String) -> String {
        let allowed = allowedAttributesByTag[tag] ?? []
        let scanner = Scanner(string: attrs)
        scanner.charactersToBeSkipped = .whitespaces
        var kept: [String] = []
        while !scanner.isAtEnd {
            guard let key = scanner.scanUpToString("=")?.lowercased() else { break }
            _ = scanner.scanString("=")
            var value = ""
            if scanner.scanString("\"") != nil {
                value = scanner.scanUpToString("\"") ?? ""
                _ = scanner.scanString("\"")
            } else if scanner.scanString("'") != nil {
                value = scanner.scanUpToString("'") ?? ""
                _ = scanner.scanString("'")
            } else {
                value = scanner.scanUpToCharacters(from: .whitespaces) ?? ""
            }
            guard allowed.contains(key) else { continue }
            // Block javascript: hrefs.
            if key == "href" && value.lowercased().hasPrefix("javascript:") { continue }
            kept.append("\(key)=\"\(value)\"")
        }
        return kept.joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run sanitizer tests**

Use `zcode`. Expected: all 7 tests pass. If a test fails (parsing edge cases are easy to get wrong), iterate on the implementation until it does.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/HTMLSanitizer.swift AppFeedbackTests/HTMLSanitizerTests.swift
git commit -m "feat(mail): allowlist HTML sanitizer for compose"
```

---

## Task 10: MailComposer (TDD)

**Files:**
- Create: `AppFeedback/Services/Mail/MailComposer.swift`
- Test: `AppFeedbackTests/MailComposerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppFeedbackTests/MailComposerTests.swift`:

```swift
import XCTest
@testable import AppFeedback

#if os(macOS)
import AppKit
#endif

final class MailComposerTests: XCTestCase {

    private func makeContext(issueTitle: String? = "Bug: crash on launch",
                             issueURL: URL? = URL(string: "https://github.com/o/r/issues/42"))
    -> PlaceholderContext {
        PlaceholderContext(
            sender: SMTPCredentials(
                preset: .gmail, host: "smtp.gmail.com", port: 587, useSTARTTLS: true,
                username: "alice@gmail.com", password: "x", senderName: "Alice Example"
            ),
            recipient: "bob@example.com",
            appName: "MyApp",
            issueTitle: issueTitle,
            issueURL: issueURL,
            date: ISO8601DateFormatter().date(from: "2026-04-27T10:00:00Z")!
        )
    }

    private func makeDraft(text: String, subject: String = "Hello") -> DraftMessage {
        #if os(macOS)
        let body = NSAttributedString(string: text)
        #else
        let body = NSAttributedString(string: text)
        #endif
        return DraftMessage(
            recipient: "bob@example.com",
            subject: subject,
            body: body
        )
    }

    func test_substitutesAllPlaceholders() {
        let template = MailTemplate(
            headerHTML: "<p>To {{recipient_email}} from {{sender_name}} ({{sender_email}}) on {{date}}</p>",
            footerHTML: "<p>App: {{app_name}} · Issue: {{issue_title}} · {{issue_url}}</p>"
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(),
            template: template
        )

        XCTAssertTrue(email.htmlBody?.contains("To bob@example.com from Alice Example (alice@gmail.com)") == true)
        XCTAssertTrue(email.htmlBody?.contains("App: MyApp") == true)
        XCTAssertTrue(email.htmlBody?.contains("Issue: Bug: crash on launch") == true)
        XCTAssertTrue(email.htmlBody?.contains("https://github.com/o/r/issues/42") == true)
    }

    func test_missingIssueContext_substitutesEmpty() {
        let template = MailTemplate(
            headerHTML: "<p>{{issue_title}}|{{issue_url}}</p>",
            footerHTML: ""
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(issueTitle: nil, issueURL: nil),
            template: template
        )
        XCTAssertTrue(email.htmlBody?.contains("|") == true)
        XCTAssertFalse(email.htmlBody?.contains("{{") == true)
    }

    func test_repeatedPlaceholdersAllSubstitute() {
        let template = MailTemplate(
            headerHTML: "<p>{{app_name}} {{app_name}} {{app_name}}</p>",
            footerHTML: ""
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(),
            template: template
        )
        let count = email.htmlBody?.components(separatedBy: "MyApp").count ?? 0
        XCTAssertEqual(count - 1, 3)
    }

    func test_emailHasBothTextAndHTMLBodies() {
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body content"),
            context: makeContext(),
            template: MailTemplate(headerHTML: "<p>HEADER</p>", footerHTML: "<p>FOOTER</p>")
        )
        XCTAssertNotNil(email.htmlBody)
        XCTAssertTrue(email.textBody.contains("body content"))
        XCTAssertTrue(email.textBody.contains("HEADER"))
        XCTAssertTrue(email.textBody.contains("FOOTER"))
    }

    func test_subjectPropagatesToEmail() {
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "x", subject: "My Subject"),
            context: makeContext(),
            template: .empty
        )
        XCTAssertEqual(email.subject, "My Subject")
    }

    func test_senderUsesSenderNameAndUsername() {
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "x"),
            context: makeContext(),
            template: .empty
        )
        XCTAssertEqual(email.sender.address, "alice@gmail.com")
        XCTAssertEqual(email.sender.name, "Alice Example")
    }
}
```

- [ ] **Step 2: Run, confirm compile failure**

Use `zcode`. Expected: `MailComposer`, `DraftMessage`, `PlaceholderContext` undefined.

- [ ] **Step 3: Implement `MailComposer`**

Create `AppFeedback/Services/Mail/MailComposer.swift`:

```swift
import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(SwiftMail)
import SwiftMail
#endif

struct DraftMessage: Sendable {
    var recipient: String
    var subject: String
    var body: NSAttributedString
}

struct PlaceholderContext: Sendable {
    var sender: SMTPCredentials
    var recipient: String
    var appName: String
    var issueTitle: String?
    var issueURL: URL?
    var date: Date
}

#if canImport(SwiftMail)
struct MailComposer {

    func compose(draft: DraftMessage, context: PlaceholderContext, template: MailTemplate) -> SwiftMail.Email {
        let bodyHTML = htmlForBody(draft.body)
        let bodyText = draft.body.string

        let header = applyPlaceholders(template.headerHTML, context: context)
        let footer = applyPlaceholders(template.footerHTML, context: context)

        let cleanedHeader = HTMLSanitizer.sanitize(header)
        let cleanedFooter = HTMLSanitizer.sanitize(footer)
        let cleanedBody   = HTMLSanitizer.sanitize(bodyHTML)

        let combinedHTML = """
        <html><body>
        \(cleanedHeader)
        \(cleanedBody)
        \(cleanedFooter)
        </body></html>
        """

        let combinedText = [
            plainText(from: cleanedHeader),
            bodyText,
            plainText(from: cleanedFooter)
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")

        return SwiftMail.Email(
            sender: EmailAddress(name: context.sender.senderName,
                                 address: context.sender.username),
            recipients: [EmailAddress(name: nil, address: draft.recipient)],
            subject: draft.subject,
            textBody: combinedText,
            htmlBody: combinedHTML
        )
    }

    // MARK: - Placeholders

    private func applyPlaceholders(_ template: String, context: PlaceholderContext) -> String {
        let dateString = context.date.formatted(
            .dateTime.day().month(.wide).year().hour().minute()
        )
        var s = template
        s = s.replacingOccurrences(of: "{{recipient_email}}", with: context.recipient)
        s = s.replacingOccurrences(of: "{{sender_name}}",     with: context.sender.senderName)
        s = s.replacingOccurrences(of: "{{sender_email}}",    with: context.sender.username)
        s = s.replacingOccurrences(of: "{{date}}",            with: dateString)
        s = s.replacingOccurrences(of: "{{app_name}}",        with: context.appName)
        s = s.replacingOccurrences(of: "{{issue_title}}",     with: context.issueTitle ?? "")
        s = s.replacingOccurrences(of: "{{issue_url}}",       with: context.issueURL?.absoluteString ?? "")
        return s
    }

    // MARK: - Body conversion

    private func htmlForBody(_ attributed: NSAttributedString) -> String {
        #if os(macOS)
        let opts: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let data = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: opts),
              let html = String(data: data, encoding: .utf8) else {
            return "<p>\(escape(attributed.string))</p>"
        }
        // AppKit wraps the body in a full document; extract the body fragment.
        return extractBodyContent(from: html)
        #else
        return "<p>\(escape(attributed.string))</p>"
        #endif
    }

    private func extractBodyContent(from html: String) -> String {
        guard let bodyOpenRange = html.range(of: "<body", options: .caseInsensitive),
              let openCloseRange = html.range(of: ">", range: bodyOpenRange.upperBound..<html.endIndex),
              let bodyCloseRange = html.range(of: "</body>", options: .caseInsensitive,
                                              range: openCloseRange.upperBound..<html.endIndex) else {
            return html
        }
        return String(html[openCloseRange.upperBound..<bodyCloseRange.lowerBound])
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func plainText(from html: String) -> String {
        // Naive tag-strip + entity-decode is enough for the header/footer plain alternative.
        var s = html
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;",  with: "&")
        s = s.replacingOccurrences(of: "&lt;",   with: "<")
        s = s.replacingOccurrences(of: "&gt;",   with: ">")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
```

- [ ] **Step 4: Run all `MailComposerTests`**

Use `zcode`. Expected: all 6 tests pass on macOS. (On iOS, the file is excluded by `#if canImport(SwiftMail)`; tests run macOS-only.)

If iOS test target compilation breaks because the test file references types behind `#if canImport(SwiftMail)`, wrap the entire test class body in the same `#if canImport(SwiftMail)` guard.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Mail/MailComposer.swift AppFeedbackTests/MailComposerTests.swift
git commit -m "feat(mail): MailComposer with placeholder substitution and HTML/text bodies"
```

---

## Task 11: MailSender protocol + actor

**Files:**
- Create: `AppFeedback/Services/Mail/MailSender.swift`

- [ ] **Step 1: Implement the protocol and actor**

Create `AppFeedback/Services/Mail/MailSender.swift`:

```swift
import Foundation
#if canImport(SwiftMail)
import SwiftMail

protocol MailSending: Sendable {
    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials) async throws
    func testConnection(_ credentials: SMTPCredentials) async throws
}

actor MailSender: MailSending {

    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials) async throws {
        let server = SMTPServer(host: credentials.host, port: credentials.port)
        try await server.connect()
        defer { Task { try? await server.disconnect() } }
        try await server.login(username: credentials.username, password: credentials.password)
        try await server.sendEmail(email)
        try? await server.disconnect()
    }

    func testConnection(_ credentials: SMTPCredentials) async throws {
        let server = SMTPServer(host: credentials.host, port: credentials.port)
        try await server.connect()
        try await server.login(username: credentials.username, password: credentials.password)
        try? await server.disconnect()
    }
}
#endif
```

If SwiftMail's actual API differs from `SMTPServer(host:port:).connect()/login(username:password:)/sendEmail(_:)/disconnect()` — verify by checking `Sources/SwiftMail/SMTP/SMTPServer.swift` in the repo or in `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/checkouts/SwiftMail`. Adjust the call sites to match exactly. If the lib requires the username also be set explicitly on the server before `login`, adjust accordingly. Treat the lib's signature as ground truth.

- [ ] **Step 2: Build to verify compilation**

Use `zcode` to build `AppFeedback_macOS`. Expected: success. If symbols don't resolve, look at SwiftMail's `SMTPServer` source for the correct method names and update.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Mail/MailSender.swift
git commit -m "feat(mail): MailSender actor wrapping SwiftMail SMTPServer"
```

---

## Task 12: RichTextEditor (NSTextView wrapper, macOS only)

**Files:**
- Create: `AppFeedback/Views/Mail/RichTextEditor.swift`

- [ ] **Step 1: Implement the wrapper**

Create `AppFeedback/Views/Mail/RichTextEditor.swift`:

```swift
#if os(macOS)
import SwiftUI
import AppKit

struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var minHeight: CGFloat = 120

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textStorage?.setAttributedString(attributedText)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.attributedText = textView.attributedString()
        }
    }
}

/// Lightweight toolbar with Bold / Italic / Underline / Link buttons.
/// Renders above a `RichTextEditor`. Sends NSResponder actions which the
/// system routes to the focused text view.
struct RichTextToolbar: View {
    @Binding var linkSheetURL: String
    @State private var showLinkSheet = false

    var body: some View {
        HStack(spacing: 4) {
            toolbarButton(systemName: "bold")     { send(#selector(NSText.toggleBold(_:))) }
            toolbarButton(systemName: "italic")   { send(#selector(NSText.toggleItalic(_:))) }
            toolbarButton(systemName: "underline"){ send(#selector(NSText.toggleUnderline(_:))) }
            toolbarButton(systemName: "link") { showLinkSheet = true }
            Spacer()
        }
        .sheet(isPresented: $showLinkSheet) {
            LinkSheet(href: $linkSheetURL) { url in
                guard let url else { return }
                NSApp.sendAction(#selector(NSResponder.insertText(_:)),
                                 to: nil,
                                 from: NSAttributedString(
                                    string: url.absoluteString,
                                    attributes: [.link: url]
                                 ))
            }
        }
    }

    private func toolbarButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
    }

    private func send(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

private struct LinkSheet: View {
    @Binding var href: String
    let onSubmit: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Link").font(.headline)
            TextField("https://", text: $href)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Insert") {
                    onSubmit(URL(string: href))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: href) == nil)
            }
        }
        .padding()
    }
}
#endif
```

If `NSText.toggleBold(_:)` etc. require dispatching through `NSFontManager` / `NSTextView.changeAttributes(_:)` to actually toggle, adjust the toolbar implementation accordingly during smoke testing — the simplest correct approach for macOS rich text is to use `NSFontManager.shared.modifyFontTrait(...)` keyed off the focused text view; treat this section as a starting point and refine if buttons don't visibly toggle in the smoke test.

- [ ] **Step 2: Build to verify compilation**

Use `zcode` to build `AppFeedback_macOS`. Expected: success.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Mail/RichTextEditor.swift
git commit -m "feat(mail): RichTextEditor NSTextView wrapper with toolbar"
```

---

## Task 13: Email tab in Settings — credentials section

**Files:**
- Create: `AppFeedback/Views/Settings/EmailSettingsView.swift`
- Modify: `AppFeedback/Views/Settings/SettingsView.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Construct `MailSettings` at app startup**

In `AppFeedbackApp.swift`, alongside `activityLog`:

```swift
@State private var mailSettings = MailSettings()
@State private var mailSender: any MailSending = {
    #if canImport(SwiftMail)
    return MailSender()
    #else
    return NoopMailSender()  // not used on iOS
    #endif
}()
```

Inject both into the environment:

```swift
.environment(activityLog)
.environment(mailSettings)
```

`MailSender` is an `actor` — pass it as `any MailSending` via a normal `@Environment(\.mailSender)` custom key, OR through plain init injection on `EmailSettingsView` and `ComposeMailViewModel`. Use whichever pattern is already established in the codebase for service injection (check `RootView.swift`).

For iOS where SwiftMail isn't available, add a noop fallback in `AppFeedback/Services/Mail/MailSender.swift` after the existing `#endif`:

```swift
#if !canImport(SwiftMail)
struct NoopMailSender: MailSending {
    struct Disabled: Error {}
    func send(_ email: Any, using credentials: SMTPCredentials) async throws { throw Disabled() }
    func testConnection(_ credentials: SMTPCredentials) async throws { throw Disabled() }
}

protocol MailSending: Sendable {
    associatedtype EmailType
    func send(_ email: EmailType, using credentials: SMTPCredentials) async throws
    func testConnection(_ credentials: SMTPCredentials) async throws
}
#endif
```

If this protocol-with-associatedtype divergence becomes painful, the simpler resolution is: only declare `MailSending` and the noop on macOS, and never reference them on iOS at all. iOS UI code is `#if os(macOS)`-gated anyway, so the noop is unnecessary if you simply don't construct or inject `MailSender` on iOS. Prefer that simpler path.

- [ ] **Step 2: Refactor `SettingsView` into a `TabView`**

Replace the `body` of `SettingsView` so the existing content is moved inside a "Repos" tab and an "Email" tab is added:

```swift
var body: some View {
    TabView {
        reposTab
            .tabItem { Label("Repos", systemImage: "folder") }
        #if os(macOS)
        EmailSettingsView()
            .tabItem { Label("Email", systemImage: "envelope") }
        #endif
    }
    #if os(macOS)
    .frame(minWidth: 540, minHeight: 380)
    #endif
}

private var reposTab: some View {
    VStack(spacing: 0) {
        CloudSyncStatusRow(state: syncStatus.state)
        if store.repos.isEmpty {
            emptyState
        } else {
            repoList
        }
        addBar
    }
    .sheet(isPresented: $showAdd) {
        AddEditRepoView(store: store)
    }
    .sheet(item: $editTarget) { repo in
        AddEditRepoView(store: store, existing: repo)
    }
    .task(id: store.repos.map(\.id)) {
        await refreshTokens()
    }
}
```

- [ ] **Step 3: Create `EmailSettingsView` with credentials form**

Create `AppFeedback/Views/Settings/EmailSettingsView.swift`:

```swift
#if os(macOS)
import SwiftUI

struct EmailSettingsView: View {
    @Environment(MailSettings.self) private var settings

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var useSTARTTLS: Bool = true
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    @State private var saveStatus: String?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in applyPresetDefaults(new) }
            }

            Section("Credentials") {
                TextField("Host",          text: $host)
                    .disabled(preset != .custom)
                TextField("Port",          text: $port)
                    .disabled(preset != .custom)
                Toggle("Use STARTTLS",     isOn: $useSTARTTLS)
                    .disabled(preset != .custom)
                TextField("Username / from address", text: $username)
                SecureField("App password",          text: $password)
                TextField("Sender display name",     text: $senderName)
            }

            Section {
                HStack {
                    Button("Save") { save() }
                    Spacer()
                    if let saveStatus { Text(saveStatus).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadFromSettings() }
    }

    private func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
        let d = SMTPCredentials.defaults(for: p)
        host = d.host
        port = String(d.port)
        useSTARTTLS = d.useSTARTTLS
    }

    private func loadFromSettings() async {
        if let creds = settings.credentials {
            preset = creds.preset
            host = creds.host
            port = String(creds.port)
            useSTARTTLS = creds.useSTARTTLS
            username = creds.username
            senderName = creds.senderName
        } else {
            applyPresetDefaults(preset)
        }
        if let pw = await KeychainService.loadSMTPPassword() {
            password = pw
        }
    }

    private func save() {
        let creds = SMTPCredentials(
            preset: preset,
            host: host,
            port: Int(port) ?? 587,
            useSTARTTLS: useSTARTTLS,
            username: username,
            password: password,
            senderName: senderName
        )
        settings.credentials = creds
        Task {
            await KeychainService.saveSMTPPassword(password)
            saveStatus = "Saved"
        }
    }
}
#endif
```

- [ ] **Step 4: Build and smoke test**

Use `zcode` to build and run `AppFeedback_macOS`.

1. Open Settings (⌘,).
2. Switch to Email tab.
3. Pick Gmail preset → host/port pre-fill.
4. Enter username + app-password + display name. Click Save.
5. Quit and relaunch. Re-open Settings → Email tab. Confirm fields are populated (password loaded from Keychain).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Settings/EmailSettingsView.swift \
        AppFeedback/Views/Settings/SettingsView.swift \
        AppFeedback/App/AppFeedbackApp.swift \
        AppFeedback/Services/Mail/MailSender.swift
git commit -m "feat(settings): add Email tab with SMTP credentials form"
```

---

## Task 14: Header / footer rich editors + preview + Test Connection

**Files:**
- Modify: `AppFeedback/Views/Settings/EmailSettingsView.swift`

- [ ] **Step 1: Add header/footer state**

Inside `EmailSettingsView`, add:

```swift
@State private var headerAttributed = NSAttributedString(string: "")
@State private var footerAttributed = NSAttributedString(string: "")
@State private var testStatus: String?
```

(Put them with the other `@State` properties.)

- [ ] **Step 2: Add the editor sections**

Add to the `Form` body, after the Credentials section, before the Save section:

```swift
Section("Header") {
    RichTextToolbar(linkSheetURL: .constant(""))
    RichTextEditor(attributedText: $headerAttributed, minHeight: 120)
        .frame(minHeight: 120)
}

Section("Footer") {
    RichTextToolbar(linkSheetURL: .constant(""))
    RichTextEditor(attributedText: $footerAttributed, minHeight: 120)
        .frame(minHeight: 120)
}

Section("Tools") {
    HStack {
        Button("Test Connection") { testConnection() }
            .disabled(settings.credentials == nil)
        Button("Preview") { showPreview() }
        Spacer()
        if let testStatus { Text(testStatus).foregroundStyle(.secondary) }
    }
}
```

- [ ] **Step 3: Wire load and save of template**

In `loadFromSettings`, after the Keychain load, add:

```swift
let headerHTML = settings.template.headerHTML
let footerHTML = settings.template.footerHTML
if let data = headerHTML.data(using: .utf8),
   let attr = try? NSAttributedString(
       data: data,
       options: [.documentType: NSAttributedString.DocumentType.html],
       documentAttributes: nil) {
    headerAttributed = attr
}
if let data = footerHTML.data(using: .utf8),
   let attr = try? NSAttributedString(
       data: data,
       options: [.documentType: NSAttributedString.DocumentType.html],
       documentAttributes: nil) {
    footerAttributed = attr
}
```

In `save()`, before setting `settings.credentials`, also persist the template:

```swift
let headerHTML = htmlString(from: headerAttributed)
let footerHTML = htmlString(from: footerAttributed)
settings.template = MailTemplate(headerHTML: headerHTML, footerHTML: footerHTML)
```

And add the helper inside the struct:

```swift
private func htmlString(from attr: NSAttributedString) -> String {
    let opts: [NSAttributedString.DocumentAttributeKey: Any] = [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue
    ]
    guard let data = try? attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: opts),
          let s = String(data: data, encoding: .utf8) else { return "" }
    return s
}
```

- [ ] **Step 4: Implement Test Connection and Preview**

Inject `MailSender` and `ActivityLog` and add the actions:

```swift
@Environment(ActivityLog.self) private var activityLog

private func testConnection() {
    guard let creds = settings.credentials else { return }
    let id = activityLog.start(kind: .testConnection, title: "\(creds.host):\(creds.port)")
    Task {
        do {
            let sender = MailSender()
            try await sender.testConnection(creds)
            activityLog.finish(id, status: .success, detail: "Login OK")
            testStatus = "Connection OK"
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
            testStatus = "Failed: \(error.localizedDescription)"
        }
    }
}

private func showPreview() {
    let composer = MailComposer()
    let creds = settings.credentials ?? SMTPCredentials.defaults(for: .gmail)
    let context = PlaceholderContext(
        sender: creds,
        recipient: "preview@example.com",
        appName: "Preview App",
        issueTitle: "Sample issue",
        issueURL: URL(string: "https://github.com/example/repo/issues/1"),
        date: Date()
    )
    let template = MailTemplate(
        headerHTML: htmlString(from: headerAttributed),
        footerHTML: htmlString(from: footerAttributed)
    )
    let draft = DraftMessage(
        recipient: "preview@example.com",
        subject: "Preview",
        body: NSAttributedString(string: "[Body goes here]")
    )
    let email = composer.compose(draft: draft, context: context, template: template)
    if let html = email.htmlBody, let url = writePreviewHTML(html) {
        NSWorkspace.shared.open(url)
    }
}

private func writePreviewHTML(_ html: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppFeedback-Preview", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("preview-\(UUID().uuidString).html")
    do {
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}
```

- [ ] **Step 5: Build and smoke test**

Use `zcode` to build and run `AppFeedback_macOS`.

1. Settings → Email → enter creds → Save.
2. Click "Test Connection". Activity window logs a `.testConnection` entry transitioning to success or a clear failure message.
3. Type something in Header (e.g. `<p>Hi {{recipient_email}}</p>` after a paragraph break) and Footer.
4. Click Preview. Default browser opens the rendered HTML.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Views/Settings/EmailSettingsView.swift
git commit -m "feat(settings): header/footer editors, preview, test connection"
```

---

## Task 15: Tap email badge — route to compose

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`
- Modify: `AppFeedback/Views/Issues/IssueListView.swift`

- [ ] **Step 1: Add an `onTapEmail` callback on `IssueCardView`**

In `IssueCardView.swift`, add to the property list:

```swift
var onTapEmail: ((String, FeedbackIssue) -> Void)? = nil
```

Replace the existing email block (around line 73-80):

```swift
if let email = issue.email {
    if let onTapEmail {
        Button {
            onTapEmail(email, issue)
        } label: {
            MetaTagView(key: "✉", value: email, isActive: false)
        }
        .buttonStyle(.plain)
    } else if let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let mailURL = URL(string: "mailto:\(encoded)") {
        Link(destination: mailURL) {
            MetaTagView(key: "✉", value: email, isActive: false)
        }
    }
}
```

This preserves the iOS / no-handler fallback (`mailto:`) while letting the macOS list provide a handler that opens the in-app composer.

- [ ] **Step 2: Wire the callback from `IssueListView`**

In `IssueListView.swift`, add state for the compose sheet:

```swift
#if os(macOS)
@State private var composing: ComposeContext?

struct ComposeContext: Identifiable {
    let id = UUID()
    let recipient: String
    let issue: FeedbackIssue
}
#endif
```

In the `IssueCardView(...)` invocation (around line 91-110), append:

```swift
#if os(macOS)
,
onTapEmail: { email, issue in
    composing = ComposeContext(recipient: email, issue: issue)
}
#endif
```

After the `ScrollView { ... }` block, attach a sheet:

```swift
#if os(macOS)
.sheet(item: $composing) { ctx in
    ComposeMailView(recipient: ctx.recipient, issue: ctx.issue)
}
#endif
```

- [ ] **Step 3: Build to verify compilation (will fail until Task 16)**

Use `zcode` to build `AppFeedback_macOS`. Expected: build fails because `ComposeMailView` doesn't exist yet. That's fine — the next task creates it.

- [ ] **Step 4: Skip commit until Task 16 completes**

(Task 15 and Task 16 commit together since the code in 15 doesn't compile without 16.)

---

## Task 16: ComposeMailView + ComposeMailViewModel (with VM tests)

**Files:**
- Create: `AppFeedback/ViewModels/ComposeMailViewModel.swift`
- Create: `AppFeedback/Views/Mail/ComposeMailView.swift`
- Test: `AppFeedbackTests/ComposeMailViewModelTests.swift`

- [ ] **Step 1: Write the failing VM tests**

Create `AppFeedbackTests/ComposeMailViewModelTests.swift`:

```swift
import XCTest
@testable import AppFeedback

#if canImport(SwiftMail)
import SwiftMail

@MainActor
final class ComposeMailViewModelTests: XCTestCase {

    actor FakeSender: MailSending {
        var sent: [(SwiftMail.Email, SMTPCredentials)] = []
        var shouldThrow: Error?

        func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials) async throws {
            if let shouldThrow { throw shouldThrow }
            sent.append((email, credentials))
        }
        func testConnection(_ credentials: SMTPCredentials) async throws {}
        func setShouldThrow(_ error: Error?) { shouldThrow = error }
        func snapshot() -> [(SwiftMail.Email, SMTPCredentials)] { sent }
    }

    private func makeSettings() -> MailSettings {
        let s = MailSettings(defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!)
        s.credentials = SMTPCredentials(
            preset: .gmail, host: "smtp.gmail.com", port: 587, useSTARTTLS: true,
            username: "alice@gmail.com", password: "secret", senderName: "Alice"
        )
        s.template = .empty
        return s
    }

    private func makeIssue() -> FeedbackIssue {
        FeedbackIssue(
            number: 7, title: "Crash", createdAt: Date(),
            rawBody: "", appName: "MyApp", appVersion: "1.0",
            device: "Mac", osVersion: "14.0", email: "bob@example.com",
            description: "Crash on launch"
        )
    }

    func test_send_callsSenderAndLogsSuccess() async throws {
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: makeSettings(),
            sender: sender,
            activityLog: log
        )
        vm.subject = "Hello"
        vm.body = NSAttributedString(string: "Hi Bob")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.recipients.first?.address, "bob@example.com")
        XCTAssertEqual(sent[0].0.subject, "Hello")
        XCTAssertEqual(log.entries.first?.status, .success)
    }

    func test_send_failureLogsFailureWithDetail() async throws {
        let sender = FakeSender()
        await sender.setShouldThrow(NSError(domain: "Test", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "boom"]))
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: makeSettings(),
            sender: sender,
            activityLog: log
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        XCTAssertEqual(log.entries.first?.status, .failure)
        XCTAssertEqual(log.entries.first?.detail, "boom")
    }

    func test_send_withoutCredentials_doesNothing() async throws {
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let settings = MailSettings(defaults: UserDefaults(suiteName: "no-creds-\(UUID().uuidString)")!)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: settings,
            sender: sender,
            activityLog: log
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }
}
#endif
```

- [ ] **Step 2: Run, confirm compile failure**

Use `zcode`. Expected: `ComposeMailViewModel` undefined.

- [ ] **Step 3: Implement the view model**

Create `AppFeedback/ViewModels/ComposeMailViewModel.swift`:

```swift
import Foundation
import Observation
#if canImport(SwiftMail)
import SwiftMail

@MainActor
@Observable
final class ComposeMailViewModel {
    var subject: String = ""
    var body: NSAttributedString = NSAttributedString(string: "")

    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String

    private let settings: MailSettings
    private let sender: any MailSending
    private let activityLog: ActivityLog
    private let composer = MailComposer()

    init(recipient: String,
         issue: FeedbackIssue,
         repoOwner: String,
         repoName: String,
         settings: MailSettings,
         sender: any MailSending,
         activityLog: ActivityLog) {
        self.recipient = recipient
        self.issue = issue
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.settings = settings
        self.sender = sender
        self.activityLog = activityLog
    }

    var canSend: Bool {
        settings.credentials != nil
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.length > 0
    }

    func send() async {
        guard let credentials = settings.credentials else { return }
        let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")

        let issueURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/issues/\(issue.number)")
        let context = PlaceholderContext(
            sender: credentials,
            recipient: recipient,
            appName: issue.appName ?? repoName,
            issueTitle: issue.title,
            issueURL: issueURL,
            date: Date()
        )
        let draft = DraftMessage(recipient: recipient, subject: subject, body: body)
        let email = composer.compose(draft: draft, context: context, template: settings.template)

        do {
            try await sender.send(email, using: credentials)
            activityLog.finish(id, status: .success, detail: nil)
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
        }
    }
}
#endif
```

- [ ] **Step 4: Implement the view**

Create `AppFeedback/Views/Mail/ComposeMailView.swift`:

```swift
#if os(macOS) && canImport(SwiftMail)
import SwiftUI

struct ComposeMailView: View {
    let recipient: String
    let issue: FeedbackIssue

    @Environment(MailSettings.self) private var settings
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ComposeMailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                composeForm(vm: vm)
            } else {
                ProgressView().task { setupViewModel() }
            }
        }
        .frame(minWidth: 540, minHeight: 460)
    }

    @ViewBuilder
    private func composeForm(vm: ComposeMailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.credentials == nil {
                missingCredentialsBanner
            }
            recipientRow
            Divider()
            subjectRow(vm: vm)
            Divider()
            RichTextToolbar(linkSheetURL: .constant(""))
            RichTextEditor(attributedText: bindingFor(vm), minHeight: 240)
                .frame(minHeight: 240)
            Divider()
            footerButtons(vm: vm)
        }
    }

    private var missingCredentialsBanner: some View {
        HStack {
            Image(systemName: "envelope.badge")
            Text("Configure email in Settings → Email to send from this app.")
            Spacer()
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
    }

    private var recipientRow: some View {
        HStack {
            Text("To:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(recipient).fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func subjectRow(vm: ComposeMailViewModel) -> some View {
        HStack {
            Text("Subject:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", text: Binding(
                get: { vm.subject },
                set: { vm.subject = $0 }
            ))
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func footerButtons(vm: ComposeMailViewModel) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Send") {
                Task {
                    await vm.send()
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!vm.canSend)
        }
        .padding(12)
    }

    private func bindingFor(_ vm: ComposeMailViewModel) -> Binding<NSAttributedString> {
        Binding(get: { vm.body }, set: { vm.body = $0 })
    }

    private func setupViewModel() {
        // Repo owner/name come from the active selection. Pass them via init upstream
        // if available — here we fall back to deriving from the issue's appName as a placeholder.
        let owner = (issue.appName ?? "").lowercased()
        let repo = owner
        viewModel = ComposeMailViewModel(
            recipient: recipient,
            issue: issue,
            repoOwner: owner,
            repoName: repo,
            settings: settings,
            sender: MailSender(),
            activityLog: activityLog
        )
    }
}
#endif
```

The `setupViewModel` placeholder for owner/repo is wrong if `issue.appName` doesn't equal the repo identifier. The cleanest fix is to plumb the active `RepoConfig` through the call site: in `IssueListView.sheet`, pass the active repo's `owner` and `repo` strings into `ComposeMailView` as additional parameters. Update `ComposeMailView` to accept `repoOwner: String, repoName: String` and use those instead of deriving from `appName`. This is the only correct path — fix it before testing.

- [ ] **Step 5: Run tests, then build**

Use `zcode` to run `AppFeedbackTests_macOS`. Expected: all 3 VM tests pass.

Then build `AppFeedback_macOS`. Expected: success.

- [ ] **Step 6: Commit (covers Tasks 15 + 16)**

```bash
git add AppFeedback/ViewModels/ComposeMailViewModel.swift \
        AppFeedback/Views/Mail/ComposeMailView.swift \
        AppFeedback/Views/Issues/IssueCardView.swift \
        AppFeedback/Views/Issues/IssueListView.swift \
        AppFeedbackTests/ComposeMailViewModelTests.swift
git commit -m "feat(mail): compose-and-send sheet from issue email badge"
```

---

## Task 17: End-to-end smoke test + polish

**Files:** none new

- [ ] **Step 1: Run the full test suite**

Use `zcode` to run `AppFeedbackTests_macOS` and `AppFeedbackTests_iOS`. Expected: all tests pass on macOS; iOS suite skips macOS-only tests cleanly.

- [ ] **Step 2: Manual smoke test of the full flow**

1. Launch the app fresh.
2. Settings → Email → Gmail → enter credentials → Save → Test Connection succeeds (Activity window shows green entry).
3. Header: type a heading line; Footer: type "Sent via AppFeedback for {{app_name}}".
4. Save. Re-open Settings → Email — fields and editor contents persist.
5. Open an issue list, find an issue with an email badge. Click the badge.
6. Compose sheet opens with recipient pre-filled. Type a subject and a body (try bolding a word with ⌘B).
7. Click Send. Sheet dismisses immediately.
8. Window → Activity. Confirm a `sendEmail` entry transitioned from in-progress to success (or failure with a clear detail string).
9. Check the recipient inbox. Verify both the HTML version (with formatting) and a sane plain-text alternative arrived; verify placeholders in the footer were substituted (e.g. "Sent via AppFeedback for MyApp").
10. Click "Clear All" in the Activity window. Confirm entries clear and the empty state persists across relaunch.

- [ ] **Step 3: Address any issues found in smoke test**

If anything's broken, fix in place; commit each fix as a small follow-up.

- [ ] **Step 4: Final commit if any changes**

```bash
git add -A
git commit -m "fix(mail): polish from end-to-end smoke test"
```

(Skip if no changes needed.)

---

## Out of Scope (do not implement)

- Scheduled sends.
- OAuth (XOAUTH2).
- Attachments.
- Outbox with retries.
- Persistent compose drafts.
- IMAP / mail reading.

These are listed in the spec's "Future Work" section. The architecture chosen here leaves room for each.

---

## Self-Review

**Spec coverage:**
- ✅ User-owned SMTP creds, presets + custom: Tasks 8, 13.
- ✅ App-passwords: Task 13 (SecureField).
- ✅ HTML header/footer with placeholders: Tasks 10, 14.
- ✅ Rich-text compose body (NSTextView): Tasks 12, 16.
- ✅ Activity window with persistence + Clear All: Tasks 2, 3, 6.
- ✅ Compose sheet dismisses immediately, status in Activity: Task 16.
- ✅ Test Connection button: Task 14.
- ✅ Tap email badge entry point: Tasks 15, 16.
- ✅ SwiftMail dependency: Task 1.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" left. The `setupViewModel` placeholder in Task 16 is explicitly flagged with the correct fix (plumb repo owner/name through), not deferred.

**Type consistency:** `ActivityLog.start(kind:title:) -> UUID` and `finish(_ id: UUID, status:, detail:)` are consistent across Tasks 2, 5, 6, 14, 16. `MailSending.send(_:using:)` and `testConnection(_:)` are consistent across Tasks 11, 14, 16. `MailComposer.compose(draft:context:template:)` is consistent across Tasks 10, 14, 16. `SMTPCredentials` field names are stable.
