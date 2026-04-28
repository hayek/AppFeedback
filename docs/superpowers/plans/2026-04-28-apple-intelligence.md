# Apple Intelligence Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device unread-issue summary card and per-issue translation toggle to the issue list, both powered by Foundation Models on macOS 26 / iOS 26+.

**Architecture:** A single `IntelligenceService` actor fronts the `FoundationModels` framework and exposes summarize + translate. `NLLanguageRecognizer` performs cheap detection. Translations are persisted on `CachedIssue` (SwiftData additive fields). Summaries live in a new `UnreadSummaryViewModel`/`UnreadSummaryView` injected between `FilterBarView` and the issue list. Settings get a new "Intelligence" tab showing live availability plus a translation language picker. Everything is gated by `#available(macOS 26, iOS 26, *)` and `SystemLanguageModel.default.availability`; on unsupported configs the summary view hides itself and translation toggles are absent.

**Tech Stack:** Swift 5.10+, SwiftUI, SwiftData, `FoundationModels`, `NaturalLanguage` (`NLLanguageRecognizer`), XCTest. Existing patterns in this repo: `@Observable @MainActor` view models, `@Model` SwiftData entities, XCTest test targets.

**Spec:** `docs/superpowers/specs/2026-04-28-apple-intelligence-design.md`

**Build & test commands** (use the `zcode` skill):

- Build: `zcode build`
- Test: `zcode test`
- Test single: `zcode test --filter <ClassName>/<testName>`

---

## File Structure

**New files:**

- `AppFeedback/Services/Intelligence/IntelligenceAvailability.swift` — `enum IntelligenceAvailability` with cases `available`, `appleIntelligenceNotEnabled`, `modelNotReady`, `deviceNotEligible`, `osTooOld`.
- `AppFeedback/Services/Intelligence/LanguageDetector.swift` — sync wrapper over `NLLanguageRecognizer`.
- `AppFeedback/Services/Intelligence/IssueSummary.swift` — `@Generable` value type returned by summarization.
- `AppFeedback/Services/Intelligence/IntelligenceProvider.swift` — protocol fronting `IntelligenceService` so tests can substitute a mock.
- `AppFeedback/Services/Intelligence/IntelligenceService.swift` — actor implementing `IntelligenceProvider` against `FoundationModels`.
- `AppFeedback/Services/Intelligence/IntelligenceSettings.swift` — `@Observable` settings store backed by `UserDefaults` + `NSUbiquitousKeyValueStore`.
- `AppFeedback/Services/Intelligence/SummaryPromptBuilder.swift` — pure function building the prompt input from `[FeedbackIssue]` (cap, code-block stripping, "+N more" note).
- `AppFeedback/ViewModels/UnreadSummaryViewModel.swift` — `@Observable @MainActor` summary lifecycle.
- `AppFeedback/Views/Issues/UnreadSummaryView.swift` — collapsible card UI.
- `AppFeedback/Views/Settings/IntelligenceSettingsSection.swift` — Settings tab content.
- `AppFeedbackTests/LanguageDetectorTests.swift`
- `AppFeedbackTests/SummaryPromptBuilderTests.swift`
- `AppFeedbackTests/IntelligenceSettingsTests.swift`
- `AppFeedbackTests/UnreadSummaryViewModelTests.swift`
- `AppFeedbackTests/MockIntelligenceProvider.swift`

**Modified files:**

- `AppFeedback/Models/CachedIssue.swift` — add optional translation fields and helpers.
- `AppFeedback/Models/FeedbackIssue.swift` — add transient translation fields and `displayed*` helpers.
- `AppFeedback/ViewModels/IssueListViewModel.swift` — start translation pipeline after `applyLoaded`, expose `unreadIssues` computed.
- `AppFeedback/Views/Issues/IssueCardView.swift` — render translated text + per-card "Show original" / "Show translation" button + unavailable hint.
- `AppFeedback/Views/Issues/IssueListView.swift` — insert `UnreadSummaryView` between filter bar and issue list.
- `AppFeedback/Views/Settings/SettingsView.swift` — add "Intelligence" tab.
- `AppFeedback/App/AppFeedbackApp.swift` — instantiate `IntelligenceSettings` + `IntelligenceService` and pass via `.environment`.

---

### Task 1: Add translation columns to `CachedIssue`

**Files:**
- Modify: `AppFeedback/Models/CachedIssue.swift`
- Modify: `AppFeedbackTests/CachedIssueTests.swift`

- [ ] **Step 1: Read existing tests**

Run: `zcode test --filter CachedIssueTests`
Expected: PASS (all current tests pass before changes)

- [ ] **Step 2: Write failing test for new fields**

Append to `AppFeedbackTests/CachedIssueTests.swift`:

```swift
func test_cachedIssue_storesTranslationFields() {
    let issue = FeedbackIssue(
        number: 42, title: "Hola", createdAt: Date(),
        rawBody: "Hola mundo", appName: "App", appVersion: "1",
        device: "Mac", osVersion: "14", email: nil,
        description: "Hola mundo", labels: []
    )
    let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
    cached.detectedLanguageCode = "es"
    cached.translatedTitle = "Hello"
    cached.translatedBody = "Hello world"
    cached.translationTargetLanguage = "en"

    let round = cached.toFeedbackIssue()
    XCTAssertEqual(round.detectedLanguageCode, "es")
    XCTAssertEqual(round.translatedTitle, "Hello")
    XCTAssertEqual(round.translatedBody, "Hello world")
    XCTAssertEqual(round.translationTargetLanguage, "en")
}
```

- [ ] **Step 3: Run test, expect failure**

Run: `zcode test --filter CachedIssueTests/test_cachedIssue_storesTranslationFields`
Expected: FAIL — "Value of type 'CachedIssue' has no member 'detectedLanguageCode'" (and similar for `FeedbackIssue`)

- [ ] **Step 4: Add fields to `CachedIssue`**

Edit `AppFeedback/Models/CachedIssue.swift`. Inside the `@Model` class, after `var labelsJSON: String?`, add:

```swift
var detectedLanguageCode: String?
var translatedTitle: String?
var translatedBody: String?
var translationTargetLanguage: String?
```

Update `toFeedbackIssue()` to forward these:

