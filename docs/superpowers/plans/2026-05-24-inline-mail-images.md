# Inline Mail Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Surface inline-image MIME parts (multipart-related `<img src="cid:...">` attachments) as thumbnail tiles in the mail message viewer.

**Architecture:** Extend IMAP parse to keep parts with `Content-ID` + `image/*` MIME, add a `contentID` field on `MailAttachment`, render those rows as a thumbnail strip via a new `MailAttachmentThumbnailView` that mirrors the feedback-side thumbnail but uses `AttachmentDownloader` (IMAP) instead of `FeedbackAttachmentDownloader` (HTTPS). Tap → existing `QuickLookPresenter`.

**Tech Stack:** SwiftMail (`MessagePart.contentId`), SwiftData (`@Model` migration), SwiftUI, QuickLook, the shared `ThumbnailCache` from `2026-05-23-feedback-attachments-design.md` task F3.

**Source design:** `docs/superpowers/specs/2026-05-24-inline-mail-images-design.md`.

**Build:** `xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' build|test`. macOS deployment target 15.0. Run `xcodegen generate` after creating new files. WIP files in working tree pre-exist; do **not** stage them.

---

## File Structure

**New:**
- `AppFeedback/Views/Mail/MailAttachmentThumbnailView.swift` — image tile for inline mail attachments.

**Modified:**
- `AppFeedback/Models/MailAttachment.swift` — add `contentID: String?` + `isInlineImage: Bool` computed.
- `AppFeedback/Services/Mail/IMAPClient.swift` — capture inline-image parts; thread `contentID` through `ParsedAttachmentMeta` + insertion.
- `AppFeedback/Views/Mail/MailMessageRowView.swift` — split `attachments` into inline-images + regular, render inline-images as a thumbnail strip.

---

## Task 1: Add `contentID` to `MailAttachment`

**Files:**
- Modify: `AppFeedback/Models/MailAttachment.swift`

- [ ] **Step 1: Add the stored property + computed helper**

Read `AppFeedback/Models/MailAttachment.swift` first. After the existing `sizeBytes` property, add:

```swift
    var contentID: String? = nil
```

Then add a computed helper at the bottom of the class body (before the init):

```swift
    var isInlineImage: Bool {
        contentID != nil && mimeType.lowercased().hasPrefix("image/")
    }
```

Update the existing init to accept `contentID: String? = nil` as a trailing defaulted parameter so existing call sites compile:

```swift
    init(
        id: UUID = UUID(),
        messageID: String = "",
        partID: String = "",
        filename: String = "",
        mimeType: String = "",
        sizeBytes: Int = 0,
        contentID: String? = nil,
        message: MailMessage? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.partID = partID
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentID = contentID
        self.message = message
    }
```

(SwiftData rule: the new property must have a default value at the type level — already covered by `var contentID: String? = nil`.)

- [ ] **Step 2: Build**

```bash
cd ~/Developer/AppFeedback && xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. The new column is additive; CloudKit-syncable schemas handle defaulted optionals without migration steps.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Models/MailAttachment.swift
git commit -m "feat(mail): add contentID + isInlineImage to MailAttachment"
```

---

## Task 2: Capture inline-image parts during IMAP parse (TDD)

