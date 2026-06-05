# Template Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the reply button into `[ ⤺ Reply | ▤ ]`; the new segment opens a modal of prewritten per-repo reply templates that the user can send (header/footer applied) or use to prefill the composer, with full add/edit/delete and a this-repo/global toggle.

**Architecture:** A new `ReplyTemplate` SwiftData `@Model` (CloudKit-synced) and a `ReplyTemplateStore` (mirrors `VersionStore`) hold templates. Both existing reply entry points already render through `InlineReplyView` → `ComposeMailViewModel`, so sending/prefilling a template is done by carrying the template body on `ComposeRequest` (new `initialBody` + `autoSend` fields) and letting the existing send pipeline apply header/footer. Both entry points already share `ReplyBadgeButton`, so the split UI is added there once. A new `ReplyTemplatePickerView` modal (+ `ReplyTemplateEditorView`) drives selection and CRUD.

**Tech Stack:** SwiftUI, SwiftData + CloudKit, Swift Observation (`@Observable`/`@Environment`), XCTest, xcodegen, SwiftMail (behind `#if canImport(SwiftMail)`).

---

## Deviations from the spec (improvements found while reading the code)

The spec proposed a standalone `ReplyTemplateSender` service and a new `SplitReplyButton`. Code reading showed:

- **No separate sender service.** `IssueCardView` (no-thread) and `MailThreadView` (in-thread) both already build a `ComposeRequest`, call `drafts.setOpenRequest(...)`, and render `InlineReplyView`, which constructs the `ComposeMailViewModel` and owns the Send button. Carrying `initialBody` + `autoSend` on `ComposeRequest` reuses that pipeline verbatim and structurally guarantees the header/footer contract. This is DRYer and lower-risk than re-implementing the SMTP path.
- **No new button component.** Both hosts already render the same top-level `ReplyBadgeButton`. Adding an optional `onTemplates` closure + a divider/template segment to it lights up both entry points at once.

Everything else matches the spec (`docs/superpowers/specs/2026-06-04-template-replies-design.md`).

## Build loop & conventions

- This is an **xcodegen** project. After **creating** any new `.swift` file, regenerate so it's in the pbxproj:
  ```bash
  cd /Users/amir/Developer/AppFeedback && xcodegen generate
  ```
  (Editing existing files needs no regeneration.)
- **Build:** `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
- **All tests:** `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' test`
- **One test class:** `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' test -only-testing:AppFeedbackTests_macOS/ReplyTemplateStoreTests`
- Test target is `AppFeedbackTests_macOS`. Use `xcodebuild` for ground truth (the zcode test summary can mask trap crashes).
- **Commit scope:** the working tree may contain unrelated user WIP. `git add` only the exact files each task lists — never `git add -A`.

## File structure

**New**
- `AppFeedback/Models/ReplyTemplate.swift` — the `@Model`.
- `AppFeedback/Services/ReplyTemplateStore.swift` — `@Observable @MainActor` store (queries/CRUD/reload + change listeners).
- `AppFeedbackTests/ReplyTemplateStoreTests.swift` — store unit tests.
- `AppFeedback/Views/Templates/ReplyTemplateEditorView.swift` — add/edit sheet.
- `AppFeedback/Views/Templates/ReplyTemplatePickerView.swift` — the modal.

**Modified**
- `AppFeedback/App/AppFeedbackApp.swift` — register model in 3 schema lists; build + inject the store.
- `AppFeedback/Views/Mail/ComposeRequest.swift` — add `initialBody` + `autoSend`.
- `AppFeedback/Views/Mail/InlineReplyView.swift` — seed `initialBody`; honor `autoSend`.
- `AppFeedback/Views/Issues/IssueCardView.swift` — add template segment to `ReplyBadgeButton`; present the modal; wire no-thread send/prefill.
- `AppFeedback/Views/Mail/MailThreadView.swift` — pass `onTemplates`; present the modal; wire in-thread send/prefill.

---

## Task 1: `ReplyTemplate` model + schema registration

**Files:**
- Create: `AppFeedback/Models/ReplyTemplate.swift`
- Modify: `AppFeedback/App/AppFeedbackApp.swift` (3 schema lists)

