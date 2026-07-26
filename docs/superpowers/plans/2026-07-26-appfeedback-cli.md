# AppFeedback CLI + AI Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the AppFeedback app a macOS command-line interface — products, filtered/paginated feedback, tasks, task creation, feedback↔task linking, and replies — plus a skill that teaches an AI agent to drive it from another repo.

**Architecture:** The app binary *is* the CLI. `@main` moves onto a dispatcher that runs a subcommand and exits before SwiftUI is touched, so the CLI reads the app's SwiftData stores through the app's own `@Model` types. Reads open both stores read-only. Writes are delegated over a file-backed IPC channel to the running app, which executes the identical call its UI makes.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, XCTest, xcodegen, SwiftMail. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-07-26-appfeedback-cli-design.md`

## Global Constraints

- **Platform:** every CLI-only file is wrapped in `#if os(macOS)`. iOS deployment target is 18.6; macOS is 15.0. The iOS build must keep compiling — the two targets share one source set.
- **No new dependencies.** Argument parsing is hand-rolled. No swift-argument-parser.
- **Test framework:** XCTest, `@testable import AppFeedback`. Test target is **`AppFeedbackTests_macOS`** (not `AppFeedbackTests`).
- **Build/test command:** use the `zcode` skill for build/test. For ground truth on crashes use `xcodebuild` directly:
  `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/<TestClass>`
- **Pre-existing failures:** ~11 failures in `KeychainServicePerAccountTests` and `GitHubAccountStoreTests` are expected in the test host (no Keychain). They are **not** regressions — do not try to fix them.
- **xcodegen:** `project.yml` changes require re-running xcodegen. It globs untracked files into the pbxproj and **overwrites `.xcscheme` files** — check `git status` before running it.
- **Commit scoping:** the working tree may hold unrelated WIP. Stage only the files each task names; never `git add -A`.
- **Naming:** all user-visible names derive from `CLIBranding`. Never hard-code `"appfeedback"` anywhere else.
- **JSON contract:** dates are ISO8601 with fractional seconds off (`.withInternetDateTime`), keys are camelCase, output is pretty-printed with sorted keys so golden assertions are stable.
- **Exit codes:** 0 ok · 1 usage · 2 not found · 3 no local data · 4 auth · 5 remote failure · 6 app not running · 7 watchdog.

---

## File Structure

**New files:**

| File | Responsibility |
|---|---|
| `AppFeedback/App/AppFeedbackMain.swift` | `@main` dispatcher: CLI or GUI |
| `AppFeedback/CLI/CLIBranding.swift` | Command name, skill folder name, IPC prefix |
| `AppFeedback/CLI/CLIInvocation.swift` | Allowlist + argument grammar → typed `CLICommand` |
| `AppFeedback/CLI/CLIError.swift` | Typed errors + exit-code mapping |
| `AppFeedback/CLI/CLIStore.swift` | Read-only containers, existence guards, snapshot fallback |
| `AppFeedback/CLI/ProductResolver.swift` | `--product` → `ProductConfig` |
| `AppFeedback/CLI/TaskIndex.swift` | Cached tasks + reverse feedback→tasks index |
| `AppFeedback/CLI/FeedbackQuery.swift` | Filters, hidden apps, pagination |
| `AppFeedback/CLI/CLIDTO.swift` | `Codable` output shapes |
| `AppFeedback/CLI/CLIOutput.swift` | JSON encoder + `--text` renderer |
| `AppFeedback/CLI/CLIRunner.swift` | Dispatch, watchdog, exit |
| `AppFeedback/CLI/CLIIPCMessage.swift` | Request/response envelopes (shared by both sides) |
| `AppFeedback/CLI/CLIIPCTransport.swift` | File + DistributedNotificationCenter transport |
| `AppFeedback/CLI/CLIRequestClient.swift` | CLI side: send, wait, timeout |
| `AppFeedback/Services/CLIRequestResponder.swift` | App side: executes UI calls, replies |
| `AppFeedback/Services/CLIInstaller.swift` | Symlinks, status, Finder reveal |
| `AppFeedback/Views/Settings/CLISettingsView.swift` | Settings pane |
| `AppFeedback/Resources/Skill/appfeedback/SKILL.md` | The skill |

**Modified files:**

| File | Change |
|---|---|
| `AppFeedback/App/AppFeedbackApp.swift:32` | Drop `@main`; add responder wiring in `init` |
| `AppFeedback/Services/GitHubIssueWriter.swift` | Add `fetchIssue` to protocol + impl |
| `AppFeedback/Views/Settings/SettingsView.swift:8-18,106-119,138-166` | New `.cli` selection, sidebar row, detail case |
| `project.yml` | Skill folder as a resources build phase |

**New test files** (all in `AppFeedbackTests/`, which builds into `AppFeedbackTests_macOS`):
`CLIInvocationTests.swift`, `CLIStoreTests.swift`, `ProductResolverTests.swift`, `TaskIndexTests.swift`, `FeedbackQueryTests.swift`, `CLIOutputTests.swift`, `CLIIPCTests.swift`, `CLIWriteCommandTests.swift`, `CLIInstallerTests.swift`.

---

## Task 0: Spike — read-only SwiftData open beside the live app

**Everything downstream depends on this.** If a read-only `ModelContainer` cannot open a store the running GUI holds, the `VACUUM INTO` snapshot stops being a fallback and becomes the baseline read path.

**Files:**
- Create: `/private/tmp/claude-501/-Users-amir-Developer-AppFeedback/*/scratchpad/spike/main.swift` (throwaway, not committed)

- [ ] **Step 1: Confirm the app is running and the stores exist**

```bash
ls -la ~/Library/Application\ Support/{cloud,local}.store
pgrep -fl AppFeedback | head
```

Expected: both files present. If the app is not running, launch it — the spike must test the *contended* case.

- [ ] **Step 2: Write the spike**

Create a scratchpad Swift file and run it with `swift` directly. It reproduces exactly what `CLIStore` will do, using one small `@Model` that mirrors `CachedIssue`'s entity name and attributes — SwiftData matches on entity/attribute names, so this is enough to prove the open path.

```swift
import Foundation
import SwiftData

@Model final class CachedIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var number: Int = 0
    var title: String = ""
    init(repoOwner: String, repoName: String, number: Int, title: String) {
        self.repoOwner = repoOwner; self.repoName = repoName
        self.number = number; self.title = title
    }
}

let url = URL.applicationSupportDirectory.appending(path: "local.store")
let config = ModelConfiguration(schema: Schema([CachedIssue.self]), url: url,
                                allowsSave: false, cloudKitDatabase: .none)
let container = try ModelContainer(for: CachedIssue.self, configurations: config)
let context = ModelContext(container)
let rows = try context.fetch(FetchDescriptor<CachedIssue>())
print("rows: \(rows.count)")
print(rows.prefix(3).map(\.title))
```

- [ ] **Step 3: Run it while the app is running**

```bash
swift <scratchpad>/spike/main.swift
```

Expected: a non-zero row count and three titles. Record the outcome.

- [ ] **Step 4: Decide**

- **Success** → proceed with Task 3 as written; the snapshot path stays a fallback.
- **Failure** (schema-mismatch, locked, or read-only-recovery error) → record the exact error in the plan file under Task 3 and make `CLIStore` use `VACUUM INTO` unconditionally. Do not proceed until this is settled.

- [ ] **Step 5: Record the result**

Append the outcome to `docs/superpowers/plans/2026-07-26-appfeedback-cli.md` under this task, then commit the plan.

```bash
git add docs/superpowers/plans/2026-07-26-appfeedback-cli.md
git commit -m "docs(plans): record CLI store read-only spike result"
```

**Spike result (2026-07-26): PASSES, but only with the app's exact container shape.**

The standalone `swift main.swift` form was inconclusive — a partial model makes SwiftData
attempt an in-place migration (`NSMigratePersistentStoresAutomaticallyOption` is on by
default), which fails read-only with *"Cannot migrate store in-place: attempt to write a
readonly database"*. That error is about schema mismatch, not about read-only or contention.

The spike was therefore folded into Task 3 as `CLIStoreTests.testOpensTheLiveStoreReadOnly`,
which opens the real `~/Library/Application Support/{local,cloud}.store` and skips when absent.

First attempt failed the same way. **Root cause:** the app builds ONE container with TWO
*named* configurations (`"cloud"`, `"local"`) over the combined schema, and Core Data records
a store's compatibility against that whole model. Opening with a single unnamed configuration
holding only the six local entities reads as an incompatible model → migration → failure.

**Fix (already applied to Task 3's code):** reproduce the app's container exactly —
`ModelContainer(for: Schema(cloudTypes + localTypes), configurations: cloudConfig, localConfig)`
with both configurations named and `allowsSave: false, cloudKitDatabase: .none`. One context
serves both stores; Core Data routes each fetch to the owning store.

Verified: **541 cached issues, 3 products**, both with the app closed and with the GUI running
and holding the stores open. The `VACUUM INTO` snapshot stays a fallback, and its test now
reads the snapshot back through the same container shape.

---

## Task 1: CLIBranding + invocation grammar

**Files:**
- Create: `AppFeedback/CLI/CLIBranding.swift`
- Create: `AppFeedback/CLI/CLIInvocation.swift`
- Test: `AppFeedbackTests/CLIInvocationTests.swift`

**Interfaces:**
- Produces: `CLIBranding.commandName/skillFolderName/ipcPrefix`; `enum CLICommand`; `struct CLIFlags`; `CLIInvocation.parse(_ argv: [String]) -> Result<CLICommand, CLIUsageError>?` (nil ⇒ not a CLI invocation, run the GUI).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIInvocationTests: XCTestCase {

    private func parse(_ args: String...) -> Result<CLICommand, CLIUsageError>? {
        CLIInvocation.parse(["/path/to/AppFeedback"] + args)
    }

    // MARK: - Allowlist

    func testNoArgumentsIsNotCLI() {
        XCTAssertNil(CLIInvocation.parse(["/path/to/AppFeedback"]))
    }

    func testFinderProcessSerialNumberIsNotCLI() {
        XCTAssertNil(parse("-psn_0_123456"))
    }

    func testXcodeLaunchArgumentsAreNotCLI() {
        XCTAssertNil(parse("-NSDocumentRevisionsDebugMode", "YES"))
    }

    func testUnknownNounIsNotCLI() {
        XCTAssertNil(parse("frobnicate"))
    }

    func testKnownNounIsCLI() {
        XCTAssertNotNil(parse("products"))
    }

    func testHelpAndVersion() {
        guard case .success(.help(nil))? = parse("help") else { return XCTFail("help") }
        guard case .success(.help("feedback"))? = parse("help", "feedback") else { return XCTFail("help sub") }
        guard case .success(.version)? = parse("--version") else { return XCTFail("version") }
    }

    // MARK: - Bare noun defaults to list

    func testBareFeedbackNounMeansList() {
        guard case .success(.feedback(.list(let flags)))? = parse("feedback", "--product", "P")
        else { return XCTFail("expected list") }
        XCTAssertEqual(flags.product, "P")
    }

    func testExplicitListVerb() {
        guard case .success(.feedback(.list))? = parse("feedback", "list", "--product", "P")
        else { return XCTFail("expected list") }
    }

    func testFeedbackShowParsesNumber() {
        guard case .success(.feedback(.show(let number, let flags)))? =
                parse("feedback", "show", "559", "--product", "P")
        else { return XCTFail("expected show") }
        XCTAssertEqual(number, 559)
        XCTAssertEqual(flags.product, "P")
    }

    // MARK: - Defaults

    func testListDefaults() {
        guard case .success(.feedback(.list(let f)))? = parse("feedback", "--product", "P")
        else { return XCTFail() }
        XCTAssertEqual(f.limit, 20)
        XCTAssertEqual(f.offset, 0)
        XCTAssertEqual(f.state, .open)
        XCTAssertEqual(f.sort, .created)
        XCTAssertEqual(f.order, .desc)
        XCTAssertFalse(f.json == false)          // JSON is the default
        XCTAssertFalse(f.includeHidden)
        XCTAssertFalse(f.includeEmails)
        XCTAssertFalse(f.refresh)
    }

    // MARK: - Repeatable flags OR their values

    func testRepeatedAppFlagAccumulates() {
        guard case .success(.feedback(.list(let f)))? =
                parse("feedback", "--product", "P", "--app", "Zcode", "--app", "XcodeMini")
        else { return XCTFail() }
        XCTAssertEqual(f.apps, ["Zcode", "XcodeMini"])
    }

    func testRepeatedStatusOnTasksAccumulates() {
        guard case .success(.tasks(.list(let f)))? =
                parse("tasks", "--product", "P", "--status", "todo", "--status", "in-progress")
        else { return XCTFail() }
        XCTAssertEqual(f.statuses, [.todo, .inProgress])
    }

    // MARK: - Validation

    func testMissingRequiredProductIsUsageError() {
        guard case .failure(let error)? = parse("feedback") else { return XCTFail() }
        XCTAssertEqual(error.code, "missing_flag")
        XCTAssertTrue(error.message.contains("--product"))
    }

    func testUnknownFlagIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--nope") else { return XCTFail() }
        XCTAssertEqual(error.code, "unknown_flag")
    }

    func testBadEnumValueIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--state", "sideways")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "bad_value")
        XCTAssertTrue(error.message.contains("open"))   // lists the valid values
    }

    func testLimitAboveMaximumIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--limit", "500")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "bad_value")
    }

    func testHasTaskAndNoTaskTogetherIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--has-task", "--no-task")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "conflicting_flags")
    }

    func testFlagMissingItsValueIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product") else { return XCTFail() }
        XCTAssertEqual(error.code, "missing_value")
    }

    // MARK: - Date parsing

    func testRelativeSinceIsResolvedAgainstNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CLIInvocation.parseDate("7d", now: now),
                       now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(CLIInvocation.parseDate("24h", now: now),
                       now.addingTimeInterval(-24 * 3_600))
    }

    func testAbsoluteSinceIsUTCMidnight() {
        let parsed = CLIInvocation.parseDate("2026-07-01", now: Date())
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day, .hour], from: parsed!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 0)
    }

    func testGarbageDateIsNil() {
        XCTAssertNil(CLIInvocation.parseDate("last tuesday", now: Date()))
    }

    // MARK: - Branding is the single source of truth

    func testBrandingDrivesIPCNames() {
        XCTAssertTrue(CLIBranding.requestNotification.hasPrefix(CLIBranding.ipcPrefix))
        XCTAssertTrue(CLIBranding.responseNotification.hasPrefix(CLIBranding.ipcPrefix))
        XCTAssertNotEqual(CLIBranding.requestNotification, CLIBranding.responseNotification)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIInvocationTests`

Expected: compile failure — `CLIInvocation`, `CLICommand`, `CLIBranding` do not exist.

- [ ] **Step 3: Write `CLIBranding.swift`**

```swift
import Foundation

/// Single source of truth for every user-visible CLI name. The product name is
/// temporary — renaming later should touch this file and nothing else.
enum CLIBranding {
    static let commandName = "appfeedback"
    static let skillFolderName = "appfeedback"
    static let ipcPrefix = "com.amirhayek.AppFeedback.cli"
    static let bundleIdentifier = "com.amirhayek.AppFeedback"

    static var requestNotification: String { "\(ipcPrefix).request" }
    static var responseNotification: String { "\(ipcPrefix).response" }
}
```

- [ ] **Step 4: Write `CLIInvocation.swift`**

Note the shape: `parse` returns `nil` for "not a CLI invocation" and `.failure` for "a CLI invocation that is malformed" — those are different outcomes and the dispatcher treats them differently.

```swift
#if os(macOS)
import Foundation

struct CLIUsageError: Error, Equatable {
    let code: String        // missing_flag | unknown_flag | bad_value | missing_value | conflicting_flags
    let message: String
    var hint: String?
}

enum CLIState: String, CaseIterable { case open, closed, all }
enum CLISort: String, CaseIterable { case created, updated }
enum CLIOrder: String, CaseIterable { case desc, asc }
enum CLIChannel: String, CaseIterable { case auto, email, appStore = "app-store", comment }

struct CLIFlags {
    var product: String = ""
    var apps: [String] = []
    var labels: [String] = []
    var sources: [FeedbackSource] = []
    var types: [IssueType] = []
    var statuses: [TaskStatus] = []
    var priorities: [TaskPriority] = []
    var state: CLIState = .open
    var search: String?
    var since: Date?
    var updatedSince: Date?
    var minRating: Int?
    var maxRating: Int?
    var appVersion: String?
    var version: String?
    var hasTask: Bool?              // nil = no constraint
    var includeHidden = false
    var includeEmails = false
    var raw = false
    var refresh = false
    var json = true
    var limit = 20
    var offset = 0
    var sort: CLISort = .created
    var order: CLIOrder = .desc
    var timeout: TimeInterval = 30

    // Write-command payload
    var title: String?
    var notes: String?
    var body: String?
    var template: String?
    var channel: CLIChannel = .auto
    var taskNumber: Int?
    var feedbackNumbers: [Int] = []
}

enum CLIFeedbackVerb { case list(CLIFlags), show(Int, CLIFlags) }
enum CLITaskVerb {
    case list(CLIFlags), show(Int, CLIFlags)
    case create(CLIFlags), link(CLIFlags), unlink(CLIFlags)
}

enum CLICommand {
    case products(CLIFlags)
    case feedback(CLIFeedbackVerb)
    case tasks(CLITaskVerb)
    case respond(CLIFlags)
    case help(String?)
    case version
}

enum CLIInvocation {
    static let maxLimit = 200
    private static let nouns: Set<String> = ["products", "feedback", "tasks", "respond"]

    /// nil ⇒ not a CLI invocation (run the GUI). Never throws on GUI argv.
    static func parse(_ argv: [String], now: Date = Date()) -> Result<CLICommand, CLIUsageError>? {
        let args = Array(argv.dropFirst())
        guard let first = args.first else { return nil }

        if first == "--version" || first == "version" { return .success(.version) }
        if first == "--help" || first == "-h" || first == "help" {
            return .success(.help(args.count > 1 ? args[1] : nil))
        }
        guard nouns.contains(first) else { return nil }

        let rest = Array(args.dropFirst())
        switch first {
        case "products":
            return parseFlags(rest, now: now).flatMap { .success(.products($0)) }

        case "feedback":
            return parseVerb(rest, verbs: ["list", "show"], now: now) { verb, number, flags in
                switch verb {
                case "show":
                    guard let number else {
                        return .failure(CLIUsageError(code: "missing_value",
                            message: "feedback show needs an issue number"))
                    }
                    return requireProduct(flags).map { .feedback(.show(number, $0)) }
                default:
                    return requireProduct(flags).map { .feedback(.list($0)) }
                }
            }

        case "tasks":
            return parseVerb(rest, verbs: ["list", "show", "create", "link", "unlink"], now: now) { verb, number, flags in
                switch verb {
                case "show":
                    guard let number else {
                        return .failure(CLIUsageError(code: "missing_value",
                            message: "tasks show needs a task number"))
                    }
                    return requireProduct(flags).map { .tasks(.show(number, $0)) }
                case "create":
                    return requireProduct(flags).flatMap { f in
                        guard f.title?.isEmpty == false else {
                            return .failure(CLIUsageError(code: "missing_flag",
                                message: "tasks create requires --title"))
                        }
                        return .success(.tasks(.create(f)))
                    }
                case "link", "unlink":
                    return requireProduct(flags).flatMap { f in
                        guard f.taskNumber != nil else {
                            return .failure(CLIUsageError(code: "missing_flag",
                                message: "tasks \(verb) requires --task"))
                        }
                        guard !f.feedbackNumbers.isEmpty else {
                            return .failure(CLIUsageError(code: "missing_flag",
                                message: "tasks \(verb) requires --feedback"))
                        }
                        return .success(.tasks(verb == "link" ? .link(f) : .unlink(f)))
                    }
                default:
                    return requireProduct(flags).map { .tasks(.list($0)) }
                }
            }

        case "respond":
            return parseFlags(rest, now: now).flatMap { f in
                guard f.feedbackNumbers.count == 1 else {
                    return .failure(CLIUsageError(code: "missing_flag",
                        message: "respond requires exactly one --feedback <number>"))
                }
                guard f.body?.isEmpty == false || f.template?.isEmpty == false else {
                    return .failure(CLIUsageError(code: "missing_flag",
                        message: "respond requires --body or --template"))
                }
                return requireProduct(f).map { .respond($0) }
            }

        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func requireProduct(_ flags: CLIFlags) -> Result<CLIFlags, CLIUsageError> {
        flags.product.isEmpty
            ? .failure(CLIUsageError(code: "missing_flag", message: "--product is required",
                                     hint: "run `\(CLIBranding.commandName) products` to list them"))
            : .success(flags)
    }

    private static func parseVerb(
        _ args: [String], verbs: Set<String>, now: Date,
        build: (String, Int?, CLIFlags) -> Result<CLICommand, CLIUsageError>
    ) -> Result<CLICommand, CLIUsageError> {
        var verb = "list"
        var number: Int?
        var rest = args
        if let first = rest.first, verbs.contains(first) {
            verb = first
            rest = Array(rest.dropFirst())
            if let candidate = rest.first, let parsed = Int(candidate) {
                number = parsed
                rest = Array(rest.dropFirst())
            }
        }
        return parseFlags(rest, now: now).flatMap { build(verb, number, $0) }
    }

    /// `7d`/`24h` relative to `now`; `YYYY-MM-DD` as UTC midnight; full ISO8601.
    static func parseDate(_ raw: String, now: Date) -> Date? {
        if let unit = raw.last, "dh".contains(unit), let value = Double(raw.dropLast()) {
            return now.addingTimeInterval(-value * (unit == "d" ? 86_400 : 3_600))
        }
        if raw.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: raw) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func parseFlags(_ args: [String], now: Date) -> Result<CLIFlags, CLIUsageError> {
        var flags = CLIFlags()
        var hasTaskSeen = false, noTaskSeen = false
        var index = 0

        func value(_ name: String) -> Result<String, CLIUsageError> {
            index += 1
            guard index < args.count else {
                return .failure(CLIUsageError(code: "missing_value", message: "\(name) needs a value"))
            }
            return .success(args[index])
        }
        func bad(_ name: String, _ raw: String, _ valid: [String]) -> CLIUsageError {
            CLIUsageError(code: "bad_value",
                          message: "\(name): '\(raw)' is not valid. Use one of: \(valid.joined(separator: ", "))")
        }

        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("--") else {
                return .failure(CLIUsageError(code: "unknown_flag", message: "unexpected argument '\(arg)'"))
            }
            switch arg {
            case "--product":   switch value(arg) { case .success(let v): flags.product = v; case .failure(let e): return .failure(e) }
            case "--app":       switch value(arg) { case .success(let v): flags.apps.append(v); case .failure(let e): return .failure(e) }
            case "--label":     switch value(arg) { case .success(let v): flags.labels.append(v); case .failure(let e): return .failure(e) }
            case "--search":    switch value(arg) { case .success(let v): flags.search = v; case .failure(let e): return .failure(e) }
            case "--title":     switch value(arg) { case .success(let v): flags.title = v; case .failure(let e): return .failure(e) }
            case "--notes":     switch value(arg) { case .success(let v): flags.notes = v; case .failure(let e): return .failure(e) }
            case "--body":      switch value(arg) { case .success(let v): flags.body = v; case .failure(let e): return .failure(e) }
            case "--template":  switch value(arg) { case .success(let v): flags.template = v; case .failure(let e): return .failure(e) }
            case "--version":   switch value(arg) { case .success(let v): flags.version = v; case .failure(let e): return .failure(e) }
            case "--app-version": switch value(arg) { case .success(let v): flags.appVersion = v; case .failure(let e): return .failure(e) }

            case "--source":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = FeedbackSource(rawValue: v) else {
                        return .failure(bad(arg, v, FeedbackSource.allCases.map(\.rawValue)))
                    }
                    flags.sources.append(parsed)
                case .failure(let e): return .failure(e)
                }
            case "--type":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = IssueType(rawValue: v) else {
                        return .failure(bad(arg, v, ["bug", "feature-request"]))
                    }
                    flags.types.append(parsed)
                case .failure(let e): return .failure(e)
                }
            case "--status":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = TaskStatus(rawValue: v) else {
                        return .failure(bad(arg, v, TaskStatus.allCases.map(\.rawValue)))
                    }
                    flags.statuses.append(parsed)
                case .failure(let e): return .failure(e)
                }
            case "--priority":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = TaskPriority(rawValue: v) else {
                        return .failure(bad(arg, v, TaskPriority.allCases.map(\.rawValue)))
                    }
                    flags.priorities.append(parsed)
                case .failure(let e): return .failure(e)
                }
            case "--state":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = CLIState(rawValue: v) else {
                        return .failure(bad(arg, v, CLIState.allCases.map(\.rawValue)))
                    }
                    flags.state = parsed
                case .failure(let e): return .failure(e)
                }
            case "--sort":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = CLISort(rawValue: v) else {
                        return .failure(bad(arg, v, CLISort.allCases.map(\.rawValue)))
                    }
                    flags.sort = parsed
                case .failure(let e): return .failure(e)
                }
            case "--order":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = CLIOrder(rawValue: v) else {
                        return .failure(bad(arg, v, CLIOrder.allCases.map(\.rawValue)))
                    }
                    flags.order = parsed
                case .failure(let e): return .failure(e)
                }
            case "--via":
                switch value(arg) {
                case .success(let v):
                    guard let parsed = CLIChannel(rawValue: v) else {
                        return .failure(bad(arg, v, CLIChannel.allCases.map(\.rawValue)))
                    }
                    flags.channel = parsed
                case .failure(let e): return .failure(e)
                }

            case "--since", "--updated-since":
                switch value(arg) {
                case .success(let v):
                    guard let date = parseDate(v, now: now) else {
                        return .failure(CLIUsageError(code: "bad_value",
                            message: "\(arg): '\(v)' is not a date. Use 7d, 24h, YYYY-MM-DD or ISO8601"))
                    }
                    if arg == "--since" { flags.since = date } else { flags.updatedSince = date }
                case .failure(let e): return .failure(e)
                }

            case "--min-rating", "--max-rating":
                switch value(arg) {
                case .success(let v):
                    guard let rating = Int(v), (1...5).contains(rating) else {
                        return .failure(CLIUsageError(code: "bad_value", message: "\(arg) must be 1-5"))
                    }
                    if arg == "--min-rating" { flags.minRating = rating } else { flags.maxRating = rating }
                case .failure(let e): return .failure(e)
                }

            case "--limit":
                switch value(arg) {
                case .success(let v):
                    guard let limit = Int(v), limit > 0 else {
                        return .failure(CLIUsageError(code: "bad_value", message: "--limit must be a positive integer"))
                    }
                    guard limit <= maxLimit else {
                        return .failure(CLIUsageError(code: "bad_value",
                            message: "--limit maximum is \(maxLimit)",
                            hint: "page with --offset instead"))
                    }
                    flags.limit = limit
                case .failure(let e): return .failure(e)
                }
            case "--offset":
                switch value(arg) {
                case .success(let v):
                    guard let offset = Int(v), offset >= 0 else {
                        return .failure(CLIUsageError(code: "bad_value", message: "--offset must be >= 0"))
                    }
                    flags.offset = offset
                case .failure(let e): return .failure(e)
                }
            case "--timeout":
                switch value(arg) {
                case .success(let v):
                    guard let seconds = Double(v), seconds > 0 else {
                        return .failure(CLIUsageError(code: "bad_value", message: "--timeout must be > 0"))
                    }
                    flags.timeout = seconds
                case .failure(let e): return .failure(e)
                }
            case "--task":
                switch value(arg) {
                case .success(let v):
                    guard let number = Int(v) else {
                        return .failure(CLIUsageError(code: "bad_value", message: "--task must be a number"))
                    }
                    flags.taskNumber = number
                case .failure(let e): return .failure(e)
                }
            case "--feedback":
                switch value(arg) {
                case .success(let v):
                    let parts = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let numbers = parts.compactMap { Int($0.hasPrefix("#") ? String($0.dropFirst()) : $0) }
                    guard numbers.count == parts.count, !numbers.isEmpty else {
                        return .failure(CLIUsageError(code: "bad_value",
                            message: "--feedback takes comma-separated issue numbers, e.g. 12,34"))
                    }
                    flags.feedbackNumbers.append(contentsOf: numbers)
                case .failure(let e): return .failure(e)
                }

            case "--has-task":       hasTaskSeen = true; flags.hasTask = true
            case "--no-task":        noTaskSeen = true;  flags.hasTask = false
            case "--include-hidden": flags.includeHidden = true
            case "--include-emails": flags.includeEmails = true
            case "--raw":            flags.raw = true
            case "--refresh":        flags.refresh = true
            case "--json":           flags.json = true
            case "--text":           flags.json = false

            default:
                return .failure(CLIUsageError(code: "unknown_flag", message: "unknown flag '\(arg)'",
                                              hint: "run `\(CLIBranding.commandName) help` for the full list"))
            }
            index += 1
        }

        if hasTaskSeen && noTaskSeen {
            return .failure(CLIUsageError(code: "conflicting_flags",
                                          message: "--has-task and --no-task are mutually exclusive"))
        }
        if let low = flags.minRating, let high = flags.maxRating, low > high {
            return .failure(CLIUsageError(code: "bad_value",
                                          message: "--min-rating cannot exceed --max-rating"))
        }
        return .success(flags)
    }
}
#endif
```

- [ ] **Step 5: Add the files to the project and run the tests**

```bash
xcodegen generate && git status --short   # confirm no .xcscheme churn
```

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIInvocationTests`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/CLI/CLIBranding.swift AppFeedback/CLI/CLIInvocation.swift \
        AppFeedbackTests/CLIInvocationTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): add branding constants and invocation grammar"
