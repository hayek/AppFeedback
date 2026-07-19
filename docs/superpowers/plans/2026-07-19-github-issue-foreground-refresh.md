# GitHub Issue Foreground Auto-Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub issues auto-refresh every 15 minutes while the app is open, via a new app-level `IssueLoaderRegistry` that replaces `MacBackgroundRefreshDriver` and absorbs `RootView`'s loader plumbing.

**Architecture:** A new `@Observable @MainActor` `IssueLoaderRegistry` (pattern: `MailSyncCoordinatorRegistry` / `AppStoreReviewCoordinatorRegistry`) owns the `[UUID: IssueLoader]` dictionary, the 15-minute poll loop, a daily full-reconcile sweep, and the notification-differ feed. `RootView` delegates all loader access to it. `MacBackgroundRefreshDriver` is deleted; `iOSBackgroundRefreshDriver` keeps only `BGTaskScheduler` glue and delegates to the registry.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData, XCTest, XcodeGen-generated Xcode project.

**Spec:** `docs/superpowers/specs/2026-07-19-github-issue-foreground-refresh-design.md`

## Global Constraints

- Project is XcodeGen-generated: after creating any new `.swift` file, run `xcodegen generate` and commit the regenerated `AppFeedback.xcodeproj/project.pbxproj` with it. Before running xcodegen, check `git status` for uncommitted `.xcscheme` hand-edits (xcodegen silently discards them) and for untracked WIP files (xcodegen bakes them into the pbxproj — flag if it happens).
- Ground-truth build/test is `xcodebuild`, NOT the zcode `/api/test` summary. Schemes: `AppFeedback_macOS`, `AppFeedback_iOS`. Test target is `AppFeedbackTests_macOS` (not `AppFeedbackTests`). Run a class with:
  `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/<TestClass>`
  iOS compile check: `xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator'`
- SourceKit per-file diagnostics on edited files ("Cannot find type X in scope", "No such module XCTest") are indexer noise — trust xcodebuild only.
- ~11 pre-existing failures in `KeychainServicePerAccountTests` + `GitHubAccountStoreTests` (no Keychain in test runner) are NOT regressions.
- The working tree has the user's uncommitted WIP in `AppFeedback/App/AppFeedbackApp.swift` and `AppFeedback/Info.plist`. Before the first commit touching `AppFeedbackApp.swift`, run `git diff AppFeedback/App/AppFeedbackApp.swift AppFeedback/Info.plist` and judge: if the pre-existing hunks are unrelated to this feature, do NOT commit those files in intermediate commits — leave them modified in the tree, commit only fully-owned files, and flag the mixed files to the user in the final summary. Never `git add -A`; always stage explicit paths.
- iOS deployment floor is 18.6; don't lower it.
- `Task.sleep` values in the registry come from `Self.pollInterval` / `Self.fullReconcileInterval` constants — no magic numbers at call sites.

---

### Task 1: IssueLoaderRegistry core (sync, loadedGroups, tick cadence)

**Files:**
- Create: `AppFeedback/Services/IssueLoaderRegistry.swift`
- Create: `AppFeedbackTests/IssueLoaderRegistryTests.swift`
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (via `xcodegen generate`)

