# Gated Translation Language Download — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop auto-presenting Apple's Translation "Download Languages" sheet; instead show a per-issue inline "Translate · download <Language>" link that triggers the sheet only when tapped.

**Architecture:** A language pair that is *supported but not downloaded* (`LanguageAvailability.Status.supported`) is gated in the view model instead of immediately starting a `TranslationSession`. The `TranslationFallbackHost` asks the view model for a pump decision; gated pairs are skipped so they don't block ready pairs. The card shows a tappable link that approves the pair, which lets the host start the session (presenting the system sheet). If the user dismisses the sheet without downloading, the pair is re-gated so the link returns.

**Tech Stack:** SwiftUI, Apple Translation framework (`Translation`), `@Observable` view model, XCTest (`AppFeedbackTests_macOS`).

**Design doc:** `docs/superpowers/specs/2026-06-01-gated-translation-language-download-design.md`

**Note on the spec's §6:** the spec proposed injecting a status closure into the host. This plan instead moves the *decision* logic into a pure view-model method (`pumpDecision(for:state:)`) over a framework-agnostic enum. Same testability goal, cleaner — the view stays a thin driver and the gating state machine is unit-tested without the Translation framework or a device.

**Running tests:** Build/iterate with the zcode skill. For ground truth on a specific test (the zcode/`/api/test` summary can mask trap crashes), run xcodebuild directly:
```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/<testName>
```
Build only:
```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```

## File Structure

- **Modify** `AppFeedback/ViewModels/IssueListViewModel.swift` — add the gating types (`LanguagePair`, `LanguageDownloadState`, `FallbackPumpDecision`), gating state, and the gating methods (`pumpDecision`, `markFallbackNeedsDownload`, `needsLanguageDownload`, `approveLanguageDownload` (two overloads), `regateDownload`, `nextPumpableFallback`). This file is large but established; we add a focused gating section rather than restructuring.
- **Modify** `AppFeedback/Views/Issues/TranslationFallbackHost.swift` — drive the new view-model API: skip gated pairs, branch on `pumpDecision`, re-gate on sheet dismissal. Small file; rewritten in full.
- **Modify** `AppFeedback/Views/Issues/IssueCardView.swift` — add `needsDownloadLanguage` / `onRequestDownload` props and the inline link branch.
- **Modify** `AppFeedback/Views/Issues/IssueListView.swift` — thread the two new props into the card.
- **Modify** `AppFeedbackTests/IssueListViewModelTests.swift` — add gating unit tests to the existing `extension IssueListViewModelTests` (reuses the `makeGuardrailFallbackVM` helper at line 405).

---

## Task 1: View-model gating types and pump decision

Pure state machine: given a fallback request and an availability state, decide whether to proceed, gate for download, or treat as unavailable. No framework dependency — testable directly.

**Files:**
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift`
- Test: `AppFeedbackTests/IssueListViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the `extension IssueListViewModelTests` block in `AppFeedbackTests/IssueListViewModelTests.swift` (before its closing `}` at line 519):

```swift
// MARK: - Language download gating

private func makeFallbackReq(
    detected: String,
    target: String = "en",
    reason: IssueListViewModel.FallbackReason = .unsupportedOnDevice
) -> IssueListViewModel.FallbackRequest {
    IssueListViewModel.FallbackRequest(
        requestID: UUID(), issueNumber: 1, title: "t", body: "b",
        detected: detected, target: target, reason: reason)
}

func test_pumpDecision_installed_proceeds() {
    let vm = IssueListViewModel()
    XCTAssertEqual(vm.pumpDecision(for: makeFallbackReq(detected: "ar"), state: .installed), .proceed)
}

func test_pumpDecision_unsupported_isUnavailable() {
    let vm = IssueListViewModel()
    XCTAssertEqual(vm.pumpDecision(for: makeFallbackReq(detected: "ar"), state: .unsupported), .unavailable)
}

func test_pumpDecision_supportedUnapproved_needsDownload() {
    let vm = IssueListViewModel()
    XCTAssertEqual(vm.pumpDecision(for: makeFallbackReq(detected: "ar"), state: .supported), .needsDownload)
}

func test_pumpDecision_supportedApproved_proceeds() {
    let vm = IssueListViewModel()
    vm.approveLanguageDownload(detected: "ar", target: "en")
    XCTAssertEqual(vm.pumpDecision(for: makeFallbackReq(detected: "ar"), state: .supported), .proceed)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_pumpDecision_installed_proceeds
```
Expected: FAIL to compile — `LanguageDownloadState`, `FallbackPumpDecision`, `pumpDecision`, and `approveLanguageDownload(detected:target:)` don't exist yet.

