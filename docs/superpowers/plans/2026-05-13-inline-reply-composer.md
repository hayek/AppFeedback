# Inline Reply Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the windowed (macOS) / sheeted (iOS) mail composer with an inline composer that opens in place inside `MailThreadView` (replies) and `IssueCardView` (first-time emails), backed by an in-memory draft store; delete the windowed/sheet plumbing in the same change.

**Architecture:** Extract the existing compose form rows into a reusable `ComposeFormCore` view. Build a new `InlineReplyView` that hosts `ComposeFormCore` plus a compact header strip and a `ComposeMailViewModel`, hydrating its `subject`/`body` from a new `@Observable` `MailDraftStore` keyed by `(threadID)` for replies or `(repoOwner, repoName, issueNumber, recipient)` for first-time emails. After both call sites switch to `InlineReplyView`, delete `ComposeMailView`, `ComposeWindowHolder`, `ComposeWindowContent`, and the `WindowGroup("Compose", …)` scene.

**Tech Stack:** SwiftUI, Swift `@Observable`, SwiftData (for environment-injected stores already in use), SwiftMail (compile-guarded by `canImport(SwiftMail)`), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-13-inline-reply-composer-design.md`

**Build/test convention:** Each task ends with a build verification. Invoke the **`zcode` skill** to build both targets (macOS + iOS). If `zcode` is unavailable, the equivalent shell commands are listed inline. Tests run via `zcode test` or the inline `xcodebuild test` command.

---

### Task 1: Add `MailDraftStore` with unit tests

**Files:**
- Create: `AppFeedback/Services/Mail/MailDraftStore.swift`
- Create: `AppFeedbackTests/MailDraftStoreTests.swift`
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (add the two new files to the `AppFeedback` and `AppFeedbackTests` targets)

- [ ] **Step 1: Write the failing test file**

Create `AppFeedbackTests/MailDraftStoreTests.swift`:

```swift
import XCTest
@testable import AppFeedback

@MainActor
final class MailDraftStoreTests: XCTestCase {
    private let threadA = UUID()
    private let threadB = UUID()

    func test_draft_returnsNilForUnknownKey() {
        let store = MailDraftStore()
        XCTAssertNil(store.draft(for: .reply(threadID: threadA)))
    }

    func test_setSubjectAndBody_persistsThenReads() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        store.setSubject("Re: Crash", for: key)
        store.setBody("Hi Bob", for: key)

        let draft = store.draft(for: key)
        XCTAssertEqual(draft?.subject, "Re: Crash")
        XCTAssertEqual(draft?.body, "Hi Bob")
    }

    func test_setSubject_createsDraftEvenWithoutBody() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        store.setSubject("Subject only", for: key)

        let draft = store.draft(for: key)
        XCTAssertEqual(draft?.subject, "Subject only")
        XCTAssertEqual(draft?.body, "")
    }

    func test_clear_removesDraft() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        store.setBody("typed", for: key)
        store.clear(key)
        XCTAssertNil(store.draft(for: key))
    }

    func test_keys_areIsolated() {
        let store = MailDraftStore()
        let keyA = DraftKey.reply(threadID: threadA)
        let keyB = DraftKey.reply(threadID: threadB)
        store.setBody("A", for: keyA)
        store.setBody("B", for: keyB)

        XCTAssertEqual(store.draft(for: keyA)?.body, "A")
        XCTAssertEqual(store.draft(for: keyB)?.body, "B")
    }

    func test_newEmailKey_isDistinctFromReplyKey() {
        let store = MailDraftStore()
        let replyKey = DraftKey.reply(threadID: threadA)
        let newKey = DraftKey.newEmail(repoOwner: "o", repoName: "r", issueNumber: 1, recipient: "x@y.com")
        store.setBody("reply", for: replyKey)
        store.setBody("new", for: newKey)

        XCTAssertEqual(store.draft(for: replyKey)?.body, "reply")
        XCTAssertEqual(store.draft(for: newKey)?.body, "new")
    }
}
```

- [ ] **Step 2: Invoke `zcode` (test) and confirm the new test file fails to compile because `MailDraftStore` / `DraftKey` do not exist yet**

Expected: build error along the lines of `cannot find 'MailDraftStore' in scope` / `cannot find 'DraftKey' in scope`. (If `zcode` is unavailable: `xcodebuild -scheme AppFeedback -destination 'platform=macOS' test 2>&1 | tail -30`.)

- [ ] **Step 3: Implement `MailDraftStore`**

Create `AppFeedback/Services/Mail/MailDraftStore.swift`:

```swift
import Foundation
import Observation

