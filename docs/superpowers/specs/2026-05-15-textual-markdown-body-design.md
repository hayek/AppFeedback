# Textual-backed issue body rendering — design

Status: draft
Date: 2026-05-15

## Problem

The issue body in `IssueCardView` cannot be selected as one unit. Users
trying to copy the full body of an issue can only select individual
chunks. In the screenshot that prompted this work, a user could select
the last paragraph "Also. Thank you very much…" but could not extend the
selection up to include "Hello!" or "I reached 100%…".

The root cause is `MarkdownBodyView` (`IssueCardView.swift:416`):

- The parser splits the body into discrete `MarkdownBlock`s (heading,
  paragraph, list).
- The view renders one `Text` per block, and inside `.paragraph` a
  separate `Text` per source line.
- SwiftUI's `.textSelection(.enabled)` is scoped per-`Text`. Selections
  cannot cross from one `Text` view to another. This is a documented
  SwiftUI limitation, not a bug we can configure around.

## Goals

- A user can drag-select (macOS) or long-press "select all" (iOS) any
  contiguous span of the rendered issue body, including across headings,
  paragraphs, and list items.
- Inline markdown (bold/italic/links) keeps working.
- The visual presentation stays close to the current rendering: headings
  remain heavier, list bullets remain visible, paragraph spacing remains
  close to current.
- Copy via `IssueCardView`'s existing "Copy" path is unaffected (it
  already uses `displayedBody` directly).

## Non-goals

- Tables, code blocks, blockquotes, math, images, syntax highlighting —
  none appear in our issue bodies and none of the current parser cases
  produce them.
- Per-issue or per-theme custom Markdown styling.
- Reworking how the title or metadata rows render — only the body changes.

## Approach

Adopt [Textual](https://github.com/gonzalezreal/textual) (gonzalezreal,
MIT, v0.3.1, January 2026) as a Swift Package Manager dependency and
replace `MarkdownBodyView` with Textual's `StructuredText` view.

Textual is the only viable path that:

- Supports continuous selection across heading + paragraph + list as one
  range (it implements a bespoke text-selection engine on top of SwiftUI's
  layout pipeline rather than relying on per-`Text` selection).
- Works on both macOS and iOS with a single SwiftUI surface.

Vendoring Textual was considered and rejected (see _Alternatives
considered_): the library is 193 source files / ~520 KB, has two
mandatory transitive deps (`swift-concurrency-extras`, `swiftui-math`),
and uses platform APIs that require macOS 15 / iOS 18 either way. SPM
gets us version pinning via `Package.resolved` with none of the local
maintenance cost.

## Deployment target bump

Textual requires **macOS 15 / iOS 18**. The project currently targets
**macOS 14 / iOS 17** (`MACOSX_DEPLOYMENT_TARGET = 14.0`,
`IPHONEOS_DEPLOYMENT_TARGET = 17.0` in `project.pbxproj`).

This refactor raises both deployment targets:

- `MACOSX_DEPLOYMENT_TARGET = 15.0`
- `IPHONEOS_DEPLOYMENT_TARGET = 18.0`

Users below those OS versions will no longer receive updates on App Store
Connect. Existing v2.6 stays available to them.

## Components

### Removed

- `MarkdownBodyView` (`IssueCardView.swift:416–480`) — replaced by
  `StructuredText`.
- `MarkdownBlock` enum and its `parse` / `parseHeading` /
  `parseOrderedItem` / `parseUnorderedItem` static helpers
  (`IssueCardView.swift:482–569`) — Textual ships its own GitHub-Flavored
  Markdown parser via Foundation's `AttributedString` and its
  `MarkupParser` protocol.
- `inlineMarkdown(_:)` helper inside `MarkdownBodyView` — Textual handles
  inline markdown internally.

### Added

- SPM dependency on `gonzalezreal/textual` pinned to `0.3.1`.
- `IssueBodyHeadingStyle` struct (small, private, local) conforming to
  Textual's `StructuredText.HeadingStyle` to preserve the existing
  17 / 15 / 14pt heading sizes. Paragraphs, list items, and list markers
  inherit Textual's defaults — which already produce 13pt body, `•`
  bullets, and `1.` ordered markers when the ambient `.font(...)` is
  `.system(size: 13)`.
- The wrapper struct `MarkdownBodyView` keeps its name (the call site at
  `IssueCardView.swift:229` is unchanged) but its body becomes:
  `StructuredText(markdown: text).font(.system(size: 13)).textual.headingStyle(IssueBodyHeadingStyle()).textual.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)`.

Implementing only `HeadingStyle` (rather than the full `Style` protocol)
keeps the override surface to the one place where we diverge from
Textual's defaults. `Style` requires 10 associated types
(`HeadingStyle`, `ParagraphStyle`, `BlockQuoteStyle`, `CodeBlockStyle`,
`ListItemStyle`, `UnorderedListMarker`, `OrderedListMarker`, `TableStyle`,
`TableCellStyle`, `ThematicBreakStyle`) — declaring eight of them just to
say "use the default" is busywork.

