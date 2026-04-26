# iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync repos, hidden apps, and per-repo OAuth tokens across the user's Macs, iPads, and iPhones via iCloud.

**Architecture:** SwiftData with CloudKit private-database mirroring stores the structured data (`Repo` entity, with hidden app names as a property). `RepoStore` is kept as a thin `@Observable` facade — its public API is unchanged, but its internals swap from `UserDefaults` to a `ModelContext`. Views require **no changes**. `KeychainService` queries gain `kSecAttrSynchronizable` so OAuth tokens propagate via iCloud Keychain. A new `CloudSyncStatus` service watches `CKContainer.accountStatus()` and surfaces a non-blocking row at the top of `SettingsView`.

**Deviation from spec:** The spec proposed retiring `RepoStore` in favor of `@Query` in views + a `RepoMutator` helper. We instead keep `RepoStore` as a SwiftData-backed facade. Same end-state (CloudKit-synced data, identical UX); much smaller blast radius (no view rewrites). If we later want `@Query` semantics in views, that is a separate, additive refactor.

**Tech Stack:** SwiftData, CloudKit, iCloud Keychain, SwiftUI (iOS 17 / macOS 14), XCTest, xcodegen (`project.yml`).

---

## File Structure

**Create:**
- `AppFeedback/Models/Repo.swift` — SwiftData `@Model` for repos.
- `AppFeedback/Services/CloudSyncStatus.swift` — `@Observable` service exposing iCloud account status.
- `AppFeedback/Views/Settings/CloudSyncStatusRow.swift` — small SwiftUI view for the Settings header.
- `AppFeedbackTests/RepoTests.swift` — tests for the `@Model`.
- `AppFeedbackTests/CloudSyncStatusTests.swift` — tests for the status service (using a stub provider).

**Modify:**
- `AppFeedback/AppFeedback.entitlements` — add CloudKit container + services.
- `project.yml` — declare CloudKit capability so xcodegen wires it.
- `AppFeedback/App/AppFeedbackApp.swift` — build `ModelContainer`, inject into `RepoStore` and the SwiftUI environment.
- `AppFeedback/Services/RepoStore.swift` — rewrite internals to use `ModelContext`; preserve public API.
- `AppFeedback/Services/KeychainService.swift` — set `kSecAttrSynchronizable = true` on every query.
- `AppFeedback/Views/Settings/SettingsView.swift` — add `CloudSyncStatusRow` at top.
- `AppFeedbackTests/RepoStoreTests.swift` — switch from `UserDefaults` suite to in-memory `ModelContainer`.

**Delete:** none (the existing `RepoStore` is rewritten in-place).

---

## Task 1 — iCloud entitlements & xcodegen wiring

**Files:**
- Modify: `AppFeedback/AppFeedback.entitlements`
- Modify: `project.yml`

Container identifier: `iCloud.com.amirhayek.AppFeedback`. **Note:** this container must be created in Apple Developer portal before signing succeeds on a real device. Simulator and "Sign to Run Locally" builds work without it.

- [ ] **Step 1: Edit entitlements**

Replace `AppFeedback/AppFeedback.entitlements` contents with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.amirhayek.AppFeedback</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.amirhayek.AppFeedback</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Regenerate Xcode project**

The project uses xcodegen. After editing entitlements, run:

```bash
cd /Users/hayek/Developer/AppFeedback && xcodegen generate
```

Expected: `Created project at AppFeedback.xcodeproj`. (`project.yml` already references the entitlements file via `CODE_SIGN_ENTITLEMENTS: AppFeedback/AppFeedback.entitlements` — no change needed there.)

- [ ] **Step 3: Build to confirm entitlements parse**

