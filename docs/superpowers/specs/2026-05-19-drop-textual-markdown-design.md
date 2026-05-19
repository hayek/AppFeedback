# Drop Textual, render issue and mail bodies as plain text

**Date:** 2026-05-19
**Status:** Approved (design)
**Supersedes:** `2026-05-15-textual-markdown-body-design.md`

## Problem

Three commits ago (`ddac2c6` → `9fdf1e9`) we adopted [gonzalezreal/textual](https://github.com/gonzalezreal/textual) 0.3.1 to render issue titles and bodies as markdown with a unified text-selection coordinator. The library is pre-1.0 with an acknowledged-unstable API and ships its own per-block view tree, a custom selection coordinator scoped inside each `StructuredText`, and a transitive `swiftui-math` dependency.

In practice this has produced:

- Scroll hitches in `IssueListView` once the list grows past a few dozen cards.
- Hand-rolled workarounds for selection state (`@Observable TextSelectionFocus` + `.id(resetToken)` to recreate the view when focus moves to another card — see `IssueCardView.swift:471`).
- Heavier re-renders on translation toggle (`showOriginal` flip rebuilds the entire `StructuredText` tree).
- An API-unstable dependency we don't otherwise need.

The "unified title-through-body drag selection" we got from Textual is a nice-to-have that is not worth this cost.

## Decision

Remove Textual. Render issue and mail bodies with two native SwiftUI `Text` views — title (15pt semibold) and body (13pt) — with `.textSelection(.enabled)` per view. The body uses `AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace)` so inline formatting (bold, italic, links, inline code) still renders, but block-level markdown (`##` headings, `-` bullets) appears verbatim. This keeps the view tree at ~2 text views per card while preserving the most common inline formatting users encounter in issue bodies.

### Why inline-only attributed markdown, not raw text?

`AttributedString` markdown parsing happens once per body string at view-build time and produces a single attributed string the `Text` view renders natively. It costs effectively nothing per frame and was never the bottleneck. Showing `**bold**` literally would be a needless regression when SwiftUI gives us inline rendering for free.

### What we accept losing

| Lost capability | Why it's acceptable |
| --- | --- |
| Unified drag-selection from title across into body | Selection still works on each `Text`. The two fields are visually distinct anyway. |
| Rendered block headings inside body (`## section`) | Most bodies are short prose; bodies that quote markdown-formatted dashboards are rare. |
| Rendered bullet/numbered lists | `- item` and `1.` still read fine; whitespace is preserved so layout matches the source. |
| Configurable per-heading styles (`IssueBodyHeadingStyle`) | Not used outside Textual integration. |

## Architecture

### New component

Replace `MarkdownBodyView` (`IssueCardView.swift:438`) with `IssueBodyText` defined in the same file:

```swift
struct IssueBodyText: View {
    let title: String
    let body: String
    let titleTrailingReserve: CGFloat

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

The component takes plain title + plain body. Inline markdown in the body is parsed by Foundation. No second `plainBody:` initializer is needed because the inline parser already treats unmatched specials (e.g., a lone `*`) as literal characters.

### Call-site changes

- `IssueCardView.swift:219` — `MarkdownBodyView(title: titleText, bodyMarkdown: bodyText, titleTrailingReserve: metaColumnReserve)` becomes `IssueBodyText(title: titleText, body: bodyText, titleTrailingReserve: metaColumnReserve)`.
- `MailMessageRowView.swift:99` — `MarkdownBodyView(title: ..., plainBody: ...)` becomes `IssueBodyText(title: message.subject, body: showFull ? stripped.full : stripped.cleaned)`. Mail bodies are already plain-text-sanitized by `HTMLSanitizer`.

### Deletions

| Symbol | File:line | Reason |
| --- | --- | --- |
| `import Textual` | `IssueCardView.swift:2` | No longer used |
| `MarkdownBodyView` | `IssueCardView.swift:438-501` | Replaced |
| `IssueBodyHeadingStyle` | `IssueCardView.swift:503-522` | Textual-specific |
| `TextSelectionFocus` `@Observable` class | `IssueCardView.swift:428-436` | Native `.textSelection` handles focus implicitly |
| `@State private var textSelectionFocus` | `AppFeedbackApp.swift:31` | Env injection no longer needed |
| `.environment(textSelectionFocus)` | `AppFeedbackApp.swift:228` | Same |
| Textual SPM refs in `project.pbxproj` | lines 195-196, 533, 543, 889, 929, 1782-1790 | Drop the package |
| `textual` + `swiftui-math` pins in `Package.resolved` | — | Stale once Xcode resolves |

`swift-concurrency-extras` is pinned transitively from Textual; do not manually remove — SPM may keep it for another transitive consumer, and Xcode regenerates `Package.resolved` on next resolve.

## Testing

This is a UI rendering change with no model changes. Verification is visual + performance:

1. **Build both platforms** via `zcode` (macOS + iOS schemes). Compile must succeed.
2. **Manual scroll perf** on macOS — open a repo with 50+ issues, scroll rapidly through `IssueListView`. Compare to current Textual build; expect noticeably smoother scroll. Frame-hitch count should drop to zero on M-series Macs.
3. **Translation toggle perf** — on an issue with `hasTranslation`, toggle "Show original" / "Show translation" rapidly. Should feel instantaneous.
4. **Selection** — confirm `.textSelection(.enabled)` works for both title and body on macOS, and that copying selected body text still preserves whitespace.
5. **Mail rows** — open an issue with an attached mail thread; verify `MailMessageRowView` bodies render the same plain text they did before, including the "Show full text" / "Show cleaned text" toggle for quoted-reply stripping.
6. **Inline markdown** — find or craft a test issue body with `**bold**`, `*italic*`, `[link](url)`, and inline `` `code` ``; confirm they render styled. Confirm `##` and `-` lines appear verbatim (not styled, but readable).

## Risks

- **Inline markdown failures regress to plain string.** Already handled by the `try?` fallback to `AttributedString(body)`.
- **Long bodies on iOS may push layout costs into the main thread.** Native `Text` handles wrapping efficiently; this should not regress compared to either Textual or the original hand-rolled parser.
- **Users who relied on rendered bullets/headings** lose that. Mitigation: monitor feedback after deploy; if it matters, revisit with a slim hand-rolled block parser (Approach C in brainstorming) — but explicitly out of scope here.

## Out of scope

- Re-introducing any markdown block rendering (headings, lists, code fences). Plain text first; revisit only if user feedback demands it.
- Touching `SummaryPromptBuilder` or `IntelligenceService` markdown references — those are LLM prompt strings, not view code.
- Migrating other selectable text surfaces (e.g., comment views, attachment chips). Limited to the two call sites that wired up `MarkdownBodyView`.