- [ ] **Step 1: Create the model**

`AppFeedback/Models/ReplyTemplate.swift` (mirrors `ProjectVersion` — every stored property has a default for the SwiftData+CloudKit constraint):

```swift
import Foundation
import SwiftData

@Model
final class ReplyTemplate: Identifiable {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), repoOwner: String, repoName: String,
         title: String, body: String,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 2: Register in the test-host container**

In `AppFeedbackApp.swift`, the `isTesting` branch container (currently ends `...RepoFetchState.self, FeedbackAttachmentLocal.self,`). Add `ReplyTemplate.self`:

Find:
```swift
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                    configurations: testConfig
```
Replace with:
```swift
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                        ReplyTemplate.self,
                    configurations: testConfig
```

- [ ] **Step 3: Register in the cloud schema**

Find:
```swift
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self])
```
Replace with (append `ReplyTemplate.self` — it must sync, so it goes in the cloud schema):
```swift
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self])
```

- [ ] **Step 4: Register in the production container**

Find:
```swift
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                    configurations: cloudConfig, localConfig
```
Replace with:
```swift
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                        ReplyTemplate.self,
                    configurations: cloudConfig, localConfig
```

> Note: `ReplyTemplate.self` is in the cloud `Schema` (Step 3) and in the container's flat model list (Steps 2 & 4). It must NOT be added to `localSchema`.

- [ ] **Step 5: Regenerate + build**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/Models/ReplyTemplate.swift AppFeedback/App/AppFeedbackApp.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(templates): add ReplyTemplate model + register in schema"
```

---

## Task 2: `ReplyTemplateStore` (TDD)

**Files:**
- Test: `AppFeedbackTests/ReplyTemplateStoreTests.swift`
- Create: `AppFeedback/Services/ReplyTemplateStore.swift`

- [ ] **Step 1: Write the failing tests**

`AppFeedbackTests/ReplyTemplateStoreTests.swift` (in-memory SwiftData, mirrors `VersionStoreTests`):

```swift
import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class ReplyTemplateStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ReplyTemplate.self, configurations: config)
        return ModelContext(container)
    }

    func testCreateIsScopedToRepo() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        store.create(owner: "o", repo: "r", title: "Thanks", body: "Thanks for the report")
        store.create(owner: "o", repo: "other", title: "Other", body: "x")

        let forRepo = store.templates(owner: "o", repo: "r")
        XCTAssertEqual(forRepo.map(\.title), ["Thanks"])
        XCTAssertEqual(forRepo.first?.body, "Thanks for the report")
    }

    func testAllTemplatesMergesAcrossRepos() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        store.create(owner: "o", repo: "r", title: "A", body: "a")
        store.create(owner: "o", repo: "other", title: "B", body: "b")

        XCTAssertEqual(Set(store.allTemplates().map(\.title)), ["A", "B"])
    }

    func testUpdateChangesFields() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        let t = store.create(owner: "o", repo: "r", title: "Old", body: "old body")
        store.update(t, title: "New", body: "new body")

        let reloaded = store.templates(owner: "o", repo: "r")
        XCTAssertEqual(reloaded.map(\.title), ["New"])
        XCTAssertEqual(reloaded.first?.body, "new body")
        XCTAssertGreaterThanOrEqual(reloaded.first!.updatedAt, reloaded.first!.createdAt)
    }

    func testDeleteRemovesTemplate() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        let t = store.create(owner: "o", repo: "r", title: "A", body: "a")
        store.delete(t)

        XCTAssertTrue(store.templates(owner: "o", repo: "r").isEmpty)
        XCTAssertTrue(store.allTemplates().isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' test -only-testing:AppFeedbackTests_macOS/ReplyTemplateStoreTests
```
Expected: FAIL — compile error, `cannot find 'ReplyTemplateStore' in scope`.

- [ ] **Step 3: Implement the store**

