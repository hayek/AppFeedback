# Drop Textual, Plain-Text Bodies — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `Textual` SPM dependency and replace `MarkdownBodyView` with a lightweight `IssueBodyText` component that renders title + body as two native SwiftUI `Text` views (inline-only markdown).

**Architecture:** Two `Text` views per card — title (15pt semibold) + body (13pt with `AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace)`). Both selectable via native `.textSelection(.enabled)`. Drops `TextSelectionFocus`, `IssueBodyHeadingStyle`, the `import Textual`, the Textual SPM package reference, and the `MarkdownBodyView` view.

**Tech Stack:** Swift 5+, SwiftUI, Xcode 16+ project (macOS 15 / iOS 18). Build/run via the `zcode` skill.

**Spec:** `docs/superpowers/specs/2026-05-19-drop-textual-markdown-design.md`

---

## File Structure

| File | Action | Responsibility |
| --- | --- | --- |
| `AppFeedback/Views/Issues/IssueCardView.swift` | Modify | Remove `import Textual`, `MarkdownBodyView`, `IssueBodyHeadingStyle`, `TextSelectionFocus`. Add `IssueBodyText`. Update call site at line 219. |
| `AppFeedback/Views/Mail/MailMessageRowView.swift` | Modify | Replace `MarkdownBodyView(title:, plainBody:)` call with `IssueBodyText(title:, body:)`. |
| `AppFeedback/App/AppFeedbackApp.swift` | Modify | Drop `@State private var textSelectionFocus` and its `.environment(...)` injection. |
| `AppFeedback.xcodeproj/project.pbxproj` | Modify | Remove all Textual references: build files, frameworks lists, package product dependencies (×2), package reference block, project-level `packageReferences` entry. |
| `AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Auto-regen | Xcode rewrites this on next resolve. Don't hand-edit. |

This is a single coherent refactor and ships as one PR / one feature commit (plus the project-file cleanup commit if it ends up large).

---

## Task 1: Add `IssueBodyText` alongside the existing `MarkdownBodyView`

We add the replacement view first without removing the old one. This lets the next task switch call sites cleanly and keeps each commit buildable.

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift` (append a new struct near the existing `MarkdownBodyView` at line 438)

- [ ] **Step 1: Add the new `IssueBodyText` view**

Open `AppFeedback/Views/Issues/IssueCardView.swift`. Just after the closing brace of `MarkdownBodyView` (currently at line 501), insert this new struct:

```swift
/// Title + body rendered as two selectable Text views. Body parses inline-only
/// markdown so `**bold**`, `*italic*`, `[link](url)` and `` `code` `` render
/// styled while block-level markdown (`##`, `-`) appears verbatim.
struct IssueBodyText: View {
    private let title: String
    private let body: String
    private let titleTrailingReserve: CGFloat

    init(title: String, body: String, titleTrailingReserve: CGFloat = 0) {
        self.title = title
        self.body = body
        self.titleTrailingReserve = titleTrailingReserve
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.trailing, titleTrailingReserve)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !body.isEmpty {
                Text(bodyAttributed)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var bodyAttributed: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }
}
```

- [ ] **Step 2: Build to confirm nothing regresses**

Use the `zcode` skill to build the macOS scheme. The project must still compile — `MarkdownBodyView` and `IssueBodyText` coexist for now. Expected: clean build, no warnings about unused `IssueBodyText` (SwiftUI views aren't flagged).

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "$(cat <<'EOF'
refactor(issue-card): add IssueBodyText alongside MarkdownBodyView

Introduces a native two-Text replacement for MarkdownBodyView. Not
wired into call sites yet; intermediate commit so the next task can
flip both call sites in one place.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Switch the `IssueCardView` call site to `IssueBodyText`

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift:219`

- [ ] **Step 1: Replace the call**

In `IssueCardView.swift`, find the line currently reading:

```swift
                        MarkdownBodyView(title: titleText, bodyMarkdown: bodyText, titleTrailingReserve: metaColumnReserve)
```

Replace with:

```swift
                        IssueBodyText(title: titleText, body: bodyText, titleTrailingReserve: metaColumnReserve)
```

- [ ] **Step 2: Build via zcode (macOS)**

Use the `zcode` skill to run a macOS build. Expected: succeeds.

- [ ] **Step 3: Manual smoke test (skip if no simulator/device available)**

