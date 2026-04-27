# Unread Feedback Indicator + SwiftData Cache — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the JSON-file issue cache with SwiftData (local-only) and add a CloudKit-synced "seen" model so users get a blue unread dot on new feedback issues that disappears on view interaction or on the next refresh, mirrored across macOS and iOS via iCloud.

**Architecture:** One `ModelContainer` with two `ModelConfiguration`s — a CloudKit-synced one (`Repo`, `SeenIssue`) and a local-only one (`CachedIssue`). `IssueLoader` is rewritten to read/write `CachedIssue`. A new `SeenIssueStore` wraps the cloud context. `IssueListViewModel` exposes `sessionUnread: Set<Int>`, populated when `.loaded` arrives by diffing fetched issue numbers against `SeenIssue` rows; the previous-load set is bulk-flushed on each new load. Card taps and badge interactions call `markSeen` to clear the dot immediately.

**Tech Stack:** Swift, SwiftUI, SwiftData (CloudKit), XCTest. macOS + iOS targets share all code.

**Spec:** `docs/superpowers/specs/2026-04-27-unread-feedback-swiftdata-design.md`

---

### Task 1: Add `CachedIssue` SwiftData model

**Files:**
- Create: `AppFeedback/Models/CachedIssue.swift`
- Test: `AppFeedbackTests/CachedIssueTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AppFeedbackTests/CachedIssueTests.swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class CachedIssueTests: XCTestCase {
    func test_roundTrip_preservesAllFields() throws {
        let issue = FeedbackIssue(
            number: 42, title: "Crash on launch",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawBody: "raw", appName: "Foo", appVersion: "1.2",
            device: "iPhone", osVersion: "17.0",
            email: "a@b.com", description: "desc"
        )
        let cached = CachedIssue.from(issue, repoOwner: "org", repoName: "repo")
        let restored = cached.toFeedbackIssue()
        XCTAssertEqual(restored.number, 42)
        XCTAssertEqual(restored.title, "Crash on launch")
        XCTAssertEqual(restored.appName, "Foo")
        XCTAssertEqual(restored.appVersion, "1.2")
        XCTAssertEqual(restored.device, "iPhone")
        XCTAssertEqual(restored.osVersion, "17.0")
        XCTAssertEqual(restored.email, "a@b.com")
        XCTAssertEqual(restored.description, "desc")
        XCTAssertEqual(restored.rawBody, "raw")
        XCTAssertEqual(cached.repoOwner, "org")
        XCTAssertEqual(cached.repoName, "repo")
    }

    func test_inMemoryContainer_persistsAndFetches() throws {
        let schema = Schema([CachedIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        ctx.insert(CachedIssue(
            repoOwner: "org", repoName: "repo", number: 1,
            title: "t", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil,
            email: nil, issueDescription: ""
        ))
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<CachedIssue>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.number, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Use the zcode skill to run `AppFeedbackTests/CachedIssueTests`. Expected: FAIL — `CachedIssue` is undefined.

- [ ] **Step 3: Implement `CachedIssue`**

```swift
// AppFeedback/Models/CachedIssue.swift
import Foundation
import SwiftData