`AppFeedback/Services/ReplyTemplateStore.swift` (mirrors `VersionStore`'s structure and change listeners exactly):

```swift
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ReplyTemplateStore {
    private(set) var templatesAll: [ReplyTemplate] = []

    private let context: ModelContext
    private var didSaveTask: Task<Void, Never>?
    private var remoteChangeTask: Task<Void, Never>?
    private var cloudKitImportTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        reload()

        let ownContext = ObjectIdentifier(context)
        let didSaves = NotificationCenter.default.notifications(named: ModelContext.didSave)
            .compactMap { @Sendable note -> Bool? in
                let senderID = (note.object as? ModelContext).map(ObjectIdentifier.init)
                return senderID == ownContext ? nil : true
            }
        didSaveTask = Task { @MainActor [weak self] in
            for await _ in didSaves { self?.reload() }
        }
        remoteChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) { self?.reload() }
        }
        cloudKitImportTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.cloudKitImportSucceeded { self?.reload() }
        }
    }

    isolated deinit {
        didSaveTask?.cancel(); remoteChangeTask?.cancel(); cloudKitImportTask?.cancel()
    }

    // MARK: Queries

    /// Templates owned by one repo, newest-edited first.
    func templates(owner: String, repo: String) -> [ReplyTemplate] {
        templatesAll
            .filter { $0.repoOwner == owner && $0.repoName == repo }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Merged view across every repo (the "Global" tab), newest-edited first.
    func allTemplates() -> [ReplyTemplate] {
        templatesAll.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Mutations

    @discardableResult
    func create(owner: String, repo: String, title: String, body: String) -> ReplyTemplate {
        let t = ReplyTemplate(repoOwner: owner, repoName: repo, title: title, body: body)
        context.insert(t); save(); reload(); return t
    }

    func update(_ template: ReplyTemplate, title: String, body: String) {
        template.title = title
        template.body = body
        template.updatedAt = Date()
        save(); reload()
    }

    func delete(_ template: ReplyTemplate) {
        context.delete(template); save(); reload()
    }

    func save() { try? context.save() }

    // MARK: Internal

    private func reload() {
        templatesAll = (try? context.fetch(FetchDescriptor<ReplyTemplate>())) ?? []
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' test -only-testing:AppFeedbackTests_macOS/ReplyTemplateStoreTests
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/ReplyTemplateStore.swift AppFeedbackTests/ReplyTemplateStoreTests.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(templates): ReplyTemplateStore with repo-scoped + global queries and CRUD"
```

---

## Task 3: Extend `ComposeRequest` with `initialBody` + `autoSend`

**Files:**
- Modify: `AppFeedback/Views/Mail/ComposeRequest.swift`

- [ ] **Step 1: Add the two fields**

Find:
```swift
struct ComposeRequest: Identifiable {
    let id = UUID()
    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let inReplyTo: MailMessageHeaders?
    let subjectOverride: String?
    let senderAccountID: UUID?
    var attachments: [PendingAttachment] = []
}
```
Replace with:
```swift
struct ComposeRequest: Identifiable {
    let id = UUID()
    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let inReplyTo: MailMessageHeaders?
    let subjectOverride: String?
    let senderAccountID: UUID?
    var attachments: [PendingAttachment] = []
    /// When set, seeds the composer body (placeholder-substituted) — used by template replies.
    var initialBody: String? = nil
    /// When true, the composer sends immediately on appear (if credentialed) — the modal's "Send" CTA.
    var autoSend: Bool = false
}
```

> Both new fields are defaulted, so the synthesized memberwise initializer still accepts every existing call site (`replyToEmail`, `beginReply`) unchanged.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED (no new file → no `xcodegen generate` needed).

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Mail/ComposeRequest.swift
git commit -m "feat(templates): add initialBody + autoSend to ComposeRequest"
```

---

## Task 4: Seed `initialBody` and honor `autoSend` in `InlineReplyView`

**Files:**
- Modify: `AppFeedback/Views/Mail/InlineReplyView.swift` (`setupViewModel()`)

- [ ] **Step 1: Seed the body and trigger auto-send**

In `setupViewModel()`, find:
```swift
        if let existing = drafts.draft(for: key) {
            if !existing.subject.isEmpty { vm.subject = existing.subject }
            if !existing.body.isEmpty { vm.body = NSAttributedString(string: existing.body) }
        }

        viewModel = vm
    }