```

---

## Task 2: Entry-point dispatch, `version` and `help`

**Files:**
- Create: `AppFeedback/App/AppFeedbackMain.swift`
- Create: `AppFeedback/CLI/CLIError.swift`
- Create: `AppFeedback/CLI/CLIRunner.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift:31-32` (remove `@main`)
- Test: `AppFeedbackTests/CLIInvocationTests.swift` (extend)

**Interfaces:**
- Consumes: `CLICommand`, `CLIUsageError`, `CLIBranding`.
- Produces: `CLIExitCode` (`Int32` raw values), `CLIError`, `CLIRunner.run(_ command: CLICommand) async -> Int32`, `CLIRunner.helpText(for:)`.

- [ ] **Step 1: Write the failing test**

Append to `CLIInvocationTests.swift`:

```swift
#if os(macOS)
final class CLIExitCodeTests: XCTestCase {

    func testExitCodesMatchTheContract() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 1)
        XCTAssertEqual(CLIExitCode.notFound.rawValue, 2)
        XCTAssertEqual(CLIExitCode.noLocalData.rawValue, 3)
        XCTAssertEqual(CLIExitCode.auth.rawValue, 4)
        XCTAssertEqual(CLIExitCode.remote.rawValue, 5)
        XCTAssertEqual(CLIExitCode.appNotRunning.rawValue, 6)
        XCTAssertEqual(CLIExitCode.watchdog.rawValue, 7)
    }

    func testUsageErrorMapsToUsageExit() {
        let error = CLIError.usage(CLIUsageError(code: "unknown_flag", message: "nope"))
        XCTAssertEqual(error.exitCode, .usage)
        XCTAssertEqual(error.code, "unknown_flag")
    }

    func testHelpTextNamesEveryCommand() {
        let text = CLIRunner.helpText(for: nil)
        for noun in ["products", "feedback", "tasks", "respond"] {
            XCTAssertTrue(text.contains(noun), "help should mention \(noun)")
        }
        XCTAssertTrue(text.contains(CLIBranding.commandName))
    }

    func testPerCommandHelpIsSpecific() {
        let text = CLIRunner.helpText(for: "feedback")
        XCTAssertTrue(text.contains("--app"))
        XCTAssertTrue(text.contains("--state"))
        XCTAssertFalse(text.contains("--title"))   // that's a tasks flag
    }

    func testUnknownHelpTopicFallsBackToGeneralHelp() {
        XCTAssertEqual(CLIRunner.helpText(for: "frobnicate"), CLIRunner.helpText(for: nil))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIExitCodeTests`

Expected: compile failure — `CLIExitCode`, `CLIError`, `CLIRunner` do not exist.

- [ ] **Step 3: Write `CLIError.swift`**

```swift
#if os(macOS)
import Foundation

enum CLIExitCode: Int32 {
    case success = 0
    case usage = 1
    case notFound = 2
    case noLocalData = 3
    case auth = 4
    case remote = 5
    case appNotRunning = 6
    case watchdog = 7
}

enum CLIError: Error {
    case usage(CLIUsageError)
    case notFound(code: String, message: String, hint: String? = nil, candidates: [String] = [])
    case noLocalData(message: String, hint: String?)
    case auth(message: String, hint: String?)
    case remote(message: String, hint: String? = nil)
    case appNotRunning

    var exitCode: CLIExitCode {
        switch self {
        case .usage:         return .usage
        case .notFound:      return .notFound
        case .noLocalData:   return .noLocalData
        case .auth:          return .auth
        case .remote:        return .remote
        case .appNotRunning: return .appNotRunning
        }
    }

    var code: String {
        switch self {
        case .usage(let error):      return error.code
        case .notFound(let code, _, _, _): return code
        case .noLocalData:           return "no_local_data"
        case .auth:                  return "auth"
        case .remote:                return "remote_failure"
        case .appNotRunning:         return "app_not_running"
        }
    }

    var message: String {
        switch self {
        case .usage(let error):            return error.message
        case .notFound(_, let message, _, _): return message
        case .noLocalData(let message, _): return message
        case .auth(let message, _):        return message
        case .remote(let message, _):      return message
        case .appNotRunning:
            return "AppFeedback is not running. Writes and --refresh need the app open."
        }
    }

    var hint: String? {
        switch self {
        case .usage(let error):          return error.hint
        case .notFound(_, _, let hint, _): return hint
        case .noLocalData(_, let hint):  return hint
        case .auth(_, let hint):         return hint
        case .remote(_, let hint):       return hint
        case .appNotRunning:             return "Open AppFeedback, then re-run."
        }
    }

    var candidates: [String] {
        if case .notFound(_, _, _, let candidates) = self { return candidates }
        return []
    }
}
#endif
```

- [ ] **Step 4: Write `CLIRunner.swift` with help, version, and the watchdog**

Commands beyond `help`/`version` return a "not implemented yet" remote error; later tasks replace each branch.

```swift
#if os(macOS)
import Foundation

enum CLIRunner {
    static let watchdogSeconds: TimeInterval = 60

    /// Entry point from the dispatcher. Never returns.
    static func run(invocation: Result<CLICommand, CLIUsageError>) -> Never {
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: watchdogSeconds)
            FileHandle.standardError.write(Data("\(CLIBranding.commandName): timed out\n".utf8))
            exit(CLIExitCode.watchdog.rawValue)
        }
        watchdog.stackSize = 1 << 16
        watchdog.start()

        Task {
            let code: Int32
            switch invocation {
            case .failure(let usage):
                code = emit(error: .usage(usage))
            case .success(let command):
                code = await execute(command)
            }
            exit(code)
        }
        RunLoop.main.run()   // services CFRunLoop sources (IPC replies) AND the main queue
        fatalError("unreachable")
    }

    static func execute(_ command: CLICommand) async -> Int32 {
        switch command {
        case .version:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            print("\(CLIBranding.commandName) \(version) (\(build))")
            return CLIExitCode.success.rawValue
        case .help(let topic):
            print(helpText(for: topic))
            return CLIExitCode.success.rawValue
        default:
            return emit(error: .remote(message: "not implemented yet"))
        }
    }

    /// Prints the JSON error to stdout and a one-liner to stderr. Returns the exit code.
    static func emit(error: CLIError) -> Int32 {
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        if let hint = error.hint { payload["hint"] = hint }
        if !error.candidates.isEmpty { payload["candidates"] = error.candidates }
        let wrapper: [String: Any] = ["error": payload]
        if let data = try? JSONSerialization.data(withJSONObject: wrapper,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        FileHandle.standardError.write(Data("\(CLIBranding.commandName): \(error.message)\n".utf8))
        return error.exitCode.rawValue
    }

    static func helpText(for topic: String?) -> String {
        let name = CLIBranding.commandName
        switch topic {
        case "feedback":
            return """
            \(name) feedback [list] --product <p> [filters]
            \(name) feedback show <number> --product <p> [--raw]

            Filters:
              --app <name>          repeatable; ORs together
              --state open|closed|all      default: open
              --source sdk|app-store|email
              --type bug|feature-request
              --label <name>        repeatable, exact match
              --search <text>       title, description, app name
              --since 7d|YYYY-MM-DD --updated-since ...
              --min-rating N --max-rating N     inclusive, 1-5
              --app-version <v>
              --has-task | --no-task
              --include-hidden      include apps hidden in the app
              --include-emails      unredacted reporter addresses
              --sort created|updated  --order desc|asc
              --limit N (<=200, default 20)  --offset N
              --refresh             ask the running app to poll GitHub first
              --text                human table (JSON is the default)
            """
        case "tasks":
            return """
            \(name) tasks [list] --product <p> [--status ...] [--priority ...] [--version <v>] [--search <t>]
            \(name) tasks show <number> --product <p>
            \(name) tasks create --product <p> --title <t> [--notes <n>] [--status todo|in-progress|done]
                                 [--priority low|med|high] [--version <v>] [--feedback 12,34]
            \(name) tasks link   --product <p> --task <n> --feedback 12,34
            \(name) tasks unlink --product <p> --task <n> --feedback 12

            create/link/unlink write to GitHub and need AppFeedback running.
            """
        case "respond":
            return """
            \(name) respond --product <p> --feedback <n> --body <text>
                            [--template <title>] [--via auto|email|app-store|comment]

            Sends immediately. Show the drafted reply to the user and get explicit
            agreement first. Needs AppFeedback running.
            """
        case "products":
            return """
            \(name) products [--refresh] [--text]

            Lists products with their feedback repo, connected code repo, app names,
            versions, counts and last-fetch time.
            """
        default:
            return """
            \(name) — read and act on app feedback

            Commands:
              products                    list products and what you can filter by
              feedback [list|show]        read feedback
              tasks [list|show|create|link|unlink]   read and write tasks
              respond                     reply to a feedback item
              help [<command>]            detailed help
              version

            Output is JSON on stdout by default; --text renders a human table.
            Start with `\(name) products` — every other command needs --product.
            """
        }
    }
}
#endif
```

- [ ] **Step 5: Write the dispatcher and remove `@main` from the app**

Create `AppFeedback/App/AppFeedbackMain.swift`:

```swift
import SwiftUI

/// Process entry point. On macOS a recognised subcommand runs the CLI and exits
/// before SwiftUI is touched; everything else — including Finder's `-psn_*` and
/// Xcode's launch arguments — falls through to the GUI.
@main
enum AppFeedbackMain {
    static func main() {
        #if os(macOS)
        // XCTest drives this binary with its own argv. Check before anything else so a
        // test argument shaped like a subcommand can never divert into the CLI.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let invocation = CLIInvocation.parse(CommandLine.arguments) {
            CLIRunner.run(invocation: invocation)
        }
        #endif
        AppFeedbackApp.main()
    }
}
```

Then in `AppFeedback/App/AppFeedbackApp.swift`, delete the `@main` attribute on line 31 so the struct declaration reads:

```swift
struct AppFeedbackApp: App {
```

- [ ] **Step 6: Run the tests and verify the GUI still launches**

```bash
xcodegen generate
xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIExitCodeTests
xcodebuild build -project AppFeedback.xcodeproj -scheme AppFeedback_iOS -destination 'generic/platform=iOS'
```

Expected: tests PASS, and the iOS build succeeds (proving the dispatcher compiles without the CLI internals).

- [ ] **Step 7: Verify the binary end to end**

```bash
APP=$(xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
"$APP/AppFeedback.app/Contents/MacOS/AppFeedback" version
"$APP/AppFeedback.app/Contents/MacOS/AppFeedback" help feedback
"$APP/AppFeedback.app/Contents/MacOS/AppFeedback" feedback ; echo "exit=$?"
```

Expected: version prints, help prints the feedback flags, and the third command prints a JSON `missing_flag` error with `exit=1`. Then double-click the app in Finder and confirm the GUI still opens normally.

- [ ] **Step 8: Commit**

```bash
git add AppFeedback/App/AppFeedbackMain.swift AppFeedback/App/AppFeedbackApp.swift \
        AppFeedback/CLI/CLIError.swift AppFeedback/CLI/CLIRunner.swift \
        AppFeedbackTests/CLIInvocationTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): dispatch subcommands from the app binary with help and version"
```

---

## Task 3: Read-only store access

**Files:**
- Create: `AppFeedback/CLI/CLIStore.swift`
- Test: `AppFeedbackTests/CLIStoreTests.swift`

**Interfaces:**
- Consumes: `CLIError`.
- Produces: `CLIStore.Paths` (`local`, `cloud` URLs), `CLIStore.open(paths:) throws -> CLIStore`, and on the instance `local: ModelContext`, `cloud: ModelContext`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class CLIStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "clistore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var paths: CLIStore.Paths {
        CLIStore.Paths(local: directory.appending(path: "local.store"),
                       cloud: directory.appending(path: "cloud.store"))
    }

    /// Writes one CachedIssue and one Product using read-write containers, then closes them.
    private func seedStores() throws {
        let localConfig = ModelConfiguration(schema: Schema(CLIStore.localTypes),
                                             url: paths.local, cloudKitDatabase: .none)
        let localContainer = try ModelContainer(for: CLIStore.localSchema, configurations: localConfig)
        let localContext = ModelContext(localContainer)
        localContext.insert(CachedIssue(repoOwner: "o", repoName: "r", number: 1, title: "Seeded",
                                        createdAt: Date(), rawBody: "b", appName: "A", appVersion: nil,
                                        device: nil, osVersion: nil, email: nil, issueDescription: "d"))
        try localContext.save()

        let cloudConfig = ModelConfiguration(schema: Schema(CLIStore.cloudTypes),
                                             url: paths.cloud, cloudKitDatabase: .none)
        let cloudContainer = try ModelContainer(for: CLIStore.cloudSchema, configurations: cloudConfig)
        let cloudContext = ModelContext(cloudContainer)
        cloudContext.insert(Product(displayName: "Seeded Product", owner: "o", repo: "r"))
        try cloudContext.save()
    }

    func testOpensBothStoresAndReads() throws {
        try seedStores()
        let store = try CLIStore.open(paths: paths)
        let issues = try store.local.fetch(FetchDescriptor<CachedIssue>())
        let products = try store.cloud.fetch(FetchDescriptor<Product>())
        XCTAssertEqual(issues.map(\.title), ["Seeded"])
        XCTAssertEqual(products.map(\.displayName), ["Seeded Product"])
    }

    func testOpenedStoreRejectsWrites() throws {
        try seedStores()
        let store = try CLIStore.open(paths: paths)
        store.local.insert(CachedIssue(repoOwner: "o", repoName: "r", number: 2, title: "Nope",
                                       createdAt: Date(), rawBody: "", appName: nil, appVersion: nil,
                                       device: nil, osVersion: nil, email: nil, issueDescription: ""))
        XCTAssertThrowsError(try store.local.save(), "allowsSave:false must reject saves")
    }

    func testMissingStoreThrowsNoLocalDataAndCreatesNothing() {
        XCTAssertThrowsError(try CLIStore.open(paths: paths)) { error in
            guard let cliError = error as? CLIError, case .noLocalData = cliError else {
                return XCTFail("expected .noLocalData, got \(error)")
            }
        }
        // The failed open must not have created a store file — that would mask the condition.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.local.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cloud.path))
    }

    func testCorruptStoreThrowsNoLocalDataRatherThanCrashing() throws {
        try Data("not a database".utf8).write(to: paths.local)
        try Data("not a database".utf8).write(to: paths.cloud)
        XCTAssertThrowsError(try CLIStore.open(paths: paths)) { error in
            guard let cliError = error as? CLIError, case .noLocalData = cliError else {
                return XCTFail("expected .noLocalData, got \(error)")
            }
        }
    }

    func testSnapshotFallbackProducesAReadableCopy() throws {
        try seedStores()
        let snapshot = try CLIStore.snapshot(of: paths.local, into: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let config = ModelConfiguration(schema: Schema(CLIStore.localTypes), url: snapshot,
                                        allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: CLIStore.localSchema, configurations: config)
        let rows = try ModelContext(container).fetch(FetchDescriptor<CachedIssue>())
        XCTAssertEqual(rows.map(\.title), ["Seeded"])
    }

    func testDefaultPathsPointAtApplicationSupport() {
        let defaults = CLIStore.Paths.default
        XCTAssertEqual(defaults.local.lastPathComponent, "local.store")
        XCTAssertEqual(defaults.cloud.lastPathComponent, "cloud.store")
        XCTAssertTrue(defaults.local.path.contains("Application Support"))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIStoreTests`

Expected: compile failure — `CLIStore` does not exist.

- [ ] **Step 3: Write `CLIStore.swift`**

The schema lists mirror `AppFeedbackApp.swift:98-105` exactly. If they drift, SwiftData refuses to open the store — which is the desired loud failure, mapped to exit 3.

```swift
#if os(macOS)
import Foundation
import SwiftData
import SQLite3

/// Read-only access to the app's two SwiftData stores. Deliberately does NOT reuse
/// ProductStore/HiddenAppStore: those write on read (ProductStore.reload calls
/// HiddenAppStore.migrateLegacy), which an allowsSave:false container rejects.
struct CLIStore {

    struct Paths {
        let local: URL
        let cloud: URL

        static var `default`: Paths {
            let base = URL.applicationSupportDirectory
            return Paths(local: base.appending(path: "local.store"),
                         cloud: base.appending(path: "cloud.store"))
        }
    }

    let local: ModelContext
    let cloud: ModelContext

    // Mirrors the split in AppFeedbackApp.init.
    static let localTypes: [any PersistentModel.Type] = [
        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
        RepoFetchState.self, FeedbackAttachmentLocal.self, TriageVerdictRecord.self,
    ]
    static let cloudTypes: [any PersistentModel.Type] = [
        Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
        GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self,
        MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self,
        ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self,
        RepoFilterPreference.self, AppStoreReviewMirror.self,
    ]
    static var localSchema: Schema { Schema(localTypes) }
    static var cloudSchema: Schema { Schema(cloudTypes) }

    static func open(paths: Paths = .default) throws -> CLIStore {
        // Existence check first: a ModelContainer pointed at a missing file CREATES one,
        // which is a write and would mask the "app never launched" condition.
        for url in [paths.local, paths.cloud] where !FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.noLocalData(
                message: "No local feedback data at \(url.path).",
                hint: "Launch AppFeedback once so it can sync, then re-run.")
        }
        do {
            return CLIStore(
                local: ModelContext(try container(schema: localSchema, types: localTypes, url: paths.local)),
                cloud: ModelContext(try container(schema: cloudSchema, types: cloudTypes, url: paths.cloud)))
        } catch {
            throw CLIError.noLocalData(
                message: "Could not read the local store: \(error.localizedDescription)",
                hint: "This usually means the CLI and the installed app were built from different schemas. Rebuild or reinstall the app.")
        }
    }

    private static func container(schema: Schema, types: [any PersistentModel.Type], url: URL) throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Consistent point-in-time copy via SQLite's VACUUM INTO. Copying .store/-wal/-shm by
    /// hand is not atomic against a live writer; this is.
    static func snapshot(of source: URL, into directory: URL) throws -> URL {
        let destination = directory.appending(path: "snapshot-\(UUID().uuidString).store")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw CLIError.noLocalData(message: "Could not open \(source.lastPathComponent) for snapshot.",
                                       hint: nil)
        }
        defer { sqlite3_close(handle) }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(handle, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw CLIError.noLocalData(message: "Snapshot failed: \(message)", hint: nil)
        }
        return destination
    }
}
#endif
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIStoreTests`

Expected: all PASS. If `testOpenedStoreRejectsWrites` fails because SwiftData silently ignores the save instead of throwing, change the assertion to verify the row count in a freshly opened container is still 1 — the guarantee that matters is that nothing is persisted.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/CLI/CLIStore.swift AppFeedbackTests/CLIStoreTests.swift \
        AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): open the app's stores read-only with a VACUUM INTO fallback"