```swift
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
        description: issueDescription,
        labels: Self.decode(labelsJSON),
        detectedLanguageCode: detectedLanguageCode,
        translatedTitle: translatedTitle,
        translatedBody: translatedBody,
        translationTargetLanguage: translationTargetLanguage
    )
}
```

`from(_:)` should leave the new fields nil (default). No change to `from(_:)` body needed; SwiftData will leave them nil.

- [ ] **Step 5: Add fields to `FeedbackIssue`**

Edit `AppFeedback/Models/FeedbackIssue.swift`. Replace the struct definition with:

```swift
struct FeedbackIssue: Identifiable, Codable, Sendable {
    let number: Int
    let title: String
    let createdAt: Date
    let rawBody: String
    let appName: String?
    let appVersion: String?
    let device: String?
    let osVersion: String?
    let email: String?
    let description: String
    let labels: [IssueLabel]
    var detectedLanguageCode: String?
    var translatedTitle: String?
    var translatedBody: String?
    var translationTargetLanguage: String?

    var id: Int { number }

    func displayedTitle(translated: Bool) -> String {
        translated ? (translatedTitle ?? title) : title
    }

    func displayedBody(translated: Bool) -> String {
        translated ? (translatedBody ?? description) : description
    }

    var hasTranslation: Bool {
        translatedTitle != nil || translatedBody != nil
    }
}
```

Note: `description` (not `rawBody`) is used for body text consistent with `IssueCardView` rendering.

- [ ] **Step 6: Run test, expect pass**

Run: `zcode test --filter CachedIssueTests/test_cachedIssue_storesTranslationFields`
Expected: PASS

- [ ] **Step 7: Run full test target to ensure no regressions**

Run: `zcode test`
Expected: All previously passing tests still pass. (Existing `FeedbackIssue` initializers in tests will still compile because the four new fields have default `nil`.)

- [ ] **Step 8: Commit**

```bash
git add AppFeedback/Models/CachedIssue.swift AppFeedback/Models/FeedbackIssue.swift AppFeedbackTests/CachedIssueTests.swift
git commit -m "feat(models): translation fields on CachedIssue/FeedbackIssue"
```

---

### Task 2: `LanguageDetector` wrapper