Use the zcode skill to run a build for the macOS scheme. Expected: build succeeds (signing may warn about missing container in Developer portal — that is fine for this step).

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/AppFeedback.entitlements AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat: add iCloud + CloudKit entitlements for AppFeedback container"
```

---

## Task 2 — `Repo` SwiftData model

**Files:**
- Create: `AppFeedback/Models/Repo.swift`
- Test: `AppFeedbackTests/RepoTests.swift`

CloudKit constraints: every property must be optional or have a default; no unique constraints; no `@Attribute(.unique)`.

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/RepoTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class RepoTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Repo.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    func test_initWithValues() {
        let r = Repo(displayName: "App", owner: "acme", repo: "feedback")
        XCTAssertEqual(r.displayName, "App")
        XCTAssertEqual(r.owner, "acme")
        XCTAssertEqual(r.repo, "feedback")
        XCTAssertTrue(r.hiddenAppNames.isEmpty)
        XCTAssertNotNil(r.id)
    }

    func test_insertAndFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Repo(displayName: "X", owner: "o", repo: "r"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Repo>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.displayName, "X")
    }

    func test_hiddenAppNamesPersists() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repo = Repo(displayName: "X", owner: "o", repo: "r")
        context.insert(repo)
        repo.hiddenAppNames = ["AppA", "AppB"]
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Repo>())
        XCTAssertEqual(fetched.first?.hiddenAppNames.sorted(), ["AppA", "AppB"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Use the zcode skill to run `RepoTests`. Expected: compilation failure (no `Repo` type).

- [ ] **Step 3: Implement the model**

Create `AppFeedback/Models/Repo.swift`:

```swift
import Foundation
import SwiftData

@Model
final class Repo {
    var id: UUID = UUID()
    var displayName: String = ""
    var owner: String = ""
    var repo: String = ""
    var hiddenAppNames: [String] = []
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        displayName: String,
        owner: String,
        repo: String,
        hiddenAppNames: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.hiddenAppNames = hiddenAppNames
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Use the zcode skill to run `RepoTests`. Expected: all three pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/Repo.swift AppFeedbackTests/RepoTests.swift
git commit -m "feat: add Repo SwiftData model with CloudKit-compatible defaults"
```

---

## Task 3 — Make `KeychainService` iCloud-synchronizable

**Files:**
- Modify: `AppFeedback/Services/KeychainService.swift`

Setting `kSecAttrSynchronizable = kCFBooleanTrue` on add/load/delete makes the items propagate via iCloud Keychain. The attribute must also be set on lookup queries — items added with `synchronizable=true` are not returned by queries that omit it.

- [ ] **Step 1: Replace the file**

Overwrite `AppFeedback/Services/KeychainService.swift` with:

```swift
import Foundation
import Security

enum KeychainService {
    private static let service = "com.feedbackviewer.tokens"