enum DraftKey: Hashable {
    case reply(threadID: UUID)
    case newEmail(repoOwner: String, repoName: String, issueNumber: Int, recipient: String)
}

struct Draft: Equatable {
    var subject: String
    var body: String

    init(subject: String = "", body: String = "") {
        self.subject = subject
        self.body = body
    }
}

@MainActor
@Observable
final class MailDraftStore {
    private var drafts: [DraftKey: Draft] = [:]

    func draft(for key: DraftKey) -> Draft? {
        drafts[key]
    }

    func setSubject(_ subject: String, for key: DraftKey) {
        var existing = drafts[key] ?? Draft()
        existing.subject = subject
        drafts[key] = existing
    }

    func setBody(_ body: String, for key: DraftKey) {
        var existing = drafts[key] ?? Draft()
        existing.body = body
        drafts[key] = existing
    }

    func clear(_ key: DraftKey) {
        drafts.removeValue(forKey: key)
    }
}
```

- [ ] **Step 4: Add the two new files to the Xcode project targets**

Open `AppFeedback.xcodeproj`. Drag `MailDraftStore.swift` into the `AppFeedback/Services/Mail/` group and tick membership for the `AppFeedback` target. Drag `MailDraftStoreTests.swift` into the `AppFeedbackTests` group and tick membership for the `AppFeedbackTests` target.

If the project uses XcodeGen (look for `project.yml` at repo root — it exists), regenerate instead:

```bash
cd /Users/hayekamir/Developer/AppFeedback
xcodegen generate
```

- [ ] **Step 5: Invoke `zcode` (test) and confirm all six `MailDraftStoreTests` pass**

Expected: 6/6 pass. (Inline fallback: `xcodebuild -scheme AppFeedback -destination 'platform=macOS' test -only-testing:AppFeedbackTests/MailDraftStoreTests`.)

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Services/Mail/MailDraftStore.swift AppFeedbackTests/MailDraftStoreTests.swift AppFeedback.xcodeproj/project.pbxproj project.yml 2>/dev/null
git commit -m "feat(mail): add in-memory MailDraftStore keyed by thread or new-email target"
```

---

### Task 2: Inject `MailDraftStore` in the app environment

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (add `@State` and two `.environment(...)` injections)

- [ ] **Step 1: Add state and inject into the root `WindowGroup`**

In `AppFeedback/App/AppFeedbackApp.swift`, add the state property next to the other mail stores (after line 29, `mailLocalStateStore`):

```swift
@State private var mailDraftStore = MailDraftStore()
```

In the root `WindowGroup` body, inject the store. Find the chain starting at `AppFeedback/App/AppFeedbackApp.swift:209` (the `RootView(...)...` block). Insert a new `.environment(mailDraftStore)` line directly below the existing `.environment(mailLocalStateStore)` (line 225):

```swift
                .environment(mailLocalStateStore)
                .environment(mailDraftStore)
                .environment(composeWindowHolder)
```

- [ ] **Step 2: Inject into the `Compose` `WindowGroup` so the still-existing windowed path can read it (transitional)**

Inside the `#if canImport(SwiftMail) WindowGroup("Compose", …)` block (currently at `AppFeedback/App/AppFeedbackApp.swift:303`), add `.environment(mailDraftStore)` next to the other environment injections so `ComposeWindowContent` would compile if we later read it from there. Place it directly below `.environment(mirrorHolder)` (line 312):

```swift
                .environment(mirrorHolder)
                .environment(mailDraftStore)
                .environment(composeWindowHolder)
```

- [ ] **Step 3: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build with no new warnings. The injected store is currently unused; that's intentional.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(mail): inject MailDraftStore into root and compose scenes"
```

---

### Task 3: Extract `ComposeRequest` to its own file

**Files:**
- Create: `AppFeedback/Views/Mail/ComposeRequest.swift`
- Modify: `AppFeedback/Views/Mail/MailThreadView.swift` (delete the `ComposeRequest` struct now living there)
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (or regenerate via `xcodegen`)

- [ ] **Step 1: Create the new file with the struct moved verbatim**

Create `AppFeedback/Views/Mail/ComposeRequest.swift`:

```swift
import Foundation