**Files:**
- Create: `AppFeedback/Services/Intelligence/LanguageDetector.swift`
- Create: `AppFeedbackTests/LanguageDetectorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `AppFeedbackTests/LanguageDetectorTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class LanguageDetectorTests: XCTestCase {

    func test_detect_english() {
        let code = LanguageDetector.detect("The application keeps crashing when I open the settings page.")
        XCTAssertEqual(code, "en")
    }

    func test_detect_spanish() {
        let code = LanguageDetector.detect("La aplicación se cierra cuando abro la página de configuración.")
        XCTAssertEqual(code, "es")
    }

    func test_detect_japanese() {
        let code = LanguageDetector.detect("設定ページを開くとアプリがクラッシュします。")
        XCTAssertEqual(code, "ja")
    }

    func test_detect_emptyString_returnsNil() {
        XCTAssertNil(LanguageDetector.detect(""))
    }

    func test_detect_tooShort_returnsNil() {
        // Single emoji or very short strings may be unreliable; expect nil.
        XCTAssertNil(LanguageDetector.detect("ok"))
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `zcode test --filter LanguageDetectorTests`
Expected: FAIL — `LanguageDetector` not defined.

- [ ] **Step 3: Implement `LanguageDetector`**

Create `AppFeedback/Services/Intelligence/LanguageDetector.swift`:

```swift
import Foundation
import NaturalLanguage

enum LanguageDetector {
    /// Detect the dominant language of `text`. Returns BCP-47 language code or
    /// nil if the input is too short or detection lacks confidence.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let confidence = hypotheses[language], confidence < 0.5 { return nil }
        return language.rawValue
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `zcode test --filter LanguageDetectorTests`
Expected: PASS (all 5 cases)

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/LanguageDetector.swift AppFeedbackTests/LanguageDetectorTests.swift
git commit -m "feat(intelligence): add NLLanguageRecognizer-based detector"
```

---

### Task 3: `IntelligenceAvailability` enum

**Files:**
- Create: `AppFeedback/Services/Intelligence/IntelligenceAvailability.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

enum IntelligenceAvailability: Equatable {
    case available
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
    case osTooOld

    var isReady: Bool { self == .available }

    var statusText: String {
        switch self {
        case .available: return "Apple Intelligence ready"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence not enabled"
        case .modelNotReady: return "Model downloading…"
        case .deviceNotEligible: return "Not supported on this device"
        case .osTooOld: return "Requires macOS 26 or later"
        }
    }

    var systemImageName: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .modelNotReady: return "arrow.down.circle"
        case .appleIntelligenceNotEnabled, .deviceNotEligible, .osTooOld: return "exclamationmark.triangle.fill"
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `zcode build`
Expected: build succeeds

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceAvailability.swift
git commit -m "feat(intelligence): availability status enum"
```

---

### Task 4: `IssueSummary` `@Generable` type

**Files:**
- Create: `AppFeedback/Services/Intelligence/IssueSummary.swift`

- [ ] **Step 1: Create file**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct IssueSummary: Equatable, Sendable {
    @Guide(description: "A 1-sentence headline summarizing the unread issues")
    var headline: String

    @Guide(description: "3-5 themed bullets, each grouping related issues")
    var bullets: [Bullet]

    @Generable
    struct Bullet: Equatable, Sendable {
        @Guide(description: "Short description of the theme")
        var text: String

        @Guide(description: "How many of the unread issues fall under this theme")
        var issueCount: Int
    }
}
#endif

/// Plain-Swift mirror used by views and tests so they don't need FoundationModels.
struct IssueSummaryDTO: Equatable, Sendable {
    var headline: String
    var bullets: [Bullet]

    struct Bullet: Equatable, Sendable {
        var text: String
        var issueCount: Int
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
extension IssueSummaryDTO {
    init(_ summary: IssueSummary) {
        self.headline = summary.headline
        self.bullets = summary.bullets.map { Bullet(text: $0.text, issueCount: $0.issueCount) }
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `zcode build`
Expected: build succeeds on machines with FoundationModels SDK; on older SDKs the conditional `canImport` skips it.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Intelligence/IssueSummary.swift
git commit -m "feat(intelligence): IssueSummary generable type and DTO"
```

---

### Task 5: `SummaryPromptBuilder` (pure)

**Files:**
- Create: `AppFeedback/Services/Intelligence/SummaryPromptBuilder.swift`
- Create: `AppFeedbackTests/SummaryPromptBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

Create `AppFeedbackTests/SummaryPromptBuilderTests.swift`:

```swift
import XCTest
@testable import AppFeedback

final class SummaryPromptBuilderTests: XCTestCase {

    private func issue(number: Int, title: String, body: String, app: String? = "App", labels: [IssueLabel] = []) -> FeedbackIssue {
        FeedbackIssue(
            number: number, title: title, createdAt: Date(),
            rawBody: body, appName: app, appVersion: nil,
            device: nil, osVersion: nil, email: nil,
            description: body, labels: labels
        )
    }

    func test_build_capsAtThirty() {
        let many = (1...50).map { issue(number: $0, title: "T\($0)", body: "B") }
        let prompt = SummaryPromptBuilder.build(issues: many, targetLanguage: "en")
        XCTAssertTrue(prompt.contains("+20 more"))
        XCTAssertEqual(prompt.components(separatedBy: "\n- #").count - 1, 30)
    }

    func test_build_truncatesBodyTo200Chars() {
        let long = String(repeating: "a", count: 500)
        let prompt = SummaryPromptBuilder.build(
            issues: [issue(number: 1, title: "T", body: long)],
            targetLanguage: "en"
        )
        let aRun = prompt.components(separatedBy: "a").count - 1
        XCTAssertLessThanOrEqual(aRun, 200)
    }

    func test_build_stripsFencedCodeBlocks() {
        let body = "before\n```swift\nlet x = 1\n```\nafter"
        let prompt = SummaryPromptBuilder.build(
            issues: [issue(number: 1, title: "T", body: body)],
            targetLanguage: "en"
        )
        XCTAssertFalse(prompt.contains("let x = 1"))
        XCTAssertTrue(prompt.contains("before"))
        XCTAssertTrue(prompt.contains("after"))
    }

    func test_build_includesLabels() {
        let issueWithLabel = issue(
            number: 1, title: "T", body: "B",
            labels: [IssueLabel(name: "crash", colorHex: "#f00")]
        )
        let prompt = SummaryPromptBuilder.build(issues: [issueWithLabel], targetLanguage: "en")
        XCTAssertTrue(prompt.contains("crash"))
    }

    func test_build_includesTargetLanguage() {
        let prompt = SummaryPromptBuilder.build(
            issues: [issue(number: 1, title: "T", body: "B")],
            targetLanguage: "fr"
        )
        XCTAssertTrue(prompt.lowercased().contains("french") || prompt.contains("fr"))
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `zcode test --filter SummaryPromptBuilderTests`
Expected: FAIL — `SummaryPromptBuilder` not defined.

- [ ] **Step 3: Implement**

Create `AppFeedback/Services/Intelligence/SummaryPromptBuilder.swift`:

```swift
import Foundation

enum SummaryPromptBuilder {
    static let issueCap = 30
    static let bodyCharCap = 200

    static func build(issues: [FeedbackIssue], targetLanguage: String) -> String {
        let included = Array(issues.prefix(issueCap))
        let extra = max(0, issues.count - issueCap)

        var lines: [String] = []
        lines.append("Summarize the following unread feedback issues.")
        lines.append("Target output language: \(languageDisplayName(targetLanguage)).")
        lines.append("Group related issues into 3-5 themed bullets, each with an issueCount.")
        lines.append("")

        for issue in included {
            let body = stripCodeBlocks(issue.description)
                .prefix(bodyCharCap)
            let labels = issue.labels.map(\.name).joined(separator: ", ")
            let labelSuffix = labels.isEmpty ? "" : " [labels: \(labels)]"
            lines.append("- #\(issue.number) \(issue.title): \(body)\(labelSuffix)")
        }

        if extra > 0 {
            lines.append("")
            lines.append("(+\(extra) more issues not shown)")
        }
        return lines.joined(separator: "\n")
    }

    static func stripCodeBlocks(_ text: String) -> String {
        var result = text
        // Fenced ``` blocks
        while let openRange = result.range(of: "```") {
            let afterOpen = openRange.upperBound
            if let closeRange = result.range(of: "```", range: afterOpen..<result.endIndex) {
                result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
            } else {
                result.replaceSubrange(openRange.lowerBound..<result.endIndex, with: "")
                break
            }
        }
        // 4-space indented blocks (line-by-line)
        let kept = result.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("    ") }
            .joined(separator: "\n")
        return kept
    }

    private static func languageDisplayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `zcode test --filter SummaryPromptBuilderTests`
Expected: PASS (all 5)

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/SummaryPromptBuilder.swift AppFeedbackTests/SummaryPromptBuilderTests.swift
git commit -m "feat(intelligence): summary prompt builder with caps and code-block stripping"
```

---

### Task 6: `IntelligenceProvider` protocol + Mock

**Files:**
- Create: `AppFeedback/Services/Intelligence/IntelligenceProvider.swift`
- Create: `AppFeedbackTests/MockIntelligenceProvider.swift`

- [ ] **Step 1: Create the protocol**

`AppFeedback/Services/Intelligence/IntelligenceProvider.swift`:

```swift
import Foundation

protocol IntelligenceProvider: AnyObject, Sendable {
    @MainActor var availability: IntelligenceAvailability { get }
    func summarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO
    func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String
}
```

- [ ] **Step 2: Create the test mock**

`AppFeedbackTests/MockIntelligenceProvider.swift`:

```swift
import Foundation
@testable import AppFeedback

final class MockIntelligenceProvider: IntelligenceProvider, @unchecked Sendable {
    @MainActor var availability: IntelligenceAvailability = .available
    var summarizeHandler: ([FeedbackIssue], String) async throws -> IssueSummaryDTO = { issues, _ in
        IssueSummaryDTO(
            headline: "\(issues.count) unread issues",
            bullets: [.init(text: "stub", issueCount: issues.count)]
        )
    }
    var translateHandler: (String, String?, String) async throws -> String = { text, _, _ in
        "[t] " + text
    }
    private(set) var summarizeCalls: [(issues: [FeedbackIssue], target: String)] = []
    private(set) var translateCalls: [(text: String, from: String?, to: String)] = []

    func summarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
        summarizeCalls.append((issues, targetLanguage))
        return try await summarizeHandler(issues, targetLanguage)
    }
    func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        translateCalls.append((text, sourceCode, targetCode))
        return try await translateHandler(text, sourceCode, targetCode)
    }
}
```

- [ ] **Step 3: Build**

Run: `zcode build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceProvider.swift AppFeedbackTests/MockIntelligenceProvider.swift
git commit -m "feat(intelligence): provider protocol and test mock"
```

---

### Task 7: `IntelligenceService` actor (availability + skeleton)

**Files:**
- Create: `AppFeedback/Services/Intelligence/IntelligenceService.swift`

- [ ] **Step 1: Create the file with availability detection**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class IntelligenceService: IntelligenceProvider {
    private(set) var availability: IntelligenceAvailability = .osTooOld
    private let summaryInstructions = """
    You are a concise product manager summarizing unread user feedback.
    Group related issues into 3-5 themes. Be specific, factual, and avoid speculation.
    Each bullet must include the count of issues that fall under its theme.
    Always respond in the requested target language.
    """
    private let translationInstructions = """
    You are a translator. Translate the user's text into the requested target language.
    Preserve meaning, tone, and any URLs, code identifiers, or @mentions verbatim.
    Output only the translated text — no preamble, no quotation marks.
    """

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private var summarySession: LanguageModelSession?
    @available(macOS 26, iOS 26, *)
    private var translationSession: LanguageModelSession?
    #endif

    init() {
        recomputeAvailability()
    }

    func recomputeAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                availability = .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: availability = .appleIntelligenceNotEnabled
                case .modelNotReady: availability = .modelNotReady
                case .deviceNotEligible: availability = .deviceNotEligible
                @unknown default: availability = .deviceNotEligible
                }
            @unknown default:
                availability = .deviceNotEligible
            }
        } else {
            availability = .osTooOld
        }
        #else
        availability = .osTooOld
        #endif
    }

    nonisolated func summarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runSummarize(issues: issues, targetLanguage: targetLanguage)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    nonisolated func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runTranslate(text: text, from: sourceCode, to: targetCode)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    @MainActor
    private func checkAvailable() throws {
        if availability != .available { throw IntelligenceError.unavailable }
    }
}

enum IntelligenceError: Error {
    case unavailable
    case empty
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
extension IntelligenceService {
    fileprivate func runSummarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
        // Implemented in Task 8
        throw IntelligenceError.unavailable
    }
    fileprivate func runTranslate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        // Implemented in Task 9
        throw IntelligenceError.unavailable
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `zcode build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceService.swift
git commit -m "feat(intelligence): IntelligenceService skeleton with availability"
```

---

### Task 8: Implement summarize via guided generation

**Files:**
- Modify: `AppFeedback/Services/Intelligence/IntelligenceService.swift`

- [ ] **Step 1: Replace the `runSummarize` stub with the real implementation**

In the `#if canImport(FoundationModels)` extension block, replace `runSummarize` with:

```swift
fileprivate func runSummarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
    guard !issues.isEmpty else { throw IntelligenceError.empty }
    let session = await MainActor.run { () -> LanguageModelSession in
        if let s = summarySession { return s }
        let s = LanguageModelSession(instructions: summaryInstructions)
        summarySession = s
        return s
    }
    let prompt = SummaryPromptBuilder.build(issues: issues, targetLanguage: targetLanguage)
    do {
        let response = try await session.respond(to: prompt, generating: IssueSummary.self)
        return IssueSummaryDTO(response.content)
    } catch let error as LanguageModelSession.GenerationError {
        if case .guardrailViolation = error {
            return IssueSummaryDTO(
                headline: "\(issues.count) unread issues",
                bullets: []
            )
        }
        throw error
    }
}
```

- [ ] **Step 2: Build**

Run: `zcode build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceService.swift
git commit -m "feat(intelligence): summarize via guided generation"
```

---

### Task 9: Implement translate

**Files:**
- Modify: `AppFeedback/Services/Intelligence/IntelligenceService.swift`

- [ ] **Step 1: Replace `runTranslate` stub**

```swift
fileprivate func runTranslate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return text }
    let session = await MainActor.run { () -> LanguageModelSession in
        if let s = translationSession { return s }
        let s = LanguageModelSession(instructions: translationInstructions)
        translationSession = s
        return s
    }
    let targetName = Locale(identifier: "en").localizedString(forLanguageCode: targetCode) ?? targetCode
    let sourceName = sourceCode.flatMap {
        Locale(identifier: "en").localizedString(forLanguageCode: $0)
    }
    let prompt: String
    if let sourceName {
        prompt = "Translate this from \(sourceName) to \(targetName):\n\n\(trimmed)"
    } else {
        prompt = "Translate this to \(targetName):\n\n\(trimmed)"
    }
    let response = try await session.respond(to: prompt)
    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

- [ ] **Step 2: Build**

Run: `zcode build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceService.swift
git commit -m "feat(intelligence): translate via LanguageModelSession"
```

---

### Task 10: `IntelligenceSettings` store

**Files:**
- Create: `AppFeedback/Services/Intelligence/IntelligenceSettings.swift`
- Create: `AppFeedbackTests/IntelligenceSettingsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class IntelligenceSettingsTests: XCTestCase {

    private func makeSettings(suite: String = UUID().uuidString) -> (IntelligenceSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (IntelligenceSettings(defaults: defaults), defaults)
    }

    func test_defaults_translationEnabledTrue_targetIsSystem() {
        let (s, _) = makeSettings()
        XCTAssertTrue(s.translationEnabled)
        XCTAssertFalse(s.targetLanguageCode.isEmpty)
    }

    func test_setTargetLanguage_persistsInDefaults() {
        let (s, defaults) = makeSettings()
        s.targetLanguageCode = "fr"
        XCTAssertEqual(defaults.string(forKey: "intelligence.targetLanguage"), "fr")
    }

    func test_setTranslationEnabled_persistsInDefaults() {
        let (s, defaults) = makeSettings()
        s.translationEnabled = false
        XCTAssertEqual(defaults.bool(forKey: "intelligence.translationEnabled"), false)
        XCTAssertNotNil(defaults.object(forKey: "intelligence.translationEnabled"))
    }

    func test_init_loadsExistingValues() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("ja", forKey: "intelligence.targetLanguage")
        defaults.set(false, forKey: "intelligence.translationEnabled")
        let s = IntelligenceSettings(defaults: defaults)
        XCTAssertEqual(s.targetLanguageCode, "ja")
        XCTAssertFalse(s.translationEnabled)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `zcode test --filter IntelligenceSettingsTests`
Expected: FAIL — `IntelligenceSettings` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

@Observable @MainActor
final class IntelligenceSettings {
    private let defaults: UserDefaults
    private static let translationEnabledKey = "intelligence.translationEnabled"
    private static let targetLanguageKey = "intelligence.targetLanguage"

    var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Self.translationEnabledKey) }
    }
    var targetLanguageCode: String {
        didSet { defaults.set(targetLanguageCode, forKey: Self.targetLanguageKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.translationEnabledKey) == nil {
            self.translationEnabled = true
        } else {
            self.translationEnabled = defaults.bool(forKey: Self.translationEnabledKey)
        }
        if let stored = defaults.string(forKey: Self.targetLanguageKey), !stored.isEmpty {
            self.targetLanguageCode = stored
        } else {
            self.targetLanguageCode = Self.systemLanguageCode()
        }
    }

    static func systemLanguageCode() -> String {
        if let code = Locale.current.language.languageCode?.identifier, !code.isEmpty {
            return code
        }
        return "en"
    }

    /// Curated picker list. Keep small; users can pick "Other…" elsewhere.
    static let pickerOptions: [(code: String, displayName: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
        ("nl", "Dutch")
    ]
}
```

- [ ] **Step 4: Run, expect pass**

Run: `zcode test --filter IntelligenceSettingsTests`
Expected: PASS (all 4)

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/Intelligence/IntelligenceSettings.swift AppFeedbackTests/IntelligenceSettingsTests.swift
git commit -m "feat(intelligence): IntelligenceSettings store"
```

---

### Task 11: Translation pipeline in `IssueListViewModel`

**Files:**
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift`
- Modify: `AppFeedbackTests/IssueListViewModelTests.swift`

- [ ] **Step 1: Add unread computed and translation hookup to view model**

Edit `AppFeedback/ViewModels/IssueListViewModel.swift`. After `var allIssues: [FeedbackIssue] = []` add:

```swift
var unreadIssues: [FeedbackIssue] {
    allIssues.filter { sessionUnread.contains($0.number) }
}
```

Then add new properties at the bottom of the class:

```swift
private(set) var intelligenceProvider: IntelligenceProvider?
private(set) var intelligenceSettings: IntelligenceSettings?
private var cacheContext: ModelContext?
private var translationTasks: [Int: Task<Void, Never>] = [:]

func attachIntelligence(
    provider: IntelligenceProvider,
    settings: IntelligenceSettings,
    cacheContext: ModelContext
) {
    self.intelligenceProvider = provider
    self.intelligenceSettings = settings
    self.cacheContext = cacheContext
}

func startTranslationsIfNeeded() {
    guard let provider = intelligenceProvider,
          let settings = intelligenceSettings,
          settings.translationEnabled,
          provider.availability == .available else { return }

    let target = settings.targetLanguageCode
    for issue in allIssues {
        if issue.translatedTitle != nil && issue.translatedBody != nil
            && issue.translationTargetLanguage == target { continue }
        if translationTasks[issue.number] != nil { continue }

        let detected = LanguageDetector.detect(issue.title + "\n" + issue.description)
        guard let detected, !detected.hasPrefix(target) else { continue }

        translationTasks[issue.number] = Task { [weak self] in
            await self?.translate(issue: issue, detected: detected, target: target)
        }
    }
}

@MainActor
private func translate(issue: FeedbackIssue, detected: String, target: String) async {
    defer { translationTasks[issue.number] = nil }
    guard let provider = intelligenceProvider else { return }
    do {
        async let titleT = provider.translate(text: issue.title, from: detected, to: target)
        async let bodyT = provider.translate(text: issue.description, from: detected, to: target)
        let (newTitle, newBody) = try await (titleT, bodyT)
        try Task.checkCancellation()

        if let idx = allIssues.firstIndex(where: { $0.number == issue.number }) {
            allIssues[idx].detectedLanguageCode = detected
            allIssues[idx].translatedTitle = newTitle
            allIssues[idx].translatedBody = newBody
            allIssues[idx].translationTargetLanguage = target
        }
        if let context = cacheContext {
            persistTranslation(
                issueNumber: issue.number,
                detected: detected,
                title: newTitle,
                body: newBody,
                target: target,
                context: context
            )
        }
    } catch {
        // Silent — leave originals in place.
    }
}

private func persistTranslation(
    issueNumber: Int,
    detected: String,
    title: String,
    body: String,
    target: String,
    context: ModelContext
) {
    let owner = seenOwner
    let repo = seenRepo
    let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
        cached.repoOwner == owner && cached.repoName == repo && cached.number == issueNumber
    })
    if let existing = try? context.fetch(descriptor).first {
        existing.detectedLanguageCode = detected
        existing.translatedTitle = title
        existing.translatedBody = body
        existing.translationTargetLanguage = target
        try? context.save()
    }
}

func invalidateTranslations() {
    for (_, task) in translationTasks { task.cancel() }
    translationTasks.removeAll()
    for i in allIssues.indices {
        allIssues[i].translatedTitle = nil
        allIssues[i].translatedBody = nil
        allIssues[i].translationTargetLanguage = nil
    }
    if let context = cacheContext {
        let owner = seenOwner
        let repo = seenRepo
        let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
            cached.repoOwner == owner && cached.repoName == repo
        })
        if let rows = try? context.fetch(descriptor) {
            for row in rows {
                row.translatedTitle = nil
                row.translatedBody = nil
                row.translationTargetLanguage = nil
            }
            try? context.save()
        }
    }
}
```

Add `import SwiftData` at the top of the file.

In `applyLoaded(_:)`, after setting `previouslyLoadedNumbers = numbers`, append:

```swift
startTranslationsIfNeeded()
```

- [ ] **Step 2: Add tests**

Append to `AppFeedbackTests/IssueListViewModelTests.swift`:

```swift
func test_translation_skipsTargetLanguageIssues() async {
    let mock = MockIntelligenceProvider()
    let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    settings.targetLanguageCode = "en"

    let vm = IssueListViewModel()
    let englishIssue = FeedbackIssue(
        number: 1,
        title: "Crash on launch when opening settings page repeatedly",
        createdAt: Date(),
        rawBody: "App crashes",
        appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
        description: "App crashes when I open settings repeatedly on macOS.",
        labels: []
    )
    vm.allIssues = [englishIssue]
    let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

    vm.startTranslationsIfNeeded()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(mock.translateCalls.count, 0)
}