**Files:**
- Modify: `AppFeedback/Services/Mail/IMAPClient.swift`
- Modify: `AppFeedbackTests/AttachmentDownloaderTests.swift` (or add a new test file if the existing one isn't the right home — see Step 1)

The existing IMAP test surface is `AttachmentDownloaderTests.swift` per the pre-existing WIP. Tests of `IMAPClient.parse` static helper may live elsewhere — if so, place the new test there.

- [ ] **Step 1: Locate the existing IMAPClient parse-helper tests**

```bash
grep -rn "IMAPClient.parse\|ParsedAttachmentMeta\|@testable import AppFeedback" AppFeedbackTests/ --include="*.swift" | head
```

Pick the file that already exercises the static parse helper. If none, create `AppFeedbackTests/IMAPClientInlineImageTests.swift`. The plan below assumes a new file; adapt if you find an existing test class to extend.

- [ ] **Step 2: Write the failing test**

```swift
// AppFeedbackTests/IMAPClientInlineImageTests.swift
import XCTest
@testable import AppFeedback

final class IMAPClientInlineImageTests: XCTestCase {

    func test_inline_image_part_is_captured_with_contentID() {
        // Synthetic input — call whatever the existing parse helper takes.
        // The current public surface is IMAPClient's static parse helper at
        // ~/Developer/AppFeedback/AppFeedback/Services/Mail/IMAPClient.swift
        // around line 357. If the surface is not directly testable in isolation,
        // promote the structure-walking subroutine to an internal helper that
        // takes a [MessagePart] (or equivalent value-type stand-ins) and
        // returns [ParsedAttachmentMeta]. Tests against that.

        // Pseudocode — fill in based on actual ParsedAttachmentMeta shape:
        let parts = makeFakeStructure([
            FakePart(contentType: "text/html", disposition: nil, filename: nil, contentId: nil),
            FakePart(contentType: "image/png", disposition: "inline", filename: nil, contentId: "image001@example.com"),
        ])
        let attachments = IMAPClient.parseAttachments(from: parts)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].mimeType, "image/png")
        XCTAssertEqual(attachments[0].contentID, "image001@example.com")
    }
}
```

If `parseAttachments(from:)` doesn't yet exist as an internal-testable helper, the implementation step will refactor the inline closure in `IMAPClient.swift` line 328-344 into a named function. That's the right shape regardless — pure value-type input, easy to test.

If extracting the helper feels too invasive, **fall back** to a documentation-only test (a comment in the existing test file stating "inline-image capture is exercised by manual K1 verification") and rely on the implementation-level type changes being caught by the build. Document the choice in your report.

- [ ] **Step 3: Run, expect fail**

```bash
xcodegen generate
xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' test -only-testing AppFeedbackTests/IMAPClientInlineImageTests 2>&1 | tail -10
```

Expected: FAIL — either `parseAttachments` doesn't exist, or `ParsedAttachmentMeta.contentID` doesn't exist.

- [ ] **Step 4: Update `ParsedAttachmentMeta`**

In `IMAPClient.swift`, find the `struct ParsedAttachmentMeta`. Add:

```swift
    let contentID: String?
```

Adjust its memberwise init / call sites accordingly. Probably:

```swift
struct ParsedAttachmentMeta {
    let partID: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let contentID: String?
}
```

- [ ] **Step 5: Update the filter at line 328-344**

Replace the existing classification block with:

```swift
        let attachments: [ParsedAttachmentMeta] = structure.compactMap { part -> ParsedAttachmentMeta? in
            let ct = part.contentType.lowercased()
            let disp = part.disposition?.lowercased()
            let hasFilename = !(part.filename?.isEmpty ?? true)
            let isExplicitAttachment = disp == "attachment"
            let hasFileNotInline = hasFilename && disp != "inline"
            let isCalendar = ct.hasPrefix("text/calendar")
            let contentID = part.contentId.flatMap { $0.isEmpty ? nil : $0 }
            let isInlineImage = (disp == "inline" || disp == nil)
                                && contentID != nil
                                && ct.hasPrefix("image/")
            guard isExplicitAttachment || hasFileNotInline || isCalendar || isInlineImage else { return nil }
            return ParsedAttachmentMeta(
                partID: part.section.description,
                filename: part.suggestedFilename,
                mimeType: String(part.contentType.split(separator: ";").first ?? "application/octet-stream"),
                sizeBytes: part.data?.count ?? 0,
                contentID: contentID
            )
        }
```

Note: `part.contentId` in SwiftMail strips angle brackets by default (see `MessagePart+BodyStructure.swift:89`). Treat empty string as nil for defensive symmetry.

- [ ] **Step 6: Thread `contentID` into `MailAttachment` insertion**

Find where `MailAttachment(messageID:, partID:, filename:, mimeType:, sizeBytes:, ...)` is constructed from `ParsedAttachmentMeta`. Pass `contentID: meta.contentID` to the init.

- [ ] **Step 7: Run tests**

```bash
xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: previous green count + 1 new test (or whatever delta). 5 pre-existing keychain failures unchanged.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/Mail/IMAPClient.swift \
        AppFeedbackTests/IMAPClientInlineImageTests.swift \
        AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(mail): capture inline-image MIME parts during IMAP parse"
```

---

## Task 3: `MailAttachmentThumbnailView` + integrate into `MailMessageRowView`

**Files:**
- Create: `AppFeedback/Views/Mail/MailAttachmentThumbnailView.swift`
- Modify: `AppFeedback/Views/Mail/MailMessageRowView.swift`

- [ ] **Step 1: Write the thumbnail tile**

```swift
// AppFeedback/Views/Mail/MailAttachmentThumbnailView.swift
import SwiftUI

struct MailAttachmentThumbnailView: View {
    let attachment: MailAttachment
    let uid: UInt32
    let folder: String
    let folderBookmark: Data?
    let downloader: AttachmentDownloader?
    let thumbnailCache: ThumbnailCache
    let onTap: () -> Void

    @State private var thumbnail: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                if let thumb = thumbnail {
                    Image(platformImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if loadFailed {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let downloader, uid > 0 else { return }
        let key = "\(attachment.messageID)/\(attachment.partID)"
        if let cached = thumbnailCache.cached(for: keyURL(key)) {
            thumbnail = cached
            return
        }
        do {
            let path = try await downloader.download(
                messageID: attachment.messageID,
                uid: uid,
                folder: folder,
                partID: attachment.partID,
                filename: attachment.filename.isEmpty ? "inline-\(attachment.partID).img" : attachment.filename,
                folderBookmark: folderBookmark
            )
            thumbnail = await thumbnailCache.thumbnail(for: keyURL(key), localPath: path)
        } catch {
            loadFailed = true
        }
    }

    /// `ThumbnailCache` keys by URL — synthesize a stable pseudo-URL from the
    /// IMAP coordinates so two messages with the same inline-image bytes don't
    /// share a cache row.
    private func keyURL(_ key: String) -> URL {
        URL(string: "imap-inline:///\(key)")!
    }
}
```

`Image(platformImage:)` and `PlatformImage` are already declared elsewhere in the inbox (see `AttachmentThumbnailView.swift` and `ThumbnailCache.swift`). No re-declaration here.

- [ ] **Step 2: Update `MailMessageRowView`**

Read the current `MailMessageRowView.swift`. Locate the `attachmentsRow` property and the call site that includes it in the body.

Add two computed properties:

```swift
    private var inlineImages: [MailAttachment] { attachments.filter(\.isInlineImage) }
    private var regularAttachments: [MailAttachment] { attachments.filter { !$0.isInlineImage } }
```

Replace the existing `attachmentsRow` with:

```swift
    @ViewBuilder
    private var attachmentsRow: some View {
        if !inlineImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(inlineImages) { att in
                        MailAttachmentThumbnailView(
                            attachment: att,
                            uid: UInt32(max(0, message.uid)),
                            folder: message.folder,
                            folderBookmark: settingsStore.settings.attachmentFolderBookmark,
                            downloader: downloaderHolder?.downloader,
                            thumbnailCache: thumbnailCache,
                            onTap: { presentInlineGallery(startingAt: att) }
                        )
                    }
                }
            }
        }
        if !regularAttachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(regularAttachments) { attachment in
                    AttachmentChipView(
                        attachment: attachment,
                        uid: UInt32(max(0, message.uid)),
                        folder: message.folder,
                        downloader: downloaderHolder?.downloader,
                        folderBookmark: settingsStore.settings.attachmentFolderBookmark
                    )
                }
            }
        }
    }

    private func presentInlineGallery(startingAt target: MailAttachment) {
        guard let downloader = downloaderHolder?.downloader else { return }
        Task {
            var localURLs: [URL] = []
            var startIdx = 0
            for (i, att) in inlineImages.enumerated() {
                do {
                    let url = try await downloader.download(
                        messageID: att.messageID,
                        uid: UInt32(max(0, message.uid)),
                        folder: message.folder,
                        partID: att.partID,
                        filename: att.filename.isEmpty ? "inline-\(att.partID).img" : att.filename,
                        folderBookmark: settingsStore.settings.attachmentFolderBookmark
                    )
                    localURLs.append(url)
                    if att.id == target.id { startIdx = i }
                } catch {
                    // Skip failures; keep gallery intact for the rest.
                }
            }
            await MainActor.run {
                quickLook.present(urls: localURLs, startingAt: startIdx)
            }
        }
    }
```

Add `@Environment(QuickLookPresenter.self) private var quickLook` and `@Environment(ThumbnailCache.self) private var thumbnailCache` to the struct (alongside the existing environment objects).

- [ ] **Step 3: Regen + build**

```bash
cd ~/Developer/AppFeedback
xcodegen generate
xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: same passing count + 0 new failures.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Mail/MailAttachmentThumbnailView.swift \
        AppFeedback/Views/Mail/MailMessageRowView.swift \
        AppFeedback.xcodeproj/project.pbxproj
git commit -m "feat(mail): render inline images as thumbnail strip in MailMessageRowView"
```

---

## Manual verification

After Task 3:

1. Refresh the mail thread on issue #359 (Jake's "Token keeps expiring" report).
2. Confirm two thumbnail tiles appear below Jake's body text — one for each inline screenshot.
3. Tap either → Quick Look opens with both screenshots in a gallery, starting on the tapped one.
4. Confirm older threads with regular attachments still show chips in the chip row, not the thumbnail strip.

---

## Acceptance checklist

- [ ] `MailAttachment.contentID` field present with `nil` default; existing rows unaffected.
- [ ] `MailAttachment.isInlineImage` returns true iff `contentID != nil && mimeType.hasPrefix("image/")`.
- [ ] IMAP parse captures parts with `Content-ID` + `image/*` MIME that were previously dropped.
- [ ] Existing attachment classifications (explicit, named-non-inline, calendar) unchanged.
- [ ] `MailMessageRowView` shows inline-image thumbnails above the existing chip row.
- [ ] Tap on an inline thumbnail opens Quick Look with the full inline-image set.
- [ ] Build green; no test regressions (5 pre-existing keychain failures stay unchanged).
- [ ] Three commits, scoped per task.
