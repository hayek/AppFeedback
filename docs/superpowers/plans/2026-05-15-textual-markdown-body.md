# Textual-backed issue body rendering — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled `MarkdownBodyView` in `IssueCardView` with `StructuredText` from the [Textual](https://github.com/gonzalezreal/textual) library so that the rendered issue body becomes a single continuous selection unit on macOS and iOS.

**Architecture:** Adopt Textual via Swift Package Manager (no vendoring). Replace the per-block `VStack` of `Text` views with one `StructuredText` view whose typography matches the current rendering via a small custom `HeadingStyle`. Delete `MarkdownBlock` and its parser — Textual ships its own. The deployment-target floor moves from macOS 14 / iOS 17 to macOS 15 / iOS 18 because Textual's selection engine depends on macOS 15 / iOS 18 platform APIs.

**Tech Stack:** SwiftUI, Swift Package Manager, [gonzalezreal/textual](https://github.com/gonzalezreal/textual) v0.3.1 (MIT). Build via the `zcode` skill.

---

## File structure

| Path | Action | Why |
|---|---|---|
| `AppFeedback.xcodeproj/project.pbxproj` | Modify (deployment targets + SPM package ref) | Bump macOS/iOS floors, add Textual package |
| `AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Auto-updated by Xcode | Records the resolved Textual version + transitive deps |
| `AppFeedback/Views/Issues/IssueCardView.swift` | Modify | Replace `MarkdownBodyView` body, delete `MarkdownBlock`, add `IssueBodyHeadingStyle` |
| `docs/superpowers/specs/2026-05-15-textual-markdown-body-design.md` | Already exists (no change) | Spec |

No new files. The custom heading style lives as a `private struct` inside `IssueCardView.swift` next to the `MarkdownBodyView` wrapper — same file ownership pattern as the existing private helpers in this file (`ToggleableDateText`, `IssueTypeIconButton`, `LabelChipView`, etc.).

---

## Task 1: Bump deployment targets to macOS 15 / iOS 18

**Why first:** Textual's `Package.swift` declares minimum platforms of macOS 15 / iOS 18. If we add the SPM dependency before bumping the target, Xcode will refuse to resolve the package.

**Files:**
- Modify: `AppFeedback.xcodeproj/project.pbxproj`

There are **six** occurrences of `IPHONEOS_DEPLOYMENT_TARGET = 17.0;` and **six** occurrences of `MACOSX_DEPLOYMENT_TARGET = 14.0;` in the pbxproj (Debug/Release × main app target / test target × macOS-only configs / shared configs). All of them get bumped.

- [ ] **Step 1: Verify current state**

Run: `grep -cE "IPHONEOS_DEPLOYMENT_TARGET = 17.0;" AppFeedback.xcodeproj/project.pbxproj && grep -cE "MACOSX_DEPLOYMENT_TARGET = 14.0;" AppFeedback.xcodeproj/project.pbxproj`
Expected: prints `6` then `6` (one count per match line).

- [ ] **Step 2: Bulk replace iOS target**

Use the Edit tool with `replace_all: true`:
- old_string: `IPHONEOS_DEPLOYMENT_TARGET = 17.0;`
- new_string: `IPHONEOS_DEPLOYMENT_TARGET = 18.0;`

- [ ] **Step 3: Bulk replace macOS target**

Use the Edit tool with `replace_all: true`:
- old_string: `MACOSX_DEPLOYMENT_TARGET = 14.0;`
- new_string: `MACOSX_DEPLOYMENT_TARGET = 15.0;`

- [ ] **Step 4: Verify replacement**

Run: `grep -cE "IPHONEOS_DEPLOYMENT_TARGET = 18.0;" AppFeedback.xcodeproj/project.pbxproj && grep -cE "MACOSX_DEPLOYMENT_TARGET = 15.0;" AppFeedback.xcodeproj/project.pbxproj && grep -E "IPHONEOS_DEPLOYMENT_TARGET = 17.0;|MACOSX_DEPLOYMENT_TARGET = 14.0;" AppFeedback.xcodeproj/project.pbxproj`
Expected: prints `6`, then `6`, then *no* lines (the old values are gone).

- [ ] **Step 5: Build for macOS to verify the project still compiles at the new floor**

Invoke the `zcode` skill: build the macOS scheme of `AppFeedback`.
Expected: build succeeds. If any code uses `@available(macOS 14, ...)` or `if #available(macOS 14, *)` checks that no longer make sense, they will not be a build error — note them but do not fix in this task; that's cleanup.

- [ ] **Step 6: Build for iOS to verify the project still compiles at the new floor**

Invoke the `zcode` skill: build the iOS scheme of `AppFeedback`.
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
chore(xcode): bump deployment targets to macOS 15 / iOS 18

Required by the upcoming Textual SPM dependency, whose selection
engine depends on macOS 15 / iOS 18 platform APIs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add Textual as a Swift Package Manager dependency

**Why next:** Locks in the dependency before we touch the view layer. Doing it as its own commit keeps the diff small and reviewable.

**Files:**
- Modify: `AppFeedback.xcodeproj/project.pbxproj` (Xcode writes the `XCRemoteSwiftPackageReference` and `XCSwiftPackageProductDependency` blocks)
- Modify: `AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (Xcode writes the resolved versions)

This task uses the **Xcode IDE** directly. The Bash/Edit tools can edit `project.pbxproj` by hand, but the chance of corrupting the file is high. Drive the IDE instead.

- [ ] **Step 1: Open the project in Xcode**

Run: `open AppFeedback.xcodeproj`
Expected: Xcode opens with the project tree visible.

- [ ] **Step 2: Add the Textual package**

In Xcode:
1. File → Add Package Dependencies…
2. In the search bar, paste: `https://github.com/gonzalezreal/textual`
3. In the **Dependency Rule** dropdown, choose **Exact Version** and enter `0.3.1`. Do not choose "Up to Next Major" or "Up to Next Minor" — Textual is pre-1.0 and its API is acknowledged-unstable. Lock the version exactly.
4. Click **Add Package**.
5. In the product selection sheet, check **Textual** and assign it to the **AppFeedback** target (the main app). Click **Add Package**.

Expected: Xcode resolves Textual plus its transitive dependencies (`swift-concurrency-extras`, `swiftui-math`) and writes them into `Package.resolved`.

- [ ] **Step 3: Verify the dependency was added**

Run: `grep -A 5 '"identity" : "textual"' AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
Expected: a block similar to
```json
"identity" : "textual",
"kind" : "remoteSourceControl",
"location" : "https://github.com/gonzalezreal/textual",
"state" : {
  "revision" : "<a-real-sha>",
  "version" : "0.3.1"
}
```

Also run: `grep -cE '"identity" : "(textual|swift-concurrency-extras|swiftui-math)"' AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
Expected: `3` (the package itself plus its two runtime deps).

- [ ] **Step 4: Build for macOS to verify resolution and link**

Invoke the `zcode` skill: build the macOS scheme.
Expected: build succeeds. The first build will compile Textual; subsequent builds use the build cache.

- [ ] **Step 5: Build for iOS**

Invoke the `zcode` skill: build the iOS scheme.
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add AppFeedback.xcodeproj/project.pbxproj AppFeedback.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "$(cat <<'EOF'
chore(deps): add Textual 0.3.1 for selectable markdown rendering

Adds the gonzalezreal/textual Swift package, pinned to exact version
0.3.1 because the library is pre-1.0 and the API is acknowledged-
unstable by the author.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Replace `MarkdownBodyView` with `StructuredText` and delete the local markdown parser

**Files:**
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`
  - Line 229 — call-site update from `MarkdownBodyView(text: bodyText)` to the new view
  - Lines 372–436 — `MarkdownBodyView` body
  - Lines 438–525 — `MarkdownBlock` enum and parser helpers

The call site is the only consumer (verified by `grep`):

```
$ grep -rn "MarkdownBlock\|MarkdownBodyView" AppFeedback/
AppFeedback/Views/Issues/IssueCardView.swift:229: (call site)
AppFeedback/Views/Issues/IssueCardView.swift:372–525 (definitions)
```

The new view keeps the name `MarkdownBodyView` so the call site at line 229 doesn't need to change. Inside, it composes a `StructuredText` with:

- `.font(.system(size: 13))` — sets the ambient font that Textual's `DefaultParagraphStyle` and our custom `IssueBodyHeadingStyle` scale relative to.
- `.foregroundStyle(.primary)` — matches the current colour for paragraphs.
- `.textual.headingStyle(IssueBodyHeadingStyle())` — overrides Textual's default heading sizes (which would render H1 at ~30pt in a 13pt body) with the existing 17 / 15 / 14pt design.
- `.textual.textSelection(.enabled)` — this is the whole point of the refactor.
- `.frame(maxWidth: .infinity, alignment: .leading)` — same as today.

Textual's default `ListItemStyle`, `UnorderedListMarker` (`.disc` → `•`), and `OrderedListMarker` (`.decimal` → `1.`) match what we render today, so no override needed.

- [ ] **Step 1: Read the current `MarkdownBodyView` block once**

Run the `Read` tool on `AppFeedback/Views/Issues/IssueCardView.swift` for lines 370–530. Confirm the structure matches what's described above (private struct + private enum + private static parser functions). This guards against the file having shifted since the plan was written.

- [ ] **Step 2: Replace `MarkdownBodyView` and remove `MarkdownBlock`**

In `AppFeedback/Views/Issues/IssueCardView.swift`, replace the entire block from line 372 (`private struct MarkdownBodyView: View {`) through the end of `MarkdownBlock` (the closing `}` after `parseUnorderedItem`, around line 525) with:

```swift
private struct MarkdownBodyView: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .textual.headingStyle(IssueBodyHeadingStyle())
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IssueBodyHeadingStyle: StructuredText.HeadingStyle {
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
            .textual.blockSpacing(.fontScaled(top: 1.0, bottom: 0.4))
    }
}
```

Use the `Edit` tool with the exact old-string spanning the lines verified in Step 1.

- [ ] **Step 3: Add the `import Textual` at the top of the file**

Find the existing import block in `AppFeedback/Views/Issues/IssueCardView.swift` (it's at the very top — likely `import SwiftUI` and possibly others). Add `import Textual` immediately after `import SwiftUI`.

Use the `Edit` tool:
- old_string: `import SwiftUI`
- new_string: `import SwiftUI\nimport Textual`

If the file has other imports (e.g. `import AppKit` for macOS-only sections), confirm by reading the top 15 lines first and adjust the anchor so the edit is unique.

- [ ] **Step 4: Build for macOS**

Invoke the `zcode` skill: build the macOS scheme.
Expected: build succeeds. If you see "cannot find 'StructuredText' in scope," the `import Textual` in Step 3 didn't land in the right file. If you see "cannot find 'IssueBodyHeadingStyle' in scope," the Step 2 edit removed something accidentally.

- [ ] **Step 5: Build for iOS**

Invoke the `zcode` skill: build the iOS scheme.
Expected: build succeeds.

- [ ] **Step 6: Sanity-grep — no leftover references**

Run: `grep -n "MarkdownBlock" AppFeedback/Views/Issues/IssueCardView.swift`
Expected: no output (the enum and helpers are gone).

Run: `grep -cn "MarkdownBodyView" AppFeedback/Views/Issues/IssueCardView.swift`
Expected: `2` — the call site (line ~229) and the new struct definition.

- [ ] **Step 7: Commit**

```bash
git add AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "$(cat <<'EOF'
refactor(issue-card): render body via Textual for cross-block selection