- [ ] **Step 3: Add the gating types**

In `AppFeedback/ViewModels/IssueListViewModel.swift`, immediately after the `FallbackRequest` struct definition (it ends at line 234 with `}` closing the struct, just before `private(set) var pendingFallbacks`), add:

```swift
/// A (source → target) translation language pair. Modeled in full (not just the
/// source) so a mid-session target switch is tracked correctly.
struct LanguagePair: Hashable {
    let detected: String
    let target: String
}

/// Framework-agnostic mirror of `Translation.LanguageAvailability.Status`, so the
/// gating decision can be unit-tested without the Translation framework.
enum LanguageDownloadState {
    case installed     // both languages on-device; translate silently
    case supported     // supported but not downloaded; needs a user-approved download
    case unsupported   // not translatable at all
}

/// What the fallback host should do with a pending request given its pair's state.
enum FallbackPumpDecision: Equatable {
    case proceed        // start the session (installed, or user approved the download)
    case needsDownload  // gate: surface the inline download affordance, don't start yet
    case unavailable    // drop/blacklist via handleFallbackUnavailable
}
```

- [ ] **Step 4: Add the gating state**

In the same file, immediately after `private(set) var pendingFallbacks: [FallbackRequest] = []` (line 236), add:

```swift
/// Pairs that are supported but not downloaded and are awaiting the user's tap.
/// Drives the per-issue "download to translate" affordance.
private(set) var pairsNeedingDownload: Set<LanguagePair> = []
/// Pairs the user explicitly approved downloading; lets `pumpDecision` proceed past
/// the `.supported` gate so the session starts and the system sheet appears.
private var approvedDownloadPairs: Set<LanguagePair> = []
/// Bumped on each approval so `TranslationFallbackHost` re-pumps the queue.
private(set) var downloadApprovalTick: Int = 0
```

- [ ] **Step 5: Add `pumpDecision` and `approveLanguageDownload(detected:target:)`**

In the same file, immediately after the `handleFallbackUnavailable(_:)` method (it ends at line 430), add:

```swift
/// Decides what the fallback host does with `request` given its pair's availability.
/// A `.supported` pair proceeds only if the user has approved its download.
func pumpDecision(for request: FallbackRequest, state: LanguageDownloadState) -> FallbackPumpDecision {
    switch state {
    case .unsupported:
        return .unavailable
    case .installed:
        return .proceed
    case .supported:
        let pair = LanguagePair(detected: request.detected, target: request.target)
        return approvedDownloadPairs.contains(pair) ? .proceed : .needsDownload
    }
}

/// Records the user's consent to download `detected`→`target`, clears any pending
/// gate for it, and nudges the host (via `downloadApprovalTick`) to re-pump.
func approveLanguageDownload(detected: String, target: String) {
    let pair = LanguagePair(detected: detected, target: target)
    pairsNeedingDownload.remove(pair)
    approvedDownloadPairs.insert(pair)
    downloadApprovalTick &+= 1
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_pumpDecision_installed_proceeds \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_pumpDecision_unsupported_isUnavailable \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_pumpDecision_supportedUnapproved_needsDownload \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_pumpDecision_supportedApproved_proceeds
```
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat(translation): add language-download gating decision to view model"
```

---

## Task 2: View-model gating lifecycle (gate → prompt → approve → re-gate)

The per-issue helpers the UI and host call: surface the prompt, pick a non-gated request to pump, approve, and re-gate on dismissal.

**Files:**
- Modify: `AppFeedback/ViewModels/IssueListViewModel.swift`
- Test: `AppFeedbackTests/IssueListViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Add to the `extension IssueListViewModelTests` block (after the Task 1 tests):