**Interfaces:**
- Consumes: `IssueLoader` (existing: `init(config:session:activityLog:cacheContext:)`, `var state: State` with cases `.idle/.loading/.loaded([FeedbackIssue], Date)/.failed(Error)`, `func load(token:fullReconcile:) async`), `NotificationService.diffAndNotify(loadedByRepo:)` + `typealias RepoIssues = (owner: String, repo: String, issues: [FeedbackIssue])`, `KeychainService.load(for:) async -> String?`, `ProductConfig`.
- Produces (later tasks rely on these exact signatures):
  - `init(factory: @escaping (ProductConfig) -> IssueLoader, tokenProvider: @escaping @Sendable (ProductConfig) async -> String? = { await KeychainService.load(for: $0) }, notificationService: NotificationService? = nil, clock: @escaping () -> Date = { Date() })`
  - `private(set) var loaders: [UUID: IssueLoader]`
  - `private(set) var lastRefreshAt: Date?`, `private(set) var lastFullReconcileAt: Date?`
  - `func syncWithProducts(_ repos: [ProductConfig])`
  - `func start()`, `func stop()`
  - `func loadAll(fullReconcile: Bool = false) async`
  - `func refreshTick() async`, `func pollIfStale() async`
  - `var loadedGroups: [NotificationService.RepoIssues]`
  - `static let pollInterval: TimeInterval` (900), `static let fullReconcileInterval: TimeInterval` (86400)
  - Note: the spec's `pollNow()` is realized as `loadAll()` — no separate alias method, since nothing would call it.

- [ ] **Step 1: Check for an existing URLSession mock in the test bundle**

Run: `grep -rn "session: .mock\|static var mock" /Users/amir/Developer/AppFeedback/AppFeedbackTests | head`
`AppStoreReviewCoordinatorTests` uses `GitHubCommentPoster(session: .mock)`, so a `URLSession.mock` (or similarly named) helper exists — find its definition and note its behavior (unhandled requests should fail fast). If, unexpectedly, none exists, add this stub at the bottom of the new test file and use `IssueLoaderRegistryTests.stubbedSession` instead of `.mock`:

```swift
final class StubFailURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

extension IssueLoaderRegistryTests {
    static var stubbedSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubFailURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `AppFeedbackTests/IssueLoaderRegistryTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class IssueLoaderRegistryTests: XCTestCase {
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeConfig(_ repo: String = "r1", id: UUID = UUID()) -> ProductConfig {
        ProductConfig(id: id, displayName: repo, owner: "o", repo: repo)
    }

    private func makeIssue(_ number: Int) -> FeedbackIssue {
        FeedbackIssue(number: number, title: "Issue \(number)", createdAt: Self.epoch,
                      rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil,
                      email: nil, description: "d", labels: [])
    }

    private func makeRegistry(
        tokenProvider: @escaping @Sendable (ProductConfig) async -> String? = { _ in nil },
        clock: @escaping () -> Date = { IssueLoaderRegistryTests.epoch }
    ) -> IssueLoaderRegistry {
        IssueLoaderRegistry(factory: { IssueLoader(config: $0, session: .mock) },
                            tokenProvider: tokenProvider, clock: clock)
    }

    // MARK: syncWithProducts

    func testSyncCreatesLoadersAndKeepsExistingIdentity() {
        let registry = makeRegistry()
        let a = makeConfig("a"); let b = makeConfig("b")
        registry.syncWithProducts([a])
        let loaderA = registry.loaders[a.id]
        XCTAssertNotNil(loaderA)
        registry.syncWithProducts([a, b])
        XCTAssertTrue(registry.loaders[a.id] === loaderA, "existing loader identity preserved")
        XCTAssertEqual(registry.loaders.count, 2)
    }

    func testSyncRemovesLoadersForDeletedProducts() {
        let registry = makeRegistry()
        let a = makeConfig("a"); let b = makeConfig("b")
        registry.syncWithProducts([a, b])
        registry.syncWithProducts([b])
        XCTAssertNil(registry.loaders[a.id])
        XCTAssertNotNil(registry.loaders[b.id])
    }

    func testSyncDispatchesInitialLoadForNewProductsOnly() async {
        let a = makeConfig("a")
        let exp = expectation(description: "token requested for newly-added repo")
        exp.assertForOverFulfill = false
        let registry = makeRegistry(tokenProvider: { repo in
            if repo.id == a.id { exp.fulfill() }
            return nil
        })
        registry.syncWithProducts([a])
        await fulfillment(of: [exp], timeout: 2)
    }

    // MARK: loadedGroups

    func testLoadedGroupsIncludesOnlyLoadedLoaders() {
        let registry = makeRegistry()
        let a = makeConfig("a"); let b = makeConfig("b")
        registry.syncWithProducts([a, b])
        registry.loaders[a.id]?.state = .loaded([makeIssue(1)], Self.epoch)
        // b stays .idle
        let groups = registry.loadedGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].owner, "o")
        XCTAssertEqual(groups[0].repo, "a")
        XCTAssertEqual(groups[0].issues.map(\.number), [1])
    }

    // MARK: refreshTick cadence (zero products — no loads dispatched, stamps still testable)

    func testFirstTickSweepsFullyThenDaily() async {
        var now = Self.epoch
        let registry = makeRegistry(clock: { now })
        await registry.refreshTick()
        XCTAssertEqual(registry.lastFullReconcileAt, Self.epoch, "first tick is a full sweep")

        now = Self.epoch.addingTimeInterval(IssueLoaderRegistry.pollInterval)
        await registry.refreshTick()
        XCTAssertEqual(registry.lastFullReconcileAt, Self.epoch, "within 24h stays incremental")

        now = Self.epoch.addingTimeInterval(IssueLoaderRegistry.fullReconcileInterval)
        await registry.refreshTick()
        XCTAssertEqual(registry.lastFullReconcileAt, now, "24h later sweeps again")
    }

    func testPollIfStaleRefreshesOnlyWhenOlderThanInterval() async {
        var now = Self.epoch
        let registry = makeRegistry(clock: { now })
        await registry.refreshTick()
        XCTAssertEqual(registry.lastRefreshAt, Self.epoch)

        now = Self.epoch.addingTimeInterval(5 * 60)
        await registry.pollIfStale()
        XCTAssertEqual(registry.lastRefreshAt, Self.epoch, "fresh → no-op")

        now = Self.epoch.addingTimeInterval(IssueLoaderRegistry.pollInterval)
        await registry.pollIfStale()
        XCTAssertEqual(registry.lastRefreshAt, now, "stale → refreshed")
    }

    func testPollIfStaleWithNoPriorRefreshRefreshes() async {
        let registry = makeRegistry()
        await registry.pollIfStale()
        XCTAssertNotNil(registry.lastRefreshAt)
    }
}
```

Adjust `session: .mock` to whatever Step 1 found.

- [ ] **Step 3: Regenerate the project and verify the tests fail**

Run:
```bash
git status --short | grep xcscheme   # expect empty; if not, STOP and flag
xcodegen generate
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/IssueLoaderRegistryTests 2>&1 | tail -20
```
Expected: build FAILS with "cannot find 'IssueLoaderRegistry' in scope".

- [ ] **Step 4: Write the implementation**

Create `AppFeedback/Services/IssueLoaderRegistry.swift`:

```swift
import Foundation
import Observation
import SwiftData

/// App-level registry owning one `IssueLoader` per product plus the 15-minute foreground
/// refresh loop. Mirrors the grain of `MailSyncCoordinatorRegistry` /
/// `AppStoreReviewCoordinatorRegistry`: spin-up creates loaders, tear-down drops them,
/// `start()` runs the poll loop, `pollIfStale()` catches up after suspension.
///
/// Replaces `MacBackgroundRefreshDriver`: because this registry owns the UI's actual
/// loaders, its refreshes are visible in the app, and it runs regardless of whether
/// notifications are enabled (`diffAndNotify` self-gates on that).
@Observable @MainActor
final class IssueLoaderRegistry {
    private(set) var loaders: [UUID: IssueLoader] = [:]

    /// Stamped when a fan-out load completes — drives `pollIfStale()`.
    private(set) var lastRefreshAt: Date?
    /// Stamped when a full (non-incremental) pass completes — drives the daily sweep that
    /// prunes phantom issues (incremental `since:` fetches never surface deletions).
    private(set) var lastFullReconcileAt: Date?