Replaces the hand-rolled MarkdownBlock parser and per-block VStack
of Text views with a single StructuredText view. Selection now spans
the whole body as one continuous range on macOS and iOS.

A small IssueBodyHeadingStyle preserves the existing 17/15/14pt
heading sizes; everything else uses Textual's default styles.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Manual selection smoke test (macOS)

**Why manual:** This is a SwiftUI text-rendering and platform-text-selection change. There is no unit-testable application logic — the value being verified is "the user can drag from line A to line C in one motion and copy a single string."

- [ ] **Step 1: Run the macOS app**

Invoke the `zcode` skill: run the macOS scheme. Wait for the app to launch and show the issue feed.

- [ ] **Step 2: Find an issue whose body spans multiple blocks**

Locate issue **#332** ("Visual way to see 100% weekly limit in the tool bar") if it's in the visible feed, or any issue whose body has both a heading (line starting with `#`) and a paragraph, or two paragraphs separated by a blank line. Cards in the feed expand inline.

- [ ] **Step 3: Drag-select across blocks**

Click and hold at the start of the first line of the body, drag down past at least one paragraph break or heading boundary, release on a later line.

Expected:
- A continuous selection highlight spans the dragged range, including across the boundary that previously broke selection in `MarkdownBodyView`.
- No visual "gap" or split in the selection rectangle at block boundaries.