```
Replace with:
```swift
        if let existing = drafts.draft(for: key) {
            if !existing.subject.isEmpty { vm.subject = existing.subject }
            if !existing.body.isEmpty { vm.body = NSAttributedString(string: existing.body) }
        }

        // Template replies: seed the chosen template body, running it through the same
        // {{placeholder}} substitution that header/footer get. The body is USER_BODY only —
        // MailComposer.compose() still wraps it with HEADER + FOOTER, so a templated send
        // carries the same header/footer as a normal reply.
        if let initial = request.initialBody, !initial.isEmpty {
            let substituted = MailComposer().applyPlaceholders(initial, context: vm.placeholderContext())
            vm.body = NSAttributedString(string: substituted)
        }

        viewModel = vm

        // One-tap template send (the modal's primary CTA). Reuses the existing send path,
        // which dismisses the composer and finishes the SMTP round-trip in the background.
        // If there are no credentials, leave the composer open with the body seeded so it
        // gracefully degrades to a prefill the user can send manually.
        if request.autoSend, vm.body.length > 0, hasCredentials {
            send(vm: vm)
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Mail/InlineReplyView.swift
git commit -m "feat(templates): seed template body + honor autoSend in InlineReplyView"
```

---

## Task 5: Add the template segment to `ReplyBadgeButton`

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift` (the `ReplyBadgeButton` struct, ~lines 679–720)

- [ ] **Step 1: Replace the button body with a split layout**

Find the whole `ReplyBadgeButton` struct:
```swift
struct ReplyBadgeButton: View {
    struct ReplyFromOption: Identifiable, Hashable {
        let id: UUID
        let address: String
    }

    let email: String
    let color: Color
    let onReply: () -> Void
    let onCopy: () -> Void
    var replyFromOptions: [ReplyFromOption] = []
    var onReplyFrom: ((UUID) -> Void)? = nil

    var body: some View {
        Button(action: onReply) {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Reply")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Reply to \(email)")
        .contextMenu {
            Button("Reply to \(email)", action: onReply)
            if !replyFromOptions.isEmpty, let onReplyFrom {
                Menu("Reply from") {
                    ForEach(replyFromOptions) { opt in
                        Button(opt.address) { onReplyFrom(opt.id) }
                    }
                }
            }
            Button("Copy address", action: onCopy)
        }
    }
}
```
Replace with:
```swift
struct ReplyBadgeButton: View {
    struct ReplyFromOption: Identifiable, Hashable {
        let id: UUID
        let address: String
    }

    let email: String
    let color: Color
    let onReply: () -> Void
    let onCopy: () -> Void
    var replyFromOptions: [ReplyFromOption] = []
    var onReplyFrom: ((UUID) -> Void)? = nil
    /// When set, renders a divider + template segment that opens the reply-template picker.
    var onTemplates: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Left segment: the existing reply action.
            Button(action: onReply) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Reply")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .help("Reply to \(email)")

            // Right segment: open the template picker. Only present when wired up.
            if let onTemplates {
                Rectangle()
                    .fill(color.opacity(0.4))
                    .frame(width: 1, height: 16)
                Button(action: onTemplates) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("Reply with a template")
            }
        }
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4), lineWidth: 1))
        .contextMenu {
            Button("Reply to \(email)", action: onReply)
            if !replyFromOptions.isEmpty, let onReplyFrom {
                Menu("Reply from") {
                    ForEach(replyFromOptions) { opt in
                        Button(opt.address) { onReplyFrom(opt.id) }
                    }
                }
            }
            if let onTemplates {
                Button("Reply with template…", action: onTemplates)
            }
            Button("Copy address", action: onCopy)
        }
    }
}
```

> `onTemplates` defaults to `nil`, so both existing call sites (`IssueCardView` and `MailThreadView`) still compile and render the plain single-segment button until Tasks 9 & 10 pass `onTemplates`.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat(templates): add optional template segment to ReplyBadgeButton"
```

---

## Task 6: `ReplyTemplateEditorView` (add & edit)

**Files:**
- Create: `AppFeedback/Views/Templates/ReplyTemplateEditorView.swift`

- [ ] **Step 1: Create the editor**

`AppFeedback/Views/Templates/ReplyTemplateEditorView.swift`:

```swift
import SwiftUI

/// Add-or-edit sheet for a single reply template. Presented from ReplyTemplatePickerView.
/// On save, a new template always attaches to the current repo (owner/repo passed in);
/// editing updates the existing record in place.
struct ReplyTemplateEditorView: View {
    let store: ReplyTemplateStore
    let owner: String
    let repo: String
    /// nil → add mode; non-nil → edit that template.
    var existing: ReplyTemplate?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    // NOTE: must NOT be named `body` — that collides with the View protocol's
    // `var body: some View` and fails with "invalid redeclaration of 'body'".
    @State private var messageBody: String

    init(store: ReplyTemplateStore, owner: String, repo: String, existing: ReplyTemplate? = nil) {
        self.store = store
        self.owner = owner
        self.repo = repo
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _messageBody = State(initialValue: existing?.body ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Thanks for the report", text: $title)
                }
                Section("Message") {
                    TextEditor(text: $messageBody)
                        .font(.body)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle(existing == nil ? "New Template" : "Edit Template")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            store.update(existing, title: trimmedTitle, body: trimmedBody)
        } else {
            store.create(owner: owner, repo: repo, title: trimmedTitle, body: trimmedBody)
        }
        dismiss()
    }
}
```

- [ ] **Step 2: Regenerate + build**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Templates/ReplyTemplateEditorView.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(templates): add ReplyTemplateEditorView (add/edit sheet)"
```

---

## Task 7: `ReplyTemplatePickerView` (the modal)

**Files:**
- Create: `AppFeedback/Views/Templates/ReplyTemplatePickerView.swift`

- [ ] **Step 1: Create the modal**

`AppFeedback/Views/Templates/ReplyTemplatePickerView.swift`. The modal is pure UI over the store; the host supplies `onSend`/`onPrefill` (which build the `ComposeRequest`). It reads `ReplyTemplateStore` from the environment (sheets inherit the presenter's environment, the same way `InlineReplyView` reads its stores):

```swift
import SwiftUI

/// Modal that lists prewritten reply templates for single selection, with a this-repo /
/// global scope toggle, full add/edit/delete, and two CTAs: Send (immediate) and Prefill.
/// The host provides onSend/onPrefill, which build the ComposeRequest for its reply context.
struct ReplyTemplatePickerView: View {
    let store: ReplyTemplateStore
    let repoOwner: String
    let repoName: String
    var accent: Color = .accentColor
    let onSend: (ReplyTemplate) -> Void
    let onPrefill: (ReplyTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable { case thisRepo, global }

    @State private var scope: Scope = .thisRepo
    @State private var selection: UUID?
    @State private var showAdd = false
    @State private var editingTemplate: ReplyTemplate?

    private var items: [ReplyTemplate] {
        scope == .thisRepo ? store.templates(owner: repoOwner, repo: repoName) : store.allTemplates()
    }

    private var selectedTemplate: ReplyTemplate? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $scope) {
                    Text("\(repoOwner)/\(repoName)").tag(Scope.thisRepo)
                    Text("Global").tag(Scope.global)
                }
                .pickerStyle(.segmented)
                .padding(8)

                Divider()

                list

                Divider()
                footer
            }
            .navigationTitle("Reply Templates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) {
                ReplyTemplateEditorView(store: store, owner: repoOwner, repo: repoName, existing: nil)
            }
            .sheet(item: $editingTemplate) { tmpl in
                ReplyTemplateEditorView(store: store, owner: repoOwner, repo: repoName, existing: tmpl)
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("No Templates", systemImage: "list.bullet.rectangle")
            } description: {
                Text(scope == .thisRepo
                     ? "Add a reply template for \(repoOwner)/\(repoName)."
                     : "No templates in any repo yet.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(items) { template in
                    row(template).tag(template.id)
                }
            }
            .tint(accent)
        }
    }

    private func row(_ template: ReplyTemplate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(template.title).font(.body.weight(.medium))
                Spacer()
                if scope == .global {
                    Text("\(template.repoOwner)/\(template.repoName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(template.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…") { editingTemplate = template }
            Button("Delete", role: .destructive) {
                if selection == template.id { selection = nil }
                store.delete(template)
            }
        }
    }

    private var footer: some View {
        HStack {
            PanelAddButton(title: "Add") { showAdd = true }
                .fixedSize()
            Spacer()
            Button("Prefill…") {
                if let t = selectedTemplate { onPrefill(t); dismiss() }
            }
            .buttonStyle(.bordered)
            .disabled(selectedTemplate == nil)

            Button("Send") {
                if let t = selectedTemplate { onSend(t); dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTemplate == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 2: Regenerate + build**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

> If the compiler reports `PanelAddButton` is ambiguous about its accent vs. `.accentColor`, note `PanelAddButton` always uses `Color.accentColor` internally (per `InspectorDesign.swift`) and takes only `title` + `action`; the call above matches that signature.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Templates/ReplyTemplatePickerView.swift AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(templates): add ReplyTemplatePickerView modal (toggle, list, CRUD, CTAs)"
```

---

## Task 8: Construct + inject `ReplyTemplateStore`

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Add the `@State` property**

Find:
```swift
    @State private var versionStore: VersionStore
```
Add a line after it:
```swift
    @State private var versionStore: VersionStore
    @State private var replyTemplateStore: ReplyTemplateStore
```

- [ ] **Step 2: Construct it in `init()`**

Find:
```swift
        _versionStore = State(initialValue: VersionStore(context: ModelContext(container)))
```
Add a line after it:
```swift
        _versionStore = State(initialValue: VersionStore(context: ModelContext(container)))
        _replyTemplateStore = State(initialValue: ReplyTemplateStore(context: ModelContext(container)))
```

- [ ] **Step 3: Inject into the primary scene**

Find (the first injection block, ~line 282):
```swift
                .environment(threadStore)
                .environment(outboundTracker)
```
Replace with:
```swift
                .environment(threadStore)
                .environment(replyTemplateStore)
                .environment(outboundTracker)
```

- [ ] **Step 4: Inject into the secondary scene**

Find (the second injection block, ~line 360 — identical two lines):
```swift
                .environment(threadStore)
                .environment(outboundTracker)
```
Replace with the same:
```swift
                .environment(threadStore)
                .environment(replyTemplateStore)
                .environment(outboundTracker)
```

> There are two occurrences of `.environment(threadStore)\n.environment(outboundTracker)` (one per scene). Apply the edit to **both**. If your editor matches only the first, repeat for the second.

- [ ] **Step 5: Build**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(templates): construct + inject ReplyTemplateStore into the environment"
```

---

## Task 9: Wire the no-thread host (`IssueCardView`)

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`

- [ ] **Step 1: Add the store dependency + picker-presentation state**

First, inject the store. Find:
```swift
    @Environment(MailThreadStore.self) private var threadStore
    #if canImport(SwiftMail)
    @Environment(MailDraftStore.self) private var drafts
    #endif
```
Replace with:
```swift
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(ReplyTemplateStore.self) private var replyTemplateStore
    #if canImport(SwiftMail)
    @Environment(MailDraftStore.self) private var drafts
    #endif
```

Then add the presentation state. Find:
```swift
    @State private var showOriginal: Bool = false
    @State private var highlightActive: Bool = false
    @State private var didCopy: Bool = false
    @State private var threads: [MailThread] = []
```
Replace with (declare `showTemplatePicker` **unconditionally** so the `onTemplates` closure compiles even in a no-SwiftMail build, where the `.sheet` below is compiled out and the segment is a harmless no-op):
```swift
    @State private var showOriginal: Bool = false
    @State private var highlightActive: Bool = false
    @State private var didCopy: Bool = false
    @State private var threads: [MailThread] = []
    @State private var showTemplatePicker: Bool = false
```

- [ ] **Step 2: Add the template-use helper**

In the `#if canImport(SwiftMail)` block that already contains `newEmailKey(for:)` / `activeInlineComposers`, add a helper. Find:
```swift
    private var activeInlineComposers: [(key: DraftKey, request: ComposeRequest)] {
        guard let email = issue.email else { return [] }
        let key = newEmailKey(for: email)
        if let req = drafts.openRequest(for: key) {
            return [(key, req)]
        }
        return []
    }
    #endif
```
Replace with:
```swift
    private var activeInlineComposers: [(key: DraftKey, request: ComposeRequest)] {
        guard let email = issue.email else { return [] }
        let key = newEmailKey(for: email)
        if let req = drafts.openRequest(for: key) {
            return [(key, req)]
        }
        return []
    }

    /// Open the inline composer for `email`, seeded with the template body. When `autoSend`
    /// is true the composer sends immediately (if credentialed); otherwise it stays open
    /// for editing. Mirrors `replyToEmail(_:)` but carries the template body.
    private func useTemplate(_ template: ReplyTemplate, autoSend: Bool, email: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(
                ComposeRequest(
                    recipient: email,
                    issue: issue,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    inReplyTo: nil,
                    subjectOverride: nil,
                    senderAccountID: nil,
                    initialBody: template.body,
                    autoSend: autoSend
                ),
                for: newEmailKey(for: email)
            )
        }
    }
    #endif
```

- [ ] **Step 3: Pass `onTemplates` to the badge button + attach the sheet**

Find the badge instantiation in the tag row:
```swift
                        if let email = issue.email, threads.isEmpty {
                            ReplyBadgeButton(
                                email: email,
                                color: appColor,
                                onReply: {
                                    onInteract?()
                                    replyToEmail(email)
                                },
                                onCopy: {
                                    onInteract?()
                                    copyEmailToClipboard(email)
                                }
                            )
                        }
```
Replace with:
```swift
                        if let email = issue.email, threads.isEmpty {
                            ReplyBadgeButton(
                                email: email,
                                color: appColor,
                                onReply: {
                                    onInteract?()
                                    replyToEmail(email)
                                },
                                onCopy: {
                                    onInteract?()
                                    copyEmailToClipboard(email)
                                },
                                onTemplates: {
                                    onInteract?()
                                    showTemplatePicker = true
                                }
                            )
                            #if canImport(SwiftMail)
                            .sheet(isPresented: $showTemplatePicker) {
                                ReplyTemplatePickerView(
                                    store: replyTemplateStore,
                                    repoOwner: repoOwner,
                                    repoName: repoName,
                                    accent: appColor,
                                    onSend: { template in useTemplate(template, autoSend: true, email: email) },
                                    onPrefill: { template in useTemplate(template, autoSend: false, email: email) }
                                )
                            }
                            #endif
                        }
```

> `onTemplates` just sets `showTemplatePicker` (declared unconditionally in Step 1), so it compiles in every config. The `.sheet` and `useTemplate` are gated on `#if canImport(SwiftMail)` because they touch `drafts`/`ComposeRequest`. In the shipping macOS build SwiftMail is present, so the sheet is active.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat(templates): wire template picker into the no-thread reply badge"
```

---

## Task 10: Wire the in-thread host (`MailThreadView`)

**Files:**
- Modify: `AppFeedback/Views/Mail/MailThreadView.swift`

- [ ] **Step 1: Add the store dependency + picker state**

`MailThreadView` already has `private var activeReply: ComposeRequest? { drafts.openRequest(for: replyKey) }`. Add the store and the state right after it. Find:
```swift
    private var activeReply: ComposeRequest? { drafts.openRequest(for: replyKey) }
```
Replace with:
```swift
    private var activeReply: ComposeRequest? { drafts.openRequest(for: replyKey) }
    @Environment(ReplyTemplateStore.self) private var replyTemplateStore
    @State private var showTemplatePicker: Bool = false
```

- [ ] **Step 2: Add the in-thread template-use helper**

`beginReply(senderAccountID:)` ends with the block below. Append the new `useTemplate` method right after it (it mirrors `beginReply` but carries the template body + autoSend, so a templated reply still threads correctly via `inReplyTo`/`References` and gets the reply-prefixed subject). Find:
```swift
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(request, for: replyKey)
        }
        #endif
    }