func test_translation_translatesNonTargetLanguage() async {
    let mock = MockIntelligenceProvider()
    let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    settings.targetLanguageCode = "en"

    let vm = IssueListViewModel()
    let spanishIssue = FeedbackIssue(
        number: 2,
        title: "La aplicación se cierra inesperadamente",
        createdAt: Date(),
        rawBody: "",
        appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
        description: "La aplicación se cierra cuando abro la página de configuración.",
        labels: []
    )
    vm.allIssues = [spanishIssue]
    let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

    vm.startTranslationsIfNeeded()

    // Wait for the in-flight task to finish
    for _ in 0..<50 {
        if mock.translateCalls.count >= 2 { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(mock.translateCalls.count, 2)
    XCTAssertEqual(vm.allIssues[0].translationTargetLanguage, "en")
    XCTAssertEqual(vm.allIssues[0].translatedTitle, "[t] La aplicación se cierra inesperadamente")
}
```

- [ ] **Step 3: Run tests**

Run: `zcode test --filter IssueListViewModelTests`
Expected: PASS for new tests; existing tests unaffected.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat(translation): background translation pipeline in IssueListViewModel"
```

---

### Task 12: `IssueCardView` translation toggle

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`

- [ ] **Step 1: Read the existing card to see title/body rendering**

Run: `head -80 AppFeedback/Views/Issues/IssueCardView.swift`
Note: identify the views that render `issue.title` and `issue.description`.

- [ ] **Step 2: Add `@State` and helper to the view**

In the struct body, near the other `@State` declarations, add:

```swift
@State private var showOriginal: Bool = false
```

Add this computed property:

```swift
private var translationVisible: Bool {
    issue.hasTranslation && !showOriginal
}
```

- [ ] **Step 3: Replace title/body usages**

Wherever `issue.title` is rendered as the main heading, change to `issue.displayedTitle(translated: translationVisible)`.

Wherever `issue.description` is rendered as the body, change to `issue.displayedBody(translated: translationVisible)`.

- [ ] **Step 4: Add the toggle button (or unavailable hint) below the body**

Below the body Text view, add:

```swift
if issue.hasTranslation {
    Button(showOriginal ? "Show translation" : "Show original") {
        showOriginal.toggle()
    }
    .font(.system(size: 11, weight: .medium))
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .padding(.top, 4)
} else if needsTranslationButUnavailable {
    Text("Apple Intelligence required to translate")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
}
```

Add this computed property to the view (the `availability` and target-language code can be passed in as new `let` properties on the view struct — `let intelligenceAvailable: Bool`, `let targetLanguageCode: String`; pass them from `IssueListView` based on `viewModel.intelligenceProvider?.availability == .available` and `viewModel.intelligenceSettings?.targetLanguageCode`):

```swift
private var needsTranslationButUnavailable: Bool {
    guard !intelligenceAvailable else { return false }
    let combined = issue.title + "\n" + issue.description
    guard let detected = LanguageDetector.detect(combined) else { return false }
    return !detected.hasPrefix(targetLanguageCode)
}
```

- [ ] **Step 5: Build**

Run: `zcode build`
Expected: build succeeds.

- [ ] **Step 6: Manual visual verification (macOS)**

Run app via `zcode run`. Confirm: when an issue has cached translation values (you can inject by editing a `CachedIssue` directly from the debugger or temporarily seeding `vm.allIssues` in `RootView`), a "Show original" button appears. Tapping flips the title and body.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat(translation): per-card show original toggle"
```

---

### Task 13: `UnreadSummaryViewModel`

**Files:**
- Create: `AppFeedback/ViewModels/UnreadSummaryViewModel.swift`
- Create: `AppFeedbackTests/UnreadSummaryViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class UnreadSummaryViewModelTests: XCTestCase {

    private func issue(_ n: Int) -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: "T\(n)", createdAt: Date(),
            rawBody: "", appName: "A", appVersion: nil, device: nil,
            osVersion: nil, email: nil, description: "D\(n)", labels: []
        )
    }

    func test_skipped_whenLessThanTwo() async {
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(unread: [issue(1)], targetLanguage: "en")
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .skipped = vm.state { } else { XCTFail("expected .skipped, got \(vm.state)") }
        XCTAssertEqual(mock.summarizeCalls.count, 0)
    }

    func test_unavailable_whenProviderUnavailable() async {
        let mock = MockIntelligenceProvider()
        mock.availability = .appleIntelligenceNotEnabled
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(unread: [issue(1), issue(2)], targetLanguage: "en")
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .unavailable = vm.state { } else { XCTFail("expected .unavailable, got \(vm.state)") }
    }

    func test_ready_whenSummarizeSucceeds() async {
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(unread: [issue(1), issue(2), issue(3)], targetLanguage: "en")
        for _ in 0..<50 {
            if case .ready = vm.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .ready(let summary) = vm.state else {
            XCTFail("expected .ready, got \(vm.state)"); return
        }
        XCTAssertEqual(summary.headline, "3 unread issues")
    }

    func test_failed_whenSummarizeThrows() async {
        let mock = MockIntelligenceProvider()
        struct Boom: Error {}
        mock.summarizeHandler = { _, _ in throw Boom() }
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(unread: [issue(1), issue(2)], targetLanguage: "en")
        for _ in 0..<50 {
            if case .failed = vm.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .failed = vm.state { } else { XCTFail("expected .failed, got \(vm.state)") }
    }

    func test_update_replacesInFlightTask() async {
        let mock = MockIntelligenceProvider()
        mock.summarizeHandler = { issues, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return IssueSummaryDTO(headline: "\(issues.count)", bullets: [])
        }
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(unread: [issue(1), issue(2)], targetLanguage: "en")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await vm.update(unread: [issue(1), issue(2), issue(3), issue(4)], targetLanguage: "en")
        for _ in 0..<50 {
            if case .ready(let s) = vm.state, s.headline == "4" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .ready(let s) = vm.state {
            XCTAssertEqual(s.headline, "4")
        } else {
            XCTFail("expected .ready, got \(vm.state)")
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `zcode test --filter UnreadSummaryViewModelTests`
Expected: FAIL — `UnreadSummaryViewModel` not defined.

- [ ] **Step 3: Implement**

Create `AppFeedback/ViewModels/UnreadSummaryViewModel.swift`:

```swift
import Foundation
import Observation

enum SummaryState: Equatable {
    case idle
    case loading
    case ready(IssueSummaryDTO)
    case skipped
    case unavailable
    case failed(String)
}

@Observable @MainActor
final class UnreadSummaryViewModel {
    private(set) var state: SummaryState = .idle

    private let provider: IntelligenceProvider
    private let debounceMs: UInt64
    private var currentTask: Task<Void, Never>?

    init(provider: IntelligenceProvider, debounceMs: UInt64 = 500) {
        self.provider = provider
        self.debounceMs = debounceMs
    }

    func update(unread: [FeedbackIssue], targetLanguage: String) async {
        currentTask?.cancel()

        if provider.availability != .available {
            state = .unavailable
            return
        }
        if unread.count < 2 {
            state = .skipped
            return
        }
        state = .loading
        currentTask = Task { [provider, debounceMs] in
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            if Task.isCancelled { return }
            do {
                let result = try await provider.summarize(issues: unread, targetLanguage: targetLanguage)
                if Task.isCancelled { return }
                await MainActor.run { self.state = .ready(result) }
            } catch is CancellationError {
                // Silent.
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `zcode test --filter UnreadSummaryViewModelTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/ViewModels/UnreadSummaryViewModel.swift AppFeedbackTests/UnreadSummaryViewModelTests.swift
git commit -m "feat(intelligence): UnreadSummaryViewModel with debounce and skip rules"
```

---

### Task 14: `UnreadSummaryView`

**Files:**
- Create: `AppFeedback/Views/Issues/UnreadSummaryView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

struct UnreadSummaryView: View {
    let state: SummaryState
    let collapseKey: String
    var onRetry: () -> Void = {}

    @AppStorage private var collapsed: Bool

    init(state: SummaryState, collapseKey: String, onRetry: @escaping () -> Void = {}) {
        self.state = state
        self.collapseKey = collapseKey
        self.onRetry = onRetry
        self._collapsed = AppStorage(wrappedValue: false, "summary.collapsed.\(collapseKey)")
    }

    var body: some View {
        switch state {
        case .skipped, .unavailable, .idle:
            EmptyView()
        case .loading:
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing unread issues…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            card {
                HStack {
                    Text("Couldn't generate summary — \(message)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry", action: onRetry)
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
        case .ready(let summary):
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        collapsed.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            Text(summary.headline)
                                .font(.system(size: 13, weight: .semibold))
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !collapsed {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(bullet.text)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text("\(bullet.issueCount)")
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.secondary.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.tint.opacity(0.2), lineWidth: 0.5)
            )
    }
}
```

- [ ] **Step 2: Build**

Run: `zcode build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Issues/UnreadSummaryView.swift
git commit -m "feat(intelligence): collapsible unread summary card view"
```

---

### Task 15: Wire up summary view in `IssueListView`

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueListView.swift`

- [ ] **Step 1: Add the summary view model property**

Inside `IssueListView`, add:

```swift
@Bindable var summaryVM: UnreadSummaryViewModel
let summaryCollapseKey: String
```

- [ ] **Step 2: Insert the view between filter bar and the issue list**

In the `LazyVStack` inside `issueList`, after the existing `FilterBarView` block and before the `HStack { Text(summaryText...) }`, add:

```swift
UnreadSummaryView(
    state: summaryVM.state,
    collapseKey: summaryCollapseKey
)
.padding(.horizontal, 2)
```

- [ ] **Step 3: Trigger updates**

Add a `.task(id: ...)` modifier on the `LazyVStack` so the summary recomputes when the unread set or target language changes:

```swift
.task(id: summaryTaskID) {
    await summaryVM.update(
        unread: viewModel.unreadIssues,
        targetLanguage: viewModel.intelligenceSettings?.targetLanguageCode ?? "en"
    )
}
```

Add this computed property to the struct:

```swift
private var summaryTaskID: String {
    let unread = viewModel.unreadIssues.map(\.number).sorted().map(String.init).joined(separator: ",")
    let lang = viewModel.intelligenceSettings?.targetLanguageCode ?? "en"
    return "\(lang)|\(unread)"
}
```

- [ ] **Step 4: Update callers**

Find where `IssueListView(...)` is constructed (probably `RootView.swift`). Update those call sites by following the compiler errors after the next build. Each call site needs to pass `summaryVM:` and `summaryCollapseKey:`. The `summaryCollapseKey` should be a stable identifier for the current sidebar selection (e.g., `"\(repoOwner)/\(repoName)"` or `selection.id` if available).

- [ ] **Step 5: Build, fix call sites**

Run: `zcode build`
Address compile errors at `IssueListView` call sites until clean.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Views/Issues/IssueListView.swift AppFeedback/App/RootView.swift
git commit -m "feat(intelligence): show unread summary card in issue list"
```

---

### Task 16: `IntelligenceSettingsSection` UI

**Files:**
- Create: `AppFeedback/Views/Settings/IntelligenceSettingsSection.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

struct IntelligenceSettingsSection: View {
    @Bindable var settings: IntelligenceSettings
    let availability: IntelligenceAvailability
    var onOpenSystemSettings: () -> Void = {}

    var body: some View {
        Form {
            Section("Status") {
                HStack(spacing: 8) {
                    Image(systemName: availability.systemImageName)
                        .foregroundStyle(availability.isReady ? .green : .orange)
                    Text(availability.statusText)
                        .font(.system(size: 13))
                    Spacer()
                    if availability == .appleIntelligenceNotEnabled {
                        Button("Open System Settings") { onOpenSystemSettings() }
                    }
                }
            }
            Section("Translation") {
                Toggle("Translate non-English issues", isOn: $settings.translationEnabled)
                    .disabled(!availability.isReady)
                Picker("Target language", selection: $settings.targetLanguageCode) {
                    ForEach(IntelligenceSettings.pickerOptions, id: \.code) { option in
                        Text(option.displayName).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!availability.isReady || !settings.translationEnabled)
                Text("Changing the target language re-translates issues as you view them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Add the tab to `SettingsView`**

In `AppFeedback/Views/Settings/SettingsView.swift`, declare the dependency:

```swift
@Environment(IntelligenceSettings.self) private var intelligenceSettings
@Environment(IntelligenceService.self) private var intelligenceService
```

In the `TabView`, after the EmailSettingsView tab item, add:

```swift
#if os(macOS)
IntelligenceSettingsSection(
    settings: intelligenceSettings,
    availability: intelligenceService.availability,
    onOpenSystemSettings: {
        if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligenceSettings") {
            NSWorkspace.shared.open(url)
        }
    }
)
.tabItem { Label("Intelligence", systemImage: "sparkles") }
#endif
```

- [ ] **Step 3: Build (will fail until Task 17 wires environment)**

Run: `zcode build`
If it fails because `IntelligenceSettings`/`IntelligenceService` aren't in environment, proceed to Task 17 first.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Settings/IntelligenceSettingsSection.swift AppFeedback/Views/Settings/SettingsView.swift
git commit -m "feat(intelligence): settings section with status and language picker"
```

---

### Task 17: Bootstrap services in `AppFeedbackApp`

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`
- Modify: `AppFeedback/App/RootView.swift`

- [ ] **Step 1: Instantiate the services in `AppFeedbackApp`**

In `AppFeedbackApp`, add `@State` properties:

```swift
@State private var intelligenceSettings: IntelligenceSettings
@State private var intelligenceService: IntelligenceService
```

In `init()`, after the existing initialization, add:

```swift
let settings = IntelligenceSettings()
_intelligenceSettings = State(initialValue: settings)
_intelligenceService = State(initialValue: IntelligenceService())
```

In the `WindowGroup` body and the `Settings` body, add `.environment` modifiers for both:

```swift
.environment(intelligenceSettings)
.environment(intelligenceService)
```

- [ ] **Step 2: Pass services into `RootView` -> `IssueListViewModel`**

In `RootView`, accept the new `@Environment` values:

```swift
@Environment(IntelligenceSettings.self) private var intelligenceSettings
@Environment(IntelligenceService.self) private var intelligenceService
```

Where `IssueListViewModel` is created and `attachSeenStore` is called, also call:

```swift
viewModel.attachIntelligence(
    provider: intelligenceService,
    settings: intelligenceSettings,
    cacheContext: cacheContext
)
```

Create one `UnreadSummaryViewModel` per active list view. Because the provider lives in environment, declare the field optional and initialize on `.task`:

```swift
@State private var summaryVM: UnreadSummaryViewModel?
```

```swift
.task {
    if summaryVM == nil {
        summaryVM = UnreadSummaryViewModel(provider: intelligenceService)
    }
}
```

Render the `IssueListView` only when `summaryVM` is non-nil (a one-frame `ProgressView` placeholder is acceptable on first appearance):

```swift
if let summaryVM {
    IssueListView(
        viewModel: viewModel,
        loader: loader,
        allApps: allApps,
        onRefresh: onRefresh,
        repoOwner: repoOwner,
        repoName: repoName,
        appColorOverrides: appColorOverrides,
        summaryVM: summaryVM,
        summaryCollapseKey: "\(repoOwner)/\(repoName)"
    )
}
```

Pass it into `IssueListView` along with a stable `summaryCollapseKey` (e.g., `"\(repoOwner)/\(repoName)"`).

- [ ] **Step 3: Re-translate on target-language change**

In `RootView`, observe target-language changes and call `viewModel.invalidateTranslations()` then `viewModel.startTranslationsIfNeeded()`. Use `.onChange`:

```swift
.onChange(of: intelligenceSettings.targetLanguageCode) { _, _ in
    viewModel.invalidateTranslations()
    viewModel.startTranslationsIfNeeded()
}
.onChange(of: intelligenceSettings.translationEnabled) { _, enabled in
    if enabled {
        viewModel.startTranslationsIfNeeded()
    } else {
        viewModel.invalidateTranslations()
    }
}
```

- [ ] **Step 4: Build**

Run: `zcode build`
Expected: succeeds.

- [ ] **Step 5: Run app and verify end-to-end**

Run: `zcode run`. With the app running:

1. Open Settings → Intelligence tab. Confirm status is shown (will be `osTooOld` on pre-macOS-26 machines, otherwise the real status).
2. If on a supported machine, open the issue list with at least 2 unread issues — confirm the summary card appears below the filter bar; tap chevron to collapse.
3. If non-English issues are present, confirm a "Show original" button appears on those cards and toggles content.
4. Change the target language in Settings — confirm previously translated cards re-translate (visible cards immediately, others on next list view).

If running on hardware where Apple Intelligence is unavailable, only steps 1 + the absence of the summary card / translation toggles needs to be verified.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift AppFeedback/App/RootView.swift
git commit -m "feat(intelligence): wire up IntelligenceService and settings into app"
```

---

### Task 18: Final verification + cleanup

- [ ] **Step 1: Run full test suite**

Run: `zcode test`
Expected: all tests pass.

- [ ] **Step 2: Build release configuration**

Run: `zcode build --configuration Release`
Expected: succeeds.

- [ ] **Step 3: Manual smoke test summary**

Re-run the app once more and walk through the user-facing scenarios from Task 17 Step 5. Note any rough edges in a follow-up issue but do not extend scope here.

- [ ] **Step 4: Open PR**

```bash
git push -u origin HEAD
gh pr create --title "Apple Intelligence: unread summary + per-issue translation" --body "Implements docs/superpowers/specs/2026-04-28-apple-intelligence-design.md"
```

---

## Out of Scope

- Translating issue comments / replies.
- Per-app or per-repo summary opt-out.
- Custom summary styles or prompts in Settings.
- Use of Foundation Models for any feature beyond summary + translation.