### Unchanged

- `copyText` and the explicit Copy action — they use `issue.displayedBody`
  directly, not the rendered view.
- Translation logic and the surrounding ShimmeringText / "Apple
  Intelligence required" affordances.
- Title `.textSelection(.enabled)` at `IssueCardView.swift:214`.

## Styling strategy

Textual `StructuredText.Style` exposes per-element style protocols
(`HeadingStyle`, `ParagraphStyle`, `BlockQuoteStyle`, `CodeBlockStyle`,
`ListItemStyle`, etc.). We override only the three our content produces;
the rest inherit Textual's `.default` preset (which we will never hit at
runtime because the parser won't yield those blocks).

Concrete style values mirror current code:

| Element | Current | Textual style override |
|---|---|---|
| Body paragraph | `.system(size: 13)` primary | `paragraphStyle` font 13pt primary |
| Heading 1 | `.system(size: 17, weight: .semibold)` | `headingStyle` for `level == 1` |
| Heading 2 | `.system(size: 15, weight: .semibold)` | `headingStyle` for `level == 2` |
| Heading ≥3 | `.system(size: 14, weight: .semibold)` | `headingStyle` for `level >= 3` |
| List item | bullet `•` or `1.`, 13pt | `listItemStyle` matching marker |
| Block spacing | VStack spacing 8 | `BlockSpacingKey` (Textual env value) set to 8 |

## Data flow

Identical to today:

1. `Issue.displayedBody(translated:)` returns a plain string.
2. The view feeds that string straight to `StructuredText(...)`.
3. Textual parses, lays out, and renders it as one selectable unit.

## Selection behavior expected

- **macOS:** Drag-select across the entire body. Standard system menu
  (Copy / Look Up / Share). Cmd+A selects the whole body.
- **iOS:** Real range selection via Textual's UIKit interaction overlay
  (not just "select all" of one Text — Textual implements `UITextInput`
  internally). Tap-and-drag handles work like a UITextView.

## Error handling

Textual's parser is total: any string produces a renderable
`StructuredText` (raw text becomes one paragraph). No new error paths
needed in `IssueCardView`.

## Testing

- Build for both macOS and iOS targets in Debug.
- Manual smoke test with the screenshot's exact issue (#332) — drag-select
  from "Hello!" through "too little:)" in one motion and copy; verify
  pasteboard contents.
- Manual check that an issue containing a heading and a list (any of the
  longer ones) selects continuously across the block boundary.
- Manual iOS check on simulator (iOS 18) that long-press + drag handles
  produces a range selection.
- No new unit tests — there is no application logic to test; the
  refactor is purely view-layer adoption of a library.

## Alternatives considered

**Vendor Textual instead of SPM dependency.** Rejected. Same platform
floor required (macOS 15 / iOS 18), 193 files to maintain locally,
pre-1.0 churn means manual re-syncs, no upside vs the package since we
can pin to a specific tag in `Package.resolved`.

**Single `AttributedString` rendered by one `Text`.** Would work on
the current iOS 17 / macOS 14 floor without any dependency, but: (a)
SwiftUI `Text` ignores `paragraphSpacing` and `headIndent`, so list
hanging-indent and paragraph gaps degrade; (b) iOS still gets only
"select all" of the one Text, not real range selection; (c) inline
markdown parsing remains per-line and headings need run-level font
attributes. Smaller change but worse UX. Kept as a fallback if the
deployment-target bump is later rejected.

**`NSTextView` / `UITextView` via `*ViewRepresentable`.** Reimplements
what Textual already gives us, badly, with two platform code paths to
maintain. ~150 lines of bridging code plus theming, dynamic-type, and
intrinsic-size plumbing. Real range selection on both platforms, but
no markdown styling — we'd have to build heading/list rendering on top.
Strictly worse than adopting Textual once we've decided the floor bump
is acceptable.

**Adopt `swift-markdown-ui` (the predecessor).** Rejected. It is in
explicit maintenance mode per its own README, with development moved
to Textual. And it does not implement cross-block selection — Textual
exists specifically because gonzalezreal needed that feature and it
required a new architecture.

## Risk

- **Pre-1.0 dependency.** Textual is v0.3.1; API can change before 1.0.
  Mitigation: pin to `0.3.1` exactly in `Package.swift` (`.upToNextMinor(from: "0.3.1")`
  would be too loose — use `.exact("0.3.1")` instead).
- **Deployment-target bump excludes some users.** App Store Connect will
  serve v2.6 to anyone below macOS 15 / iOS 18.
- **Textual's selection engine is bespoke.** If a selection bug shows up,
  we can't fall back on Apple's NSTextView — we have to file an issue
  upstream or patch Textual via the local SPM source.