```
Replace with:
```swift
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(request, for: replyKey)
        }
        #endif
    }

    private func useTemplate(_ template: ReplyTemplate, autoSend: Bool) {
        #if canImport(SwiftMail)
        guard let last = messages.last, let recipient = replyRecipient else { return }
        guard let chosen = resolvedSenderAccountID else { return }
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
            senderAccountID: chosen,
            initialBody: template.body,
            autoSend: autoSend
        )
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(request, for: replyKey)
        }
        #endif
    }
```

> The `find` block above is unique at edit time — only `beginReply` contains `drafts.setOpenRequest(request, for: replyKey)` ending in `#endif` + `}`. After this edit the new method contains an identical tail; that's expected and harmless.

- [ ] **Step 3: Pass `onTemplates` to the badge + attach the sheet**

In `replyArea`, find:
```swift
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
```
Replace with:
```swift
            ReplyBadgeButton(
                email: recipient,
                color: appColor,
                onReply: { beginReply() },
                onCopy: copyRecipient,
                replyFromOptions: options.count > 1 ? options : [],
                onReplyFrom: { id in beginReply(senderAccountID: id) },
                onTemplates: { showTemplatePicker = true }
            )
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .sheet(isPresented: $showTemplatePicker) {
                ReplyTemplatePickerView(
                    store: replyTemplateStore,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    accent: appColor,
                    onSend: { template in useTemplate(template, autoSend: true) },
                    onPrefill: { template in useTemplate(template, autoSend: false) }
                )
            }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Mail/MailThreadView.swift
git commit -m "feat(templates): wire template picker into the in-thread reply"
```