Launch the macOS app. Open `IssueListView` for any repo with issues. Confirm:
- Issue title renders at 15pt semibold.
- Body renders at 13pt with inline `**bold**`/`*italic*`/links rendered.
- Selecting text in the body works (drag selects; ⌘C copies).

If something is broken visually, fix forward in this task before committing.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "$(cat <<'EOF'
refactor(issue-card): render body via plain-text IssueBodyText

Drops the per-block StructuredText tree in favor of two native Text
views. Inline markdown still renders; block-level (headings, lists)
shows source syntax.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Switch the `MailMessageRowView` call site to `IssueBodyText`

**Files:**
- Modify: `AppFeedback/Views/Mail/MailMessageRowView.swift:99-102`

- [ ] **Step 1: Replace the call**

In `MailMessageRowView.swift`, find:

```swift
        MarkdownBodyView(
            title: message.subject,
            plainBody: showFull ? stripped.full : stripped.cleaned
        )
```

Replace with:

```swift
        IssueBodyText(
            title: message.subject,
            body: showFull ? stripped.full : stripped.cleaned
        )
```

Note: the mail body is already sanitized plain text from `HTMLSanitizer.stripQuotedReply`. The inline-markdown parser is harmless on plain text — any stray `*` becomes literal.

- [ ] **Step 2: Build via zcode**

Use the `zcode` skill to build the macOS scheme. Expected: succeeds.

- [ ] **Step 3: Manual smoke test**

Open an issue that has an attached mail thread. Confirm the mail message renders the subject as bold and the body as plain text, and that the "Show full text" / "Show cleaned text" toggle still works.

- [ ] **Step 4: Commit**

```bash
git add AppFeedback/Views/Mail/MailMessageRowView.swift
git commit -m "$(cat <<'EOF'
refactor(mail): render mail rows via IssueBodyText

Switches MailMessageRowView's body off MarkdownBodyView so we can
remove the latter and the Textual dependency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Delete `MarkdownBodyView`, `IssueBodyHeadingStyle`, `TextSelectionFocus`, and `import Textual`

With both call sites switched, all four can be removed in one commit. The build will fail if any other site still references them — that's a signal to add a call-site update, not skip the deletion.

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift` (remove line 2, lines 428–436, lines 438–501, lines 503–522)

- [ ] **Step 1: Verify nothing else uses these symbols**

Run from the repo root:

```bash
grep -rn "MarkdownBodyView\|IssueBodyHeadingStyle\|TextSelectionFocus\|import Textual\|StructuredText" AppFeedback --include="*.swift"
```