/// Single shape used by every "open the compose UI" call site — both first-time emails
/// (no thread yet) and replies in an existing thread. Optional fields are nil when the
/// compose is brand-new.
struct ComposeRequest: Identifiable {
    let id = UUID()
    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let inReplyTo: MailMessageHeaders?
    let subjectOverride: String?
    let senderAccountID: UUID?
}
```

- [ ] **Step 2: Remove the struct declaration from `MailThreadView.swift`**

Delete lines 8–20 of `AppFeedback/Views/Mail/MailThreadView.swift` (the `///` doc comment and the `struct ComposeRequest: Identifiable { … }` declaration). Leave everything else.

- [ ] **Step 3: Add the new file to the Xcode target**

Either drag into the project (membership: `AppFeedback`) or regenerate:

```bash
cd /Users/hayekamir/Developer/AppFeedback
xcodegen generate
```

- [ ] **Step 4: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build. No behavior change.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Mail/ComposeRequest.swift AppFeedback/Views/Mail/MailThreadView.swift AppFeedback.xcodeproj/project.pbxproj project.yml 2>/dev/null
git commit -m "refactor(mail): extract ComposeRequest into its own file"
```

---

### Task 4: Extract `ComposeFormCore` from `ComposeMailView`

**Files:**
- Create: `AppFeedback/Views/Mail/ComposeFormCore.swift`
- Modify: `AppFeedback/Views/Mail/ComposeMailView.swift` (use `ComposeFormCore` for the body of `composeForm`)
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (or regenerate)

The goal: move the **rows** (From / To / Subject / header preview / body editor / footer preview) and the **footer buttons** into a new view that takes the `ComposeMailViewModel` and a small action set. `ComposeMailView` keeps the outer shell (title bar, `ScrollView`, `frame(minWidth:)`, the missing-credentials banner). No behavior change in this task — the windowed/sheet shell still works exactly as before.

- [ ] **Step 1: Create `ComposeFormCore.swift`**

```swift
#if canImport(SwiftMail)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shared body of any compose surface (windowed, sheeted, inline). Renders the From / To /
/// Subject rows, header/footer template previews, the body editor, and a Send button.
/// The host owns the view model and is responsible for the surrounding chrome.
struct ComposeFormCore: View {
    @Bindable var vm: ComposeMailViewModel
    let headerPreview: String
    let footerPreview: String
    var sendLabel: String = "Send"
    var onSend: () -> Void
    var onDiscard: (() -> Void)? = nil
    var discardLabel: String = "Cancel"