```swift
func test_languageDownloadGate_lifecycle() async {
    // A real pending fallback request (German guardrail route) to exercise the gate.
    let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App."
    guard let (vm, _, request) = await makeGuardrailFallbackVM(germanBody: germanBody) else {
        return XCTFail("guardrail body never routed to fallback")
    }
    let issue = vm.allIssues[0]

    // Not gated yet: no prompt, request is pumpable.
    XCTAssertNil(vm.needsLanguageDownload(issue))
    XCTAssertEqual(vm.nextPumpableFallback()?.issueNumber, 381)

    // Host gates the pair (simulating a `.supported` status): prompt appears,
    // and the gated pair is skipped so it can't block a ready pair behind it.
    vm.markFallbackNeedsDownload(detected: request.detected, target: request.target)
    XCTAssertNotNil(vm.needsLanguageDownload(issue))
    XCTAssertNil(vm.nextPumpableFallback())

    // User taps download: prompt clears, request becomes pumpable, a `.supported`
    // pair now proceeds, and the host is nudged via the tick.
    let tickBefore = vm.downloadApprovalTick
    vm.approveLanguageDownload(for: issue)
    XCTAssertNil(vm.needsLanguageDownload(issue))
    XCTAssertEqual(vm.nextPumpableFallback()?.issueNumber, 381)
    XCTAssertEqual(vm.pumpDecision(for: request, state: .supported), .proceed)
    XCTAssertGreaterThan(vm.downloadApprovalTick, tickBefore)

    // User dismisses the sheet without downloading: re-gate, prompt returns.
    vm.regateDownload(detected: request.detected, target: request.target)
    XCTAssertNotNil(vm.needsLanguageDownload(issue))
    XCTAssertEqual(vm.pumpDecision(for: request, state: .supported), .needsDownload)
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_languageDownloadGate_lifecycle
```
Expected: FAIL to compile — `markFallbackNeedsDownload`, `needsLanguageDownload`, `approveLanguageDownload(for:)`, `regateDownload`, `nextPumpableFallback` don't exist yet.

- [ ] **Step 3: Add the lifecycle methods**

In `AppFeedback/ViewModels/IssueListViewModel.swift`, immediately after the `approveLanguageDownload(detected:target:)` method added in Task 1, add:

```swift
/// Marks a `detected`→`target` pair as needing a user-approved download. Called by
/// the host when availability reports `.supported` for a pair the user hasn't approved.
func markFallbackNeedsDownload(detected: String, target: String) {
    pairsNeedingDownload.insert(LanguagePair(detected: detected, target: target))
}

/// The source-language display name to prompt the user to download for `issue`, or
/// nil if it isn't gated on a download (no pending request, or already approved).
func needsLanguageDownload(_ issue: FeedbackIssue) -> String? {
    guard let req = pendingFallbacks.first(where: { $0.issueNumber == issue.number }) else { return nil }
    let pair = LanguagePair(detected: req.detected, target: req.target)
    guard pairsNeedingDownload.contains(pair) else { return nil }
    return Locale.current.localizedString(forLanguageCode: req.detected) ?? req.detected
}

/// Convenience for the card: resolves `issue` to its pending pair and approves it.
func approveLanguageDownload(for issue: FeedbackIssue) {
    guard let req = pendingFallbacks.first(where: { $0.issueNumber == issue.number }) else { return }
    approveLanguageDownload(detected: req.detected, target: req.target)
}

/// Re-gates a previously-approved pair — used when the user dismissed the system
/// download sheet without downloading, so the inline prompt reappears.
func regateDownload(detected: String, target: String) {
    let pair = LanguagePair(detected: detected, target: target)
    approvedDownloadPairs.remove(pair)
    pairsNeedingDownload.insert(pair)
}

/// The first pending fallback eligible to pump now: one whose pair is not currently
/// gated awaiting a download. Approving a pair removes it from `pairsNeedingDownload`,
/// so approved pairs are eligible again.
func nextPumpableFallback() -> FallbackRequest? {
    pendingFallbacks.first { req in
        !pairsNeedingDownload.contains(LanguagePair(detected: req.detected, target: req.target))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests/test_languageDownloadGate_lifecycle
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/ViewModels/IssueListViewModel.swift AppFeedbackTests/IssueListViewModelTests.swift
git commit -m "feat(translation): add language-download gate lifecycle to view model"
```