    static let pollInterval: TimeInterval = 15 * 60
    static let fullReconcileInterval: TimeInterval = 24 * 3600

    private var products: [ProductConfig] = []
    private var loopTask: Task<Void, Never>?
    private let factory: (ProductConfig) -> IssueLoader
    private let tokenProvider: @Sendable (ProductConfig) async -> String?
    private let notificationService: NotificationService?
    private let clock: () -> Date

    init(
        factory: @escaping (ProductConfig) -> IssueLoader,
        tokenProvider: @escaping @Sendable (ProductConfig) async -> String? = { await KeychainService.load(for: $0) },
        notificationService: NotificationService? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.factory = factory
        self.tokenProvider = tokenProvider
        self.notificationService = notificationService
        self.clock = clock
    }

    /// Creates loaders for newly-added products (dispatching their initial load) and drops
    /// loaders for removed ones. Safe to call repeatedly.
    func syncWithProducts(_ repos: [ProductConfig]) {
        products = repos
        var newlyAdded: [ProductConfig] = []
        for repo in repos where loaders[repo.id] == nil {
            loaders[repo.id] = factory(repo)
            newlyAdded.append(repo)
        }
        let ids = Set(repos.map(\.id))
        loaders = loaders.filter { ids.contains($0.key) }
        if !newlyAdded.isEmpty {
            Task { await self.load(newlyAdded, fullReconcile: false) }
        }
    }

    /// Starts the foreground poll loop. Safe to call multiple times.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                await self?.refreshTick()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One poll-loop iteration: load every repo (full reconcile once per 24h) then feed the
    /// notification differ (which self-gates on notifications being enabled).
    func refreshTick() async {
        let needsFull = lastFullReconcileAt
            .map { clock().timeIntervalSince($0) >= Self.fullReconcileInterval } ?? true
        await loadAll(fullReconcile: needsFull)
        await notificationService?.diffAndNotify(loadedByRepo: loadedGroups)
    }

    /// Catch-up poll after suspension (scene re-activation): a full tick, but only when the
    /// last refresh is older than the poll interval.
    func pollIfStale() async {
        let stale = lastRefreshAt
            .map { clock().timeIntervalSince($0) >= Self.pollInterval } ?? true
        guard stale else { return }
        await refreshTick()
    }

    /// Fan-out load across every product; stamps the refresh clocks.
    func loadAll(fullReconcile: Bool = false) async {
        await load(products, fullReconcile: fullReconcile)
        lastRefreshAt = clock()
        if fullReconcile { lastFullReconcileAt = clock() }
    }

    /// All currently-loaded (owner, repo, issues) groups — the notification differ's input.
    var loadedGroups: [NotificationService.RepoIssues] {
        products.compactMap { repo in
            guard let loader = loaders[repo.id],
                  case .loaded(let issues, _) = loader.state else { return nil }
            return (owner: repo.owner, repo: repo.repo, issues: issues)
        }
    }