---

## Task 11: Full verification

- [ ] **Step 1: Full build**

Run:
```bash
cd /Users/amir/Developer/AppFeedback && xcodegen generate && xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Full test suite**

Run: `xcodebuild -scheme AppFeedback_macOS -destination 'platform=macOS' test`
Expected: all tests pass, including `ReplyTemplateStoreTests` (4 tests). Confirm the printed summary shows them executing (not skipped).

- [ ] **Step 3: Manual smoke (run the app)**

Verify by hand:
1. On an issue with an email and no thread, the reply badge shows `[ ⤺ Reply | ▤ ]` with a divider.
2. Tapping the template segment opens the modal. Toggle reads `owner/repo | Global`.
3. `+ Add` creates a template (title + body); it appears under the repo tab.
4. Switching to Global shows templates from all repos with an origin caption.
5. Selecting a template + **Prefill** opens the inline composer with the body seeded (header/footer preview visible). **Send** sends immediately (with an email account configured); with no account, the composer stays open seeded.
6. Edit and Delete via row context menu work.
7. On an issue that already has a thread, the in-thread reply badge shows the same split and behaves the same (replies thread correctly).

- [ ] **Step 4: Final commit (only if Step 1–2 produced changes, e.g. pbxproj)**

```bash
git add AppFeedback.xcodeproj/project.pbxproj
git commit -m "chore(templates): regenerate project for template-replies files"
```

---

## Self-review notes (verified against the spec)

- **Split button with divider, both entry points** → Task 5 (`ReplyBadgeButton` divider + segment) consumed by Task 9 (no-thread) and Task 10 (in-thread). ✓
- **Left segment unchanged** → Task 5 keeps `onReply` as the left `Button`. ✓
- **Modal: single-selection list, +Add bottom-left, Send CTA, repo/global toggle** → Task 7. ✓
- **Global = merged all-repos view; templates stored per-repo; +Add attaches to current repo** → `ReplyTemplateStore.allTemplates()`/`templates(owner:repo:)` (Task 2) + editor always passing `owner/repo` (Task 6). ✓
- **Send immediate (primary) + secondary prefill** → Task 7 CTAs → `autoSend` true/false → Task 4. ✓
- **Header/footer like normal replies** → template body seeded as USER_BODY; `MailComposer.compose()` wraps HEADER/FOOTER unchanged (Task 4). ✓
- **Placeholders in template bodies** → `applyPlaceholders` on the seeded body (Task 4). ✓
- **Full CRUD** → store (Task 2) + editor (Task 6) + row context menu (Task 7). ✓
- **CloudKit sync** → model in cloud schema (Task 1); store change listeners (Task 2). ✓
- **Subject auto-derived** → no subject field on the model; no-thread uses default/derived subject, in-thread uses `MailSubject.replyPrefixed(last.subject)` (Tasks 9/10). ✓
```