    @Environment(MailAccountStore.self) private var store
    @Environment(SettingsNavigation.self) private var settingsNavigation
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fromRow
            Divider()
            recipientRow
            Divider()
            subjectRow
            Divider()
            templateRow(label: "Header", text: headerPreview)
            Divider()
            TextEditor(text: Binding(
                get: { vm.body.string },
                set: { vm.body = NSAttributedString(string: $0) }
            ))
            .font(.body)
            .scrollDisabled(true)
            .frame(minHeight: 200)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            templateRow(label: "Footer", text: footerPreview)
            Divider()
            footerButtons
        }
    }

    private var fromRow: some View {
        HStack {
            Text("From:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            if let acc = store.account(id: vm.senderAccountID) {
                Text(acc.smtpUsername).fontWeight(.medium)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var recipientRow: some View {
        HStack {
            Text("To:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(vm.recipient).fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var subjectRow: some View {
        HStack {
            Text("Subject:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", text: $vm.subject)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func templateRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Group {
                if text.isEmpty {
                    Text("Not set").foregroundStyle(.tertiary).italic()
                } else {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            Button {
                settingsNavigation.selectedTab = .email
                openWindow(id: "settings")
            } label: {
                Label("Edit", systemImage: "pencil").labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            #endif
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            if let onDiscard {
                Button(discardLabel) { onDiscard() }
            }
            Button(sendLabel) { onSend() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canSend)
        }
        .padding(12)
    }
}
#endif
```

- [ ] **Step 2: Update `ComposeMailView` to use `ComposeFormCore`**

Replace the `composeForm(vm:)` and `fromRow` / `recipientRow` / `subjectRow(vm:)` / `templateRow(label:text:)` / `footerButtons(vm:)` / `plainBindingFor(_:)` definitions in `AppFeedback/Views/Mail/ComposeMailView.swift` with one call to `ComposeFormCore`. The shell keeps the title bar, scroll view, missing-credentials banner, and the on-appear/on-change preview refresh:

Replace lines 46–79 (the `composeForm(vm:)` function) with:

```swift
    @ViewBuilder
    private func composeForm(vm: ComposeMailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()
            if !hasCredentials {
                missingCredentialsBanner
            }
            ScrollView {
                ComposeFormCore(
                    vm: vm,
                    headerPreview: headerPreview,
                    footerPreview: footerPreview,
                    sendLabel: "Send",
                    onSend: {
                        Task { await vm.send() }
                        dismiss()
                    },
                    onDiscard: { dismiss() },
                    discardLabel: "Cancel"
                )
            }
        }
        .onAppear { refreshPreviews(vm: vm) }
        .onChange(of: settingsStore.settings.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
        .onChange(of: settingsStore.settings.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }
    }
```

Then delete the now-unused private helpers from `ComposeMailView.swift`:
- `private var fromRow: some View` (lines ~173–184)
- `private var recipientRow: some View` (lines ~186–193)
- `private func subjectRow(vm:)` (lines ~195–205)
- `private func footerButtons(vm:)` (lines ~207–220)
- `private func plainBindingFor(_:)` (lines ~222–227)
- `private func templateRow(label:text:)` (lines ~106–137)

Keep `titleBar`, `missingCredentialsBanner`, `hasCredentials`, `currentTemplate`, `refreshPreviews`, `setupViewModel`, and the `init(request:)` extension.

- [ ] **Step 3: Expose `senderAccountID` and `recipient` to `ComposeFormCore`**

`ComposeFormCore` reads `vm.senderAccountID` and `vm.recipient`. Both are already declared `let` properties on `ComposeMailViewModel` (`AppFeedback/ViewModels/ComposeMailViewModel.swift:12` and `:16`), and the type is `@Observable`. No change needed.

- [ ] **Step 4: Add the new file to the Xcode target (`xcodegen generate` if applicable)**

- [ ] **Step 5: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build. Open a compose window (macOS) or sheet (iOS) and confirm the form still looks the same. (UI behavior change is verified after Tasks 6 and 7.)

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Views/Mail/ComposeFormCore.swift AppFeedback/Views/Mail/ComposeMailView.swift AppFeedback.xcodeproj/project.pbxproj project.yml 2>/dev/null
git commit -m "refactor(mail): extract ComposeFormCore from ComposeMailView"
```

---

### Task 5: Create `InlineReplyView`

**Files:**
- Create: `AppFeedback/Views/Mail/InlineReplyView.swift`
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (or regenerate)

`InlineReplyView` is the inline shell: a tiny header strip, a missing-credentials banner if needed, and `ComposeFormCore`. It owns its `ComposeMailViewModel` for the lifetime of the view, hydrates from `MailDraftStore` on appear, and writes back on every subject/body change.

- [ ] **Step 1: Create the file**

```swift
#if canImport(SwiftMail)
import SwiftUI

/// In-place compose surface used by MailThreadView (replies) and IssueCardView (first-time
/// emails). Hydrates subject/body from MailDraftStore on appear, persists edits back so
/// drafts survive thread collapse and LazyVStack recycling, and clears the draft on Send
/// or explicit Discard.
struct InlineReplyView: View {
    let key: DraftKey
    let request: ComposeRequest
    var onClose: () -> Void

    @Environment(MailAccountStore.self) private var store
    @Environment(MailSettingsStore.self) private var settingsStore
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(OutboundSendTracker.self) private var outboundTracker
    @Environment(OutboundFailureStore.self) private var outboundFailures
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailToGitHubMirrorHolder.self) private var mirrorHolder: MailToGitHubMirrorHolder?
    @Environment(MailDraftStore.self) private var drafts
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var viewModel: ComposeMailViewModel?
    @State private var headerPreview: String = ""
    @State private var footerPreview: String = ""
    @State private var showsDiscardConfirm: Bool = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            Divider()
            if let vm = viewModel {
                if !hasCredentials {
                    missingCredentialsBanner
                }
                ComposeFormCore(
                    vm: vm,
                    headerPreview: headerPreview,
                    footerPreview: footerPreview,
                    sendLabel: "Send",
                    onSend: { send(vm: vm) },
                    onDiscard: { attemptDiscard(vm: vm) },
                    discardLabel: "Discard"
                )
                .focused($bodyFocused)
                .onAppear {
                    refreshPreviews(vm: vm)
                    bodyFocused = true
                }
                .onChange(of: vm.subject) { _, newValue in
                    drafts.setSubject(newValue, for: key)
                }
                .onChange(of: vm.body) { _, newValue in
                    drafts.setBody(newValue.string, for: key)
                }
                .onChange(of: settingsStore.settings.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
                .onChange(of: settingsStore.settings.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }
            } else {
                ProgressView().padding(12).task { setupViewModel() }
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, 6)
        .alert("Discard draft?", isPresented: $showsDiscardConfirm) {
            Button("Discard", role: .destructive) {
                drafts.clear(key)
                onClose()
            }
            Button("Keep", role: .cancel) { }
        } message: {
            Text("This will discard the text you've typed.")
        }
    }

    private var headerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: request.inReplyTo == nil ? "envelope" : "arrowshape.turn.up.left")
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                if let vm = viewModel { attemptDiscard(vm: vm) } else { onClose() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close composer")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var headerTitle: String {
        let verb = request.inReplyTo == nil ? "New email to" : "Reply to"
        return "\(verb) \(request.recipient)"
    }

    private var hasCredentials: Bool {
        guard let id = request.senderAccountID ?? store.defaultSender?.id,
              let acc = store.account(id: id) else { return false }
        return !acc.smtpUsername.isEmpty
    }

    private var missingCredentialsBanner: some View {
        HStack {
            Image(systemName: "envelope.badge")
            Text("Configure email in Settings → Email to send from this app.")
            Spacer()
            #if os(macOS)
            Button("Open Settings…") {
                openWindow(id: "settings")
            }
            #endif
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
    }

    private var currentTemplate: MailTemplate {
        MailTemplate(
            headerHTML: settingsStore.settings.templateHeaderHTML,
            footerHTML: settingsStore.settings.templateFooterHTML
        )
    }

    private func refreshPreviews(vm: ComposeMailViewModel) {
        let context = vm.placeholderContext()
        let composer = MailComposer()
        let template = currentTemplate
        headerPreview = MailTemplatePlainText
            .from(html: composer.applyPlaceholders(template.headerHTML, context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        footerPreview = MailTemplatePlainText
            .from(html: composer.applyPlaceholders(template.footerHTML, context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attemptDiscard(vm: ComposeMailViewModel) {
        if vm.body.length > 0 {
            showsDiscardConfirm = true
        } else {
            drafts.clear(key)
            onClose()
        }
    }

    private func send(vm: ComposeMailViewModel) {
        Task {
            await vm.send()
            drafts.clear(key)
            onClose()
        }
    }

    private func setupViewModel() {
        let vm = ComposeMailViewModel(
            recipient: request.recipient,
            issue: request.issue,
            repoOwner: request.repoOwner,
            repoName: request.repoName,
            store: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            tracker: outboundTracker,
            failureStore: outboundFailures,
            sender: MailSender(),
            activityLog: activityLog,
            mirror: mirrorHolder?.mirror,
            inReplyTo: request.inReplyTo,
            initialSubject: request.subjectOverride,
            senderAccountID: request.senderAccountID ?? store.defaultSender?.id ?? UUID()
        )

        if let existing = drafts.draft(for: key) {
            if !existing.subject.isEmpty { vm.subject = existing.subject }
            if !existing.body.isEmpty { vm.body = NSAttributedString(string: existing.body) }
        }

        viewModel = vm
    }
}
#endif
```

- [ ] **Step 2: Add the file to the Xcode target (`xcodegen generate` if applicable)**

- [ ] **Step 3: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build. The view is unused so far; that's intentional.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Mail/InlineReplyView.swift AppFeedback.xcodeproj/project.pbxproj project.yml 2>/dev/null
git commit -m "feat(mail): add InlineReplyView backed by MailDraftStore"
```

---

### Task 6: Switch `MailThreadView` reply to inline

**Files:**
- Modify: `AppFeedback/Views/Mail/MailThreadView.swift`

Replace the windowed/sheet reply with an inline composer. The reply badge and the inline composer occupy the same slot — the badge disappears while the composer is open.

- [ ] **Step 1: Replace the imports and state at the top of `MailThreadView`**

In `AppFeedback/Views/Mail/MailThreadView.swift`, edit the `MailThreadView` struct (currently starts at line 50). The new shape:

```swift
struct MailThreadView: View {
    let thread: MailThread
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let appColor: Color

    @Environment(MailAccountStore.self) private var accountStore

    @State private var isExpanded: Bool = true
    @State private var activeReply: ComposeRequest? = nil

    private var messages: [MailMessage] { thread.sortedDedupedMessages }

    private var resolvedSenderAccountID: UUID? {
        if let last = messages.last,
           let id = last.accountID,
           accountStore.account(id: id) != nil {
            return id
        }
        return accountStore.defaultSender?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(messages) { message in
                    MailMessageRowView(message: message)
                    Divider()
                }
                replyArea
            }
        }
    }
```

Concretely: remove the `#if os(macOS) @Environment(\.openWindow) … @Environment(ComposeWindowHolder.self) … #endif` block, the `#if os(iOS) @State private var pendingCompose … #endif` block, and the `.sheet(item: $pendingCompose)` modifier on `body`. Replace `replyButton` with `replyArea`. Add `activeReply` state.

- [ ] **Step 2: Replace `beginReply` and `presentCompose` with the inline switch**

Delete `private func presentCompose(_ request: ComposeRequest)` (lines ~160–166).

Change `beginReply(senderAccountID:)` to set `activeReply` instead of calling `presentCompose`:

```swift
    private func beginReply(senderAccountID: UUID? = nil) {
        guard let last = messages.last, let recipient = replyRecipient else { return }
        guard let chosen = senderAccountID ?? resolvedSenderAccountID else { return }
        let headers = MailMessageHeaders(
            messageID: last.messageID,
            inReplyTo: last.inReplyTo,
            references: last.referencesAsArray
        )
        let request = ComposeRequest(
            recipient: recipient,
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            inReplyTo: headers,
            subjectOverride: MailSubject.replyPrefixed(last.subject),
            senderAccountID: chosen
        )
        withAnimation(.easeOut(duration: 0.2)) {
            activeReply = request
        }
    }
```

- [ ] **Step 3: Replace `replyButton` with `replyArea`**

Replace the `replyButton` computed property (currently `AppFeedback/Views/Mail/MailThreadView.swift:179-196`) with:

```swift
    @ViewBuilder
    private var replyArea: some View {
        if let req = activeReply {
            #if canImport(SwiftMail)
            InlineReplyView(
                key: .reply(threadID: thread.id),
                request: req,
                onClose: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        activeReply = nil
                    }
                }
            )
            .padding(.top, 8)
            #endif
        } else if let recipient = replyRecipient {
            let options = accountStore.accounts
                .filter { !$0.smtpUsername.isEmpty }
                .map { ReplyBadgeButton.ReplyFromOption(id: $0.id, address: $0.smtpUsername) }
            ReplyBadgeButton(
                email: recipient,
                color: appColor,
                onReply: { beginReply() },
                onCopy: copyRecipient,
                replyFromOptions: options.count > 1 ? options : [],
                onReplyFrom: { id in beginReply(senderAccountID: id) }
            )
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
```

The `body` already calls `replyArea` (from Step 1).

- [ ] **Step 4: Keep `ComposeWindowHolder` / `ComposeWindowContent` in this file untouched for now**

Those two types still live at the bottom of `MailThreadView.swift` (lines ~199–222 originally, slightly shifted after Step 1). Leave them — Task 8 deletes them. The macOS `Compose` `WindowGroup` still references `ComposeWindowContent` and will continue to compile.

- [ ] **Step 5: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build.

- [ ] **Step 6: Manual smoke test (macOS first, then iOS sim if available)**

Run the app via `zcode run`. Pick an issue with an existing email thread. Click **Reply** in the thread.

Expected:
- Inline composer appears below the messages (no new window or sheet).
- Type some subject/body, collapse the thread, expand — text persists.
- Click the `×` button with body text → confirm prompt → Discard → composer closes.
- Click Reply → type → Send → composer closes; the sent message appears in the thread after the next sync tick.
- With ≥2 accounts: right-click Reply → "Reply from" submenu → pick a different account → inline composer opens with that account in the From row.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Views/Mail/MailThreadView.swift
git commit -m "feat(mail): inline reply composer inside MailThreadView"
```

---

### Task 7: Switch `IssueCardView` first-time email tap to inline

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`
- Modify: `AppFeedback/Views/Issues/IssueListView.swift`

The card now owns the inline composer slot for first-time emails. `IssueListView` no longer threads a `tapEmailHandler` through.

- [ ] **Step 1: Drop the `onTapEmail` plumbing in `IssueListView`**

In `AppFeedback/Views/Issues/IssueListView.swift`:

1. Delete the `#if canImport(SwiftMail) #if os(iOS) @State private var pendingCompose: ComposeRequest? #else @Environment(\.openWindow) ... @Environment(ComposeWindowHolder.self) ... #endif #endif` block (lines 21–28).
2. Delete the `.sheet(item: $pendingCompose) { req in ComposeMailView(request: req) }` modifier and its surrounding `#if canImport(SwiftMail) && os(iOS)` (lines 176–180).
3. Delete the `private func tapEmailHandler(for issue: FeedbackIssue) -> ((String) -> Void)?` function (lines 234–255).
4. In `issueCard(for:)`, remove the `onTapEmail: tapEmailHandler(for: issue),` argument (around line 226).

- [ ] **Step 2: Drop the `onTapEmail` parameter from `IssueCardView`**

In `AppFeedback/Views/Issues/IssueCardView.swift`:

1. Delete the `var onTapEmail: ((String) -> Void)? = nil` declaration (line 68).
2. Replace the body of `replyToEmail(_ email: String)` (currently lines 148–160) with:

```swift
    private func replyToEmail(_ email: String) {
        #if canImport(SwiftMail)
        withAnimation(.easeOut(duration: 0.2)) {
            activeInlineEmail = email
        }
        #else
        guard let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let mailURL = URL(string: "mailto:\(encoded)") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(mailURL)
        #else
        UIApplication.shared.open(mailURL)
        #endif
        #endif
    }
```

- [ ] **Step 3: Add the inline state and view to `IssueCardView`**

Add a state property near the other `@State` declarations at the top of `IssueCardView` (around line 76, next to `showOriginal` / `highlightActive` / `didCopy` / `threads`):

```swift
    #if canImport(SwiftMail)
    @State private var activeInlineEmail: String? = nil
    #endif
```

Then add an inline composer slot inside the body. Find the `if !threads.isEmpty { ForEach(threads) { thread in MailThreadView(...) } }` block (around lines 317–322) and insert an inline-email composer immediately after it, before the closing `}` of the inner `VStack(alignment: .leading, spacing: 8)`:

```swift
                #if canImport(SwiftMail)
                if let email = activeInlineEmail {
                    InlineReplyView(
                        key: .newEmail(repoOwner: repoOwner, repoName: repoName, issueNumber: issue.number, recipient: email),
                        request: ComposeRequest(
                            recipient: email,
                            issue: issue,
                            repoOwner: repoOwner,
                            repoName: repoName,
                            inReplyTo: nil,
                            subjectOverride: nil,
                            senderAccountID: nil
                        ),
                        onClose: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                activeInlineEmail = nil
                            }
                        }
                    )
                    .padding(.top, 8)
                }
                #endif
```

- [ ] **Step 4: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build.

- [ ] **Step 5: Manual smoke test**

Run the app. Open an issue card that has an email address but **no** thread (e.g., a fresh issue). Tap the **Reply** badge.

Expected:
- Inline composer appears within the card. No new window or sheet.
- Type → tap a different issue (or scroll until the card recycles) → tap back → draft is still there (keyed by issue+recipient).
- Send → composer closes; the message kicks off a new thread on the next sync tick.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift AppFeedback/Views/Issues/IssueListView.swift
git commit -m "feat(mail): inline first-time email composer in IssueCardView"
```

---

### Task 8: Delete `ComposeMailView`, `ComposeWindowHolder`, `ComposeWindowContent`, and the `Compose` `WindowGroup`

**Files:**
- Delete: `AppFeedback/Views/Mail/ComposeMailView.swift`
- Modify: `AppFeedback/Views/Mail/MailThreadView.swift` (remove `ComposeWindowHolder` and `ComposeWindowContent` types)
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (remove the holder state, both `.environment(composeWindowHolder)` injections, and the `Compose` `WindowGroup`)
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (or regenerate)
- Modify: `AppFeedbackTests/ComposeMailViewModelTests.swift` (no change unless it imports `ComposeMailView` — it does not; leave alone)

- [ ] **Step 1: Verify there are no remaining references to the soon-to-delete types**

```bash
cd /Users/hayekamir/Developer/AppFeedback
grep -rn "ComposeMailView\|ComposeWindowHolder\|ComposeWindowContent\|pendingCompose" AppFeedback --include="*.swift"
```

Expected output: only matches inside `AppFeedback/Views/Mail/ComposeMailView.swift`, `AppFeedback/Views/Mail/MailThreadView.swift`, and `AppFeedback/App/AppFeedbackApp.swift`. If any other file references these symbols, stop and fix that file before continuing.

- [ ] **Step 2: Delete `ComposeMailView.swift`**

```bash
rm /Users/hayekamir/Developer/AppFeedback/AppFeedback/Views/Mail/ComposeMailView.swift
```

- [ ] **Step 3: Remove `ComposeWindowHolder` and `ComposeWindowContent` from `MailThreadView.swift`**

Open `AppFeedback/Views/Mail/MailThreadView.swift`. Delete:

1. The `@MainActor @Observable final class ComposeWindowHolder { … }` block (was lines 23–48 originally; slightly shifted after Task 6).
2. The `#if os(macOS) && canImport(SwiftMail) struct ComposeWindowContent: View { … } #endif` block at the bottom of the file (was lines 199–222 originally).

The file should now contain only the `MailThreadView` struct.

- [ ] **Step 4: Remove the holder and the `Compose` `WindowGroup` from `AppFeedbackApp.swift`**

In `AppFeedback/App/AppFeedbackApp.swift`:

1. Delete `@State private var composeWindowHolder = ComposeWindowHolder()` (line 30 originally).
2. Delete the `.environment(composeWindowHolder)` line in the root `WindowGroup` chain (was line 226).
3. Delete the entire `#if canImport(SwiftMail) WindowGroup("Compose", id: ComposeWindowHolder.windowID, for: UUID.self) { … } .windowStyle(.titleBar) .defaultSize(...) .windowResizability(...) #endif` block (was lines 302–319).

- [ ] **Step 5: Regenerate the project to drop the deleted file**

```bash
cd /Users/hayekamir/Developer/AppFeedback
xcodegen generate
```

If the project does not use XcodeGen, instead open the `.xcodeproj` and delete the red (missing) `ComposeMailView.swift` reference from the file list.

- [ ] **Step 6: Invoke `zcode` (build) for macOS and iOS**

Expected: both targets build. No references to deleted symbols remain.

- [ ] **Step 7: Run the full test suite**

Invoke `zcode test` (or `xcodebuild -scheme AppFeedback -destination 'platform=macOS' test`). Expected: all pre-existing tests + the 6 new `MailDraftStoreTests` pass.

- [ ] **Step 8: Manual full-flow smoke**

Run the app and walk the full spec test plan (steps 1–12 in the spec's *Test plan* section). Verify no second window or sheet opens at any point.

- [ ] **Step 9: Commit**

```bash
git add AppFeedback/Views/Mail/MailThreadView.swift AppFeedback/App/AppFeedbackApp.swift AppFeedback.xcodeproj/project.pbxproj project.yml 2>/dev/null
git rm AppFeedback/Views/Mail/ComposeMailView.swift
git commit -m "refactor(mail): delete windowed/sheet compose plumbing"
```

---

## Self-review checklist (already applied while writing)

- **Spec coverage:** every section of the spec maps to a task — `MailDraftStore` → Task 1; environment injection → Task 2; `ComposeRequest` extraction → Task 3; `ComposeFormCore` → Task 4; `InlineReplyView` → Task 5; `MailThreadView` rewire → Task 6; `IssueCardView` / `IssueListView` rewire → Task 7; deletion of `ComposeMailView` / `ComposeWindowHolder` / `ComposeWindowContent` / `WindowGroup("Compose")` → Task 8. Spec test plan steps 1–12 are walked manually in Task 8 Step 8.
- **Placeholders:** none. Every code step shows the exact code; every command shows the exact invocation and expected outcome.
- **Type consistency:** `DraftKey.reply(threadID:)`, `DraftKey.newEmail(repoOwner:repoName:issueNumber:recipient:)`, `MailDraftStore.draft(for:)`, `setSubject(_:for:)`, `setBody(_:for:)`, `clear(_:)` are used identically in every task that touches them. `ComposeRequest` field names match the original. `ComposeFormCore` reads `vm.recipient`, `vm.senderAccountID`, `vm.subject`, `vm.body`, `vm.canSend` — all already public on `ComposeMailViewModel`.
- **Build-stays-green ordering:** Tasks 1–5 add new code without removing call sites. Task 6 removes the macOS-window and iOS-sheet wiring inside `MailThreadView` but leaves `ComposeWindowHolder` / `ComposeWindowContent` / the `Compose` `WindowGroup` intact so the project still compiles. Task 7 removes the equivalent wiring from `IssueListView` / `IssueCardView`. Task 8 deletes the orphaned types and scene last.