---

## Task 3: Drive gating from the fallback host

Rewrite `TranslationFallbackHost` to: pick a non-gated request, branch on `pumpDecision`, observe approvals, and re-gate when the user dismisses the sheet without downloading.

**Files:**
- Modify: `AppFeedback/Views/Issues/TranslationFallbackHost.swift` (full rewrite)

There is no unit test for this task — the host is a SwiftUI view that's impractical to drive in a unit test, and its decision logic now lives in the view-model methods covered by Tasks 1–2. Verify by building; the manual behavior is checked at the end of the plan.

- [ ] **Step 1: Replace the file contents**

Overwrite `AppFeedback/Views/Issues/TranslationFallbackHost.swift` with:

```swift
import SwiftUI
import Translation

/// Invisible host that drives Apple's Translation framework as a fallback for
/// issues the on-device Foundation Models translator refused with
/// `unsupportedLanguageOrLocale` (or a guardrail false-positive). Reads
/// `viewModel.pendingFallbacks`, processes one language pair at a time, and reports
/// results back. Pairs whose languages aren't downloaded are gated in the view model
/// and surfaced as a per-issue tap target rather than auto-presenting the system
/// download sheet; the session for such a pair starts only after the user approves.
struct TranslationFallbackHost: View {
    @Bindable var viewModel: IssueListViewModel

    @State private var activeConfig: TranslationSession.Configuration?
    @State private var activeLanguage: String?
    @State private var activeTarget: String?
    /// Set synchronously inside `pumpIfIdle` before the LanguageAvailability roundtrip
    /// dispatches, so a second `pumpIfIdle` call in the same runloop tick (initial `.task`
    /// + `.onChange`) doesn't launch a duplicate availability check. Cleared on the
    /// MainActor hop that decides what to do next.
    @State private var isPumping = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(activeConfig) { session in
                guard let detected = activeLanguage, let target = activeTarget else { return }
                await drain(session: session, detected: detected, target: target)
            }
            .task { pumpIfIdle() }
            .onChange(of: viewModel.pendingFallbacks) { _, _ in pumpIfIdle() }
            .onChange(of: viewModel.downloadApprovalTick) { _, _ in pumpIfIdle() }
    }

    /// Maps Apple's availability status into the view-model's framework-agnostic enum.
    private func currentState(detected: String, target: String) async -> IssueListViewModel.LanguageDownloadState {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: detected),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    private func pumpIfIdle() {
        guard activeConfig == nil, !isPumping else { return }
        // Take the first pending request whose pair isn't gated awaiting a download —
        // otherwise a gated pair at the head would block a ready pair behind it.
        guard let next = viewModel.nextPumpableFallback() else { return }
        let detected = next.detected
        let target = next.target
        isPumping = true
        Task {
            let state = await currentState(detected: detected, target: target)
            await MainActor.run {
                isPumping = false
                switch viewModel.pumpDecision(for: next, state: state) {
                case .unavailable:
                    // Genuine unsupported blacklists the language; a guardrail
                    // false-positive drops just this issue (see handleFallbackUnavailable).
                    viewModel.handleFallbackUnavailable(next)
                    pumpIfIdle()
                case .needsDownload:
                    // Gate it and surface the inline affordance; try other pairs that
                    // may already be installed.
                    viewModel.markFallbackNeedsDownload(detected: detected, target: target)
                    pumpIfIdle()
                case .proceed:
                    activeLanguage = detected
                    activeTarget = target
                    activeConfig = TranslationSession.Configuration(
                        source: Locale.Language(identifier: detected),
                        target: Locale.Language(identifier: target)
                    )
                }
            }
        }
    }

    private func drain(session: TranslationSession, detected: String, target: String) async {
        while true {
            // Match BOTH detected and target — if the user switched the global target
            // mid-drain, new requests carry the new target and must be processed by a
            // session bound to that target, not this one.
            let request: IssueListViewModel.FallbackRequest? = await MainActor.run {
                viewModel.pendingFallbacks.first(where: { $0.detected == detected && $0.target == target })
            }
            guard let request else { break }

            // A request with no content to translate would otherwise hit the
            // "neither translatedTitle nor translatedBody, no thrown error" branch and
            // poison the whole source language for the session.
            if request.title.isEmpty && request.body.isEmpty {
                await MainActor.run { viewModel.dropPendingFallback(request) }
                continue
            }

            var translatedTitle: String?
            var translatedBody: String?
            var transientError = false
            do {
                if !request.title.isEmpty {
                    translatedTitle = try await session.translate(request.title).targetText
                }
                if !request.body.isEmpty {
                    translatedBody = try await session.translate(request.body).targetText
                }
            } catch {
                // The user may have dismissed the system download sheet without
                // downloading. If the pair still only reports `.supported` (not
                // installed), treat it as a declined download: re-gate so the inline
                // prompt returns and leave every queued request for this pair pending.
                if await currentState(detected: detected, target: target) == .supported {
                    await MainActor.run {
                        viewModel.regateDownload(detected: detected, target: target)
                    }
                    break
                }
                // Otherwise a genuine transient error (network, cancellation) — don't
                // blacklist the whole source language on the strength of one failure.
                transientError = true
                print("[FallbackTranslate] error for #\(request.issueNumber): \(error)")
            }

            await MainActor.run {
                if translatedTitle != nil || translatedBody != nil {
                    viewModel.applyFallbackTranslation(request, title: translatedTitle, body: translatedBody)
                } else if transientError {
                    viewModel.dropPendingFallback(request)
                } else {
                    viewModel.markFallbackUnsupported(detectedLanguage: request.detected)
                }
            }
        }

        await MainActor.run {
            activeConfig = nil
            activeLanguage = nil
            activeTarget = nil
            pumpIfIdle()
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Issues/TranslationFallbackHost.swift
git commit -m "feat(translation): gate download sheet behind user approval in fallback host"
```