Expected output: matches only inside `IssueCardView.swift` (where they're defined) and inside `AppFeedbackApp.swift` (the `TextSelectionFocus` env wiring — handled in Task 5). No matches in any other file.

If any other file matches, STOP and update those call sites first.

- [ ] **Step 2: Remove `import Textual`**

In `AppFeedback/Views/Issues/IssueCardView.swift`, delete line 2:

```swift
import Textual
```

- [ ] **Step 3: Remove `TextSelectionFocus`**

Delete the class block (currently lines 428–436):

```swift
@MainActor
@Observable
final class TextSelectionFocus {
    private(set) var activeID: UUID?

    func activate(_ id: UUID) {
        if activeID != id { activeID = id }
    }
}
```

- [ ] **Step 4: Remove `MarkdownBodyView`**

Delete the struct block (currently lines 438–501) starting at `struct MarkdownBodyView: View {` through its closing `}`. Do NOT delete the new `IssueBodyText` struct that follows it.

- [ ] **Step 5: Remove `IssueBodyHeadingStyle`**

Delete the struct block (currently lines 503–522):

```swift
struct IssueBodyHeadingStyle: StructuredText.HeadingStyle {
    var trailingReserve: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), 6)
        let size: CGFloat
        switch level {
        case 1: size = 17
        case 2: size = 15
        default: size = 14
        }
        return configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.leading, 4)
            .padding(.trailing, trailingReserve)
            .padding(.bottom, 4)
            .textual.blockSpacing(.fontScaled(top: 1.0, bottom: 0.4))
    }
}
```

- [ ] **Step 6: Build via zcode**

Use the `zcode` skill to build macOS. Expected: build will likely fail because `AppFeedbackApp.swift` still references `TextSelectionFocus`. That's fine — move to Task 5.

If the build fails on anything *other than* `AppFeedbackApp.swift`'s `TextSelectionFocus` references, fix the new call site here before continuing.

---

## Task 5: Drop `TextSelectionFocus` env injection from `AppFeedbackApp`

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift:31` and `AppFeedback/App/AppFeedbackApp.swift:228`

- [ ] **Step 1: Remove the @State declaration**

In `AppFeedbackApp.swift`, find and delete the line at ~line 31:

```swift
    @State private var textSelectionFocus = TextSelectionFocus()
```

- [ ] **Step 2: Remove the environment injection**

In the same file, find and delete the line at ~line 228:

```swift
                .environment(textSelectionFocus)
```

- [ ] **Step 3: Build via zcode**

Use the `zcode` skill to build macOS. Expected: clean compile.

- [ ] **Step 4: Build iOS scheme via zcode**

Use the `zcode` skill to build the iOS scheme as well. Both platforms must build before committing — the Textual package still lives in the iOS target until Task 6.

Expected: clean compile.

- [ ] **Step 5: Commit Tasks 4+5 together**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "$(cat <<'EOF'
refactor(issue-card): remove Textual integration code

Deletes MarkdownBodyView, IssueBodyHeadingStyle, TextSelectionFocus,
and the import Textual / .environment(textSelectionFocus) wiring.
The SPM package itself is removed in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Remove the Textual SPM package from the Xcode project

Surgical edits to `project.pbxproj`. Each edit removes one entry; the file stays well-formed throughout. **Line numbers shift after each edit** — locate each block by its content, not its line number.

**Files:**
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (six locations)
- Auto-regenerated: `AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

- [ ] **Step 1: Delete the two `PBXBuildFile` entries**

Find and delete these two lines (in the `Begin PBXBuildFile section`):

```
		9781E6432FB84AF6008FDDC6 /* Textual in Frameworks */ = {isa = PBXBuildFile; productRef = 9781E6422FB84AF6008FDDC6 /* Textual */; };
		9781E6462FB84AFD008FDDC6 /* Textual in Frameworks */ = {isa = PBXBuildFile; productRef = 9781E6452FB84AFD008FDDC6 /* Textual */; };
```

- [ ] **Step 2: Delete from both frameworks build phases**

In the `Begin PBXFrameworksBuildPhase section`, remove these two lines from the `files = ( … );` arrays of `086ED100B02E72FC026C3AC6 /* Frameworks */` and `FC2D3271F35D1471178721AF /* Frameworks */`:

```
				9781E6432FB84AF6008FDDC6 /* Textual in Frameworks */,
				9781E6462FB84AFD008FDDC6 /* Textual in Frameworks */,
```

(One is in each `files` array.) Leave the rest of the array intact.

- [ ] **Step 3: Delete from both target `packageProductDependencies`**

Find the `AppFeedback_macOS` native target's `packageProductDependencies` array and remove this line:

```
					9781E6452FB84AFD008FDDC6 /* Textual */,
```

Find the `AppFeedback_iOS` native target's `packageProductDependencies` array and remove this line:

```
					9781E6422FB84AF6008FDDC6 /* Textual */,
```

- [ ] **Step 4: Delete the two `XCSwiftPackageProductDependency` blocks**

In `Begin XCSwiftPackageProductDependency section`, remove both blocks in full:

```
		9781E6422FB84AF6008FDDC6 /* Textual */ = {
			isa = XCSwiftPackageProductDependency;
			package = 9781E6412FB84AF6008FDDC6 /* XCRemoteSwiftPackageReference "textual" */;
			productName = Textual;
		};
		9781E6452FB84AFD008FDDC6 /* Textual */ = {
			isa = XCSwiftPackageProductDependency;
			package = 9781E6412FB84AF6008FDDC6 /* XCRemoteSwiftPackageReference "textual" */;
			productName = Textual;
		};
```

- [ ] **Step 5: Delete the `XCRemoteSwiftPackageReference`**

In `Begin XCRemoteSwiftPackageReference section`, remove the block:

```
		9781E6412FB84AF6008FDDC6 /* XCRemoteSwiftPackageReference "textual" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/gonzalezreal/textual";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 0.3.1;
			};
		};
```

- [ ] **Step 6: Delete from the project-level `packageReferences`**

Find the project root's `packageReferences = ( … );` array (around what was line 989) and remove this single line:

```
				9781E6412FB84AF6008FDDC6 /* XCRemoteSwiftPackageReference "textual" */,
```

- [ ] **Step 7: Sanity-check the project file**

Run from the repo root:

```bash
grep -c "9781E6\|textual\|Textual" AppFeedback.xcodeproj/project.pbxproj
```

Expected output: `0`.

- [ ] **Step 8: Resolve packages via zcode and build both platforms**

Use the `zcode` skill to build the macOS scheme. Xcode will re-resolve SPM packages on first build after the edit; `Package.resolved` will be rewritten without `textual` and `swiftui-math`. Then build the iOS scheme.

Expected: both build cleanly. `Package.resolved` shows `textual` and `swiftui-math` are gone. `swift-concurrency-extras` may stay (used by some Apple packages) — leave whatever Xcode writes.

If the build fails with "missing package product", repeat Steps 1–6, then build again.

- [ ] **Step 9: Commit**

```bash
git add AppFeedback.xcodeproj/project.pbxproj AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "$(cat <<'EOF'
chore(deps): drop Textual 0.3.1

The pre-1.0 markdown renderer's per-block view tree caused scroll
hitches in IssueListView and its selection coordinator required a
.id()-recreation workaround. Replaced by native Text + inline-only
AttributedString markdown in IssueBodyText.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final verification

- [ ] **Step 1: Confirm no Textual residue**

Run from the repo root:

```bash
grep -rn "Textual\|MarkdownBodyView\|IssueBodyHeadingStyle\|TextSelectionFocus\|StructuredText" AppFeedback AppFeedback.xcodeproj --include="*.swift" --include="*.pbxproj" --include="*.resolved"
```

Expected output: empty.

- [ ] **Step 2: Build both platforms one more time**

Use the `zcode` skill to build macOS, then iOS. Both must build cleanly.

- [ ] **Step 3: Manual perf check (macOS)**

Launch the macOS app. Open a repo whose issue list has 50+ items. Scroll rapidly top-to-bottom; the list should feel smooth (no hitches or frame drops). Open an issue with `hasTranslation` and rapidly toggle "Show original" / "Show translation" — flips should be instant.

- [ ] **Step 4: Manual selection check**

In a card body, drag-select some text and copy it (⌘C). Paste it elsewhere — content should match what you selected, including preserved whitespace. Repeat for an issue title.

- [ ] **Step 5: Manual inline-markdown check**

If you have an issue with `**bold**` / `*italic*` / `[link](url)` / `` `code` `` in its body, confirm those render styled. Confirm any `## Heading` or `- bullet` lines render as literal source characters (acceptable per spec).

- [ ] **Step 6: No commit needed**

This task is verification only. If anything is wrong, go back and fix in the relevant task's commit (use `git commit --fixup` or amend if it's the most recent commit; otherwise stack a new commit).