    static func save(token: String, for repo: RepoConfig) {
        let account = accountKey(for: repo)
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
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

    static func load(for repo: RepoConfig) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      accountKey(for: repo),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for repo: RepoConfig) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      accountKey(for: repo),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func accountKey(for repo: RepoConfig) -> String {
        "\(repo.owner)/\(repo.repo)"
    }
}
```

- [ ] **Step 2: Build and run existing tests**

Use the zcode skill to run the full test suite. Expected: all existing tests still pass (KeychainService is not directly unit-tested; this is a smoke check).

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/KeychainService.swift
git commit -m "feat: enable iCloud Keychain sync for OAuth tokens"
```

---

## Task 4 — `CloudSyncStatus` service

**Files:**
- Create: `AppFeedback/Services/CloudSyncStatus.swift`
- Test: `AppFeedbackTests/CloudSyncStatusTests.swift`

Public API:

```swift
enum SyncState: Equatable {
    case unknown
    case syncing
    case unavailable(reason: UnavailableReason)
    case error(message: String)
}

enum UnavailableReason: Equatable {
    case notSignedIn, restricted, temporarilyUnavailable
}

@MainActor
protocol CloudSyncStatusProviding: AnyObject {
    var state: SyncState { get }
}
```

The concrete `CloudSyncStatus` queries `CKContainer.default().accountStatus(...)` and observes `CKAccountChanged`. The protocol exists so views can preview/test against a stub.

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/CloudSyncStatusTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class CloudSyncStatusTests: XCTestCase {
    func test_stub_reportsConfiguredState() {
        let stub = StubCloudSyncStatus(state: .syncing)
        XCTAssertEqual(stub.state, .syncing)
    }

    func test_unavailableReasonsAreEquatable() {
        XCTAssertEqual(
            SyncState.unavailable(reason: .notSignedIn),
            SyncState.unavailable(reason: .notSignedIn)
        )
        XCTAssertNotEqual(
            SyncState.unavailable(reason: .notSignedIn),
            SyncState.unavailable(reason: .restricted)
        )
    }
}

@MainActor
final class StubCloudSyncStatus: CloudSyncStatusProviding {
    var state: SyncState
    init(state: SyncState) { self.state = state }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Use the zcode skill to run `CloudSyncStatusTests`. Expected: compilation failure (no `SyncState`/`CloudSyncStatusProviding`).

- [ ] **Step 3: Implement the service**

Create `AppFeedback/Services/CloudSyncStatus.swift`:

```swift
import Foundation
import CloudKit
import Observation

enum SyncState: Equatable {
    case unknown
    case syncing
    case unavailable(reason: UnavailableReason)
    case error(message: String)
}

enum UnavailableReason: Equatable {
    case notSignedIn
    case restricted
    case temporarilyUnavailable
}

@MainActor
protocol CloudSyncStatusProviding: AnyObject {
    var state: SyncState { get }
}

@Observable @MainActor
final class CloudSyncStatus: CloudSyncStatusProviding {
    private(set) var state: SyncState = .unknown

    private let container: CKContainer
    private var observer: NSObjectProtocol?

    init(container: CKContainer = .default()) {
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() async {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:           state = .syncing
            case .noAccount:           state = .unavailable(reason: .notSignedIn)
            case .restricted:          state = .unavailable(reason: .restricted)
            case .couldNotDetermine:   state = .unavailable(reason: .temporarilyUnavailable)
            case .temporarilyUnavailable: state = .unavailable(reason: .temporarilyUnavailable)
            @unknown default:          state = .unavailable(reason: .temporarilyUnavailable)
            }
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Use the zcode skill to run `CloudSyncStatusTests`. Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/CloudSyncStatus.swift AppFeedbackTests/CloudSyncStatusTests.swift
git commit -m "feat: add CloudSyncStatus service backed by CKContainer.accountStatus"
```

---

## Task 5 — Rewrite `RepoStore` on top of SwiftData

**Files:**
- Modify: `AppFeedback/Services/RepoStore.swift`
- Modify: `AppFeedbackTests/RepoStoreTests.swift`

Public API (`repos: [RepoConfig]`, `hiddenApps`, `add/update/remove/hideApp/unhideAllApps/hiddenAppsFor`) is preserved so views, view models, and the `RootView`/`SidebarView` need no changes. Internally, `RepoStore` holds a `ModelContext` and republishes changes when the context saves (locally or via CloudKit pull).

- [ ] **Step 1: Replace the test file**

Overwrite `AppFeedbackTests/RepoStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class RepoStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Repo.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        store = RepoStore(context: ModelContext(container))
    }

    override func tearDown() async throws {
        store = nil
        container = nil
        try await super.tearDown()
    }

    func test_initiallyEmpty() {
        XCTAssertTrue(store.repos.isEmpty)
    }

    func test_add_appendsRepo() {
        let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
        store.add(repo)
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.owner, "org")
    }

    func test_remove_deletesRepo() {
        let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
        store.add(repo)
        store.remove(id: repo.id)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func test_update_replacesRepo() {
        var repo = RepoConfig(displayName: "Old", owner: "org", repo: "feedback")
        store.add(repo)
        repo.displayName = "New"
        store.update(repo)
        XCTAssertEqual(store.repos.first?.displayName, "New")
    }

    func test_hideApp_recordsName() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.hideApp("AppA", in: repo.id)
        XCTAssertEqual(store.hiddenAppsFor(repo.id), ["AppA"])
    }

    func test_unhideAllApps_clearsNames() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.hideApp("AppA", in: repo.id)
        store.hideApp("AppB", in: repo.id)
        store.unhideAllApps(in: repo.id)
        XCTAssertTrue(store.hiddenAppsFor(repo.id).isEmpty)
    }

    func test_persistsAcrossInstances() {
        let repo = RepoConfig(displayName: "Persisted", owner: "x", repo: "y")
        store.add(repo)

        let store2 = RepoStore(context: ModelContext(container))
        XCTAssertEqual(store2.repos.first?.displayName, "Persisted")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Use the zcode skill to run `RepoStoreTests`. Expected: compilation failure (`RepoStore` initializer signature changed).

- [ ] **Step 3: Replace `RepoStore.swift`**

Overwrite `AppFeedback/Services/RepoStore.swift`:

```swift
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class RepoStore {
    private(set) var repos: [RepoConfig] = []
    private(set) var hiddenApps: [UUID: Set<String>] = [:]

    private let context: ModelContext
    private var didSaveObserver: NSObjectProtocol?

    init(context: ModelContext) {
        self.context = context
        reload()
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let didSaveObserver {
            NotificationCenter.default.removeObserver(didSaveObserver)
        }
    }

    // MARK: - Repos

    func add(_ repo: RepoConfig) {
        let model = Repo(
            id: repo.id,
            displayName: repo.displayName,
            owner: repo.owner,
            repo: repo.repo
        )
        context.insert(model)
        save()
        reload()
    }

    func update(_ repo: RepoConfig) {
        guard let model = fetchModel(id: repo.id) else { return }
        model.displayName = repo.displayName
        model.owner = repo.owner
        model.repo = repo.repo
        save()
        reload()
    }

    func remove(id: UUID) {
        guard let model = fetchModel(id: id) else { return }
        context.delete(model)
        save()
        reload()
    }

    // MARK: - Hidden apps

    func hideApp(_ appName: String, in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        var names = Set(model.hiddenAppNames)
        names.insert(appName)
        model.hiddenAppNames = Array(names)
        save()
        reload()
    }

    func unhideAllApps(in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        model.hiddenAppNames = []
        save()
        reload()
    }

    func hiddenAppsFor(_ repoId: UUID) -> Set<String> {
        hiddenApps[repoId] ?? []
    }

    // MARK: - Internal

    private func fetchModel(id: UUID) -> Repo? {
        let descriptor = FetchDescriptor<Repo>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        try? context.save()
    }

    private func reload() {
        let models = (try? context.fetch(FetchDescriptor<Repo>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
        repos = models.map {
            RepoConfig(id: $0.id, displayName: $0.displayName, owner: $0.owner, repo: $0.repo)
        }
        hiddenApps = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, Set($0.hiddenAppNames)) }
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Use the zcode skill to run `RepoStoreTests`. Expected: all seven pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/RepoStore.swift AppFeedbackTests/RepoStoreTests.swift
git commit -m "feat: back RepoStore with SwiftData ModelContext"
```

---

## Task 6 — Wire `ModelContainer` and `CloudSyncStatus` into the app

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

`RepoStore` now needs a `ModelContext` at construction. `CloudSyncStatus` is created once and injected into the SwiftUI environment so `SettingsView` can read it.

- [ ] **Step 1: Replace `AppFeedbackApp.swift`**

```swift
import SwiftUI
import SwiftData

@main
struct AppFeedbackApp: App {
    private let container: ModelContainer
    @State private var store: RepoStore
    @State private var syncStatus = CloudSyncStatus()

    init() {
        do {
            let schema = Schema([Repo.self])
            let config = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
            )
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            assertionFailure("Failed to create ModelContainer: \(error)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        _store = State(initialValue: RepoStore(context: ModelContext(container)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(syncStatus)
        }
        .modelContainer(container)
        #if os(macOS)
        Settings {
            SettingsView(store: store)
                .environment(syncStatus)
        }
        #endif
    }
}
```

- [ ] **Step 2: Build the app**

Use the zcode skill to build the macOS scheme. Expected: build succeeds. (Running may fail on a real device without the iCloud container provisioned — that is fine; the simulator works.)

- [ ] **Step 3: Run the full test suite**

Use the zcode skill to run all tests. Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat: wire ModelContainer with CloudKit private DB into app entry"
```

---

## Task 7 — Surface sync status in `SettingsView`

**Files:**
- Create: `AppFeedback/Views/Settings/CloudSyncStatusRow.swift`
- Modify: `AppFeedback/Views/Settings/SettingsView.swift`

The row sits at the top of `SettingsView`. It is read from the SwiftUI environment so previews and tests can inject a stub.

- [ ] **Step 1: Create `CloudSyncStatusRow.swift`**

```swift
import SwiftUI

struct CloudSyncStatusRow: View {
    let state: SyncState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsOpenSettingsButton {
                Button("Open Settings", action: openSystemSettings)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
    }

    private var iconName: String {
        switch state {
        case .unknown:           return "icloud"
        case .syncing:           return "checkmark.icloud"
        case .unavailable:       return "icloud.slash"
        case .error:             return "exclamationmark.icloud"
        }
    }

    private var tint: Color {
        switch state {
        case .unknown:     return .secondary
        case .syncing:     return .green
        case .unavailable: return .orange
        case .error:       return .red
        }
    }

    private var title: String {
        switch state {
        case .unknown:           return "Checking iCloud…"
        case .syncing:           return "Syncing via iCloud"
        case .unavailable:       return "iCloud unavailable"
        case .error:             return "iCloud error"
        }
    }

    private var detail: String? {
        switch state {
        case .unavailable(let reason):
            switch reason {
            case .notSignedIn:           return "Sign in to sync across devices."
            case .restricted:            return "iCloud is restricted on this device."
            case .temporarilyUnavailable: return "Try again in a moment."
            }
        case .error(let message):        return message
        default:                         return nil
        }
    }

    private var showsOpenSettingsButton: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
```

- [ ] **Step 2: Modify `SettingsView.swift`**

In `AppFeedback/Views/Settings/SettingsView.swift`, add an environment property and place the row above the existing content. Replace the current `body` with:

```swift
@Environment(CloudSyncStatus.self) private var syncStatus

var body: some View {
    VStack(spacing: 0) {
        CloudSyncStatusRow(state: syncStatus.state)
        if store.repos.isEmpty {
            emptyState
        } else {
            repoList
        }
        addBar
    }
    #if os(macOS)
    .frame(minWidth: 500, minHeight: 340)
    #endif
    .sheet(isPresented: $showAdd) {
        AddEditRepoView(store: store)
    }
    .sheet(item: $editTarget) { repo in
        AddEditRepoView(store: store, existing: repo)
    }
}
```

(Leave `repoList`, `emptyState`, `addBar`, `maskedToken`, and `RepoRowView` unchanged.)

- [ ] **Step 3: Build the app**

Use the zcode skill to build the macOS scheme. Expected: build succeeds. (Note: `AppFeedbackApp` already injects `syncStatus` into the macOS Settings scene and the WindowGroup root; the iOS sheet path inherits the environment from `RootView`.)

- [ ] **Step 4: Run the full test suite**

Use the zcode skill. Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Settings/CloudSyncStatusRow.swift AppFeedback/Views/Settings/SettingsView.swift
git commit -m "feat: show iCloud sync status row at top of SettingsView"
```

---

## Task 8 — Final verification

**Files:** none

- [ ] **Step 1: Build both schemes**

Use the zcode skill to build both `AppFeedback_macOS` and `AppFeedback_iOS`. Expected: both succeed.

- [ ] **Step 2: Run the full test suite on both schemes**

Use the zcode skill to run all tests on both platforms. Expected: all pass.

- [ ] **Step 3: Manual smoke checklist (report to user, do not block)**

Document for the user to verify on real devices when ready:
- Add a repo on Mac → appears on iPad after a few seconds.
- Hide an app on iPad → reflected on Mac.
- Sign out of iCloud on a device → status row turns orange and shows "iCloud unavailable"; app still usable.
- Sign back in → status returns to "Syncing via iCloud"; data resyncs.

- [ ] **Step 4: No commit needed for this task**

---

## Self-Review Notes

- **Spec coverage:** entitlements (Task 1), `Repo` model (Task 2), Keychain sync (Task 3), `CloudSyncStatus` service (Task 4), `RepoStore` SwiftData backing (Task 5), container wiring (Task 6), Settings status row (Task 7), verification (Task 8). All spec requirements covered.
- **Deviation flagged:** the spec said retire `RepoStore`; the plan keeps it as a SwiftData-backed facade (smaller diff, no view rewrites). Same end-state.
- **No placeholders:** every step has the full code or the exact command.
- **Type consistency:** `SyncState` cases (`unknown`, `syncing`, `unavailable(reason:)`, `error(message:)`) are used identically in `CloudSyncStatus`, the tests, and `CloudSyncStatusRow`. `RepoStore` initializer is `(context: ModelContext)` everywhere.
- **Open risk** (carried from spec): the iCloud container `iCloud.com.amirhayek.AppFeedback` must be created in Apple Developer portal before signing for a real device works. Simulator and "Sign to Run Locally" builds are unaffected.