    private func load(_ repos: [ProductConfig], fullReconcile: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                guard let loader = loaders[repo.id] else { continue }
                let tokenProvider = tokenProvider
                group.addTask {
                    // iCloud Keychain may not have synced this token yet on a fresh device;
                    // one short retry catches that without blocking the happy path.
                    for attempt in 0..<2 {
                        if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                        if let token = await tokenProvider(repo) {
                            await loader.load(token: token, fullReconcile: fullReconcile)
                            return
                        }
                    }
                }
            }
        }
    }
}
```

If the compiler rejects capturing the `@MainActor` `loader` in `group.addTask` under strict concurrency, change the closure to `group.addTask { @MainActor in ... }` (the awaits inside make this non-blocking).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/IssueLoaderRegistryTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/IssueLoaderRegistry.swift AppFeedbackTests/IssueLoaderRegistryTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(refresh): add IssueLoaderRegistry with 15-min poll loop and daily full-reconcile

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Registry retryStuck + single-product load

**Files:**
- Modify: `AppFeedback/Services/IssueLoaderRegistry.swift`
- Modify: `AppFeedbackTests/IssueLoaderRegistryTests.swift`

**Interfaces:**
- Produces (Task 3 relies on these):
  - `func retryStuck()` — re-dispatches loads for loaders in `.idle`/`.failed` state
  - `func load(productID: UUID, fullReconcile: Bool = false) async` — loads one product (replaces `RootView.refresh(repo:)` / `refreshSelectedRepo()` / the single-repo full-reconcile at RootView.swift:343)

- [ ] **Step 1: Write the failing tests**

Add to `IssueLoaderRegistryTests.swift` (inside the class), plus the recorder actor at file scope (outside the class):

```swift
    // MARK: retryStuck / single-product load

    func testRetryStuckReloadsIdleAndFailedButNotLoaded() async throws {
        let idle = makeConfig("idle"); let failed = makeConfig("failed"); let loaded = makeConfig("loaded")
        let recorder = TokenRequestRecorder()
        let registry = makeRegistry(tokenProvider: { repo in
            await recorder.record(repo.id)
            return "tok"   // non-nil → loader.load runs against the mock session and fails fast
        })
        registry.syncWithProducts([idle, failed, loaded])

        // Wait for the initial-load dispatch to settle: all loaders leave .idle via the
        // mock session (→ .failed).
        try await waitUntil { registry.loaders.values.allSatisfy { if case .failed = $0.state { return true }; return false } }

        registry.loaders[idle.id]?.state = .idle
        registry.loaders[loaded.id]?.state = .loaded([], Self.epoch)
        // failed's loader stays .failed
        await recorder.startRecording()

        registry.retryStuck()
        try await waitUntil { await recorder.recorded.count >= 2 }
        try? await Task.sleep(for: .milliseconds(50))   // settle window for a spurious third load
        let recorded = await recorder.recorded
        XCTAssertTrue(recorded.contains(idle.id))
        XCTAssertTrue(recorded.contains(failed.id))
        XCTAssertFalse(recorded.contains(loaded.id), "a loaded repo must not be re-fetched")
    }

    func testLoadProductIDLoadsOnlyThatProduct() async throws {
        let a = makeConfig("a"); let b = makeConfig("b")
        let recorder = TokenRequestRecorder()
        let registry = makeRegistry(tokenProvider: { repo in
            await recorder.record(repo.id)
            return "tok"
        })
        registry.syncWithProducts([a, b])
        // Recorder is off during the initial-load dispatch, so settle on loader state instead.
        try await waitUntil { registry.loaders.values.allSatisfy { if case .failed = $0.state { return true }; return false } }
        await recorder.startRecording()

        await registry.load(productID: a.id)
        let recorded = await recorder.recorded
        XCTAssertEqual(recorded, [a.id])
    }

    /// Polls `condition` every 10ms until true or ~2s elapse.
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within timeout")
    }
```

```swift
/// Records tokenProvider calls, but only after `startRecording()` — lets tests ignore the
/// initial-load dispatch from syncWithProducts.
private actor TokenRequestRecorder {
    private(set) var recorded: [UUID] = []
    private var recording = false
    func startRecording() { recorded = []; recording = true }
    func record(_ id: UUID) { if recording { recorded.append(id) } }
}
```

Note: `waitUntil`'s closure signature may need `@escaping`/`@Sendable` tweaks to satisfy the compiler — the shape (poll every 10ms, fail after 2s) is the requirement, exact annotations are flexible.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/IssueLoaderRegistryTests 2>&1 | tail -10`
Expected: build FAILS — `retryStuck`/`load(productID:)` not defined.

- [ ] **Step 3: Implement**

Add to `IssueLoaderRegistry` (after `loadAll`):