- [ ] **Step 4: Copy and verify pasteboard contents**

With the selection still active, press ⌘C. Then ⌘Tab into a text editor (Notes, TextEdit) and ⌘V.

Expected: the pasted text contains the entire selected range as one continuous string with appropriate `\n` line breaks between blocks (not just one block's content).

- [ ] **Step 5: Cmd+A inside the body**

Click once inside the body to focus it, then press ⌘A.

Expected: the entire body is highlighted as one selection. ⌘C → paste into a text editor produces the full body.

- [ ] **Step 6: Verify the existing "Copy" button is still functional**

Find the explicit copy affordance on the issue card (the small clipboard icon next to the issue number — `IssueCardView.swift:232` area). Click it.

Expected: the existing copyText (title + body + metadata) is on the pasteboard, same as before this refactor.

If any of Steps 3–6 fail, stop and report the failure rather than continuing to Task 5. The most likely failure modes:
- Selection still breaks at block boundaries → `import Textual` missing, or `.textual.textSelection(.enabled)` not applied.
- Heading sizes look wrong (way too big) → `IssueBodyHeadingStyle` not registered; verify the `.textual.headingStyle(...)` modifier is on the `StructuredText`, not on something else.

---

## Task 5: Manual selection smoke test (iOS)

- [ ] **Step 1: Run the iOS app in a simulator**

Invoke the `zcode` skill: run the iOS scheme on an iPhone simulator running iOS 18 or later.

- [ ] **Step 2: Find a multi-block issue and long-press inside the body**

Wait for the simulator to load the feed. Long-press inside the rendered body of any issue with more than one paragraph or a heading + paragraph.

Expected: the system text-selection UI appears with blue drag handles around an initial selection (a word or paragraph), and a popover menu with Copy / Look Up / Share.

- [ ] **Step 3: Drag the selection handles across a block boundary**

Drag one of the selection handles past the boundary between two paragraphs (or between a heading and the paragraph below it).

Expected: the selection extends continuously, including content from both blocks. This is the iOS-side validation that Textual's `UITextInput` conformance is providing real range selection, not just SwiftUI's "select all of one Text" behaviour.

- [ ] **Step 4: Tap Copy and paste into Notes**

Tap **Copy** in the popover. Open the Notes app in the simulator (or any text field) and paste.

Expected: the pasted text contains the full dragged range.

If iOS selection regresses to single-block-only, stop and report. Most likely cause: Textual's `TEXTUAL_ENABLE_TEXT_SELECTION` build flag is not active for iOS in the resolved package — verify by inspecting the resolved Package.resolved or by checking the Textual target settings in Xcode.

---

## Task 6: Final cleanup commit (only if needed)

The previous task commits leave the worktree clean. Run a final check:

- [ ] **Step 1: Verify clean worktree**

Run: `git status --short`
Expected: no output (everything committed).

If anything is uncommitted (e.g., a stray Xcode-generated `xcuserdata` directory), check whether it belongs in `.gitignore` and either stage and commit it or add an ignore rule.

- [ ] **Step 2: Verify the branch is ready to merge**

Run: `git log --oneline main..HEAD`
Expected: three commits on `worktree-textual-markdown-body` —
1. `chore(xcode): bump deployment targets to macOS 15 / iOS 18`
2. `chore(deps): add Textual 0.3.1 for selectable markdown rendering`
3. `refactor(issue-card): render body via Textual for cross-block selection`

(Plus the existing spec doc commit `docs(specs): …` that was made before this plan started.)

- [ ] **Step 3: Run the existing test suite once more**

Invoke the `zcode` skill: run all tests on both schemes.
Expected: all tests pass. (This refactor touches only the view layer for issue bodies — no test should be affected. If a test breaks, it points at an unrelated issue introduced by the deployment-target bump.)

---

## Risks revisited (engineer should be aware)

- **Heading typography may look slightly different.** Textual scales heading line-spacing relative to font-scale by default, and we keep that behaviour through the `.textual.blockSpacing(.fontScaled(top: 1.0, bottom: 0.4))` line in `IssueBodyHeadingStyle`. If the result looks visibly wrong, tweak those scalars in `IssueBodyHeadingStyle.makeBody` rather than fighting the system.
- **Block-spacing-between-paragraphs.** Textual's default `paragraphStyle` adds `blockSpacing(.fontScaled(top: 0.8))` — roughly the same visual gap as the current `VStack(spacing: 8)` in a 13pt body. If users complain about tightness/looseness, override `.textual.paragraphStyle(...)` rather than the global `lineSpacing`.
- **Pre-1.0 dependency.** Pinned to exact `0.3.1`. Future upgrades require a deliberate `Package.resolved` change and re-test.
- **The deployment-target bump excludes users on macOS 14 and iOS 17.** App Store Connect will keep serving the previous build to them.