```

---

## Task 4: Product resolution and the `products` command

**Files:**
- Create: `AppFeedback/CLI/ProductResolver.swift`
- Create: `AppFeedback/CLI/CLIDTO.swift`
- Create: `AppFeedback/CLI/CLIOutput.swift`
- Modify: `AppFeedback/CLI/CLIRunner.swift` (wire the `products` branch)
- Test: `AppFeedbackTests/ProductResolverTests.swift`

**Interfaces:**
- Consumes: `CLIStore`, `CLIError`, `CLIFlags`.
- Produces: `ProductResolver.all(store:) throws -> [ProductSummary]`, `ProductResolver.resolve(_ query: String, store:) throws -> ProductConfig`, `struct ProductSummary`, `CLIOutput.encode<T: Encodable>(_:) -> String`, `CLIOutput.iso8601`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class ProductResolverTests: XCTestCase {

    private var container: ModelContainer!
    private var cloud: ModelContext!
    private var local: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: Product.self, HiddenApp.self, ProjectVersion.self,
                CachedIssue.self, RepoFetchState.self, TriageVerdictRecord.self,
            configurations: config)
        cloud = ModelContext(container)
        local = cloud            // one in-memory container stands in for both stores
    }

    private func makeProduct(_ name: String, owner: String = "o", repo: String = "r",
                             connected: (String, String)? = nil) -> Product {
        let product = Product(displayName: name, owner: owner, repo: repo)
        product.connectedRepoOwner = connected?.0
        product.connectedRepoName = connected?.1
        cloud.insert(product)
        return product
    }

    private func makeIssue(number: Int, app: String?, labels: [String] = [], state: IssueState = .open) {
        let issue = CachedIssue(repoOwner: "o", repoName: "r", number: number, title: "T\(number)",
                                createdAt: Date(), state: state, rawBody: "", appName: app,
                                appVersion: nil, device: nil, osVersion: nil, email: nil,
                                issueDescription: "", labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") })
        local.insert(issue)
    }

    // MARK: - Resolution order

    func testResolvesByDisplayNameCaseInsensitively() throws {
        _ = makeProduct("Usage for Claude")
        let resolved = try ProductResolver.resolve("usage FOR claude", cloud: cloud)
        XCTAssertEqual(resolved.displayName, "Usage for Claude")
    }

    func testResolvesByUUID() throws {
        let product = makeProduct("Zcode")
        let resolved = try ProductResolver.resolve(product.id.uuidString, cloud: cloud)
        XCTAssertEqual(resolved.id, product.id)
    }

    func testResolvesByOwnerSlashRepo() throws {
        _ = makeProduct("Only One", owner: "hayek", repo: "FeedbackRepo")
        let resolved = try ProductResolver.resolve("hayek/FeedbackRepo", cloud: cloud)
        XCTAssertEqual(resolved.displayName, "Only One")
    }

    func testUUIDBeatsDisplayName() throws {
        let first = makeProduct("A")
        _ = makeProduct(first.id.uuidString)      // a product literally named like a UUID
        let resolved = try ProductResolver.resolve(first.id.uuidString, cloud: cloud)
        XCTAssertEqual(resolved.id, first.id)
    }

    func testAmbiguousRepoQueryListsCandidates() throws {
        _ = makeProduct("Usage for Claude", owner: "hayek", repo: "FeedbackRepo")
        _ = makeProduct("FeedbackRepo", owner: "hayek", repo: "FeedbackRepo")
        XCTAssertThrowsError(try ProductResolver.resolve("hayek/FeedbackRepo", cloud: cloud)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, let candidates) = cliError else {
                return XCTFail("expected .notFound, got \(error)")
            }
            XCTAssertEqual(code, "product_ambiguous")
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates.contains { $0.contains("Usage for Claude") })
        }
    }

    func testUnknownProductIsNotFoundWithCandidates() throws {
        _ = makeProduct("Zcode")
        XCTAssertThrowsError(try ProductResolver.resolve("Nope", cloud: cloud)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, let candidates) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "product_not_found")
            XCTAssertTrue(candidates.contains { $0.contains("Zcode") })
        }
    }

    // MARK: - Summaries

    func testSummaryReportsAppsWithCountsAndHiddenFlag() throws {
        _ = makeProduct("P", connected: ("hayek", "UsageForClaude"))
        makeIssue(number: 1, app: "Zcode")
        makeIssue(number: 2, app: "Zcode")
        makeIssue(number: 3, app: "Secret")
        cloud.insert(HiddenApp(repoOwner: "o", repoName: "r", appName: "Secret"))

        let summaries = try ProductResolver.all(cloud: cloud, local: local)
        let apps = try XCTUnwrap(summaries.first).apps
        XCTAssertEqual(apps.first(where: { $0.name == "Zcode" })?.count, 2)
        XCTAssertEqual(apps.first(where: { $0.name == "Zcode" })?.hidden, false)
        XCTAssertEqual(apps.first(where: { $0.name == "Secret" })?.hidden, true)
    }

    func testSummarySeparatesFeedbackFromTaskCounts() throws {
        _ = makeProduct("P")
        makeIssue(number: 1, app: "A")
        makeIssue(number: 2, app: "A", labels: [AppFeedbackLabels.task])
        makeIssue(number: 3, app: "A", labels: [AppFeedbackLabels.task])

        let summary = try XCTUnwrap(ProductResolver.all(cloud: cloud, local: local).first)
        XCTAssertEqual(summary.feedbackCount, 1)
        XCTAssertEqual(summary.taskCount, 2)
    }

    func testSummaryCountsOnlyOpenIssues() throws {
        _ = makeProduct("P")
        makeIssue(number: 1, app: "A")
        makeIssue(number: 2, app: "A", state: .closed)
        let summary = try XCTUnwrap(ProductResolver.all(cloud: cloud, local: local).first)
        XCTAssertEqual(summary.feedbackCount, 1)
    }

    func testSummaryIncludesConnectedRepoAndVersions() throws {
        _ = makeProduct("P", connected: ("hayek", "UsageForClaude"))
        let version = ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0", milestoneNumber: 12)
        cloud.insert(version)

        let summary = try XCTUnwrap(ProductResolver.all(cloud: cloud, local: local).first)
        XCTAssertEqual(summary.connectedRepo, "hayek/UsageForClaude")
        XCTAssertEqual(summary.versions.first?.name, "1.4.0")
        XCTAssertEqual(summary.versions.first?.milestoneNumber, 12)
        XCTAssertEqual(summary.versions.first?.released, false)
    }

    func testSummaryReportsLastFetchedAt() throws {
        _ = makeProduct("P")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        local.insert(RepoFetchState(repoOwner: "o", repoName: "r", lastFetchedAt: stamp))
        let summary = try XCTUnwrap(ProductResolver.all(cloud: cloud, local: local).first)
        XCTAssertEqual(summary.lastFetchedAt, stamp)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/ProductResolverTests`

Expected: compile failure — `ProductResolver` does not exist.

- [ ] **Step 3: Write `CLIDTO.swift`**

```swift
#if os(macOS)
import Foundation

struct AppSummary: Codable, Equatable {
    let name: String
    let count: Int
    let hidden: Bool
}

struct VersionSummary: Codable, Equatable {
    let name: String
    let milestoneNumber: Int?
    let released: Bool
}

struct SourceFlags: Codable, Equatable {
    let sdk: Bool
    let appStore: Bool
    let email: Bool
}

struct ProductSummary: Codable, Equatable {
    let id: String
    let displayName: String
    let repo: String
    let connectedRepo: String?
    let apps: [AppSummary]
    let versions: [VersionSummary]
    let sources: SourceFlags
    let feedbackCount: Int
    let taskCount: Int
    let lastFetchedAt: Date?
}

/// Compact product identity echoed in every envelope.
struct ProductRef: Codable, Equatable {
    let id: String
    let displayName: String
    let repo: String
}

struct PageInfo: Codable, Equatable {
    let limit: Int
    let offset: Int
    let total: Int
    let hasMore: Bool
}

/// Every successful response. `items` is generic so one envelope serves every command.
/// Defaults on every optional so call sites can pass only what they have — nil optionals
/// are omitted from the JSON rather than encoded as null.
struct CLIEnvelope<Item: Codable>: Codable {
    var asOf: Date? = nil
    var stale: Bool = false
    var refreshTimedOut: Bool? = nil
    var closedDataIncomplete: Bool? = nil
    var product: ProductRef? = nil
    var filters: [String: String]? = nil
    var page: PageInfo? = nil
    var warnings: [String]? = nil
    var items: [Item]
}
#endif
```

- [ ] **Step 4: Write `CLIOutput.swift`**

```swift
#if os(macOS)
import Foundation

enum CLIOutput {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":"encoding_failed","message":"Could not encode the response."}}"#
        }
        return text
    }
}
#endif
```

- [ ] **Step 5: Write `ProductResolver.swift`**

```swift
#if os(macOS)
import Foundation
import SwiftData

enum ProductResolver {

    static func products(cloud: ModelContext) throws -> [Product] {
        (try? cloud.fetch(FetchDescriptor<Product>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// UUID → display name (case-insensitive) → owner/repo. Ambiguity is an error, never a guess.
    static func resolve(_ query: String, cloud: ModelContext) throws -> ProductConfig {
        let all = try products(cloud: cloud)
        guard !all.isEmpty else {
            throw CLIError.notFound(code: "no_products",
                                    message: "No products are configured.",
                                    hint: "Add one in AppFeedback's Settings.")
        }
        func describe(_ product: Product) -> String {
            "\(product.displayName) (\(product.owner)/\(product.repo)) \(product.id.uuidString)"
        }

        if let uuid = UUID(uuidString: query), let match = all.first(where: { $0.id == uuid }) {
            return config(from: match)
        }
        let byName = all.filter { $0.displayName.compare(query, options: .caseInsensitive) == .orderedSame }
        if byName.count == 1 { return config(from: byName[0]) }
        if byName.count > 1 {
            throw CLIError.notFound(code: "product_ambiguous",
                                    message: "'\(query)' matches \(byName.count) products by name.",
                                    hint: "Use the product id instead.",
                                    candidates: byName.map(describe))
        }
        let byRepo = all.filter { "\($0.owner)/\($0.repo)".compare(query, options: .caseInsensitive) == .orderedSame }
        if byRepo.count == 1 { return config(from: byRepo[0]) }
        if byRepo.count > 1 {
            throw CLIError.notFound(code: "product_ambiguous",
                                    message: "\(byRepo.count) products share the repo '\(query)'. They see identical feedback.",
                                    hint: "Use the product id, or pick either and scope with --app.",
                                    candidates: byRepo.map(describe))
        }
        throw CLIError.notFound(code: "product_not_found",
                                message: "No product matches '\(query)'.",
                                hint: "Run `\(CLIBranding.commandName) products` to list them.",
                                candidates: all.map(describe))
    }

    static func all(cloud: ModelContext, local: ModelContext) throws -> [ProductSummary] {
        try products(cloud: cloud).map { product in
            let owner = product.owner, repo = product.repo
            let cached = (try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo
            }))) ?? []
            let open = cached.filter { $0.state == IssueState.open.rawValue }
            let (tasks, feedback) = partition(open)

            let hidden = hiddenApps(owner: owner, repo: repo, cloud: cloud)
            let counts = Dictionary(grouping: feedback.compactMap(\.appName).filter { !$0.isEmpty },
                                    by: { $0 }).mapValues(\.count)
            let apps = counts.keys.sorted().map {
                AppSummary(name: $0, count: counts[$0] ?? 0, hidden: hidden.contains($0))
            }

            let versions = ((try? cloud.fetch(FetchDescriptor<ProjectVersion>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo
            }))) ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .map { VersionSummary(name: $0.name, milestoneNumber: $0.milestoneNumber,
                                      released: $0.releasePublished) }

            var fetchDescriptor = FetchDescriptor<RepoFetchState>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo
            })
            fetchDescriptor.fetchLimit = 1
            let fetchState = (try? local.fetch(fetchDescriptor))?.first

            return ProductSummary(
                id: product.id.uuidString,
                displayName: product.displayName,
                repo: "\(owner)/\(repo)",
                connectedRepo: product.connectedRepoOwner.flatMap { connectedOwner in
                    product.connectedRepoName.map { "\(connectedOwner)/\($0)" }
                },
                apps: apps,
                versions: versions,
                sources: SourceFlags(sdk: true,
                                     appStore: product.appStoreAppAppleID != nil,
                                     email: product.feedbackInboxAccountID != nil),
                feedbackCount: feedback.count,
                taskCount: tasks.count,
                lastFetchedAt: fetchState?.lastFetchedAt)
        }
    }

    /// Splits cached rows into (tasks, feedback) by the appfeedback:task label.
    static func partition(_ rows: [CachedIssue]) -> (tasks: [CachedIssue], feedback: [CachedIssue]) {
        var tasks: [CachedIssue] = [], feedback: [CachedIssue] = []
        for row in rows {
            if labelNames(of: row).contains(AppFeedbackLabels.task) { tasks.append(row) } else { feedback.append(row) }
        }
        return (tasks, feedback)
    }

    static func labelNames(of row: CachedIssue) -> [String] {
        row.toFeedbackIssue().labels.map(\.name)
    }

    static func hiddenApps(owner: String, repo: String, cloud: ModelContext) -> Set<String> {
        let rows = (try? cloud.fetch(FetchDescriptor<HiddenApp>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        return Set(rows.map(\.appName))
    }

    static func config(from product: Product) -> ProductConfig {
        ProductConfig(
            id: product.id, displayName: product.displayName, owner: product.owner, repo: product.repo,
            mirrorEmailsToGitHub: product.mirrorEmailsToGitHub,
            redactEmailAddresses: product.redactEmailAddresses,
            connectedRepoOwner: product.connectedRepoOwner, connectedRepoName: product.connectedRepoName,
            colorHex: product.colorHex, appStoreIssuerID: product.appStoreIssuerID,
            appStoreKeyID: product.appStoreKeyID, appStoreAppAppleID: product.appStoreAppAppleID,
            feedbackInboxAccountID: product.feedbackInboxAccountID)
    }

    static func ref(_ config: ProductConfig) -> ProductRef {
        ProductRef(id: config.id.uuidString, displayName: config.displayName,
                   repo: "\(config.owner)/\(config.repo)")
    }
}
#endif
```

- [ ] **Step 6: Wire the `products` branch in `CLIRunner.execute`**

Replace the `default:` case body with a `case .products(let flags):` branch above it:

```swift
        case .products(let flags):
            do {
                let store = try CLIStore.open()
                let summaries = try ProductResolver.all(cloud: store.cloud, local: store.local)
                let envelope = CLIEnvelope(asOf: summaries.compactMap(\.lastFetchedAt).max(),
                                           stale: false, items: summaries)
                print(flags.json ? CLIOutput.encode(envelope) : CLIText.render(products: summaries))
                return CLIExitCode.success.rawValue
            } catch let error as CLIError {
                return emit(error: error)
            } catch {
                return emit(error: .noLocalData(message: error.localizedDescription, hint: nil))
            }
```

`CLIText.render(products:)` comes in Task 8; until then, add a temporary stub in `CLIOutput.swift`:

```swift
enum CLIText {
    static func render(products: [ProductSummary]) -> String {
        products.map { "\($0.displayName)\t\($0.repo)\t\($0.feedbackCount) feedback\t\($0.taskCount) tasks" }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 7: Run the tests and try it against the real store**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/ProductResolverTests`

Expected: all PASS. Then:

```bash
"$APP/AppFeedback.app/Contents/MacOS/AppFeedback" products
```

Expected: three products, `hayek/FeedbackRepo` twice, with app names including "Usage for Claude" and "Zcode".

- [ ] **Step 8: Commit**

```bash
git add AppFeedback/CLI/ProductResolver.swift AppFeedback/CLI/CLIDTO.swift \
        AppFeedback/CLI/CLIOutput.swift AppFeedback/CLI/CLIRunner.swift \
        AppFeedbackTests/ProductResolverTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): resolve products and implement the products command"
```

---

## Task 5: Task index and the task↔feedback reverse map

**Files:**
- Create: `AppFeedback/CLI/TaskIndex.swift`
- Test: `AppFeedbackTests/TaskIndexTests.swift`

**Interfaces:**
- Consumes: `CLIStore`, `ProductResolver.partition`, `TaskItem`, `FeedbackTaskRefParser`.
- Produces: `struct TaskRef: Codable` (`number`, `title`, `status`, `priority`, `isClosed`); `TaskIndex.build(local:owner:repo:) -> TaskIndex`; on the instance `tasks: [TaskItem]`, `refs(forFeedback: Int) -> [TaskRef]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class TaskIndexTests: XCTestCase {

    private var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(for: CachedIssue.self, configurations: config))
    }

    @discardableResult
    private func insert(number: Int, title: String = "T", body: String = "",
                        labels: [String] = [], state: IssueState = .open) -> CachedIssue {
        let row = CachedIssue(repoOwner: "o", repoName: "r", number: number, title: title,
                              createdAt: Date(), state: state, rawBody: body, appName: nil,
                              appVersion: nil, device: nil, osVersion: nil, email: nil,
                              issueDescription: "",
                              labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") })
        context.insert(row)
        return row
    }

    func testIndexesOnlyTaskLabelledIssues() {
        insert(number: 1, labels: ["bug"])
        insert(number: 2, labels: [AppFeedbackLabels.task])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertEqual(index.tasks.map(\.number), [2])
    }

    func testReverseMapLinksFeedbackToItsTasks() {
        let body = FeedbackTaskRefParser.upsert(into: "Fix it", refs: [10, 11])
        insert(number: 2, title: "Fix the thing", body: body,
               labels: [AppFeedbackLabels.task, "status:in-progress", "priority:high"])

        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        let refs = index.refs(forFeedback: 10)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.number, 2)
        XCTAssertEqual(refs.first?.title, "Fix the thing")
        XCTAssertEqual(refs.first?.status, "in-progress")
        XCTAssertEqual(refs.first?.priority, "high")
        XCTAssertEqual(index.refs(forFeedback: 11).first?.number, 2)
        XCTAssertTrue(index.refs(forFeedback: 99).isEmpty)
    }

    func testOneFeedbackCanHaveSeveralTasks() {
        insert(number: 2, body: FeedbackTaskRefParser.upsert(into: "A", refs: [10]),
               labels: [AppFeedbackLabels.task])
        insert(number: 3, body: FeedbackTaskRefParser.upsert(into: "B", refs: [10]),
               labels: [AppFeedbackLabels.task])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertEqual(index.refs(forFeedback: 10).map(\.number).sorted(), [2, 3])
    }

    /// Closed/done tasks still count as "this is tracked" — that is the whole point of the field.
    func testClosedTasksAreIncludedAndReportDoneStatus() {
        insert(number: 2, body: FeedbackTaskRefParser.upsert(into: "A", refs: [10]),
               labels: [AppFeedbackLabels.task, "status:todo"], state: .closed)
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        let ref = try? XCTUnwrap(index.refs(forFeedback: 10).first)
        XCTAssertEqual(ref??.isClosed, true)
        XCTAssertEqual(ref??.status, "done", "a closed task displays as done")
    }

    func testScopedToTheRequestedRepo() {
        insert(number: 2, body: FeedbackTaskRefParser.upsert(into: "A", refs: [10]),
               labels: [AppFeedbackLabels.task])
        let other = CachedIssue(repoOwner: "other", repoName: "repo", number: 3, title: "X",
                                createdAt: Date(), rawBody: FeedbackTaskRefParser.upsert(into: "B", refs: [10]),
                                appName: nil, appVersion: nil, device: nil, osVersion: nil,
                                email: nil, issueDescription: "",
                                labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")])
        context.insert(other)
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertEqual(index.refs(forFeedback: 10).map(\.number), [2])
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/TaskIndexTests`

Expected: compile failure — `TaskIndex` does not exist.

- [ ] **Step 3: Write `TaskIndex.swift`**

```swift
#if os(macOS)
import Foundation
import SwiftData

struct TaskRef: Codable, Equatable {
    let number: Int
    let title: String
    let status: String
    let priority: String
    let isClosed: Bool
}

/// Cached tasks for one repo plus the feedback→tasks reverse map. The map is built from
/// each task body's machine-managed addresses block, which is the source of truth for the
/// task↔feedback relationship.
struct TaskIndex {
    let tasks: [TaskItem]
    private let byFeedback: [Int: [TaskRef]]

    static func build(local: ModelContext, owner: String, repo: String) -> TaskIndex {
        let rows = (try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        let tasks = ProductResolver.partition(rows).tasks
            .map { TaskItem(issue: $0.toFeedbackIssue()) }
            .sorted { $0.number > $1.number }

        var map: [Int: [TaskRef]] = [:]
        for task in tasks {
            let ref = TaskRef(number: task.number, title: task.title,
                              status: task.displayStatus.rawValue,
                              priority: task.priority.rawValue,
                              isClosed: task.isClosed)
            for feedbackNumber in task.feedbackRefs {
                map[feedbackNumber, default: []].append(ref)
            }
        }
        for key in map.keys { map[key]?.sort { $0.number < $1.number } }
        return TaskIndex(tasks: tasks, byFeedback: map)
    }

    func refs(forFeedback number: Int) -> [TaskRef] { byFeedback[number] ?? [] }
}
#endif
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/TaskIndexTests`

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/CLI/TaskIndex.swift AppFeedbackTests/TaskIndexTests.swift \
        AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): index tasks and map feedback back to the tasks that address it"