```swift
    /// Loads one product's issues (e.g. after creating a task so the new issue appears,
    /// even if the user has since switched projects). Does not stamp the refresh clocks.
    func load(productID: UUID, fullReconcile: Bool = false) async {
        guard let repo = products.first(where: { $0.id == productID }) else { return }
        await load([repo], fullReconcile: fullReconcile)
    }

    /// Re-dispatches loads for loaders that are idle or failed (scene re-activation,
    /// CloudKit import landing).
    func retryStuck() {
        let stuck = products.filter { repo in
            guard let loader = loaders[repo.id] else { return false }
            switch loader.state {
            case .idle, .failed: return true
            case .loading, .loaded: return false
            }
        }
        guard !stuck.isEmpty else { return }
        Task { await self.load(stuck, fullReconcile: false) }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/IssueLoaderRegistryTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/IssueLoaderRegistry.swift AppFeedbackTests/IssueLoaderRegistryTests.swift
git commit -m "feat(refresh): registry retryStuck and single-product load

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Wire the registry into AppFeedbackApp and RootView

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (registry construction ~line 292, RootView call site ~line 353)
- Modify: `AppFeedback/App/RootView.swift` (throughout — all `loaders` access)

**Interfaces:**
- Consumes: everything Task 1–2 produced.
- Produces: `RootView.init` gains `issueLoaderRegistry: IssueLoaderRegistry` (non-optional, after `filterStore`); `AppFeedbackApp` holds `@State private var issueLoaderRegistry: IssueLoaderRegistry`. `MacBackgroundRefreshDriver` still exists after this task (deleted in Task 4).

- [ ] **Step 1: Construct the registry in AppFeedbackApp.init**

In `AppFeedbackApp.swift`, add the property near the other registries (~line 63):

```swift
    @State private var issueLoaderRegistry: IssueLoaderRegistry
```

In `init()`, just before the `#if os(iOS)` driver block (~line 293), add:

```swift
        let cacheCtx = _cacheContext.wrappedValue
        let issueRegistry = IssueLoaderRegistry(
            factory: { cfg in IssueLoader(config: cfg, activityLog: activityLogValue, cacheContext: cacheCtx) },
            notificationService: service
        )
        _issueLoaderRegistry = State(initialValue: issueRegistry)
```

- [ ] **Step 2: Pass the registry to RootView**

At the `RootView(...)` call site (~line 353), add `issueLoaderRegistry: issueLoaderRegistry` after `filterStore:`.

- [ ] **Step 3: Update RootView to delegate to the registry**

In `RootView.swift`:

1. Add the stored property + init parameter (after `filterStore`):
```swift
    var issueLoaderRegistry: IssueLoaderRegistry
```
and in `init`, parameter `issueLoaderRegistry: IssueLoaderRegistry` with `self.issueLoaderRegistry = issueLoaderRegistry`.
2. Delete `@State private var loaders: [UUID: IssueLoader] = [:]` (line 26).
3. Replace every read of `loaders` with `issueLoaderRegistry.loaders`. Known sites (verify with `grep -n "loaders" RootView.swift` — line numbers will have shifted): SidebarView call (~89), IssueListView `loader:` (~113), guard in the seen-count helper (~315), single-repo full-reconcile (~343 — becomes `await issueLoaderRegistry.load(productID: selection.repoId, fullReconcile: true)`), `updateViewModel` (~392, ~424), `purgeFromCache` sites (~549, ~570, ~574), `findIssue` (~746).
4. Replace method bodies:
   - `syncLoaders(repos:)` (~439–454): delete the method; both call sites (`onChange(of: store.repos)` ~240 and `.task` ~259) become `issueLoaderRegistry.syncWithProducts(...)` with the same argument.
   - `loadRepos(_:fullReconcile:)` (~695–712): delete; the pull-to-refresh site (~120) becomes `await issueLoaderRegistry.loadAll(fullReconcile: true)`.
   - `loadAllRepos()` (~469): delete; `handleNotificationTap` (~763) calls `await issueLoaderRegistry.loadAll()`.
   - `refresh(repo:)` (~681) and `refreshSelectedRepo()` (~688): bodies become `await issueLoaderRegistry.load(productID: repo.id)` / `await issueLoaderRegistry.load(productID: selection.repoId)` (keep the existing guards that resolve `selection`; drop the KeychainService calls).
   - `retryStuckLoaders()` (~714–724): delete; both call sites (scenePhase ~289, cloudKitImportSucceeded ~293) become `issueLoaderRegistry.retryStuck()`.
   - `allLoadedRepoGroups` (~729): delete; its consumers (`maybeSnapshotBacklog` — find with grep) use `issueLoaderRegistry.loadedGroups`.