@Model
final class CachedIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var number: Int = 0
    var title: String = ""
    var createdAt: Date = Date()
    var rawBody: String = ""
    var appName: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var issueDescription: String = ""

    init(
        repoOwner: String,
        repoName: String,
        number: Int,
        title: String,
        createdAt: Date,
        rawBody: String,
        appName: String?,
        appVersion: String?,
        device: String?,
        osVersion: String?,
        email: String?,
        issueDescription: String
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.number = number
        self.title = title
        self.createdAt = createdAt
        self.rawBody = rawBody
        self.appName = appName
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.email = email
        self.issueDescription = issueDescription
    }

    func toFeedbackIssue() -> FeedbackIssue {
        FeedbackIssue(
            number: number,
            title: title,
            createdAt: createdAt,
            rawBody: rawBody,
            appName: appName,
            appVersion: appVersion,
            device: device,
            osVersion: osVersion,
            email: email,
            description: issueDescription
        )
    }

    static func from(_ issue: FeedbackIssue, repoOwner: String, repoName: String) -> CachedIssue {
        CachedIssue(
            repoOwner: repoOwner,
            repoName: repoName,
            number: issue.number,
            title: issue.title,
            createdAt: issue.createdAt,
            rawBody: issue.rawBody,
            appName: issue.appName,
            appVersion: issue.appVersion,
            device: issue.device,
            osVersion: issue.osVersion,
            email: issue.email,
            issueDescription: issue.description
        )
    }
}
```

Add the new file to the Xcode target via `AppFeedback.xcodeproj/project.pbxproj` (mirror the pattern used for `Repo.swift`). Also add the test file to the test target the same way.

- [ ] **Step 4: Run tests to verify they pass**

Run via zcode. Expected: both tests in `CachedIssueTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/CachedIssue.swift AppFeedbackTests/CachedIssueTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cache): add CachedIssue SwiftData model"
```

---

### Task 2: Add `SeenIssue` SwiftData model + `SeenIssueStore`

**Files:**
- Create: `AppFeedback/Models/SeenIssue.swift`
- Create: `AppFeedback/Services/SeenIssueStore.swift`
- Test: `AppFeedbackTests/SeenIssueStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AppFeedbackTests/SeenIssueStoreTests.swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class SeenIssueStoreTests: XCTestCase {
    private func makeStore() throws -> (SeenIssueStore, ModelContext) {
        let schema = Schema([SeenIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        return (SeenIssueStore(context: ctx), ctx)
    }

    func test_seenNumbers_isEmptyInitially() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.seenNumbers(owner: "o", repo: "r").isEmpty)
    }

    func test_markSeen_persistsAndIsIdempotent() throws {
        let (store, ctx) = try makeStore()
        store.markSeen(owner: "o", repo: "r", issueNumber: 1)
        store.markSeen(owner: "o", repo: "r", issueNumber: 1) // duplicate
        let rows = try ctx.fetch(FetchDescriptor<SeenIssue>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1])
    }

    func test_markSeenBulk_skipsExisting() throws {
        let (store, ctx) = try makeStore()
        store.markSeen(owner: "o", repo: "r", issueNumber: 2)
        store.markSeenBulk(owner: "o", repo: "r", issueNumbers: [1, 2, 3])
        let rows = try ctx.fetch(FetchDescriptor<SeenIssue>())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1, 2, 3])
    }

    func test_seenNumbers_isolatedByRepo() throws {
        let (store, _) = try makeStore()
        store.markSeen(owner: "o", repo: "r1", issueNumber: 5)
        store.markSeen(owner: "o", repo: "r2", issueNumber: 6)
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r1"), [5])
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r2"), [6])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run via zcode. Expected: FAIL — `SeenIssue` and `SeenIssueStore` undefined.

- [ ] **Step 3: Implement `SeenIssue`**

```swift
// AppFeedback/Models/SeenIssue.swift
import Foundation
import SwiftData

@Model
final class SeenIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var issueNumber: Int = 0
    var seenAt: Date = Date()

    init(repoOwner: String, repoName: String, issueNumber: Int, seenAt: Date = Date()) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.issueNumber = issueNumber
        self.seenAt = seenAt
    }
}
```

- [ ] **Step 4: Implement `SeenIssueStore`**

```swift
// AppFeedback/Services/SeenIssueStore.swift
import Foundation
import SwiftData

@MainActor
final class SeenIssueStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func seenNumbers(owner: String, repo: String) -> Set<Int> {
        let predicate = #Predicate<SeenIssue> {
            $0.repoOwner == owner && $0.repoName == repo
        }
        let descriptor = FetchDescriptor<SeenIssue>(predicate: predicate)
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.issueNumber))
    }

    func markSeen(owner: String, repo: String, issueNumber: Int) {
        guard !exists(owner: owner, repo: repo, issueNumber: issueNumber) else { return }
        context.insert(SeenIssue(repoOwner: owner, repoName: repo, issueNumber: issueNumber))
        try? context.save()
    }

    func markSeenBulk(owner: String, repo: String, issueNumbers: [Int]) {
        guard !issueNumbers.isEmpty else { return }
        let existing = seenNumbers(owner: owner, repo: repo)
        var inserted = false
        for n in issueNumbers where !existing.contains(n) {
            context.insert(SeenIssue(repoOwner: owner, repoName: repo, issueNumber: n))
            inserted = true
        }
        if inserted { try? context.save() }
    }

    private func exists(owner: String, repo: String, issueNumber: Int) -> Bool {
        let predicate = #Predicate<SeenIssue> {
            $0.repoOwner == owner && $0.repoName == repo && $0.issueNumber == issueNumber
        }
        var descriptor = FetchDescriptor<SeenIssue>(predicate: predicate)
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first) != nil
    }
}
```

Add both files to the AppFeedback target in the pbxproj. Add the test file to the test target.

- [ ] **Step 5: Run tests to verify they pass**

Run via zcode. Expected: all `SeenIssueStoreTests` PASS.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Models/SeenIssue.swift AppFeedback/Services/SeenIssueStore.swift AppFeedbackTests/SeenIssueStoreTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(unread): add SeenIssue model + SeenIssueStore"
```

---

### Task 3: Update `ModelContainer` with two configurations

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Update container creation**

Replace the existing container init block in `AppFeedbackApp.init` with:

```swift
let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
do {
    let cloudSchema = Schema([Repo.self, SeenIssue.self])
    let localSchema = Schema([CachedIssue.self])
    let cloudConfig: ModelConfiguration = isTesting
        ? ModelConfiguration("cloud", schema: cloudSchema, isStoredInMemoryOnly: true)
        : ModelConfiguration(
            "cloud",
            schema: cloudSchema,
            cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
        )
    let localConfig: ModelConfiguration = isTesting
        ? ModelConfiguration("local", schema: localSchema, isStoredInMemoryOnly: true)
        : ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
    container = try ModelContainer(
        for: Repo.self, SeenIssue.self, CachedIssue.self,
        configurations: cloudConfig, localConfig
    )
} catch {
    assertionFailure("Failed to create ModelContainer: \(error)")
    fatalError("Failed to create ModelContainer: \(error)")
}
```

- [ ] **Step 2: Build the project**

Use the zcode skill to build. Expected: build succeeds. (`CachedIssue` and `SeenIssue` from earlier tasks are now both in the schema.)

- [ ] **Step 3: Run all tests**

Run via zcode. Expected: all existing tests still PASS (Repo persistence works, new tests still pass).

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(swiftdata): split container into cloud + local configs"
```

---

### Task 4: Migrate `IssueLoader` cache from JSON to SwiftData

**Files:**
- Modify: `AppFeedback/Services/IssueLoader.swift`
- Modify: `AppFeedbackTests/IssueLoaderTests.swift`

- [ ] **Step 1: Update existing tests to use SwiftData**

Replace `IssueLoaderTests` setup/teardown and inject a context:

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class IssueLoaderTests: XCTestCase {
    private let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        let schema = Schema([CachedIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    private func makeLoader() -> IssueLoader {
        IssueLoader(config: repo, session: .mock, cacheContext: context)
    }
    // ... existing makeIssuesJSON helper unchanged ...
```

Update each existing test to call `makeLoader()` instead of `IssueLoader(config: repo, session: .mock)`. Add this new test at the bottom:

```swift
    func test_load_persistsToSwiftDataCache_andReloadsOnSecondLoaderInit() async throws {
        let data = makeIssuesJSON(count: 2)
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        await makeLoader().load(token: "tok")

        // New loader, same context — should hydrate from cache before any network.
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let second = makeLoader()
        await second.load(token: "tok")
        guard case .loaded(let issues, _) = second.state else {
            return XCTFail("Expected .loaded from cache")
        }
        XCTAssertEqual(issues.count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run via zcode. Expected: FAIL — `IssueLoader.init` does not accept `cacheContext:`.

- [ ] **Step 3: Update `IssueLoader`**

Replace the cache plumbing in `AppFeedback/Services/IssueLoader.swift`. Specifically:

Add `import SwiftData` at the top.

Change the stored properties:

```swift
private let config: RepoConfig
private let session: URLSession
private let cacheContext: ModelContext?
private var inFlight: (token: String, task: Task<Void, Never>)?
private let activityLog: ActivityLog?
```

Change the initializer:

```swift
init(
    config: RepoConfig,
    session: URLSession = .shared,
    activityLog: ActivityLog? = nil,
    cacheContext: ModelContext? = nil
) {
    self.config = config
    self.session = session
    self.activityLog = activityLog
    self.cacheContext = cacheContext
}
```

Replace `loadFromCache` and `saveToCache`:

```swift
private func loadFromCache() {
    guard let context = cacheContext else { return }
    let owner = config.owner
    let name = config.repo
    let predicate = #Predicate<CachedIssue> {
        $0.repoOwner == owner && $0.repoName == name
    }
    let descriptor = FetchDescriptor<CachedIssue>(predicate: predicate)
    guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
    let issues = rows.map { $0.toFeedbackIssue() }
    state = .loaded(issues, Date(timeIntervalSince1970: 0))
}

private func saveToCache(_ issues: [FeedbackIssue]) {
    guard let context = cacheContext else { return }
    let owner = config.owner
    let name = config.repo
    let predicate = #Predicate<CachedIssue> {
        $0.repoOwner == owner && $0.repoName == name
    }
    if let existing = try? context.fetch(FetchDescriptor<CachedIssue>(predicate: predicate)) {
        for row in existing { context.delete(row) }
    }
    for issue in issues {
        context.insert(CachedIssue.from(issue, repoOwner: owner, repoName: name))
    }
    try? context.save()
}
```

Delete the `cacheURL` property entirely.

- [ ] **Step 4: Run tests to verify they pass**

Run via zcode. Expected: all `IssueLoaderTests` PASS, including the new round-trip test.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/IssueLoader.swift AppFeedbackTests/IssueLoaderTests.swift
git commit -m "feat(cache): use SwiftData CachedIssue instead of JSON file"
```

---

### Task 5: Add unread tracking to `IssueListViewModel`

**Files:**
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift`
- Modify: `AppFeedbackTests/IssueListViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `AppFeedbackTests/IssueListViewModelTests.swift`:

```swift
import SwiftData

@MainActor
extension IssueListViewModelTests {
    private func makeStore() throws -> SeenIssueStore {
        let schema = Schema([SeenIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return SeenIssueStore(context: ModelContext(container))
    }

    private func issue(_ n: Int) -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: "t\(n)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
            rawBody: "", appName: nil, appVersion: nil,
            device: nil, osVersion: nil, email: nil, description: ""
        )
    }

    func test_applyLoaded_marksIssuesUnreadOnFirstLoad() throws {
        let vm = IssueListViewModel()
        vm.attachSeenStore(try makeStore(), owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2), issue(3)])
        XCTAssertTrue(vm.isUnread(issue(1)))
        XCTAssertTrue(vm.isUnread(issue(2)))
        XCTAssertTrue(vm.isUnread(issue(3)))
    }

    func test_applyLoaded_secondLoadFlushesPreviousAsSeen() throws {
        let vm = IssueListViewModel()
        let store = try makeStore()
        vm.attachSeenStore(store, owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2)])
        vm.applyLoaded([issue(1), issue(2), issue(3)]) // flushes 1,2 as seen
        XCTAssertFalse(vm.isUnread(issue(1)))
        XCTAssertFalse(vm.isUnread(issue(2)))
        XCTAssertTrue(vm.isUnread(issue(3)))
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1, 2])
    }

    func test_markSeen_clearsDotImmediately() throws {
        let vm = IssueListViewModel()
        let store = try makeStore()
        vm.attachSeenStore(store, owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2)])
        vm.markSeen(issue(1))
        XCTAssertFalse(vm.isUnread(issue(1)))
        XCTAssertTrue(vm.isUnread(issue(2)))
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1])
    }

    func test_isUnread_falseWhenNoStoreAttached() {
        let vm = IssueListViewModel()
        vm.applyLoaded([issue(1)])
        XCTAssertFalse(vm.isUnread(issue(1)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run via zcode. Expected: FAIL — `attachSeenStore`, `applyLoaded`, `isUnread`, `markSeen` are undefined.

- [ ] **Step 3: Add unread plumbing to the view model**

Append/modify in `AppFeedback/ViewModels/IssueListViewModel.swift`:

```swift
// Add new properties below existing ones
private var seenStore: SeenIssueStore?
private var seenOwner: String = ""
private var seenRepo: String = ""
private var sessionUnread: Set<Int> = []
private var previouslyLoadedNumbers: Set<Int> = []

func attachSeenStore(_ store: SeenIssueStore, owner: String, repo: String) {
    // Reset session state when switching repo context.
    if seenOwner != owner || seenRepo != repo {
        sessionUnread = []
        previouslyLoadedNumbers = []
    }
    self.seenStore = store
    self.seenOwner = owner
    self.seenRepo = repo
}

func applyLoaded(_ issues: [FeedbackIssue]) {
    let numbers = Set(issues.map(\.number))
    if let store = seenStore {
        // Flush the previous loaded set as "seen" before computing new unread.
        let toFlush = previouslyLoadedNumbers.subtracting(store.seenNumbers(owner: seenOwner, repo: seenRepo))
        if !toFlush.isEmpty {
            store.markSeenBulk(owner: seenOwner, repo: seenRepo, issueNumbers: Array(toFlush))
        }
        let alreadySeen = store.seenNumbers(owner: seenOwner, repo: seenRepo)
        sessionUnread = numbers.subtracting(alreadySeen)
    } else {
        sessionUnread = []
    }
    previouslyLoadedNumbers = numbers
}

func isUnread(_ issue: FeedbackIssue) -> Bool {
    sessionUnread.contains(issue.number)
}

func markSeen(_ issue: FeedbackIssue) {
    sessionUnread.remove(issue.number)
    seenStore?.markSeen(owner: seenOwner, repo: seenRepo, issueNumber: issue.number)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run via zcode. Expected: all four new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat(unread): track session unread set in IssueListViewModel"
```

---

### Task 6: Add blue dot + interaction hook to `IssueCardView`

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`

(UI only — verify visually rather than via XCTest. Run the app in zcode after build.)

- [ ] **Step 1: Add `isUnread` and `onInteract` parameters and render the dot**

In `IssueCardView`, add to the parameter list (after `appColor`):

```swift
var isUnread: Bool = false
var onInteract: (() -> Void)? = nil
```

Replace the `HStack(alignment: .top, spacing: 8)` row that contains `#\(issue.number)` and the title — change the leading content to include the dot:

```swift
HStack(alignment: .top, spacing: 8) {
    if isUnread {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .padding(.top, 6)
            .accessibilityLabel("Unread")
    }
    Text("#\(issue.number)")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    Text(issue.title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)
    Spacer(minLength: 8)
    Text(formattedDate)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
        .fixedSize()
}
```

- [ ] **Step 2: Wire `onInteract` into existing taps**

Wrap each existing closure to call `onInteract` first. Update the `tappable` helper at the bottom of the file:

```swift
@ViewBuilder
private func tappable<Content: View>(
    value: String,
    onTap: ((String) -> Void)?,
    @ViewBuilder content: () -> Content
) -> some View {
    if let onTap {
        Button {
            onInteract?()
            onTap(value)
        } label: { content() }
            .buttonStyle(.plain)
    } else {
        content()
    }
}
```

For the email tap: change

```swift
Button {
    onTapEmail(email)
} label: {
    MetaTagView(key: "✉", value: email, isActive: false)
}
```

to

```swift
Button {
    onInteract?()
    onTapEmail(email)
} label: {
    MetaTagView(key: "✉", value: email, isActive: false)
}
```

For the `Link` mailto branch (no callback path): leave the `Link` alone — the user has left the app, so dot dismissal there is best-effort. Add a `.simultaneousGesture(TapGesture().onEnded { onInteract?() })` modifier on the `Link` so the dot still clears.

- [ ] **Step 3: Add a card-surface tap that fires `onInteract`**

At the very end of `body` (after `.shadow(...)`), add:

```swift
.contentShape(Rectangle())
.onTapGesture { onInteract?() }
```

This catches taps on the title area / blank space without disturbing inner buttons.

- [ ] **Step 4: Build and run**

Use zcode to build. Expected: build succeeds. Visually verify the dot appears (we'll wire data in Task 7).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat(unread): blue dot + interaction hook on IssueCardView"
```

---

### Task 7: Wire it all up in `RootView` / `IssueListView`

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`
- Modify: `AppFeedback/App/RootView.swift`
- Modify: `AppFeedback/Views/Issues/IssueListView.swift`

- [ ] **Step 1: Build the stores in `AppFeedbackApp` and pass them down**

In `AppFeedbackApp`, just below the existing `_store = State(...)` line, add:

```swift
let cloudContext = ModelContext(container)
_seenStore = State(initialValue: SeenIssueStore(context: cloudContext))
let cacheContext = ModelContext(container)
_cacheContext = State(initialValue: cacheContext)
```

And declare the new states near the other `@State` properties:

```swift
@State private var seenStore: SeenIssueStore
@State private var cacheContext: ModelContext
```

In the `body`, pass them through to `RootView`:

```swift
RootView(store: store, seenStore: seenStore, cacheContext: cacheContext)
```

- [ ] **Step 2: Update `RootView` to inject loaders + attach VM to seen store**

In `AppFeedback/App/RootView.swift`, change the struct properties:

```swift
var store: RepoStore
var seenStore: SeenIssueStore
var cacheContext: ModelContext
```

Update `syncLoaders` to pass `cacheContext`:

```swift
private func syncLoaders(repos: [RepoConfig]) {
    var newlyAdded: [RepoConfig] = []
    for repo in repos where loaders[repo.id] == nil {
        loaders[repo.id] = IssueLoader(
            config: repo,
            activityLog: activityLog,
            cacheContext: cacheContext
        )
        newlyAdded.append(repo)
    }
    let ids = Set(repos.map(\.id))
    loaders = loaders.filter { ids.contains($0.key) }
    if !newlyAdded.isEmpty {
        Task { await loadRepos(newlyAdded) }
    }
}
```

Update `updateViewModel` to attach the seen store and apply the loaded set every time:

```swift
private func updateViewModel(for selection: SidebarSelection) {
    guard let loader = loaders[selection.repoId],
          case .loaded(let issues, _) = loader.state else { return }
    let owner = store.repos.first(where: { $0.id == selection.repoId })?.owner ?? ""
    let name  = store.repos.first(where: { $0.id == selection.repoId })?.repo  ?? ""
    viewModel.attachSeenStore(seenStore, owner: owner, repo: name)
    viewModel.applyLoaded(issues)
    viewModel.allIssues = issues
    viewModel.clearFilters()
    switch selection {
    case .allIssues:
        viewModel.appFilter = nil
        viewModel.allowsAppFilter = true
    case .app(_, let name):
        viewModel.appFilter = name
        viewModel.allowsAppFilter = false
    }
}
```

Add `import SwiftData` at the top.

- [ ] **Step 3: Pass `isUnread` / `onInteract` through `IssueListView`**

In `AppFeedback/Views/Issues/IssueListView.swift`, inside `issueCard(for:)`, both branches of `#if os(macOS)` / `#else`, add the new parameters:

```swift
IssueCardView(
    issue: issue,
    appColor: ColorPalette.color(for: issue.appName ?? "", in: allApps),
    isUnread: viewModel.isUnread(issue),
    onInteract: { viewModel.markSeen(issue) },
    activeApp: viewModel.appFilter,
    // ...rest unchanged
)
```

(For the macOS branch, leave the `onTapEmail` callback as-is — the markSeen is already covered by `onInteract` because the tappable helper / email button calls it via the wrapped Buttons in Task 6.)

- [ ] **Step 4: Build the project**

Use zcode to build. Expected: build succeeds for both macOS and iOS schemes.

- [ ] **Step 5: Run all tests**

Run via zcode. Expected: every test in the project PASSES (including all earlier task tests).

- [ ] **Step 6: Manual smoke test (macOS)**

Use zcode to launch the macOS app. Expected behavior:
- First launch on a never-seen repo: every issue shows a blue dot.
- Click any badge or email or the card surface → that card's dot disappears.
- Press the refresh button → the dot disappears for issues that were on the previous list (because `applyLoaded` flushed them); any newly-arrived issue from GitHub shows a fresh dot.
- Quit and relaunch: only issues newer than what was loaded last session show the dot.

If anything is wrong, debug and fix before committing. Note any UI issues observed.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift AppFeedback/App/RootView.swift AppFeedback/Views/Issues/IssueListView.swift
git commit -m "feat(unread): wire unread store + cache context through views"
```

---

## Self-review checklist (already applied)

- Spec coverage: container split (Task 3), CachedIssue (Task 1), SeenIssue + store (Task 2), IssueLoader migration (Task 4), VM unread state w/ next-load flush + immediate-on-interact (Task 5), card UI + interaction hooks (Task 6), wiring + iOS coverage via shared views (Task 7). All covered.
- No placeholders. Every code step shows the code.
- Method/property names consistent across tasks: `attachSeenStore`, `applyLoaded`, `isUnread`, `markSeen`, `cacheContext`, `seenStore`, `markSeenBulk`, `seenNumbers`.
- `IssueLoader` initializer ordering: `cacheContext` is the last parameter with a default, preserving call-site compatibility for tests that don't supply it; existing call sites in `RootView` are updated in Task 7 and tests are updated in Task 4.