---

## Self-Review

**Spec coverage:**

| Spec requirement | Implemented by |
| --- | --- |
| Replace `MarkdownBodyView` with `IssueBodyText` | Tasks 1, 2, 4 |
| Two `Text` views per card (title + body) | Task 1 step 1 |
| Inline-only attributed-string markdown for body | Task 1 step 1 (`bodyAttributed`) |
| Per-`Text` `.textSelection(.enabled)` | Task 1 step 1 |
| Title trailing reserve preserved | Task 1 step 1 (`titleTrailingReserve`), Task 2 step 1 (pass `metaColumnReserve`) |
| Drop `import Textual` | Task 4 step 2 |
| Drop `TextSelectionFocus` class | Task 4 step 3 |
| Drop `MarkdownBodyView` | Task 4 step 4 |
| Drop `IssueBodyHeadingStyle` | Task 4 step 5 |
| Drop env injection in `AppFeedbackApp` | Task 5 |
| Remove SPM package from `project.pbxproj` | Task 6 (steps 1–6) |
| Mail rows switched to plain-text component | Task 3 |
| Build both platforms | Tasks 2, 3, 5 step 4, 6 step 8, 7 step 2 |
| Manual perf check | Task 7 step 3 |
| Selection regression check | Task 7 step 4 |
| Inline markdown visual check | Task 7 step 5 |

**Placeholder scan:** No "TBD" / "TODO" / "handle edge cases". Code blocks are complete and self-contained.

**Type/signature consistency:** `IssueBodyText(title:body:titleTrailingReserve:)` is used identically in Tasks 1, 2, and 3. No drift between definition and call sites.

**Ordering safety:** Tasks 1–3 are additive and keep the build green at every commit. Task 4's deletions intentionally break the build until Task 5's env-injection cleanup; the two commit together in Task 5 step 5. Task 6 is self-contained at the project-file level.