5. Keep the comment at ~255–258 explaining why `.task` doesn't double-fetch, updating the method names it mentions.

- [ ] **Step 4: Build and run the full macOS test suite**

```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -5
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -15
```
Expected: build succeeds; only the ~11 known Keychain-related failures.

- [ ] **Step 5: Commit (respecting the user's WIP)**

Run `git diff AppFeedback/App/AppFeedbackApp.swift` and compare against the pre-existing WIP hunks noted at plan start. If the WIP is unrelated: commit only `RootView.swift` now and leave `AppFeedbackApp.swift` uncommitted until the final task (flagging it in the summary). If the tree turns out to hold only our changes, commit both:

```bash
git add AppFeedback/App/RootView.swift   # + AppFeedbackApp.swift only if WIP-free
git commit -m "refactor(refresh): RootView delegates issue loaders to IssueLoaderRegistry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Delete MacBackgroundRefreshDriver; start the loop; catch-up on activation

**Files:**
- Delete: `AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (driver wiring, `onAppear`, scenePhase handlers, notifications toggle)
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (via `xcodegen generate`)

**Interfaces:**
- Consumes: `issueLoaderRegistry.start()`, `.pollIfStale()` from Tasks 1–3.

- [ ] **Step 1: Remove the mac driver and start the registry**

In `AppFeedbackApp.swift`:

1. Delete the `#elseif os(macOS)` property block (~lines 71–73 `@State private var macRefreshDriver...`) — keep the `#if os(iOS)` half.
2. Delete the `#elseif os(macOS)` init block (~lines 304–315, `MacBackgroundRefreshDriver(...)` through `_macRefreshDriver = State(...)`).
3. In `.onAppear` (~line 363), add `issueLoaderRegistry.start()` alongside `appStoreRegistry.start()`.
4. Rework `.onChange(of: notificationSettings.isEnabled)` (~369–375): the macOS branch (`macRefreshDriver.startIfEnabled()/stop()`) disappears; wrap the remaining iOS branch so the modifier only exists on iOS:
```swift
                #if os(iOS)
                .onChange(of: notificationSettings.isEnabled) { _, isOn in
                    if isOn { iosRefreshDriver.scheduleNextRefresh() } else { iosRefreshDriver.cancelPending() }
                }
                #endif
```
5. In BOTH scenePhase `.onChange` handlers (iOS ~377, macOS ~389), add to the `phase == .active` branch:
```swift
                    if phase == .active {
                        Task { await issueLoaderRegistry.pollIfStale() }
                    }
```
(The spec names iOS foregrounding; the macOS handler gets the same line for symmetry — it's a no-op while the loop keeps the data fresh.)

- [ ] **Step 2: Delete the driver file and regenerate**

```bash
rm AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift
git status --short | grep xcscheme   # expect empty
xcodegen generate
```

- [ ] **Step 3: Build both platforms, run macOS tests**

```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -5
xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -15
```
Expected: both builds succeed; only the known Keychain failures.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Services/Notifications/MacBackgroundRefreshDriver.swift AppFeedback.xcodeproj/project.pbxproj   # the rm is staged via add
git commit -m "refactor(refresh): replace MacBackgroundRefreshDriver with IssueLoaderRegistry loop

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
(`AppFeedbackApp.swift` joins this commit only if Task 3 Step 5 found it WIP-free; otherwise it stays uncommitted until the final flag.)

---

### Task 5: Slim iOSBackgroundRefreshDriver to BGTask glue

**Files:**
- Modify: `AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (driver construction ~line 294)

**Interfaces:**
- Consumes: `issueLoaderRegistry.refreshTick()` (loads all + feeds `diffAndNotify` internally).
- Produces: `iOSBackgroundRefreshDriver.init(registry:settings:appStoreRegistry:)` — `store`, `cacheContext`, `notificationService`, `activityLog` parameters are dropped.

- [ ] **Step 1: Rewrite the driver**

Replace the class body of `iOSBackgroundRefreshDriver.swift` with:

```swift
#if os(iOS)
import Foundation
import BackgroundTasks

/// BGTaskScheduler glue for background refresh. The actual fetch + notification diff is
/// `IssueLoaderRegistry.refreshTick()` — the same code path as the foreground poll loop —
/// so background-fetched data lands in the UI's own loaders.
@MainActor
final class iOSBackgroundRefreshDriver {
    static let taskIdentifier = "com.amirhayek.AppFeedback.refresh"

    private let registry: IssueLoaderRegistry
    private let settings: NotificationSettings
    private let appStoreRegistry: AppStoreReviewCoordinatorRegistry

    init(
        registry: IssueLoaderRegistry,
        settings: NotificationSettings,
        appStoreRegistry: AppStoreReviewCoordinatorRegistry
    ) {
        self.registry = registry
        self.settings = settings
        self.appStoreRegistry = appStoreRegistry
    }

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            let work = Task { @MainActor in
                await self.runRefresh()
                refresh.setTaskCompleted(success: true)
                self.scheduleNextRefresh()
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    func scheduleNextRefresh() {
        guard settings.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(IssueLoaderRegistry.pollInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private func runRefresh() async {
        guard settings.isEnabled else { return }
        await registry.refreshTick()
        // The App Store registry's own poll loop is suspended while backgrounded, so this
        // background window must poll it explicitly.
        await appStoreRegistry.pollNow()
    }
}
#endif
```

- [ ] **Step 2: Update the construction site**

In `AppFeedbackApp.swift`, the `#if os(iOS)` block (~line 294) becomes:

```swift
        #if os(iOS)
        let driver = iOSBackgroundRefreshDriver(
            registry: issueRegistry,
            settings: settings,
            appStoreRegistry: ascRegistry
        )
        driver.register()
        _iosRefreshDriver = State(initialValue: driver)
        #endif
```
(This block must come AFTER the `issueRegistry` construction added in Task 3 Step 1.)

- [ ] **Step 3: Build both platforms**

```bash
xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Services/Notifications/iOSBackgroundRefreshDriver.swift
git commit -m "refactor(refresh): iOS background driver delegates to IssueLoaderRegistry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Full verification and AppFeedbackApp.swift resolution

**Files:**
- Possibly commit: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Full macOS test suite**

Run: `xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS 2>&1 | tail -20`
Expected: only the ~11 known Keychain failures (compare class names against the known list: `KeychainServicePerAccountTests`, `GitHubAccountStoreTests`).

- [ ] **Step 2: iOS build**

Run: `xcodebuild build -scheme AppFeedback_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Resolve AppFeedbackApp.swift**

If Task 3 deferred committing `AppFeedbackApp.swift` because of the user's WIP: report the mixed state to the user — show which hunks are ours vs. pre-existing — and let them decide whether to commit the file whole or separate the WIP. Do NOT silently bundle their WIP into a feature commit.

- [ ] **Step 4: Sanity-check the poll loop wiring by inspection**

Confirm (grep): exactly one `issueLoaderRegistry.start()` call (onAppear), `pollIfStale()` in both scenePhase handlers, no remaining references to `MacBackgroundRefreshDriver`, and `RootView` contains no `KeychainService.load` calls for issue loading.