```

---

## Task 6: Feedback query engine and `feedback list`

**Files:**
- Create: `AppFeedback/CLI/FeedbackQuery.swift`
- Modify: `AppFeedback/CLI/CLIDTO.swift` (add `FeedbackItem`)
- Modify: `AppFeedback/CLI/CLIRunner.swift` (wire `feedback list`)
- Test: `AppFeedbackTests/FeedbackQueryTests.swift`

**Interfaces:**
- Consumes: `CLIStore`, `CLIFlags`, `TaskIndex`, `ProductResolver`.
- Produces: `struct FeedbackItem: Codable`; `FeedbackQuery.run(flags:config:store:index:) -> (items: [FeedbackItem], total: Int)`; `FeedbackQuery.redact(_ email: String) -> String`; `FeedbackQuery.truncate(_ text: String) -> (String, Bool)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class FeedbackQueryTests: XCTestCase {

    private var context: ModelContext!
    private let config = ProductConfig(displayName: "P", owner: "o", repo: "r")

    override func setUpWithError() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(
            for: CachedIssue.self, HiddenApp.self, TriageVerdictRecord.self,
            configurations: modelConfig))
    }

    @discardableResult
    private func insert(number: Int, title: String = "T", app: String? = "Zcode",
                        description: String = "d", labels: [String] = [],
                        state: IssueState = .open, source: FeedbackSource = .sdk,
                        rating: Int? = nil, email: String? = nil,
                        appVersion: String? = nil,
                        created: Date = Date(timeIntervalSince1970: 1_000_000),
                        updated: Date? = nil, body: String = "") -> CachedIssue {
        let row = CachedIssue(repoOwner: "o", repoName: "r", number: number, title: title,
                              createdAt: created, updatedAt: updated, state: state, rawBody: body,
                              appName: app, appVersion: appVersion, device: "iPhone", osVersion: "iOS 18.6",
                              email: email, issueDescription: description,
                              labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") })
        row.source = source.rawValue
        row.rating = rating
        context.insert(row)
        return row
    }

    private func run(_ mutate: (inout CLIFlags) -> Void = { _ in }) -> (items: [FeedbackItem], total: Int) {
        var flags = CLIFlags()
        flags.product = "P"
        mutate(&flags)
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        return FeedbackQuery.run(flags: flags, config: config, local: context, cloud: context, index: index)
    }

    // MARK: - Task exclusion and hidden apps

    func testExcludesTaskLabelledIssues() {
        insert(number: 1)
        insert(number: 2, labels: [AppFeedbackLabels.task])
        XCTAssertEqual(run().items.map(\.number), [1])
    }

    func testHiddenAppsAreExcludedByDefaultAndIncludableOnDemand() {
        insert(number: 1, app: "Zcode")
        insert(number: 2, app: "Secret")
        context.insert(HiddenApp(repoOwner: "o", repoName: "r", appName: "Secret"))
        XCTAssertEqual(run().items.map(\.number), [1])
        XCTAssertEqual(run { $0.includeHidden = true }.items.map(\.number).sorted(), [1, 2])
    }

    // MARK: - Filters

    func testDefaultStateIsOpenOnly() {
        insert(number: 1, state: .open)
        insert(number: 2, state: .closed)
        XCTAssertEqual(run().items.map(\.number), [1])
        XCTAssertEqual(run { $0.state = .closed }.items.map(\.number), [2])
        XCTAssertEqual(run { $0.state = .all }.items.map(\.number).sorted(), [1, 2])
    }

    func testRepeatedAppFlagOrsValues() {
        insert(number: 1, app: "Zcode")
        insert(number: 2, app: "XcodeMini")
        insert(number: 3, app: "Other")
        XCTAssertEqual(run { $0.apps = ["Zcode", "XcodeMini"] }.items.map(\.number).sorted(), [1, 2])
    }

    func testDifferentFlagsAndTogether() {
        insert(number: 1, app: "Zcode", labels: ["bug"])
        insert(number: 2, app: "Zcode", labels: ["feature-request"])
        insert(number: 3, app: "Other", labels: ["bug"])
        let result = run { $0.apps = ["Zcode"]; $0.types = [.bug] }
        XCTAssertEqual(result.items.map(\.number), [1])
    }

    func testLabelFilterRequiresEveryRequestedLabel() {
        insert(number: 1, labels: ["bug", "user-submitted"])
        insert(number: 2, labels: ["bug"])
        XCTAssertEqual(run { $0.labels = ["bug", "user-submitted"] }.items.map(\.number), [1])
    }

    func testSourceFilter() {
        insert(number: 1, source: .sdk)
        insert(number: 2, source: .appStore)
        XCTAssertEqual(run { $0.sources = [.appStore] }.items.map(\.number), [2])
    }

    func testRatingRangeIsInclusiveAndDropsUnrated() {
        insert(number: 1, source: .appStore, rating: 1)
        insert(number: 2, source: .appStore, rating: 3)
        insert(number: 3, source: .sdk, rating: nil)
        XCTAssertEqual(run { $0.maxRating = 2 }.items.map(\.number), [1])
        XCTAssertEqual(run { $0.minRating = 3 }.items.map(\.number), [2])
    }

    func testSinceFiltersOnCreatedAtInclusively() {
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        insert(number: 1, created: cutoff.addingTimeInterval(-1))
        insert(number: 2, created: cutoff)
        insert(number: 3, created: cutoff.addingTimeInterval(1))
        XCTAssertEqual(run { $0.since = cutoff }.items.map(\.number).sorted(), [2, 3])
    }

    func testUpdatedSinceFiltersOnUpdatedAt() {
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        insert(number: 1, created: cutoff.addingTimeInterval(-100), updated: cutoff.addingTimeInterval(-100))
        insert(number: 2, created: cutoff.addingTimeInterval(-100), updated: cutoff.addingTimeInterval(50))
        XCTAssertEqual(run { $0.updatedSince = cutoff }.items.map(\.number), [2])
    }

    func testSearchMatchesTitleDescriptionAndAppCaseInsensitively() {
        insert(number: 1, title: "Crash on launch", description: "x", app: "Zcode")
        insert(number: 2, title: "x", description: "It CRASHES sometimes", app: "Zcode")
        insert(number: 3, title: "x", description: "y", app: "CrashPad")
        insert(number: 4, title: "unrelated", description: "y", app: "Zcode")
        XCTAssertEqual(run { $0.search = "crash" }.items.map(\.number).sorted(), [1, 2, 3])
    }

    func testAppVersionFilter() {
        insert(number: 1, appVersion: "1.4.2")
        insert(number: 2, appVersion: "1.4.3")
        XCTAssertEqual(run { $0.appVersion = "1.4.2" }.items.map(\.number), [1])
    }

    func testHasTaskAndNoTask() {
        insert(number: 1)
        insert(number: 2)
        insert(number: 90, body: FeedbackTaskRefParser.upsert(into: "t", refs: [1]),
               labels: [AppFeedbackLabels.task])
        XCTAssertEqual(run { $0.hasTask = true }.items.map(\.number), [1])
        XCTAssertEqual(run { $0.hasTask = false }.items.map(\.number), [2])
    }

    // MARK: - Sorting and pagination

    func testSortsByCreatedDescendingByDefaultWithNumberTiebreak() {
        let same = Date(timeIntervalSince1970: 5_000)
        insert(number: 1, created: same)
        insert(number: 3, created: same)
        insert(number: 2, created: same.addingTimeInterval(100))
        XCTAssertEqual(run().items.map(\.number), [2, 3, 1])
    }

    func testAscendingOrder() {
        insert(number: 1, created: Date(timeIntervalSince1970: 1))
        insert(number: 2, created: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(run { $0.order = .asc }.items.map(\.number), [1, 2])
    }

    func testPaginationReportsTotalAcrossPages() {
        for number in 1...5 { insert(number: number, created: Date(timeIntervalSince1970: TimeInterval(number))) }
        let page = run { $0.limit = 2; $0.offset = 1 }
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.items.map(\.number), [4, 3])
    }

    func testOffsetPastTheEndYieldsNoItemsButKeepsTheTotal() {
        insert(number: 1)
        let page = run { $0.offset = 99 }
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.total, 1)
    }

    // MARK: - Item shape

    func testEmailIsRedactedByDefault() {
        insert(number: 1, email: "amir@icloud.com")
        XCTAssertEqual(run().items.first?.email, "a***@icloud.com")
        XCTAssertEqual(run { $0.includeEmails = true }.items.first?.email, "amir@icloud.com")
    }

    func testRedactionHandlesSingleCharacterAndMalformedAddresses() {
        XCTAssertEqual(FeedbackQuery.redact("a@b.com"), "a***@b.com")
        XCTAssertEqual(FeedbackQuery.redact("no-at-sign"), "***")
    }

    func testDescriptionTruncatesAtFiveHundredCharacters() {
        insert(number: 1, description: String(repeating: "x", count: 600))
        let item = run().items.first
        XCTAssertEqual(item?.description.count, 500)
        XCTAssertEqual(item?.truncated, true)
    }

    func testShortDescriptionIsNotMarkedTruncated() {
        insert(number: 1, description: "short")
        XCTAssertEqual(run().items.first?.truncated, false)
    }

    func testItemCarriesExpandedTasksAndTriage() {
        insert(number: 1)
        insert(number: 90, title: "The task", body: FeedbackTaskRefParser.upsert(into: "t", refs: [1]),
               labels: [AppFeedbackLabels.task, "status:todo", "priority:high"])
        let verdict = TriageVerdictRecord(repoOwner: "o", repoName: "r", feedbackNumber: 1,
                                          state: TriageState.accepted.rawValue)
        verdict.kind = TriageKind.usability.rawValue
        verdict.signal = "users cannot find the button"
        context.insert(verdict)

        let item = run().items.first
        XCTAssertEqual(item?.tasks.first?.number, 90)
        XCTAssertEqual(item?.tasks.first?.status, "todo")
        XCTAssertEqual(item?.triage?.state, "accepted")
        XCTAssertEqual(item?.triage?.kind, "usability")
        XCTAssertEqual(item?.triage?.signal, "users cannot find the button")
    }

    func testItemUrlPointsAtTheFeedbackRepo() {
        insert(number: 559)
        XCTAssertEqual(run().items.first?.url,
                       "https://github.com/o/r/issues/559")
    }

    func testTypeComesFromLabelsNotTriage() {
        insert(number: 1, labels: ["feature-request"])
        XCTAssertEqual(run().items.first?.type, "feature-request")
        insert(number: 2, labels: [])
        XCTAssertNil(run { $0.search = "" }.items.first(where: { $0.number == 2 })?.type)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/FeedbackQueryTests`

Expected: compile failure — `FeedbackQuery` and `FeedbackItem` do not exist.

- [ ] **Step 3: Add `FeedbackItem` and `TriageInfo` to `CLIDTO.swift`**

```swift
struct TriageInfo: Codable, Equatable {
    let state: String
    let kind: String?
    let signal: String?
    let suggestedTaskNumber: Int?
    let createdTaskNumber: Int?
}

struct FeedbackItem: Codable, Equatable {
    let number: Int
    let title: String
    let app: String?
    let appVersion: String?
    let source: String
    let type: String?
    let rating: Int?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let device: String?
    let os: String?
    let email: String?
    let description: String
    let truncated: Bool
    let labels: [String]
    let tasks: [TaskRef]
    let triage: TriageInfo?
    let url: String
}
```

- [ ] **Step 4: Write `FeedbackQuery.swift`**

```swift
#if os(macOS)
import Foundation
import SwiftData

enum FeedbackQuery {
    static let descriptionLimit = 500

    static func run(flags: CLIFlags, config: ProductConfig,
                    local: ModelContext, cloud: ModelContext,
                    index: TaskIndex) -> (items: [FeedbackItem], total: Int) {
        let owner = config.owner, repo = config.repo
        let rows = (try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []

        let hidden = flags.includeHidden ? [] : ProductResolver.hiddenApps(owner: owner, repo: repo, cloud: cloud)
        let verdicts = triageByNumber(local: local, owner: owner, repo: repo)

        var issues = ProductResolver.partition(rows).feedback
            .map { $0.toFeedbackIssue() }
            .filter { matches($0, flags: flags, hidden: hidden, index: index) }

        issues.sort { left, right in
            let leftKey = flags.sort == .created ? left.createdAt : (left.updatedAt ?? left.createdAt)
            let rightKey = flags.sort == .created ? right.createdAt : (right.updatedAt ?? right.createdAt)
            if leftKey != rightKey {
                return flags.order == .desc ? leftKey > rightKey : leftKey < rightKey
            }
            return flags.order == .desc ? left.number > right.number : left.number < right.number
        }

        let total = issues.count
        let page = Array(issues.dropFirst(flags.offset).prefix(flags.limit))
        let items = page.map { item(from: $0, flags: flags, config: config,
                                    index: index, triage: verdicts[$0.number]) }
        return (items, total)
    }

    // MARK: - Filtering

    private static func matches(_ issue: FeedbackIssue, flags: CLIFlags,
                                hidden: Set<String>, index: TaskIndex) -> Bool {
        if hidden.contains(issue.appName ?? "") { return false }

        switch flags.state {
        case .open:   if (issue.state ?? .open) != .open { return false }
        case .closed: if (issue.state ?? .open) != .closed { return false }
        case .all:    break
        }
        if !flags.apps.isEmpty, !flags.apps.contains(issue.appName ?? "") { return false }
        if !flags.sources.isEmpty, !flags.sources.contains(issue.source) { return false }
        if !flags.types.isEmpty {
            guard let type = issue.labels.issueType?.type, flags.types.contains(type) else { return false }
        }
        if !flags.labels.isEmpty {
            let names = Set(issue.labels.map(\.name))
            guard flags.labels.allSatisfy(names.contains) else { return false }
        }
        if let version = flags.appVersion, issue.appVersion != version { return false }
        if let since = flags.since, issue.createdAt < since { return false }
        if let since = flags.updatedSince, (issue.updatedAt ?? issue.createdAt) < since { return false }
        if flags.minRating != nil || flags.maxRating != nil {
            guard let rating = issue.rating else { return false }
            if let low = flags.minRating, rating < low { return false }
            if let high = flags.maxRating, rating > high { return false }
        }
        if let query = flags.search, !query.isEmpty {
            let needle = query.lowercased()
            let haystacks = [issue.title, issue.description, issue.appName ?? ""]
            guard haystacks.contains(where: { $0.lowercased().contains(needle) }) else { return false }
        }
        if let wantsTask = flags.hasTask {
            let hasTask = !index.refs(forFeedback: issue.number).isEmpty
            if hasTask != wantsTask { return false }
        }
        return true
    }

    // MARK: - Projection

    private static func item(from issue: FeedbackIssue, flags: CLIFlags, config: ProductConfig,
                             index: TaskIndex, triage: TriageVerdictRecord?) -> FeedbackItem {
        let (description, truncated) = truncate(issue.description)
        return FeedbackItem(
            number: issue.number,
            title: issue.title,
            app: issue.appName,
            appVersion: issue.appVersion,
            source: issue.source.rawValue,
            type: issue.labels.issueType?.type.rawValue,
            rating: issue.rating,
            state: (issue.state ?? .open).rawValue,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt ?? issue.createdAt,
            device: issue.device,
            os: issue.osVersion,
            email: issue.email.map { flags.includeEmails ? $0 : redact($0) },
            description: description,
            truncated: truncated,
            labels: issue.labels.map(\.name),
            tasks: index.refs(forFeedback: issue.number),
            triage: triage.map {
                TriageInfo(state: $0.state, kind: $0.kind, signal: $0.signal.isEmpty ? nil : $0.signal,
                           suggestedTaskNumber: $0.suggestedTaskNumber,
                           createdTaskNumber: $0.createdTaskNumber)
            },
            url: "https://github.com/\(config.owner)/\(config.repo)/issues/\(issue.number)")
    }

    static func truncate(_ text: String) -> (String, Bool) {
        guard text.count > descriptionLimit else { return (text, false) }
        return (String(text.prefix(descriptionLimit)), true)
    }

    /// `amir@icloud.com` → `a***@icloud.com`. Same shape the app uses when mirroring email.
    static func redact(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@"), atIndex != email.startIndex else { return "***" }
        return "\(email[email.startIndex])***\(email[atIndex...])"
    }

    private static func triageByNumber(local: ModelContext, owner: String, repo: String) -> [Int: TriageVerdictRecord] {
        let rows = (try? local.fetch(FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        return Dictionary(rows.map { ($0.feedbackNumber, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
#endif
```

- [ ] **Step 5: Wire `feedback list` into `CLIRunner.execute`**

Add above the `default:` case. `refresh` is a no-op until Task 10 — leave the flag parsed but unused, and do not claim freshness the CLI cannot deliver.

```swift
        case .feedback(.list(let flags)):
            do {
                let store = try CLIStore.open()
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let result = FeedbackQuery.run(flags: flags, config: config,
                                               local: store.local, cloud: store.cloud, index: index)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(
                    asOf: asOf,
                    stale: isStale(asOf),
                    closedDataIncomplete: flags.state == .open ? nil : true,
                    product: ProductResolver.ref(config),
                    filters: describe(flags),
                    page: PageInfo(limit: flags.limit, offset: flags.offset, total: result.total,
                                   hasMore: flags.offset + result.items.count < result.total),
                    items: result.items)
                print(flags.json ? CLIOutput.encode(envelope) : CLIText.render(feedback: result.items))
                return CLIExitCode.success.rawValue
            } catch let error as CLIError {
                return emit(error: error)
            } catch {
                return emit(error: .noLocalData(message: error.localizedDescription, hint: nil))
            }
```

Add these helpers to `CLIRunner`:

```swift
    /// The app polls every 15 minutes; anything older than that is stale.
    static func isStale(_ asOf: Date?, now: Date = Date()) -> Bool {
        guard let asOf else { return true }
        return now.timeIntervalSince(asOf) > 15 * 60
    }

    /// Echoes the filters that were actually applied, so an agent can self-check a guessed value.
    static func describe(_ flags: CLIFlags) -> [String: String] {
        var described: [String: String] = ["state": flags.state.rawValue,
                                           "sort": flags.sort.rawValue,
                                           "order": flags.order.rawValue]
        if !flags.apps.isEmpty      { described["app"] = flags.apps.joined(separator: ",") }
        if !flags.labels.isEmpty    { described["label"] = flags.labels.joined(separator: ",") }
        if !flags.sources.isEmpty   { described["source"] = flags.sources.map(\.rawValue).joined(separator: ",") }
        if !flags.types.isEmpty     { described["type"] = flags.types.map(\.rawValue).joined(separator: ",") }
        if !flags.statuses.isEmpty  { described["status"] = flags.statuses.map(\.rawValue).joined(separator: ",") }
        if !flags.priorities.isEmpty { described["priority"] = flags.priorities.map(\.rawValue).joined(separator: ",") }
        if let search = flags.search { described["search"] = search }
        if let since = flags.since   { described["since"] = CLIOutput.iso8601.string(from: since) }
        if let since = flags.updatedSince { described["updatedSince"] = CLIOutput.iso8601.string(from: since) }
        if let low = flags.minRating { described["minRating"] = String(low) }
        if let high = flags.maxRating { described["maxRating"] = String(high) }
        if let version = flags.appVersion { described["appVersion"] = version }
        if let hasTask = flags.hasTask { described["hasTask"] = String(hasTask) }
        if flags.includeHidden      { described["includeHidden"] = "true" }
        return described
    }
```

Add to `ProductResolver`:

```swift
    static func lastFetchedAt(local: ModelContext, owner: String, repo: String) -> Date? {
        var descriptor = FetchDescriptor<RepoFetchState>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        })
        descriptor.fetchLimit = 1
        return (try? local.fetch(descriptor))?.first?.lastFetchedAt
    }
```

And a temporary `CLIText.render(feedback:)` stub beside the products one (Task 8 replaces both):

```swift
    static func render(feedback items: [FeedbackItem]) -> String {
        items.map { "#\($0.number)\t\($0.state)\t\($0.app ?? "-")\t\($0.title)" }.joined(separator: "\n")
    }
```

- [ ] **Step 6: Run the tests and try it against the real store**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/FeedbackQueryTests`

Expected: all PASS. Then:

```bash
BIN="$APP/AppFeedback.app/Contents/MacOS/AppFeedback"
"$BIN" feedback --product "Usage for Claude" --limit 3
"$BIN" feedback --product "Usage for Claude" --app Zcode --state all | head -40
"$BIN" feedback --product "hayek/FeedbackRepo" ; echo "exit=$?"
```

Expected: the first two print envelopes with real data; the third exits 1 with `product_ambiguous` listing both products that share the repo.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/CLI/FeedbackQuery.swift AppFeedback/CLI/CLIDTO.swift \
        AppFeedback/CLI/CLIOutput.swift AppFeedback/CLI/CLIRunner.swift \
        AppFeedback/CLI/ProductResolver.swift AppFeedbackTests/FeedbackQueryTests.swift \
        AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): filter, sort and paginate feedback from the local cache"
```

---

## Task 7: `feedback show` and `tasks list` / `tasks show`

**Files:**
- Modify: `AppFeedback/CLI/CLIDTO.swift` (add `FeedbackDetail`, `TaskItemDTO`, `TaskDetail`, `AttachmentDTO`, `ThreadSummary`)
- Modify: `AppFeedback/CLI/FeedbackQuery.swift` (add `detail`)
- Modify: `AppFeedback/CLI/TaskIndex.swift` (add `filter`, `dto`, `detail`)
- Modify: `AppFeedback/CLI/CLIRunner.swift` (wire three branches)
- Test: `AppFeedbackTests/FeedbackQueryTests.swift` (extend), `AppFeedbackTests/TaskIndexTests.swift` (extend)

**Interfaces:**
- Produces: `FeedbackQuery.detail(number:flags:config:local:cloud:index:) throws -> FeedbackDetail`; `TaskIndex.filter(_ flags: CLIFlags) -> [TaskItemDTO]`; `TaskIndex.detail(number:config:local:) throws -> TaskDetail`.

- [ ] **Step 1: Write the failing tests**

Append to `FeedbackQueryTests.swift`:

```swift
#if os(macOS)
extension FeedbackQueryTests {

    func testDetailReturnsFullDescriptionAndOmitsRawBodyByDefault() throws {
        let long = String(repeating: "y", count: 900)
        insert(number: 7, description: long, body: "RAW BODY <!-- marker -->")
        var flags = CLIFlags(); flags.product = "P"
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        let detail = try FeedbackQuery.detail(number: 7, flags: flags, config: config,
                                              local: context, cloud: context, index: index)
        XCTAssertEqual(detail.description.count, 900)
        XCTAssertNil(detail.rawBody)

        flags.raw = true
        let withRaw = try FeedbackQuery.detail(number: 7, flags: flags, config: config,
                                               local: context, cloud: context, index: index)
        XCTAssertEqual(withRaw.rawBody, "RAW BODY <!-- marker -->")
    }

    func testDetailForUnknownNumberIsNotFound() {
        var flags = CLIFlags(); flags.product = "P"
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertThrowsError(try FeedbackQuery.detail(number: 404, flags: flags, config: config,
                                                      local: context, cloud: context, index: index)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "feedback_not_found")
        }
    }

    func testDetailRefusesToReturnATaskAsFeedback() {
        insert(number: 8, labels: [AppFeedbackLabels.task])
        var flags = CLIFlags(); flags.product = "P"
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertThrowsError(try FeedbackQuery.detail(number: 8, flags: flags, config: config,
                                                      local: context, cloud: context, index: index)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, let hint, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "feedback_not_found")
            XCTAssertEqual(hint, "#8 is a task. Use `tasks show 8`.")
        }
    }
}
#endif
```

Append to `TaskIndexTests.swift`:

```swift
#if os(macOS)
extension TaskIndexTests {

    func testFilterByStatusOrsValues() {
        insert(number: 1, labels: [AppFeedbackLabels.task, "status:todo"])
        insert(number: 2, labels: [AppFeedbackLabels.task, "status:in-progress"])
        insert(number: 3, labels: [AppFeedbackLabels.task, "status:done"])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        var flags = CLIFlags(); flags.statuses = [.todo, .inProgress]
        XCTAssertEqual(index.filter(flags).map(\.number).sorted(), [1, 2])
    }

    func testFilterByPriorityAndSearch() {
        insert(number: 1, title: "Fix crash", labels: [AppFeedbackLabels.task, "priority:high"])
        insert(number: 2, title: "Polish UI", labels: [AppFeedbackLabels.task, "priority:high"])
        insert(number: 3, title: "Fix crash", labels: [AppFeedbackLabels.task, "priority:low"])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        var flags = CLIFlags(); flags.priorities = [.high]; flags.search = "crash"
        XCTAssertEqual(index.filter(flags).map(\.number), [1])
    }

    func testFilterByVersionMatchesMilestoneTitle() {
        let row = insert(number: 1, labels: [AppFeedbackLabels.task])
        row.milestoneTitle = "1.4.0"
        insert(number: 2, labels: [AppFeedbackLabels.task])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        var flags = CLIFlags(); flags.version = "1.4.0"
        XCTAssertEqual(index.filter(flags).map(\.number), [1])
    }

    func testDefaultStatusFilterExcludesDone() {
        insert(number: 1, labels: [AppFeedbackLabels.task, "status:todo"])
        insert(number: 2, labels: [AppFeedbackLabels.task, "status:done"])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        var flags = CLIFlags()          // state defaults to .open
        XCTAssertEqual(index.filter(flags).map(\.number), [1])
        flags.state = .all
        XCTAssertEqual(index.filter(flags).map(\.number).sorted(), [1, 2])
    }

    func testDetailExpandsLinkedFeedbackTitles() throws {
        insert(number: 10, title: "Users report a crash")
        insert(number: 90, title: "Fix the crash",
               body: FeedbackTaskRefParser.upsert(into: "Root-cause it", refs: [10]),
               labels: [AppFeedbackLabels.task])
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        let detail = try index.detail(number: 90,
                                      config: ProductConfig(displayName: "P", owner: "o", repo: "r"),
                                      local: context)
        XCTAssertEqual(detail.notes, "Root-cause it")
        XCTAssertEqual(detail.feedback.first?.number, 10)
        XCTAssertEqual(detail.feedback.first?.title, "Users report a crash")
    }

    func testDetailForUnknownTaskIsNotFound() {
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertThrowsError(try index.detail(number: 404,
                                              config: ProductConfig(displayName: "P", owner: "o", repo: "r"),
                                              local: context)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "task_not_found")
        }
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run both test classes. Expected: compile failure — `FeedbackQuery.detail`, `TaskIndex.filter`, `TaskIndex.detail` do not exist.

- [ ] **Step 3: Add the DTOs to `CLIDTO.swift`**

```swift
struct AttachmentDTO: Codable, Equatable {
    let filename: String
    let url: String
    let localPath: String?
}

struct ThreadSummary: Codable, Equatable {
    let messageCount: Int
    let lastMessageAt: Date?
    let lastDirection: String?      // "inbound" | "outbound"
}

struct FeedbackDetail: Codable, Equatable {
    let number: Int
    let title: String
    let app: String?
    let appVersion: String?
    let source: String
    let type: String?
    let rating: Int?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let device: String?
    let os: String?
    let email: String?
    let description: String
    let rawBody: String?
    let labels: [String]
    let milestone: String?
    let attachments: [AttachmentDTO]
    let translatedTitle: String?
    let translatedBody: String?
    let thread: ThreadSummary?
    let tasks: [TaskRef]
    let triage: TriageInfo?
    let url: String
}

struct TaskItemDTO: Codable, Equatable {
    let number: Int
    let title: String
    let status: String
    let priority: String
    let isClosed: Bool
    let milestone: String?
    let feedback: [Int]
    let url: String
}

struct LinkedFeedback: Codable, Equatable {
    let number: Int
    let title: String
    let state: String
}

struct TaskDetail: Codable, Equatable {
    let number: Int
    let title: String
    let status: String
    let priority: String
    let isClosed: Bool
    let milestone: String?
    let notes: String
    let feedback: [LinkedFeedback]
    let url: String
}
```

- [ ] **Step 4: Add `FeedbackQuery.detail`**

```swift
    static func detail(number: Int, flags: CLIFlags, config: ProductConfig,
                       local: ModelContext, cloud: ModelContext,
                       index: TaskIndex) throws -> FeedbackDetail {
        let owner = config.owner, repo = config.repo
        var descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.number == number
        })
        descriptor.fetchLimit = 1
        guard let row = (try? local.fetch(descriptor))?.first else {
            throw CLIError.notFound(code: "feedback_not_found",
                                    message: "No cached feedback #\(number) in \(owner)/\(repo).",
                                    hint: "It may be closed and never cached — see closedDataIncomplete in list output.")
        }
        let issue = row.toFeedbackIssue()
        if issue.labels.contains(where: { $0.name == AppFeedbackLabels.task }) {
            throw CLIError.notFound(code: "feedback_not_found",
                                    message: "#\(number) is not a feedback item.",
                                    hint: "#\(number) is a task. Use `tasks show \(number)`.")
        }
        let triage = triageByNumber(local: local, owner: owner, repo: repo)[number]
        return FeedbackDetail(
            number: issue.number, title: issue.title, app: issue.appName, appVersion: issue.appVersion,
            source: issue.source.rawValue, type: issue.labels.issueType?.type.rawValue,
            rating: issue.rating, state: (issue.state ?? .open).rawValue,
            createdAt: issue.createdAt, updatedAt: issue.updatedAt ?? issue.createdAt,
            device: issue.device, os: issue.osVersion,
            email: issue.email.map { flags.includeEmails ? $0 : redact($0) },
            description: issue.description,
            rawBody: flags.raw ? issue.rawBody : nil,
            labels: issue.labels.map(\.name),
            milestone: issue.milestoneTitle,
            attachments: issue.attachments.map {
                AttachmentDTO(filename: $0.filename, url: $0.url,
                              localPath: localAttachmentPath(for: $0, local: local))
            },
            translatedTitle: issue.translatedTitle, translatedBody: issue.translatedBody,
            thread: threadSummary(owner: owner, repo: repo, number: number,
                                  title: issue.title, cloud: cloud),
            tasks: index.refs(forFeedback: number),
            triage: triage.map {
                TriageInfo(state: $0.state, kind: $0.kind, signal: $0.signal.isEmpty ? nil : $0.signal,
                           suggestedTaskNumber: $0.suggestedTaskNumber,
                           createdTaskNumber: $0.createdTaskNumber)
            },
            url: "https://github.com/\(owner)/\(repo)/issues/\(number)")
    }

    private static func localAttachmentPath(for ref: FeedbackAttachmentRef, local: ModelContext) -> String? {
        let url = ref.url
        var descriptor = FetchDescriptor<FeedbackAttachmentLocal>(predicate: #Predicate { $0.remoteURL == url })
        descriptor.fetchLimit = 1
        return (try? local.fetch(descriptor))?.first?.localPath
    }

    private static func threadSummary(owner: String, repo: String, number: Int,
                                      title: String, cloud: ModelContext) -> ThreadSummary? {
        let threads = (try? cloud.fetch(FetchDescriptor<MailThread>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.issueNumber == number
        }))) ?? []
        guard !threads.isEmpty else { return nil }
        let messages = threads.flatMap { $0.messages ?? [] }.sorted { $0.date < $1.date }
        return ThreadSummary(messageCount: messages.count,
                             lastMessageAt: messages.last?.date,
                             lastDirection: messages.last.map { $0.isOutbound ? "outbound" : "inbound" })
    }
```

**Note for the implementer:** `MailThread`'s property names for the issue number, message list and direction may differ from the guesses above (`issueNumber`, `messages`, `isOutbound`, `date`). Open `AppFeedback/Models/MailThread.swift` and `MailMessage.swift` and use the real ones. If a mail thread cannot be located cheaply, return `nil` and drop the `thread` field rather than inventing a shape — a missing optional is honest; a wrong one is not.

- [ ] **Step 5: Add `TaskIndex.filter` and `TaskIndex.detail`**

```swift
    /// `--state open` (the default) hides completed tasks; `.all` shows everything;
    /// `.closed` shows only completed ones.
    func filter(_ flags: CLIFlags) -> [TaskItemDTO] {
        tasks
            .filter { task in
                switch flags.state {
                case .open:   if task.isCompleted { return false }
                case .closed: if !task.isCompleted { return false }
                case .all:    break
                }
                if !flags.statuses.isEmpty, !flags.statuses.contains(task.displayStatus) { return false }
                if !flags.priorities.isEmpty, !flags.priorities.contains(task.priority) { return false }
                if let version = flags.version, task.milestoneTitle != version { return false }
                if let query = flags.search, !query.isEmpty, !task.matchesSearch(query) { return false }
                return true
            }
            .map { task in
                TaskItemDTO(number: task.number, title: task.title,
                            status: task.displayStatus.rawValue, priority: task.priority.rawValue,
                            isClosed: task.isClosed, milestone: task.milestoneTitle,
                            feedback: task.feedbackRefs, url: "")   // url filled by the caller
            }
    }

    func detail(number: Int, config: ProductConfig, local: ModelContext) throws -> TaskDetail {
        guard let task = tasks.first(where: { $0.number == number }) else {
            throw CLIError.notFound(code: "task_not_found",
                                    message: "No cached task #\(number) in \(config.owner)/\(config.repo).",
                                    hint: "Run `\(CLIBranding.commandName) tasks --product <p>` to list them.")
        }
        let owner = config.owner, repo = config.repo
        let linked: [LinkedFeedback] = task.feedbackRefs.compactMap { reference in
            var descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo && $0.number == reference
            })
            descriptor.fetchLimit = 1
            guard let row = (try? local.fetch(descriptor))?.first else { return nil }
            return LinkedFeedback(number: row.number, title: row.title, state: row.state)
        }
        return TaskDetail(number: task.number, title: task.title,
                          status: task.displayStatus.rawValue, priority: task.priority.rawValue,
                          isClosed: task.isClosed, milestone: task.milestoneTitle,
                          notes: FeedbackTaskRefParser.prose(of: task.body),
                          feedback: linked,
                          url: "https://github.com/\(owner)/\(repo)/issues/\(number)")
    }
```

Because `filter` cannot build URLs without the config, give the caller a small helper on `TaskIndex`:

```swift
    static func withURLs(_ items: [TaskItemDTO], config: ProductConfig) -> [TaskItemDTO] {
        items.map {
            TaskItemDTO(number: $0.number, title: $0.title, status: $0.status, priority: $0.priority,
                        isClosed: $0.isClosed, milestone: $0.milestone, feedback: $0.feedback,
                        url: "https://github.com/\(config.owner)/\(config.repo)/issues/\($0.number)")
        }
    }
```

- [ ] **Step 6: Wire the three branches in `CLIRunner.execute`**

Each follows the `feedback list` shape. `feedback show` and `tasks show` return a single-element `items` array so every response has one envelope shape.

```swift
        case .feedback(.show(let number, let flags)):
            do {
                let store = try CLIStore.open()
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let detail = try FeedbackQuery.detail(number: number, flags: flags, config: config,
                                                      local: store.local, cloud: store.cloud, index: index)
                let asOf = ProductResolver.lastFetchedAt(local: store.local, owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           product: ProductResolver.ref(config), items: [detail])
                print(flags.json ? CLIOutput.encode(envelope) : CLIText.render(detail: detail))
                return CLIExitCode.success.rawValue
            } catch let error as CLIError { return emit(error: error) }
              catch { return emit(error: .noLocalData(message: error.localizedDescription, hint: nil)) }

        case .tasks(.list(let flags)):
            do {
                let store = try CLIStore.open()
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let all = TaskIndex.withURLs(index.filter(flags), config: config)
                let page = Array(all.dropFirst(flags.offset).prefix(flags.limit))
                let asOf = ProductResolver.lastFetchedAt(local: store.local, owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(
                    asOf: asOf, stale: isStale(asOf),
                    closedDataIncomplete: flags.state == .open ? nil : true,
                    product: ProductResolver.ref(config), filters: describe(flags),
                    page: PageInfo(limit: flags.limit, offset: flags.offset, total: all.count,
                                   hasMore: flags.offset + page.count < all.count),
                    items: page)
                print(flags.json ? CLIOutput.encode(envelope) : CLIText.render(tasks: page))
                return CLIExitCode.success.rawValue
            } catch let error as CLIError { return emit(error: error) }
              catch { return emit(error: .noLocalData(message: error.localizedDescription, hint: nil)) }

        case .tasks(.show(let number, let flags)):
            do {
                let store = try CLIStore.open()
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let detail = try index.detail(number: number, config: config, local: store.local)
                let asOf = ProductResolver.lastFetchedAt(local: store.local, owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           product: ProductResolver.ref(config), items: [detail])
                print(flags.json ? CLIOutput.encode(envelope) : CLIText.render(taskDetail: detail))
                return CLIExitCode.success.rawValue
            } catch let error as CLIError { return emit(error: error) }
              catch { return emit(error: .noLocalData(message: error.localizedDescription, hint: nil)) }
```

Add matching one-line stubs to `CLIText` for `detail:`, `tasks:` and `taskDetail:` (Task 8 replaces them all).

- [ ] **Step 7: Run the tests and try it live**

```bash
xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/FeedbackQueryTests -only-testing:AppFeedbackTests_macOS/TaskIndexTests
"$BIN" feedback show 559 --product "Usage for Claude"
"$BIN" tasks --product "Usage for Claude" --limit 5
"$BIN" tasks show 557 --product "Usage for Claude"
```

Expected: tests PASS; the detail calls print full descriptions and linked feedback.

- [ ] **Step 8: Commit**

```bash
git add AppFeedback/CLI/ AppFeedbackTests/FeedbackQueryTests.swift \
        AppFeedbackTests/TaskIndexTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): add feedback show and the tasks read commands"
```

---

## Task 8: The `--text` renderer

**Files:**
- Modify: `AppFeedback/CLI/CLIOutput.swift` (replace every `CLIText` stub)
- Test: `AppFeedbackTests/CLIOutputTests.swift`

**Interfaces:**
- Produces: `CLIText.render(products:)`, `render(feedback:)`, `render(detail:)`, `render(tasks:)`, `render(taskDetail:)` — all `-> String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIOutputTests: XCTestCase {

    private func makeItem(number: Int, title: String, app: String? = "Zcode",
                          tasks: [TaskRef] = []) -> FeedbackItem {
        FeedbackItem(number: number, title: title, app: app, appVersion: "1.0", source: "sdk",
                     type: "bug", rating: nil, state: "open",
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     device: "iPhone", os: "iOS 18.6", email: nil, description: "d",
                     truncated: false, labels: ["bug"], tasks: tasks, triage: nil,
                     url: "https://github.com/o/r/issues/\(number)")
    }

    // MARK: - JSON contract

    func testJSONUsesISO8601AndSortedKeys() {
        let envelope = CLIEnvelope(asOf: Date(timeIntervalSince1970: 1_700_000_000),
                                   stale: false, items: [makeItem(number: 1, title: "T")])
        let json = CLIOutput.encode(envelope)
        XCTAssertTrue(json.contains("\"asOf\" : \"2023-11-14T22:13:20Z\""), json)
        // sortedKeys: asOf precedes items, items precedes stale
        let asOfIndex = try? XCTUnwrap(json.range(of: "\"asOf\""))
        let staleIndex = try? XCTUnwrap(json.range(of: "\"stale\""))
        XCTAssertTrue((asOfIndex??.lowerBound ?? json.startIndex) < (staleIndex??.lowerBound ?? json.startIndex))
    }

    func testJSONDoesNotEscapeSlashesInURLs() {
        let envelope = CLIEnvelope(stale: false, items: [makeItem(number: 1, title: "T")])
        XCTAssertTrue(CLIOutput.encode(envelope).contains("https://github.com/o/r/issues/1"))
    }

    func testNilOptionalsAreOmittedNotNulled() {
        let envelope = CLIEnvelope(stale: false, items: [makeItem(number: 1, title: "T")])
        let json = CLIOutput.encode(envelope)
        XCTAssertFalse(json.contains("\"page\""), "page is nil and should be omitted")
        XCTAssertFalse(json.contains("\"closedDataIncomplete\""))
    }

    // MARK: - Text rendering

    func testFeedbackTextIncludesNumberTitleAndTaskMarker() {
        let tracked = makeItem(number: 559, title: "Crash on launch",
                               tasks: [TaskRef(number: 557, title: "Fix", status: "todo",
                                               priority: "high", isClosed: false)])
        let text = CLIText.render(feedback: [tracked, makeItem(number: 560, title: "Slow sync")])
        XCTAssertTrue(text.contains("559"))
        XCTAssertTrue(text.contains("Crash on launch"))
        XCTAssertTrue(text.contains("#557"), "tracked items should show their task")
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testTextRenderingOfAnEmptyListIsAFriendlyLine() {
        XCTAssertEqual(CLIText.render(feedback: []), "No matching feedback.")
        XCTAssertEqual(CLIText.render(tasks: []), "No matching tasks.")
        XCTAssertEqual(CLIText.render(products: []), "No products configured.")
    }

    func testTextTruncatesLongTitlesToKeepColumnsAligned() {
        let long = String(repeating: "x", count: 200)
        let text = CLIText.render(feedback: [makeItem(number: 1, title: long)])
        XCTAssertTrue(text.count < 150, "expected a truncated single line, got \(text.count) chars")
        XCTAssertTrue(text.contains("…"))
    }

    func testProductTextShowsRepoAndCounts() {
        let summary = ProductSummary(id: "id", displayName: "Usage for Claude", repo: "hayek/FeedbackRepo",
                                     connectedRepo: "hayek/UsageForClaude",
                                     apps: [AppSummary(name: "Zcode", count: 5, hidden: false)],
                                     versions: [], sources: SourceFlags(sdk: true, appStore: false, email: false),
                                     feedbackCount: 499, taskCount: 40, lastFetchedAt: nil)
        let text = CLIText.render(products: [summary])
        XCTAssertTrue(text.contains("Usage for Claude"))
        XCTAssertTrue(text.contains("hayek/FeedbackRepo"))
        XCTAssertTrue(text.contains("499"))
        XCTAssertTrue(text.contains("40"))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIOutputTests`

Expected: failures in the text tests (the stubs don't truncate or handle empties) and possibly the omit-nil test.

- [ ] **Step 3: Make optionals omit rather than null, and write the real renderers**

`CLIEnvelope` already uses optionals; `JSONEncoder` omits `nil` optional properties by default, so `testNilOptionalsAreOmittedNotNulled` should pass once the stubs are gone. Replace the whole `CLIText` enum:

```swift
enum CLIText {
    private static let titleWidth = 60

    private static func clip(_ text: String, _ width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }

    static func render(products: [ProductSummary]) -> String {
        guard !products.isEmpty else { return "No products configured." }
        return products.map { product in
            let apps = product.apps.filter { !$0.hidden }.map(\.name).joined(separator: ", ")
            return """
            \(product.displayName)  [\(product.repo)]
              feedback: \(product.feedbackCount)   tasks: \(product.taskCount)
              apps: \(apps.isEmpty ? "—" : apps)
              code repo: \(product.connectedRepo ?? "—")
              id: \(product.id)
            """
        }.joined(separator: "\n\n")
    }

    static func render(feedback items: [FeedbackItem]) -> String {
        guard !items.isEmpty else { return "No matching feedback." }
        return items.map { item in
            let tasks = item.tasks.isEmpty ? "" : "  → " + item.tasks.map { "#\($0.number)" }.joined(separator: " ")
            let rating = item.rating.map { " \($0)★" } ?? ""
            return "#\(item.number)  \(item.state.padding(toLength: 6, withPad: " ", startingAt: 0))  "
                 + "\(clip(item.app ?? "—", 18).padding(toLength: 18, withPad: " ", startingAt: 0))  "
                 + "\(clip(item.title, titleWidth))\(rating)\(tasks)"
        }.joined(separator: "\n")
    }

    static func render(detail: FeedbackDetail) -> String {
        var lines = [
            "#\(detail.number)  \(detail.title)",
            "\(detail.state) · \(detail.source) · \(detail.app ?? "—") \(detail.appVersion ?? "")",
            "\(detail.device ?? "—") · \(detail.os ?? "—") · \(CLIOutput.iso8601.string(from: detail.createdAt))",
        ]
        if let email = detail.email { lines.append("reporter: \(email)") }
        if !detail.labels.isEmpty { lines.append("labels: \(detail.labels.joined(separator: ", "))") }
        if !detail.tasks.isEmpty {
            lines.append("tasks: " + detail.tasks.map { "#\($0.number) \($0.status)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append(detail.description)
        lines.append("")
        lines.append(detail.url)
        return lines.joined(separator: "\n")
    }

    static func render(tasks: [TaskItemDTO]) -> String {
        guard !tasks.isEmpty else { return "No matching tasks." }
        return tasks.map { task in
            let feedback = task.feedback.isEmpty ? "" : "  ← " + task.feedback.map { "#\($0)" }.joined(separator: " ")
            return "#\(task.number)  \(task.status.padding(toLength: 12, withPad: " ", startingAt: 0))  "
                 + "\(task.priority.padding(toLength: 5, withPad: " ", startingAt: 0))  "
                 + "\(clip(task.title, titleWidth))\(feedback)"
        }.joined(separator: "\n")
    }

    static func render(taskDetail: TaskDetail) -> String {
        var lines = [
            "#\(taskDetail.number)  \(taskDetail.title)",
            "\(taskDetail.status) · \(taskDetail.priority) · \(taskDetail.milestone ?? "no version")",
        ]
        if !taskDetail.feedback.isEmpty {
            lines.append("addresses: " + taskDetail.feedback
                .map { "#\($0.number) \(clip($0.title, 40))" }.joined(separator: "\n           "))
        }
        lines.append("")
        lines.append(taskDetail.notes.isEmpty ? "(no notes)" : taskDetail.notes)
        lines.append("")
        lines.append(taskDetail.url)
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIOutputTests`

Expected: all PASS.

- [ ] **Step 5: Eyeball the text output**

```bash
"$BIN" products --text
"$BIN" feedback --product "Usage for Claude" --limit 10 --text
"$BIN" tasks --product "Usage for Claude" --limit 10 --text
```

Expected: aligned, readable columns; no wrapped lines at 120 columns.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/CLI/CLIOutput.swift AppFeedbackTests/CLIOutputTests.swift
git commit -m "feat(cli): render human-readable tables for --text"
```

---

## Task 9: IPC transport

**Files:**
- Create: `AppFeedback/CLI/CLIIPCMessage.swift`
- Create: `AppFeedback/CLI/CLIIPCTransport.swift`
- Test: `AppFeedbackTests/CLIIPCTests.swift`

**Interfaces:**
- Produces: `struct CLIRequest: Codable` (`id: UUID`, `kind: CLIRequestKind`, `payload: [String: String]`), `enum CLIRequestKind: String, Codable` (`refresh`, `createTask`, `linkTask`, `unlinkTask`, `respond`), `struct CLIResponse: Codable` (`id: UUID`, `ok: Bool`, `errorCode: String?`, `errorMessage: String?`, `warnings: [String]`, `json: String?`), `CLIIPCTransport.write(request:in:)`, `.readRequest(id:in:)`, `.write(response:in:)`, `.readResponse(id:in:)`, `.sweep(in:olderThan:)`, `CLIIPCTransport.directory`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIIPCTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "cliipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRequestRoundTrips() throws {
        let request = CLIRequest(id: UUID(), kind: .createTask,
                                 payload: ["title": "Fix the crash", "productID": UUID().uuidString])
        try CLIIPCTransport.write(request: request, in: directory)
        let recovered = try CLIIPCTransport.readRequest(id: request.id, in: directory)
        XCTAssertEqual(recovered.kind, .createTask)
        XCTAssertEqual(recovered.payload["title"], "Fix the crash")
    }

    func testResponseRoundTrips() throws {
        let id = UUID()
        let response = CLIResponse(id: id, ok: true, warnings: ["#99 is not cached"], json: "{\"number\":42}")
        try CLIIPCTransport.write(response: response, in: directory)
        let recovered = try CLIIPCTransport.readResponse(id: id, in: directory)
        XCTAssertTrue(recovered.ok)
        XCTAssertEqual(recovered.warnings, ["#99 is not cached"])
        XCTAssertEqual(recovered.json, "{\"number\":42}")
    }

    func testFailureResponseCarriesCodeAndMessage() throws {
        let id = UUID()
        try CLIIPCTransport.write(response: CLIResponse(id: id, ok: false, errorCode: "no_token",
                                                        errorMessage: "No GitHub token"), in: directory)
        let recovered = try CLIIPCTransport.readResponse(id: id, in: directory)
        XCTAssertFalse(recovered.ok)
        XCTAssertEqual(recovered.errorCode, "no_token")
    }

    func testReadingAMissingResponseThrows() {
        XCTAssertThrowsError(try CLIIPCTransport.readResponse(id: UUID(), in: directory))
    }

    /// A long email body must survive — this is exactly why payloads are files, not
    /// distributed-notification userInfo.
    func testLargePayloadSurvives() throws {
        let body = String(repeating: "Thanks for the detailed report. ", count: 2_000)
        let request = CLIRequest(id: UUID(), kind: .respond, payload: ["body": body])
        try CLIIPCTransport.write(request: request, in: directory)
        XCTAssertEqual(try CLIIPCTransport.readRequest(id: request.id, in: directory).payload["body"], body)
    }

    func testReadingConsumesTheFile() throws {
        let request = CLIRequest(id: UUID(), kind: .refresh, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)
        _ = try CLIIPCTransport.readRequest(id: request.id, in: directory)
        XCTAssertThrowsError(try CLIIPCTransport.readRequest(id: request.id, in: directory),
                             "a consumed request must not be readable twice")
    }

    func testSweepRemovesStaleFilesOnly() throws {
        let old = CLIRequest(id: UUID(), kind: .refresh, payload: [:])
        let fresh = CLIRequest(id: UUID(), kind: .refresh, payload: [:])
        try CLIIPCTransport.write(request: old, in: directory)
        try CLIIPCTransport.write(request: fresh, in: directory)

        let oldPath = CLIIPCTransport.requestURL(id: old.id, in: directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                              ofItemAtPath: oldPath.path)
        CLIIPCTransport.sweep(in: directory, olderThan: 3600)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CLIIPCTransport.requestURL(id: fresh.id, in: directory).path))
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        XCTAssertTrue(CLIIPCTransport.directory.path.contains("Application Support"))
        XCTAssertEqual(CLIIPCTransport.directory.lastPathComponent, "cli-ipc")
    }

    func testNotificationNamesAreDistinctAndBranded() {
        XCTAssertNotEqual(CLIBranding.requestNotification, CLIBranding.responseNotification)
        XCTAssertTrue(CLIBranding.requestNotification.hasPrefix("com.amirhayek.AppFeedback.cli"))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIIPCTests`

Expected: compile failure — the IPC types do not exist.

- [ ] **Step 3: Write `CLIIPCMessage.swift`**

```swift
#if os(macOS)
import Foundation

enum CLIRequestKind: String, Codable {
    case refresh
    case createTask
    case linkTask
    case unlinkTask
    case respond
}

/// Payload values are strings so the envelope stays trivially Codable across the process
/// boundary; numeric fields are parsed by the responder.
struct CLIRequest: Codable {
    let id: UUID
    let kind: CLIRequestKind
    var payload: [String: String]
}

struct CLIResponse: Codable {
    let id: UUID
    let ok: Bool
    var errorCode: String?
    var errorMessage: String?
    var errorHint: String?
    var warnings: [String] = []
    /// The successful result, already JSON-encoded by the app side.
    var json: String?
}
#endif
```

- [ ] **Step 4: Write `CLIIPCTransport.swift`**

```swift
#if os(macOS)
import Foundation

/// File-backed request/response passing. Distributed-notification userInfo is plist/XPC
/// bounded and cannot carry an email body, so only the correlation UUID travels in the
/// notification and the payload lands on disk.
enum CLIIPCTransport {

    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "AppFeedback", directoryHint: .isDirectory)
            .appending(path: "cli-ipc", directoryHint: .isDirectory)
    }

    static func requestURL(id: UUID, in directory: URL) -> URL {
        directory.appending(path: "req-\(id.uuidString).json")
    }

    static func responseURL(id: UUID, in directory: URL) -> URL {
        directory.appending(path: "res-\(id.uuidString).json")
    }

    static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func write(request: CLIRequest, in directory: URL) throws {
        try ensureDirectory(directory)
        try JSONEncoder().encode(request).write(to: requestURL(id: request.id, in: directory), options: .atomic)
    }

    static func readRequest(id: UUID, in directory: URL) throws -> CLIRequest {
        let url = requestURL(id: id, in: directory)
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)   // the reader consumes it
        return try JSONDecoder().decode(CLIRequest.self, from: data)
    }

    static func write(response: CLIResponse, in directory: URL) throws {
        try ensureDirectory(directory)
        try JSONEncoder().encode(response).write(to: responseURL(id: response.id, in: directory), options: .atomic)
    }

    static func readResponse(id: UUID, in directory: URL) throws -> CLIResponse {
        let url = responseURL(id: id, in: directory)
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return try JSONDecoder().decode(CLIResponse.self, from: data)
    }

    /// Drops abandoned files (a CLI that was killed mid-wait, or a request no app answered).
    static func sweep(in directory: URL = directory, olderThan seconds: TimeInterval = 3600) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }
}
#endif
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIIPCTests`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/CLI/CLIIPCMessage.swift AppFeedback/CLI/CLIIPCTransport.swift \
        AppFeedbackTests/CLIIPCTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): add file-backed IPC envelopes and transport"
```

---

## Task 10: `--refresh` — client, responder, and app wiring

**Files:**
- Create: `AppFeedback/CLI/CLIRequestClient.swift`
- Create: `AppFeedback/Services/CLIRequestResponder.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (create the responder in `init`, sweep the IPC directory)
- Modify: `AppFeedback/CLI/CLIRunner.swift` (honour `--refresh` on all four read commands)
- Test: `AppFeedbackTests/CLIIPCTests.swift` (extend)

**Interfaces:**
- Consumes: `CLIRequest`, `CLIResponse`, `CLIIPCTransport`, `IssueLoaderRegistry.load(productID:)`.
- Produces: `CLIRequestClient.isAppRunning() -> Bool`, `CLIRequestClient.send(_ request: CLIRequest, timeout: TimeInterval) async throws -> CLIResponse`; `CLIRequestResponder(handler:)` with `start()`.

- [ ] **Step 1: Write the failing test**

The distributed-notification hop needs two processes, so the unit tests cover everything either side of it: the client's not-running guard, the responder's dispatch, and the suspension-behaviour registration that Task 10's whole reliability rests on.

Append to `CLIIPCTests.swift`:

```swift
#if os(macOS)
final class CLIRequestResponderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "cliresp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testResponderRunsTheHandlerAndWritesASuccessResponse() async throws {
        let request = CLIRequest(id: UUID(), kind: .refresh, payload: ["productID": UUID().uuidString])
        try CLIIPCTransport.write(request: request, in: directory)

        let responder = CLIRequestResponder(directory: directory) { received in
            XCTAssertEqual(received.kind, .refresh)
            return CLIResponse(id: received.id, ok: true, json: "{\"refreshed\":true}")
        }
        await responder.handle(requestID: request.id)

        let response = try CLIIPCTransport.readResponse(id: request.id, in: directory)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.json, "{\"refreshed\":true}")
    }

    @MainActor
    func testResponderTurnsAThrownErrorIntoAFailureResponse() async throws {
        struct Boom: Error {}
        let request = CLIRequest(id: UUID(), kind: .createTask, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)

        let responder = CLIRequestResponder(directory: directory) { _ in throw Boom() }
        await responder.handle(requestID: request.id)

        let response = try CLIIPCTransport.readResponse(id: request.id, in: directory)
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.errorMessage)
    }

    @MainActor
    func testResponderIgnoresAnUnknownRequestIDWithoutCrashing() async {
        let responder = CLIRequestResponder(directory: directory) { _ in
            XCTFail("handler must not run for a missing request")
            return CLIResponse(id: UUID(), ok: true)
        }
        await responder.handle(requestID: UUID())
    }

    /// AppKit suspends distributed-notification delivery while the app is inactive — which it
    /// always is when an agent drives a terminal. Without .deliverImmediately every --refresh
    /// would hang until the app next came forward.
    func testResponderRegistersForImmediateDelivery() {
        XCTAssertEqual(CLIRequestResponder.suspensionBehavior, .deliverImmediately)
    }

    func testClientReportsAppNotRunningWhenTheBundleIsAbsent() {
        // The test host is not the AppFeedback app bundle, so this must be false.
        XCTAssertFalse(CLIRequestClient.isAppRunning(bundleIdentifier: "com.example.definitely.not.running"))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIRequestResponderTests`

Expected: compile failure — `CLIRequestResponder`, `CLIRequestClient` do not exist.

- [ ] **Step 3: Write `CLIRequestClient.swift`**

```swift
#if os(macOS)
import Foundation
import AppKit

enum CLIRequestClient {

    static func isAppRunning(bundleIdentifier: String = CLIBranding.bundleIdentifier) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Writes the request, pings the app, and waits for its reply. Throws `.appNotRunning`
    /// up front and `.remote` on timeout.
    static func send(_ request: CLIRequest, timeout: TimeInterval) async throws -> CLIResponse {
        guard isAppRunning() else { throw CLIError.appNotRunning }

        let directory = CLIIPCTransport.directory
        try CLIIPCTransport.write(request: request, in: directory)

        let center = DistributedNotificationCenter.default()
        let response: CLIResponse? = await withCheckedContinuation { continuation in
            var finished = false
            let lock = NSLock()
            var observer: NSObjectProtocol?

            func finish(_ value: CLIResponse?) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                if let observer { center.removeObserver(observer) }
                continuation.resume(returning: value)
            }

            observer = center.addObserver(
                forName: Notification.Name(CLIBranding.responseNotification),
                object: nil, queue: .main
            ) { notification in
                guard let raw = notification.userInfo?["id"] as? String,
                      UUID(uuidString: raw) == request.id else { return }   // ignore other CLIs' replies
                finish(try? CLIIPCTransport.readResponse(id: request.id, in: directory))
            }

            // deliverImmediately is load-bearing: AppKit suspends delivery to an inactive app.
            center.postNotificationName(Notification.Name(CLIBranding.requestNotification),
                                        object: nil, userInfo: ["id": request.id.uuidString],
                                        deliverImmediately: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }

        guard let response else {
            throw CLIError.remote(
                message: "AppFeedback did not answer within \(Int(timeout))s.",
                hint: "The app is running but busy. For a write, the outcome is unknown — check the app before retrying.")
        }
        return response
    }
}
#endif
```

- [ ] **Step 4: Write `CLIRequestResponder.swift`**

```swift
#if os(macOS)
import Foundation

/// App-side half of the CLI channel. Observes request pings, runs the handler on the main
/// actor (every app service it calls is @MainActor), and writes the reply back.
@MainActor
final class CLIRequestResponder {

    /// AppKit suspends distributed-notification delivery while the app is inactive, which it
    /// always is when an agent drives a terminal. Immediate delivery is mandatory.
    static let suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior = .deliverImmediately

    typealias Handler = @MainActor (CLIRequest) async throws -> CLIResponse

    private let directory: URL
    private let handler: Handler
    private var observer: NSObjectProtocol?

    init(directory: URL = CLIIPCTransport.directory, handler: @escaping Handler) {
        self.directory = directory
        self.handler = handler
    }

    func start() {
        CLIIPCTransport.sweep(in: directory)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(CLIBranding.requestNotification),
            object: nil, queue: .main, suspensionBehavior: Self.suspensionBehavior
        ) { [weak self] notification in
            guard let raw = notification.userInfo?["id"] as? String, let id = UUID(uuidString: raw) else { return }
            Task { @MainActor in await self?.handle(requestID: id) }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Exposed for tests: reads the request, runs the handler, writes the response, pings back.
    func handle(requestID: UUID) async {
        guard let request = try? CLIIPCTransport.readRequest(id: requestID, in: directory) else { return }
        var response: CLIResponse
        do {
            response = try await handler(request)
        } catch let error as CLIError {
            response = CLIResponse(id: requestID, ok: false, errorCode: error.code,
                                   errorMessage: error.message, errorHint: error.hint)
        } catch {
            response = CLIResponse(id: requestID, ok: false, errorCode: "remote_failure",
                                   errorMessage: error.localizedDescription)
        }
        try? CLIIPCTransport.write(response: response, in: directory)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(CLIBranding.responseNotification),
            object: nil, userInfo: ["id": requestID.uuidString], deliverImmediately: true)
    }
}
#endif
```

- [ ] **Step 5: Create the responder in the app**

In `AppFeedbackApp`, add a stored property and start it at the end of `init`. It must be created in `init` rather than `onAppear` so it answers regardless of window state.

```swift
    #if os(macOS)
    @State private var cliResponder: CLIRequestResponder?
    #endif
```

At the end of `init()`, after the other stores are built:

```swift
        #if os(macOS)
        // Registered here, not in a view, so the CLI channel is live regardless of windows.
        let registry = issueLoaderRegistry          // capture the already-built registry
        let responder = CLIRequestResponder { request in
            try await CLIRequestHandlers.handle(request, registry: registry)
        }
        responder.start()
        _cliResponder = State(initialValue: responder)
        #endif
```

Create the handler dispatcher in `CLIRequestResponder.swift` (below the class). `refresh` is the only kind implemented here; Tasks 12-14 fill in the rest.

```swift
@MainActor
enum CLIRequestHandlers {
    static func handle(_ request: CLIRequest, registry: IssueLoaderRegistry) async throws -> CLIResponse {
        switch request.kind {
        case .refresh:
            if let raw = request.payload["productID"], let id = UUID(uuidString: raw) {
                await registry.load(productID: id)      // scoped: only the product being asked about
            } else {
                await registry.loadAll()
            }
            return CLIResponse(id: request.id, ok: true)
        default:
            throw CLIError.remote(message: "\(request.kind.rawValue) is not implemented yet.")
        }
    }
}
```

- [ ] **Step 6: Honour `--refresh` in the read commands**

Add this helper to `CLIRunner` and call it at the top of each read branch, right after resolving the product. A refresh timeout is **not** fatal for a read: answer from cache and say so.

```swift
    /// Returns (refreshed, timedOut). Throws only for app-not-running.
    static func refreshIfRequested(_ flags: CLIFlags, productID: UUID?) async throws -> Bool {
        guard flags.refresh else { return false }
        var payload: [String: String] = [:]
        if let productID { payload["productID"] = productID.uuidString }
        let request = CLIRequest(id: UUID(), kind: .refresh, payload: payload)
        do {
            _ = try await CLIRequestClient.send(request, timeout: flags.timeout)
            return false
        } catch CLIError.appNotRunning {
            throw CLIError.appNotRunning
        } catch {
            return true            // timed out — fall through to the cache
        }
    }
```

In each read branch, after `let config = try ProductResolver.resolve(...)`:

```swift
                let refreshTimedOut = try await refreshIfRequested(flags, productID: config.id)
                // reopen so the fetch sees what the app just wrote
                let store = try CLIStore.open()
```

and set `refreshTimedOut: refreshTimedOut ? true : nil` on the envelope. For `products`, pass `productID: nil` and open the store after the refresh.

**Ordering matters:** the store must be opened *after* the refresh completes, or the fetch reads pre-refresh data. Restructure each branch so `CLIStore.open()` happens twice only if needed — simplest correct form: resolve the product from a first short-lived store, refresh, then open a fresh store for the actual query.

- [ ] **Step 7: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIRequestResponderTests -only-testing:AppFeedbackTests_macOS/CLIIPCTests`

Expected: all PASS.

- [ ] **Step 8: Verify the round trip against the running app**

Install the new build (`cp -R` the built `.app` over `/Applications/AppFeedback.app`, or run the built one), launch the GUI, then from a terminal:

```bash
time "$BIN" feedback --product "Usage for Claude" --limit 1 --refresh
```

Expected: completes in a few seconds (not 30), and `asOf` is within the last minute. Then quit the app and re-run:

```bash
"$BIN" feedback --product "Usage for Claude" --limit 1 --refresh ; echo "exit=$?"
```

Expected: `exit=6` with `app_not_running`. **If the first command takes exactly the timeout, the suspension behaviour is wrong** — recheck `.deliverImmediately` on both the observer and the post.

- [ ] **Step 9: Commit**

```bash
git add AppFeedback/CLI/CLIRequestClient.swift AppFeedback/Services/CLIRequestResponder.swift \
        AppFeedback/App/AppFeedbackApp.swift AppFeedback/CLI/CLIRunner.swift \
        AppFeedbackTests/CLIIPCTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): add --refresh over the app IPC channel"
```

---

## Task 11: `GitHubIssueWriter.fetchIssue`

**Files:**
- Modify: `AppFeedback/Services/GitHubIssueWriter.swift:6-10` (protocol), `:40-88` (implementation)
- Test: `AppFeedbackTests/GitHubIssueWriterTests.swift` (extend)

**Interfaces:**
- Produces: `func fetchIssue(owner:repo:number:token:) async throws -> FetchedIssue` on the writer protocol, where `struct FetchedIssue { let number: Int; let title: String; let body: String; let labels: [String]; let state: String }`.

- [ ] **Step 1: Write the failing test**

Follow the existing stubbed-`URLProtocol` pattern already used in `GitHubIssueWriterTests.swift` — read that file first and reuse its fake session helper rather than inventing a second one.

```swift
#if os(macOS)
extension GitHubIssueWriterTests {

    func testFetchIssueParsesBodyAndLabels() async throws {
        let json = """
        {"number": 557, "title": "Fix the crash", "state": "open",
         "body": "Notes\\n\\n<!-- appfeedback:addresses -->\\nAddresses: #10, #11\\n<!-- /appfeedback:addresses -->",
         "labels": [{"name": "appfeedback:task"}, {"name": "status:todo"}]}
        """
        let writer = makeWriter(responding: json, status: 200)
        let issue = try await writer.fetchIssue(owner: "o", repo: "r", number: 557, token: "t")

        XCTAssertEqual(issue.number, 557)
        XCTAssertEqual(issue.title, "Fix the crash")
        XCTAssertEqual(issue.state, "open")
        XCTAssertEqual(issue.labels, ["appfeedback:task", "status:todo"])
        XCTAssertEqual(FeedbackTaskRefParser.parse(issue.body), [10, 11])
    }

    func testFetchIssueMapsNotFoundToAnError() async {
        let writer = makeWriter(responding: #"{"message":"Not Found"}"#, status: 404)
        do {
            _ = try await writer.fetchIssue(owner: "o", repo: "r", number: 999, token: "t")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue("\(error)".contains("404"))
        }
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/GitHubIssueWriterTests`

Expected: compile failure — `fetchIssue` does not exist. (If `makeWriter(responding:status:)` doesn't exist in that file under that name, adapt the test to the helper that is there.)

- [ ] **Step 3: Add `FetchedIssue` and `fetchIssue`**

Add to the protocol declaration at the top of `GitHubIssueWriter.swift`, then implement:

```swift
struct FetchedIssue: Sendable {
    let number: Int
    let title: String
    let body: String
    let labels: [String]
    let state: String
}
```

```swift
    /// Reads one issue. `tasks link` needs the LIVE body: rewriting the addresses block from
    /// the cached body would clobber any edit made since the last poll.
    func fetchIssue(owner: String, repo: String, number: Int, token: String) async throws -> FetchedIssue {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw WriteError.apiError(code, message: message)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int else {
            throw WriteError.apiError(http.statusCode, message: "Malformed issue response")
        }
        let labels = (object["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return FetchedIssue(number: number,
                            title: object["title"] as? String ?? "",
                            body: object["body"] as? String ?? "",
                            labels: labels,
                            state: object["state"] as? String ?? "open")
    }
```

**Note:** match the existing error type's real name (the file's own `enum` for write failures) rather than assuming `WriteError`, and add `fetchIssue` to the protocol so fakes in the test suite must implement it. Update any existing fake writer in `AppFeedbackTests/Fakes/` to satisfy the new requirement.

- [ ] **Step 4: Run the tests**

Run the full macOS suite so any fake that now fails to conform surfaces immediately:

`xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS`

Expected: only the known Keychain/GitHubAccountStore failures remain.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/GitHubIssueWriter.swift AppFeedbackTests/GitHubIssueWriterTests.swift \
        AppFeedbackTests/Fakes/
git commit -m "feat(github): read a single issue so link can rewrite the live body"
```

---

## Task 12: `tasks create`

**Files:**
- Modify: `AppFeedback/Services/CLIRequestResponder.swift` (handler)
- Modify: `AppFeedback/CLI/CLIRunner.swift` (command branch)
- Test: `AppFeedbackTests/CLIWriteCommandTests.swift`

**Interfaces:**
- Consumes: `TaskService.createTask(repo:title:prose:feedbackRefs:status:priority:milestoneNumber:)`, `IssueLoaderRegistry.load(productID:)`.
- Produces: `CLIRequestHandlers.createTask(_:deps:) async throws -> CLIResponse`; `struct CLIWriteDeps` carrying `taskService`, `registry`, `store`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
@MainActor
final class CLIWriteCommandTests: XCTestCase {

    private var context: ModelContext!
    private let config = ProductConfig(displayName: "P", owner: "o", repo: "r")

    override func setUpWithError() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(
            for: CachedIssue.self, ProjectVersion.self, configurations: modelConfig))
    }

    // MARK: - Milestone resolution

    func testResolvesVersionNameToMilestoneNumber() throws {
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0", milestoneNumber: 12))
        let resolved = try CLIRequestHandlers.milestoneNumber(forVersion: "1.4.0", config: config, cloud: context)
        XCTAssertEqual(resolved, 12)
    }

    func testNilMilestoneNumberIsAHardErrorNotASilentClear() {
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.5.0", milestoneNumber: nil))
        XCTAssertThrowsError(try CLIRequestHandlers.milestoneNumber(forVersion: "1.5.0",
                                                                   config: config, cloud: context)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "version_has_no_milestone")
        }
    }

    func testUnknownVersionIsNotFound() {
        XCTAssertThrowsError(try CLIRequestHandlers.milestoneNumber(forVersion: "9.9.9",
                                                                   config: config, cloud: context)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "version_not_found")
        }
    }

    func testNoVersionRequestedMeansNoMilestone() throws {
        XCTAssertNil(try CLIRequestHandlers.milestoneNumber(forVersion: nil, config: config, cloud: context))
    }

    // MARK: - Body and labels

    func testCreateBuildsTheAddressesBlockFromFeedbackRefs() {
        let body = TaskService.body(prose: "Root-cause it", feedbackRefs: [12, 34])
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [12, 34])
        XCTAssertTrue(body.hasPrefix("Root-cause it"))
    }

    func testCreateUsesTaskStatusAndPriorityLabels() {
        let labels = TaskService.labels(status: .inProgress, priority: .high)
        XCTAssertEqual(Set(labels), Set([AppFeedbackLabels.task, "status:in-progress", "priority:high"]))
    }

    // MARK: - Ref-set maths for link/unlink

    func testLinkUnionsWithTheLiveRefsAndSorts() {
        let live = FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 12])
        let updated = CLIRequestHandlers.rewriteRefs(in: live, adding: [11, 10], removing: [])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [10, 11, 12])
        XCTAssertEqual(FeedbackTaskRefParser.prose(of: updated), "notes")
    }

    func testUnlinkSubtracts() {
        let live = FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 11, 12])
        let updated = CLIRequestHandlers.rewriteRefs(in: live, adding: [], removing: [11])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [10, 12])
    }

    func testUnlinkingEverythingRemovesTheBlockButKeepsTheProse() {
        let live = FeedbackTaskRefParser.upsert(into: "notes", refs: [10])
        let updated = CLIRequestHandlers.rewriteRefs(in: live, adding: [], removing: [10])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [])
        XCTAssertEqual(updated.trimmingCharacters(in: .whitespacesAndNewlines), "notes")
    }

    func testUnknownFeedbackNumbersProduceWarningsNotFailures() {
        let row = CachedIssue(repoOwner: "o", repoName: "r", number: 10, title: "T", createdAt: Date(),
                              rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil,
                              email: nil, issueDescription: "")
        context.insert(row)
        let warnings = CLIRequestHandlers.warnAboutUncached([10, 99], config: config, local: context)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("99"))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIWriteCommandTests`

Expected: compile failure — the helpers do not exist.

- [ ] **Step 3: Add the helpers and the create handler**

In `CLIRequestResponder.swift`, extend `CLIRequestHandlers`:

```swift
    /// nil version ⇒ nil milestone (leave it alone). A version with no milestone number is a
    /// hard error: collapsing it to .some(nil) would silently CLEAR the task's milestone.
    static func milestoneNumber(forVersion version: String?, config: ProductConfig,
                                cloud: ModelContext) throws -> Int? {
        guard let version else { return nil }
        let owner = config.owner, repo = config.repo
        let versions = (try? cloud.fetch(FetchDescriptor<ProjectVersion>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        guard let match = versions.first(where: { $0.name == version }) else {
            throw CLIError.notFound(code: "version_not_found",
                                    message: "No version '\(version)' in \(owner)/\(repo).",
                                    hint: "Run `\(CLIBranding.commandName) products` to see the versions.",
                                    candidates: versions.map(\.name))
        }
        guard let number = match.milestoneNumber else {
            throw CLIError.notFound(code: "version_has_no_milestone",
                                    message: "Version '\(version)' has no GitHub milestone yet.",
                                    hint: "Create the milestone in AppFeedback first.")
        }
        return number
    }

    static func rewriteRefs(in body: String, adding: [Int], removing: [Int]) -> String {
        var refs = Set(FeedbackTaskRefParser.parse(body))
        refs.formUnion(adding)
        refs.subtract(removing)
        return FeedbackTaskRefParser.upsert(into: FeedbackTaskRefParser.prose(of: body),
                                            refs: refs.sorted())
    }

    /// Uncached numbers may be legitimately closed-and-never-cached, so warn rather than fail.
    static func warnAboutUncached(_ numbers: [Int], config: ProductConfig,
                                  local: ModelContext) -> [String] {
        let owner = config.owner, repo = config.repo
        return numbers.compactMap { number in
            var descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo && $0.number == number
            })
            descriptor.fetchLimit = 1
            let exists = ((try? local.fetch(descriptor))?.first) != nil
            return exists ? nil : "#\(number) is not in the local cache — linking it anyway."
        }
    }