---

## Task 4: Inline download affordance on the card

Add the per-issue "Translate · download <Language>" link and wire it from the list.

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`
- Modify: `AppFeedback/Views/Issues/IssueListView.swift`

This is SwiftUI wiring; verify by building (and the manual check below). No unit test.

- [ ] **Step 1: Add the two card props**

In `AppFeedback/Views/Issues/IssueCardView.swift`, immediately after `var onRetranslate: (() -> Void)? = nil` (line 73), add:

```swift
/// Non-nil source-language display name when this issue is waiting on a
/// user-approved language download before it can be translated.
var needsDownloadLanguage: String? = nil
/// Invoked when the user taps the inline download link; approves the language pair.
var onRequestDownload: (() -> Void)? = nil
```

- [ ] **Step 2: Add the inline link branch**

In the same file, the footer block currently reads (around line 236):

```swift
                    if isTranslating {
                        ShimmeringText("Translating…")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.top, 4)
                    } else if issue.hasTranslation {
```

Replace that opening with a new branch inserted between the two:

```swift
                    if isTranslating {
                        ShimmeringText("Translating…")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.top, 4)
                    } else if let downloadLanguage = needsDownloadLanguage {
                        Button { onRequestDownload?() } label: {
                            Label("Translate · download \(downloadLanguage)",
                                  systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.top, 4)
                    } else if issue.hasTranslation {
```

(Leave the rest of the `else if issue.hasTranslation { ... }` block unchanged.)

- [ ] **Step 3: Thread the props from the list**

In `AppFeedback/Views/Issues/IssueListView.swift`, the card builder passes `isTranslating: viewModel.isTranslating(issue),` (line 280). Immediately after that line, add:

```swift
            needsDownloadLanguage: viewModel.needsLanguageDownload(issue),
            onRequestDownload: { viewModel.approveLanguageDownload(for: issue) },
```

- [ ] **Step 4: Build to verify it compiles**

```bash
xcodebuild build -scheme AppFeedback_macOS -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift AppFeedback/Views/Issues/IssueListView.swift
git commit -m "feat(translation): show per-issue language-download link on feedback cards"
```

---

## Task 5: Full verification

- [ ] **Step 1: Run the full view-model test suite**

```bash
xcodebuild test -scheme AppFeedback_macOS -destination 'platform=macOS' \
  -only-testing:AppFeedbackTests_macOS/IssueListViewModelTests
```
Expected: PASS — all existing tests plus the 5 new gating tests.

- [ ] **Step 2: Manual behavior check (real device/Mac with the Translation framework)**

Run the app against a repo containing feedback in a language whose pair is **not** downloaded (e.g. Arabic with Arabic/English not installed). Confirm:
1. The system "Download Languages to Translate" sheet does **not** appear on its own.
2. Each affected card shows a secondary "Translate · download <Language>" link.
3. Tapping the link presents the system sheet; the link disappears for that issue.
4. After downloading both languages, every queued issue in that pair translates and the link is replaced by the normal "Show original" control.
5. Tapping the link then **Done** without downloading brings the link back (does not leave the issue stuck or silently untranslated).

- [ ] **Step 3: Final commit (if any manual-fix tweaks were needed)**

```bash
git add -A && git commit -m "fix(translation): manual-test adjustments for download gating"
```
(Skip if no changes.)

---

## Self-Review

**Spec coverage:**
- §1 `.supported` gate + skip-gated pump → Task 1 (`pumpDecision`), Task 2 (`nextPumpableFallback`), Task 3 (host branch).
- §2 view-model state + four methods → Tasks 1–2 (state, `markFallbackNeedsDownload`, `needsLanguageDownload`, `approveLanguageDownload`, plus `regateDownload`/`nextPumpableFallback`).
- §3 card UI → Task 4 Steps 1–2.
- §4 tap → download → resume → Task 2 (`approveLanguageDownload`, tick), Task 3 (`onChange(downloadApprovalTick)` → `pumpDecision` `.proceed`), Task 4 wiring.
- §5 re-gate on dismiss → Task 2 (`regateDownload`), Task 3 (`drain` catch re-checks `.supported` and re-gates).
- §6 testability → realized as pure `pumpDecision` over `LanguageDownloadState`; covered by Tasks 1–2 tests. Deviation from the spec's closure-injection noted in the header.

**Type consistency:** `LanguagePair(detected:target:)`, `LanguageDownloadState{installed,supported,unsupported}`, `FallbackPumpDecision{proceed,needsDownload,unavailable}`, `pumpDecision(for:state:)`, `markFallbackNeedsDownload(detected:target:)`, `needsLanguageDownload(_:)`, `approveLanguageDownload(detected:target:)` + `approveLanguageDownload(for:)`, `regateDownload(detected:target:)`, `nextPumpableFallback()`, `downloadApprovalTick`, card props `needsDownloadLanguage`/`onRequestDownload` — all names used identically across tasks and tests.

**Placeholder scan:** none — every step has concrete code and exact commands.