```

Then the create handler, dispatched from `handle(_:registry:)`:

```swift
    static func createTask(_ request: CLIRequest, registry: IssueLoaderRegistry,
                           store: CLIStore, service: TaskService = TaskService()) async throws -> CLIResponse {
        let config = try resolveConfig(request, store: store)
        let title = request.payload["title"] ?? ""
        let prose = request.payload["notes"] ?? ""
        let refs = (request.payload["feedback"] ?? "").split(separator: ",").compactMap { Int($0) }
        let status = TaskStatus(rawValue: request.payload["status"] ?? "") ?? .todo
        let priority = TaskPriority(rawValue: request.payload["priority"] ?? "") ?? .med
        let milestone = try milestoneNumber(forVersion: request.payload["version"],
                                            config: config, cloud: store.cloud)
        let warnings = warnAboutUncached(refs, config: config, local: store.local)

        let number: Int
        do {
            number = try await service.createTask(repo: config, title: title, prose: prose,
                                                  feedbackRefs: refs, status: status,
                                                  priority: priority, milestoneNumber: milestone)
        } catch is TaskService.ServiceError {
            throw CLIError.auth(message: "No GitHub token for \(config.owner)/\(config.repo).",
                                hint: "Re-authenticate in AppFeedback's Settings.")
        } catch {
            throw CLIError.remote(message: error.localizedDescription)
        }

        await registry.load(productID: config.id)      // so the app shows it immediately

        let created = TaskItemDTO(number: number, title: title, status: status.rawValue,
                                  priority: priority.rawValue, isClosed: status == .done,
                                  milestone: request.payload["version"], feedback: refs.sorted(),
                                  url: "https://github.com/\(config.owner)/\(config.repo)/issues/\(number)")
        return CLIResponse(id: request.id, ok: true, warnings: warnings,
                           json: CLIOutput.encode(created))
    }

    static func resolveConfig(_ request: CLIRequest, store: CLIStore) throws -> ProductConfig {
        guard let query = request.payload["product"] else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--product is required"))
        }
        return try ProductResolver.resolve(query, cloud: store.cloud)
    }
```

The app-side handler opens its own `CLIStore` (read-only is fine — it only reads config and cache) at the top of `handle`.

- [ ] **Step 4: Wire the CLI branch**

```swift
        case .tasks(.create(let flags)):
            return await sendWrite(kind: .createTask, flags: flags, payload: [
                "product": flags.product,
                "title": flags.title ?? "",
                "notes": flags.notes ?? "",
                "status": flags.statuses.first?.rawValue ?? TaskStatus.todo.rawValue,
                "priority": flags.priorities.first?.rawValue ?? TaskPriority.med.rawValue,
                "version": flags.version ?? "",
                "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ","),
            ].filter { !$0.value.isEmpty })
```

with one shared helper on `CLIRunner`:

```swift
    static func sendWrite(kind: CLIRequestKind, flags: CLIFlags, payload: [String: String]) async -> Int32 {
        do {
            let response = try await CLIRequestClient.send(
                CLIRequest(id: UUID(), kind: kind, payload: payload), timeout: flags.timeout)
            guard response.ok else {
                return emit(error: mapRemote(response))
            }
            // The result is already JSON from the app side; wrap it so the shape matches reads.
            var envelope: [String: Any] = ["ok": true]
            if let json = response.json,
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
                envelope["result"] = object
            }
            if !response.warnings.isEmpty { envelope["warnings"] = response.warnings }
            if let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return CLIExitCode.success.rawValue
        } catch let error as CLIError {
            return emit(error: error)
        } catch {
            return emit(error: .remote(message: error.localizedDescription))
        }
    }

    static func mapRemote(_ response: CLIResponse) -> CLIError {
        let message = response.errorMessage ?? "The app reported a failure."
        switch response.errorCode {
        case "auth", "no_token":                    return .auth(message: message, hint: response.errorHint)
        case let code? where code.hasSuffix("_not_found"):
            return .notFound(code: code, message: message, hint: response.errorHint)
        case "missing_flag", "bad_value":
            return .usage(CLIUsageError(code: response.errorCode ?? "usage",
                                        message: message, hint: response.errorHint))
        default:                                    return .remote(message: message, hint: response.errorHint)
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIWriteCommandTests`

Expected: all PASS.

- [ ] **Step 6: Create a real task end to end**

With the app running:

```bash
"$BIN" tasks create --product "Usage for Claude" --title "CLI smoke test — delete me" \
   --notes "Created by the CLI end-to-end check." --priority low
```

Expected: `{"ok": true, "result": {...}}` with a real issue number and URL. Confirm the task appears in the app's UI **within seconds** (that is `registry.load(productID:)` working), then close the issue on GitHub.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Services/CLIRequestResponder.swift AppFeedback/CLI/CLIRunner.swift \
        AppFeedbackTests/CLIWriteCommandTests.swift
git commit -m "feat(cli): create tasks through the app's TaskService"
```

---

## Task 13: `tasks link` and `tasks unlink`

**Files:**
- Modify: `AppFeedback/Services/CLIRequestResponder.swift` (handler)
- Modify: `AppFeedback/CLI/CLIRunner.swift` (two branches)
- Test: `AppFeedbackTests/CLIWriteCommandTests.swift` (extend)

**Interfaces:**
- Consumes: `GitHubIssueWriter.fetchIssue`, `GitHubIssueWriter.updateIssue`, `CLIRequestHandlers.rewriteRefs`.
- Produces: `CLIRequestHandlers.linkTask(_:registry:store:writer:removing:) async throws -> CLIResponse`.

- [ ] **Step 1: Write the failing test**

Append to `CLIWriteCommandTests.swift`. Use a fake writer so no network is touched.

```swift
#if os(macOS)
final class FakeIssueWriter: GitHubIssueWriting {
    var fetched: FetchedIssue?
    private(set) var updatedBody: String?
    private(set) var updatedNumber: Int?

    func fetchIssue(owner: String, repo: String, number: Int, token: String) async throws -> FetchedIssue {
        guard let fetched else { throw CLIError.remote(message: "no stub") }
        return fetched
    }
    func updateIssue(owner: String, repo: String, number: Int, title: String?, body: String?,
                     labels: [String]?, state: String?, milestoneNumber: Int??, token: String) async throws {
        updatedNumber = number
        updatedBody = body
    }
    func createIssue(owner: String, repo: String, title: String, body: String,
                     labels: [String], milestoneNumber: Int?, token: String) async throws -> Int { 1 }
}

extension CLIWriteCommandTests {

    func testLinkRewritesTheLiveBodyNotTheCachedOne() async throws {
        // Cache says [10]; GitHub says [10, 20] — a link of 30 must produce [10, 20, 30].
        let cached = CachedIssue(repoOwner: "o", repoName: "r", number: 90, title: "Task",
                                 createdAt: Date(),
                                 rawBody: FeedbackTaskRefParser.upsert(into: "notes", refs: [10]),
                                 appName: nil, appVersion: nil, device: nil, osVersion: nil,
                                 email: nil, issueDescription: "",
                                 labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")])
        context.insert(cached)

        let writer = FakeIssueWriter()
        writer.fetched = FetchedIssue(number: 90, title: "Task",
                                      body: FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 20]),
                                      labels: [AppFeedbackLabels.task], state: "open")

        let body = CLIRequestHandlers.rewriteRefs(
            in: try await writer.fetchIssue(owner: "o", repo: "r", number: 90, token: "t").body,
            adding: [30], removing: [])
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [10, 20, 30],
                       "must union against the LIVE body, not the cached [10]")
    }

    func testLinkPatchesOnlyTheBody() async throws {
        let writer = FakeIssueWriter()
        writer.fetched = FetchedIssue(number: 90, title: "Task", body: "notes",
                                      labels: [AppFeedbackLabels.task], state: "open")
        try await writer.updateIssue(owner: "o", repo: "r", number: 90, title: nil,
                                     body: CLIRequestHandlers.rewriteRefs(in: "notes", adding: [7], removing: []),
                                     labels: nil, state: nil, milestoneNumber: nil, token: "t")
        XCTAssertEqual(writer.updatedNumber, 90)
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(writer.updatedBody)), [7])
    }
}
#endif
```

**Note:** `GitHubIssueWriting` is the existing protocol name in `GitHubIssueWriter.swift:6` — check the real name and the real `updateIssue` signature (which uses default arguments) and match the fake to it exactly.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIWriteCommandTests`

Expected: compile failure.

- [ ] **Step 3: Write the handler**

```swift
    static func linkTask(_ request: CLIRequest, registry: IssueLoaderRegistry, store: CLIStore,
                         writer: any GitHubIssueWriting = GitHubIssueWriter(),
                         removing: Bool) async throws -> CLIResponse {
        let config = try resolveConfig(request, store: store)
        guard let taskNumber = request.payload["task"].flatMap(Int.init) else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--task is required"))
        }
        let refs = (request.payload["feedback"] ?? "").split(separator: ",").compactMap { Int($0) }
        guard let token = KeychainService.loadSync(for: config) else {
            throw CLIError.auth(message: "No GitHub token for \(config.owner)/\(config.repo).",
                                hint: "Re-authenticate in AppFeedback's Settings.")
        }

        // The LIVE body is the source of truth — the cache may be up to 15 minutes behind and
        // rewriting from it would drop any edit made since the last poll.
        let live: FetchedIssue
        do {
            live = try await writer.fetchIssue(owner: config.owner, repo: config.repo,
                                               number: taskNumber, token: token)
        } catch {
            throw CLIError.notFound(code: "task_not_found",
                                    message: "Could not read task #\(taskNumber): \(error.localizedDescription)")
        }
        guard live.labels.contains(AppFeedbackLabels.task) else {
            throw CLIError.notFound(code: "task_not_found",
                                    message: "#\(taskNumber) is not a task.",
                                    hint: "It has no \(AppFeedbackLabels.task) label.")
        }

        let warnings = removing ? [] : warnAboutUncached(refs, config: config, local: store.local)
        let newBody = rewriteRefs(in: live.body, adding: removing ? [] : refs, removing: removing ? refs : [])
        do {
            try await writer.updateIssue(owner: config.owner, repo: config.repo, number: taskNumber,
                                         body: newBody, token: token)
        } catch {
            throw CLIError.remote(message: error.localizedDescription)
        }
        await registry.load(productID: config.id)

        let result = TaskDetail(number: taskNumber, title: live.title,
                                status: TaskStatus(labels: live.labels).rawValue,
                                priority: TaskPriority(labels: live.labels).rawValue,
                                isClosed: live.state == "closed", milestone: nil,
                                notes: FeedbackTaskRefParser.prose(of: newBody),
                                feedback: FeedbackTaskRefParser.parse(newBody).map {
                                    LinkedFeedback(number: $0, title: "", state: "")
                                },
                                url: "https://github.com/\(config.owner)/\(config.repo)/issues/\(taskNumber)")
        return CLIResponse(id: request.id, ok: true, warnings: warnings, json: CLIOutput.encode(result))
    }
```

**Note:** `updateIssue`'s real signature uses default arguments for the fields you are not changing — pass only `body:` and `token:` so labels, state and milestone are untouched. Verify against `GitHubIssueWriter.swift:54`.

- [ ] **Step 4: Wire both branches**

```swift
        case .tasks(.link(let flags)):
            return await sendWrite(kind: .linkTask, flags: flags, payload: [
                "product": flags.product,
                "task": String(flags.taskNumber ?? 0),
                "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ","),
            ])

        case .tasks(.unlink(let flags)):
            return await sendWrite(kind: .unlinkTask, flags: flags, payload: [
                "product": flags.product,
                "task": String(flags.taskNumber ?? 0),
                "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ","),
            ])
```

and dispatch both in `CLIRequestHandlers.handle`, passing `removing: request.kind == .unlinkTask`.

- [ ] **Step 5: Run the tests and verify live**

```bash
xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/CLIWriteCommandTests
"$BIN" tasks link --product "Usage for Claude" --task <task#> --feedback <feedback#>
"$BIN" tasks show <task#> --product "Usage for Claude"
"$BIN" tasks unlink --product "Usage for Claude" --task <task#> --feedback <feedback#>
```

Expected: the link appears on GitHub and in the app; unlink removes it; the task's prose is unchanged throughout.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/CLIRequestResponder.swift AppFeedback/CLI/CLIRunner.swift \
        AppFeedbackTests/CLIWriteCommandTests.swift
git commit -m "feat(cli): link and unlink feedback against a task's live body"
```

---

## Task 14: `respond`

**Files:**
- Modify: `AppFeedback/Services/CLIRequestResponder.swift` (handler + channel selection)
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (pass the mail/App Store dependencies into the responder)
- Modify: `AppFeedback/CLI/CLIRunner.swift` (branch)
- Test: `AppFeedbackTests/CLIWriteCommandTests.swift` (extend)

**Interfaces:**
- Consumes: `ComposeMailViewModel.send()`, `AppStoreResponseController.submit()`, `GitHubCommentPoster.postComment`, `MailThreadStore.threads(forIssue:)`, `IMAPClientProvider`.
- Produces: `CLIRequestHandlers.channel(for:requested:) throws -> CLIChannel`, `CLIRequestHandlers.respond(_:deps:) async throws -> CLIResponse`.

- [ ] **Step 1: Write the failing test**

Channel selection is the part worth unit-testing; the send paths are covered by the live check in Step 6 because they need real accounts.

```swift
#if os(macOS)
extension CLIWriteCommandTests {

    private func issue(number: Int, source: FeedbackSource, email: String?) -> FeedbackIssue {
        FeedbackIssue(number: number, title: "T", createdAt: Date(), rawBody: "", appName: nil,
                      appVersion: nil, device: nil, osVersion: nil, email: email,
                      description: "", labels: [], source: source)
    }

    func testAppStoreFeedbackAutoSelectsTheAppStoreChannel() throws {
        let channel = try CLIRequestHandlers.channel(for: issue(number: 1, source: .appStore, email: nil),
                                                     requested: .auto)
        XCTAssertEqual(channel, .appStore)
    }

    func testEmailSourceAutoSelectsEmail() throws {
        let channel = try CLIRequestHandlers.channel(for: issue(number: 1, source: .email, email: "a@b.com"),
                                                     requested: .auto)
        XCTAssertEqual(channel, .email)
    }

    func testSDKWithAnAddressAutoSelectsEmail() throws {
        let channel = try CLIRequestHandlers.channel(for: issue(number: 1, source: .sdk, email: "a@b.com"),
                                                     requested: .auto)
        XCTAssertEqual(channel, .email)
    }

    func testSDKWithoutAnAddressHasNoAutoChannel() {
        XCTAssertThrowsError(try CLIRequestHandlers.channel(for: issue(number: 1, source: .sdk, email: nil),
                                                            requested: .auto)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, let hint, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "no_reply_channel")
            XCTAssertTrue(hint?.contains("--via comment") == true)
        }
    }

    func testAnExplicitChannelOverridesAutoSelection() throws {
        let channel = try CLIRequestHandlers.channel(for: issue(number: 1, source: .appStore, email: nil),
                                                     requested: .comment)
        XCTAssertEqual(channel, .comment)
    }

    func testExplicitEmailWithoutAnAddressIsAnError() {
        XCTAssertThrowsError(try CLIRequestHandlers.channel(for: issue(number: 1, source: .sdk, email: nil),
                                                            requested: .email))
    }

    func testAppStoreBodyLengthIsValidatedAgainstTheDocumentedCap() {
        let tooLong = String(repeating: "x", count: AppStoreResponseController.maxBodyLength + 1)
        XCTAssertThrowsError(try CLIRequestHandlers.validateAppStoreBody(tooLong)) { error in
            guard let cliError = error as? CLIError, case .usage(let usage) = cliError else {
                return XCTFail("expected .usage")
            }
            XCTAssertEqual(usage.code, "bad_value")
        }
        XCTAssertNoThrow(try CLIRequestHandlers.validateAppStoreBody("short"))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIWriteCommandTests`

Expected: compile failure — `channel(for:requested:)` does not exist.

- [ ] **Step 3: Write channel selection and validation**

```swift
    static func channel(for issue: FeedbackIssue, requested: CLIChannel) throws -> CLIChannel {
        switch requested {
        case .comment:  return .comment
        case .appStore: return .appStore
        case .email:
            guard issue.email?.isEmpty == false else {
                throw CLIError.notFound(code: "no_reply_channel",
                                        message: "Feedback #\(issue.number) has no email address.",
                                        hint: "Use --via comment to comment on the issue instead.")
            }
            return .email
        case .auto:
            if issue.source == .appStore { return .appStore }
            if issue.email?.isEmpty == false { return .email }
            throw CLIError.notFound(code: "no_reply_channel",
                                    message: "Feedback #\(issue.number) has no email address and is not an App Store review.",
                                    hint: "Use --via comment to comment on the issue instead.")
        }
    }

    static func validateAppStoreBody(_ body: String) throws {
        guard body.count <= AppStoreResponseController.maxBodyLength else {
            throw CLIError.usage(CLIUsageError(
                code: "bad_value",
                message: "App Store responses are capped at \(AppStoreResponseController.maxBodyLength) characters; this is \(body.count).",
                hint: "Shorten the reply."))
        }
    }
```

- [ ] **Step 4: Write the respond handler**

The email path must reproduce the UI's request construction exactly. Read `InlineReplyView.swift:174-195`, `MailThreadView.swift:89-108` and `IssueCardView.swift:166-176` before writing this, and mirror them.

```swift
    struct RespondDeps {
        let accountStore: MailAccountStore
        let settingsStore: MailSettingsStore
        let threadStore: MailThreadStore
        let tracker: OutboundSendTracker
        let failureStore: OutboundFailureStore
        let activityLog: ActivityLog
        let mirror: MailToGitHubMirror?
        let templateStore: ReplyTemplateStore
    }

    static func respond(_ request: CLIRequest, registry: IssueLoaderRegistry, store: CLIStore,
                        deps: RespondDeps) async throws -> CLIResponse {
        let config = try resolveConfig(request, store: store)
        guard let number = request.payload["feedback"].flatMap(Int.init) else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--feedback is required"))
        }
        var flags = CLIFlags(); flags.product = request.payload["product"] ?? ""
        let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
        let detail = try FeedbackQuery.detail(number: number, flags: flags, config: config,
                                              local: store.local, cloud: store.cloud, index: index)
        // detail redacts the address; re-read the raw issue for the actual recipient.
        let issue = try rawIssue(number: number, config: config, local: store.local)

        let requested = CLIChannel(rawValue: request.payload["via"] ?? "auto") ?? .auto
        let selected = try channel(for: issue, requested: requested)

        var body = request.payload["body"] ?? ""
        if body.isEmpty, let templateTitle = request.payload["template"] {
            body = try templateBody(titled: templateTitle, config: config, store: deps.templateStore)
        }

        switch selected {
        case .comment:
            guard let token = KeychainService.loadSync(for: config) else {
                throw CLIError.auth(message: "No GitHub token for \(config.owner)/\(config.repo).", hint: nil)
            }
            let id = try await GitHubCommentPoster().postComment(
                owner: config.owner, repo: config.repo, issueNumber: number, body: body, token: token)
            return CLIResponse(id: request.id, ok: true,
                               json: CLIOutput.encode(["via": "comment", "commentID": String(id),
                                                       "url": detail.url]))

        case .appStore:
            try validateAppStoreBody(body)
            // Drive the same controller the "Respond on App Store" panel uses.
            throw CLIError.remote(message: "App Store responses from the CLI need the controller wired in — see Step 5.")

        case .email:
            let sent = try await sendEmailReply(issue: issue, config: config, body: body, deps: deps)
            guard sent else {
                throw CLIError.remote(message: "The send failed. Check Activity in AppFeedback for the reason.")
            }
            await registry.load(productID: config.id)
            return CLIResponse(id: request.id, ok: true,
                               json: CLIOutput.encode(["via": "email",
                                                       "to": FeedbackQuery.redact(issue.email ?? ""),
                                                       "url": detail.url]))
        case .auto:
            throw CLIError.remote(message: "unreachable")
        }
    }

    /// Mirrors MailThreadView.beginReply when a thread exists, IssueCardView.replyToEmail when it
    /// doesn't, then builds the VM exactly as InlineReplyView.setupViewModel does.
    private static func sendEmailReply(issue: FeedbackIssue, config: ProductConfig,
                                       body: String, deps: RespondDeps) async throws -> Bool {
        guard let recipient = issue.email, !recipient.isEmpty else { return false }

        let threads = deps.threadStore.threads(forIssue: (owner: config.owner, repo: config.repo,
                                                          number: issue.number, title: issue.title))
        let lastMessage = threads
            .flatMap { $0.messages ?? [] }
            .sorted { $0.date < $1.date }
            .last

        let headers = lastMessage.map {
            MailMessageHeaders(messageID: $0.messageID, inReplyTo: $0.inReplyTo,
                               references: $0.referencesAsArray)
        }
        let senderID = deps.accountStore.defaultSender?.id
        let resolvedSenderID = senderID ?? UUID()
        let appenderProvider = IMAPClientProvider(accountStore: deps.accountStore, accountID: resolvedSenderID)

        let viewModel = ComposeMailViewModel(
            recipient: MailAddress.bare(from: recipient) ?? recipient,
            issue: issue, repoOwner: config.owner, repoName: config.repo,
            store: deps.accountStore, settingsStore: deps.settingsStore, threadStore: deps.threadStore,
            tracker: deps.tracker, failureStore: deps.failureStore, sender: MailSender(),
            activityLog: deps.activityLog, mirror: deps.mirror,
            inReplyTo: headers,
            initialSubject: lastMessage.map { MailSubject.replyPrefixed($0.subject) },
            senderAccountID: resolvedSenderID,
            sentAppender: { @Sendable email in try await appenderProvider.appendToSent(email) })

        // Same placeholder substitution the UI applies to template bodies.
        viewModel.body = NSAttributedString(
            string: MailComposer().applyPlaceholders(body, context: viewModel.placeholderContext()))
        return await viewModel.send()
    }
```

**Notes for the implementer:**
- `MailThread`'s message accessor, `MailMessage.date`, `.messageID`, `.inReplyTo`, `.referencesAsArray` and `.subject` must be checked against the real models; use what is actually there.
- `ReplyTemplateStore`'s lookup API needs checking; if it exposes templates as an array, filter by `title` and repo.
- The App Store branch is left explicitly unimplemented in this step so it fails loudly rather than silently doing nothing — Step 5 completes it.

- [ ] **Step 5: Complete the App Store branch**

Read `AppStoreResponseController.swift:118-160` and `AppFeedback/Views/Issues/AppStoreResponsePanel.swift` to see how the panel constructs the controller and calls `submit()`. Build the controller the same way in the responder — the review id comes from the feedback body's `source-meta-v1` marker (`IssueBodyParser` exposes it as `reviewId`) — set `draft = body`, `await submit()`, and map `controller.lastError` onto `CLIError`:

- `.tooLong` → `.usage(bad_value)`
- `.conflict`, `.validation`, `.api` → `.remote` with the API message
- `.network` → `.remote`
- `disabledReadOnly` / `discoveredReadOnly` → `.auth(message: "This App Store Connect key is read-only.")`

Replace the placeholder `throw` with that implementation, and return `CLIResponse(... json: ["via": "app-store", "reviewId": ...])` on success.

- [ ] **Step 6: Wire the branch, dependencies and run**

Add the `respond` case to `CLIRunner.execute` via `sendWrite(kind: .respond, ...)` with payload `product`, `feedback`, `body`, `template`, `via`. Pass a `RespondDeps` built from the app's existing `@State` stores when constructing the responder in `AppFeedbackApp.init`.

```bash
xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/CLIWriteCommandTests
```

Then, with the app running, reply to **your own** test feedback item (not a real user's):

```bash
"$BIN" respond --product "Usage for Claude" --feedback <your-test-issue> --via comment --body "CLI check"
"$BIN" respond --product "Usage for Claude" --feedback <your-test-issue> --body "CLI email check"
```

Expected: the comment appears on GitHub; the email appears in the app's thread view with a sending badge and then lands in the recipient's inbox. Confirm the Sent folder copy for a non-auto-saving provider.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Services/CLIRequestResponder.swift AppFeedback/App/AppFeedbackApp.swift \
        AppFeedback/CLI/CLIRunner.swift AppFeedbackTests/CLIWriteCommandTests.swift
git commit -m "feat(cli): reply to feedback through the app's own send paths"
```

---

## Task 15: Installer

**Files:**
- Create: `AppFeedback/Services/CLIInstaller.swift`
- Test: `AppFeedbackTests/CLIInstallerTests.swift`

**Interfaces:**
- Produces: `enum CLIInstaller` with `InstallStatus` (`notInstalled`, `installed(URL)`, `brokenLink(URL)`), `cliStatus(searchPaths:) -> InstallStatus`, `installCLI(candidates:binary:) throws -> URL`, `skillStatus() -> InstallStatus`, `installSkill() throws -> URL`, `skillSourceURL: URL?`, `revealSkillInFinder()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIInstallerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBinary(named name: String = "AppFeedback") throws -> URL {
        let url = root.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    func testInstallsIntoTheFirstWritableCandidate() throws {
        let preferred = root.appending(path: "usr-local-bin")
        let fallback = root.appending(path: "dot-local-bin")
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        // `preferred` deliberately does not exist → must fall back.

        let installed = try CLIInstaller.installCLI(candidates: [preferred, fallback],
                                                    binary: try makeBinary())
        XCTAssertEqual(installed.deletingLastPathComponent().lastPathComponent, "dot-local-bin")
        XCTAssertEqual(installed.lastPathComponent, CLIBranding.commandName)
    }

    func testInstallCreatesASymlinkNotACopy() throws {
        let directory = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = try makeBinary()

        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: binary)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: installed.path)
        XCTAssertEqual(destination, binary.path,
                       "must symlink — a copy loses the provisioning profile and keychain access")
    }

    func testInstallIsIdempotentAndRepointsAnExistingLink() throws {
        let directory = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary(named: "Old"))
        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary(named: "New"))
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: installed.path)
        XCTAssertTrue(destination.hasSuffix("New"))
    }

    func testStatusReportsNotInstalledInstalledAndBroken() throws {
        let directory = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard case .notInstalled = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .notInstalled")
        }

        let binary = try makeBinary()
        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: binary)
        guard case .installed(let url) = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .installed")
        }
        XCTAssertEqual(url, installed)

        try FileManager.default.removeItem(at: binary)   // dangling link
        guard case .brokenLink = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .brokenLink")
        }
    }

    func testInstallFailsCleanlyWhenNoCandidateIsWritable() throws {
        XCTAssertThrowsError(try CLIInstaller.installCLI(
            candidates: [URL(filePath: "/System/definitely-not-writable")],
            binary: try makeBinary()))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIInstallerTests`

Expected: compile failure — `CLIInstaller` does not exist.

- [ ] **Step 3: Write `CLIInstaller.swift`**

```swift
#if os(macOS)
import Foundation
import AppKit

enum CLIInstaller {

    enum InstallStatus: Equatable {
        case notInstalled
        case installed(URL)
        case brokenLink(URL)
    }

    static var defaultCandidates: [URL] {
        [URL(filePath: "/usr/local/bin"),
         URL.homeDirectory.appending(path: ".local/bin")]
    }

    static var binaryURL: URL { URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath() }

    /// The skill folder inside the app bundle. Symlinked, never copied.
    static var skillSourceURL: URL? {
        Bundle.main.resourceURL?.appending(path: "Skill/\(CLIBranding.skillFolderName)")
    }

    static var skillDestinationURL: URL {
        URL.homeDirectory.appending(path: ".claude/skills/\(CLIBranding.skillFolderName)")
    }

    // MARK: - Status

    static func cliStatus(searchPaths: [URL] = defaultCandidates) -> InstallStatus {
        status(of: searchPaths.map { $0.appending(path: CLIBranding.commandName) })
    }

    static func skillStatus() -> InstallStatus { status(of: [skillDestinationURL]) }

    private static func status(of links: [URL]) -> InstallStatus {
        let manager = FileManager.default
        for link in links {
            guard let target = try? manager.destinationOfSymbolicLink(atPath: link.path) else {
                if manager.fileExists(atPath: link.path) { return .installed(link) }   // a real file, not a link
                continue
            }
            return manager.fileExists(atPath: target) ? .installed(link) : .brokenLink(link)
        }
        return .notInstalled
    }

    // MARK: - Install

    @discardableResult
    static func installCLI(candidates: [URL] = defaultCandidates,
                           binary: URL = binaryURL) throws -> URL {
        try link(source: binary, intoFirstWritable: candidates, named: CLIBranding.commandName)
    }

    @discardableResult
    static func installSkill() throws -> URL {
        guard let source = skillSourceURL, FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = skillDestinationURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try replaceSymlink(at: destination, pointingTo: source)
        return destination
    }

    /// Re-points both links so a moved or reinstalled app self-heals. Failures are silent —
    /// this runs at launch and must never block the app.
    static func refreshInstalledLinks() {
        if case .notInstalled = cliStatus() {} else { try? installCLI() }
        if case .notInstalled = skillStatus() {} else { try? installSkill() }
    }

    static func revealSkillInFinder() {
        guard let source = skillSourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }

    // MARK: - Helpers

    private static func link(source: URL, intoFirstWritable candidates: [URL], named name: String) throws -> URL {
        let manager = FileManager.default
        var lastError: Error = CocoaError(.fileWriteNoPermission)
        for directory in candidates {
            guard manager.fileExists(atPath: directory.path),
                  manager.isWritableFile(atPath: directory.path) else { continue }
            let destination = directory.appending(path: name)
            do {
                try replaceSymlink(at: destination, pointingTo: source)
                return destination
            } catch { lastError = error }
        }
        throw lastError
    }

    private static func replaceSymlink(at destination: URL, pointingTo source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path)
            || (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try manager.removeItem(at: destination)
        }
        try manager.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}
#endif
```

- [ ] **Step 4: Call `refreshInstalledLinks()` at launch**

In `AppFeedbackApp.init`, inside the existing `#if os(macOS)` block added in Task 10:

```swift
        CLIInstaller.refreshInstalledLinks()
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/CLIInstallerTests`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/CLIInstaller.swift AppFeedback/App/AppFeedbackApp.swift \
        AppFeedbackTests/CLIInstallerTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(cli): install the CLI and skill as self-healing symlinks"
```

---

## Task 16: Settings pane

**Files:**
- Create: `AppFeedback/Views/Settings/CLISettingsView.swift`
- Modify: `AppFeedback/Views/Settings/SettingsView.swift:8-18` (selection case), `:106-119` (sidebar row), `:138-166` (detail case)
- Test: manual (SwiftUI view; the logic it calls is covered by Task 15)

**Interfaces:**
- Consumes: `CLIInstaller`.

- [ ] **Step 1: Write `CLISettingsView.swift`**

```swift
#if os(macOS)
import SwiftUI

struct CLISettingsView: View {
    @State private var cliStatus = CLIInstaller.cliStatus()
    @State private var skillStatus = CLIInstaller.skillStatus()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Command Line") {
                statusRow(status: cliStatus,
                          installedLabel: { "Installed at \($0.path)" },
                          missingLabel: "Not installed")
                HStack {
                    Button("Install Command Line Tool") { installCLI() }
                    if case .installed(let url) = cliStatus, !isOnPath(url.deletingLastPathComponent()) {
                        Text("Add \(url.deletingLastPathComponent().path) to your PATH, or call it by full path.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text("Symlinks this app's binary so `\(CLIBranding.commandName)` works in any terminal. "
                     + "The link points at the app — moving the app re-links on next launch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("AI Skill") {
                statusRow(status: skillStatus,
                          installedLabel: { "Installed at \($0.path)" },
                          missingLabel: "Not installed")
                HStack {
                    Button("Install for Claude Code") { installSkill() }
                    Button("Show in Finder") { CLIInstaller.revealSkillInFinder() }
                }
                Text("Installs into ~/.claude/skills so any project can read your feedback. "
                     + "For another AI tool, reveal the folder and copy it wherever that tool expects.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("CLI & AI Skill")
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func statusRow(status: CLIInstaller.InstallStatus,
                           installedLabel: (URL) -> String,
                           missingLabel: String) -> some View {
        switch status {
        case .installed(let url):
            Label(installedLabel(url), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .brokenLink(let url):
            Label("Broken link at \(url.path) — reinstall", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notInstalled:
            Label(missingLabel, systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func isOnPath(_ directory: URL) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").contains { $0 == directory.path }
    }

    private func refresh() {
        cliStatus = CLIInstaller.cliStatus()
        skillStatus = CLIInstaller.skillStatus()
    }

    private func installCLI() {
        errorMessage = nil
        do { _ = try CLIInstaller.installCLI() }
        catch {
            errorMessage = "Could not install: \(error.localizedDescription). "
                         + "Create ~/.local/bin and try again."
        }
        refresh()
    }

    private func installSkill() {
        errorMessage = nil
        do { _ = try CLIInstaller.installSkill() }
        catch { errorMessage = "Could not install the skill: \(error.localizedDescription)" }
        refresh()
    }
}
#endif
```

- [ ] **Step 2: Add the pane to the Settings sidebar**

In `SettingsView.swift`, add `case cli` to `SettingsSelection` (after `.notifications`), a sidebar row in the same `Section` as Notifications:

```swift
                    SettingsIconRow(title: "CLI & AI Skill", systemImage: "terminal.fill", tileColor: .gray)
                        .tag(SettingsSelection.cli)
```

and a detail case:

```swift
        case .cli:
            CLISettingsView()
```

- [ ] **Step 3: Verify manually**

Build and run the app, open Settings → CLI & AI Skill.

Expected: both rows read "Not installed" on a clean machine. Click both Install buttons; both flip to "Installed at …". Click Show in Finder — the skill folder reveals. Quit and relaunch; statuses persist. `which appfeedback` (or the reported path) resolves, and `appfeedback products` works from a fresh terminal.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Settings/CLISettingsView.swift AppFeedback/Views/Settings/SettingsView.swift \
        AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(settings): add a CLI & AI Skill pane with one-click install"
```

---

## Task 17: The skill

**Files:**
- Create: `AppFeedback/Resources/Skill/appfeedback/SKILL.md`
- Modify: `project.yml` (resources build phase)
- Test: bundle verification (Step 4) + a live agent run (Step 5)

- [ ] **Step 1: Write `SKILL.md`**

```markdown
---
name: appfeedback
description: Read and act on real user feedback for the developer's apps — bug reports, feature requests, App Store reviews and support emails — and the tasks tracking them. Use when asked what users are reporting, whether an issue is already tracked, what to build next, or to reply to a reporter.
---

The `appfeedback` CLI reads the AppFeedback inbox: user feedback from the in-app SDK,
App Store reviews and support email, plus the tasks that track them.

Output is JSON on stdout by default. `--text` is for humans — never parse it.
Every command needs `--product`, so **always start with `products`**.

If `appfeedback` is not on PATH, use the full path the app's Settings → CLI & AI Skill
pane reports (usually `~/.local/bin/appfeedback`).

## 1. Pick the product

    appfeedback products

Match the `connectedRepo` field against the current repo:

    git remote get-url origin

If nothing matches, or several do, **ask the user which product** — never guess.
Products that share a `repo` return identical feedback; `--app` is how you narrow to one app.

## 2. Read feedback

    appfeedback feedback --product "Usage for Claude" --app Zcode --limit 20
    appfeedback feedback --product "Usage for Claude" --type bug --since 14d
    appfeedback feedback --product "Usage for Claude" --source app-store --max-rating 2
    appfeedback feedback --product "Usage for Claude" --search "crash" --no-task
    appfeedback feedback show 559 --product "Usage for Claude"

Filters: `--app` `--state open|closed|all` `--source sdk|app-store|email`
`--type bug|feature-request` `--label` `--search` `--since 7d|YYYY-MM-DD` `--updated-since`
`--min-rating` `--max-rating` `--app-version` `--has-task` `--no-task` `--include-hidden`
`--sort created|updated` `--order desc|asc` `--limit` (max 200) `--offset`.

Repeating a flag ORs its values (`--app A --app B`); different flags AND together.

`list` truncates `description` at 500 characters and sets `"truncated": true` — use
`feedback show` for the full text. Paginate while `page.hasMore` is true.

## 3. Read tasks

    appfeedback tasks --product "Usage for Claude" --status todo --status in-progress
    appfeedback tasks show 557 --product "Usage for Claude"

Each feedback item carries a `tasks` array — the tasks that already address it, with status.
That is the fastest way to answer "is this already being worked on?".

## 4. Before creating a task

Duplicates are the main failure mode. Both checks are required:

1. If the feedback item's `tasks` array is **not empty**, use `tasks link` — do not create.
2. Run `tasks list --status todo --status in-progress` and scan titles for an existing
   task covering the same theme. If one exists, link to it.

Only when both come up empty:

    appfeedback tasks create --product "Usage for Claude" --title "Fix crash on launch" \
        --notes "Several reports on 1.4.2" --priority high --feedback 559,560

    appfeedback tasks link   --product "Usage for Claude" --task 557 --feedback 561
    appfeedback tasks unlink --product "Usage for Claude" --task 557 --feedback 561

`tasks create` writes to GitHub immediately. `--version` must name a version that already
has a GitHub milestone (see `products`).

## 5. Replying — always ask first

    appfeedback respond --product "Usage for Claude" --feedback 559 --body "Fixed in 1.4.3."

**`respond` sends immediately and cannot be undone.** It reaches a real user by email, or
posts a public App Store developer response.

Before every call: draft the reply, **show the user the exact text you intend to send, and
send only after they explicitly agree.** Never send on your own initiative, and never send
a reply you have not shown them.

`--via auto` (the default) picks the channel: App Store reviews get a developer response,
anything with an email address gets an email reply. `--via comment` posts a GitHub comment
on the feedback issue instead — that one is internal and does not reach the user.

## 6. Freshness

Every response carries `asOf` and `stale`. Data comes from the app's local cache, which
refreshes every 15 minutes while AppFeedback is running.

- Add `--refresh` to any read command to make the app poll GitHub first.
- Exit code 6 means AppFeedback is not running — ask the user to open it. Writes and
  `--refresh` both need it; plain reads work without it.
- After `tasks create`, the new task will **not** appear in `tasks list` until a refresh
  succeeds. Trust the create response — do not re-query to "verify" it.

## 7. Data honesty

- `--state closed` and `--state all` set `"closedDataIncomplete": true`. The cache is
  open-issue-centric: issues closed before the app ever saw them were never cached, and a
  cached `closed` can also mean *deleted upstream*. Open-state results are complete.
- `triage` is this app's own local AI advice, not ground truth. Its `kind` vocabulary
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

Errors are JSON on stdout too, so parse the output either way.
```

- [ ] **Step 2: Declare the skill folder as a resource**

In `project.yml`, under the `AppFeedback` target's `sources`, add a second entry beside the existing `- path: AppFeedback`:

```yaml
    sources:
      - path: AppFeedback
        createIntermediateGroups: true
        excludes:
          - "Resources/Skill/**"
      - path: AppFeedback/Resources/Skill
        buildPhase: resources
        type: folder
```

`type: folder` creates a folder reference so the directory structure (`Skill/appfeedback/SKILL.md`) is preserved in the bundle. The `excludes` prevents the same files being picked up twice by the broad source path.

- [ ] **Step 3: Regenerate and build**

```bash
git status --short          # note any uncommitted .xcscheme work first
xcodegen generate
git status --short          # confirm xcodegen didn't clobber a scheme you needed
xcodebuild build -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS'
```

- [ ] **Step 4: Verify the skill actually shipped**

```bash
ls -la "$APP/AppFeedback.app/Contents/Resources/Skill/appfeedback/SKILL.md"
```

Expected: the file exists. **If it does not, the `type: folder` declaration is wrong** — fix it before wiring anything else, because the Settings install button silently produces a broken link otherwise.

Then install it from Settings and confirm:

```bash
ls -la ~/.claude/skills/appfeedback
cat ~/.claude/skills/appfeedback/SKILL.md | head -5
```

- [ ] **Step 5: Have an agent use it**

In a *different* repo (e.g. the Zcode code repo), start a fresh Claude Code session and ask:
"What are users reporting about this app lately?"

Expected: the agent invokes the skill, runs `products`, matches `connectedRepo` against the
git remote (or asks which product), then runs a filtered `feedback` query and summarises.
Then ask it to reply to one item and confirm it **shows you the draft and waits** rather
than sending.

If the agent guesses a product, creates a duplicate task, or sends without asking, fix the
wording in `SKILL.md` — those three behaviours are what it exists to prevent.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Resources/Skill/appfeedback/SKILL.md project.yml AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(skill): ship the appfeedback skill in the app bundle"
```

---

## Final verification

- [ ] **Full macOS suite**

```bash
xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS 2>&1 | tail -40
```

Expected: only the ~11 known `KeychainServicePerAccountTests` / `GitHubAccountStoreTests` failures.

- [ ] **iOS still builds**

```bash
xcodebuild build -project AppFeedback.xcodeproj -scheme AppFeedback_iOS -destination 'generic/platform=iOS'
```

- [ ] **GUI unaffected** — launch from Finder, confirm the app opens normally, feedback loads, and Settings shows the new pane.

- [ ] **Every command against the live store**

```bash
for cmd in "products" \
           "feedback --product 'Usage for Claude' --limit 3" \
           "feedback show 559 --product 'Usage for Claude'" \
           "tasks --product 'Usage for Claude' --limit 3" \
           "tasks show 557 --product 'Usage for Claude'"; do
  echo "=== $cmd"; eval "\"$BIN\" $cmd" | head -20; echo "exit=$?"
done
```

- [ ] **Update the spec's status** to Implemented and commit.

---

## Self-review notes

**Spec coverage:** entry point (T2) · read-only stores (T0, T3) · products (T4) · feedback list/show (T6, T7) · tasks read (T7) · text output (T8) · IPC (T9) · refresh (T10) · fetchIssue (T11) · tasks create (T12) · link/unlink (T13) · respond (T14) · installer (T15) · Settings (T16) · skill + xcodegen resource (T17). Exit codes, envelope shape, redaction, truncation, `closedDataIncomplete` and filter-combination rules all have tests.

**Known soft spots for the implementer:**
- Tasks 7 and 14 depend on `MailThread`/`MailMessage` property names not verified while writing this plan. Both steps say so explicitly — read the models first and use the real names.
- Task 14's App Store branch is deliberately staged (fail loudly in Step 4, implement in Step 5) so a half-wired channel can't silently no-op.
- Task 10 Step 6 requires restructuring each read branch so the store is opened *after* the refresh; getting this backwards yields pre-refresh data with a fresh `asOf`, which is worse than not refreshing at all.

