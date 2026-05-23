# Feedback Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add image + file attachments to the AppFeedback SDK, render them in the inbox with Quick Look, and let inbox users send + receive attachments in mail threads.

**Architecture:** SDK uploads attachments to a `feedback-attachments` branch of the same GitHub repo via the Contents API, then embeds `raw.githubusercontent.com` URLs inside a `<!-- attachments-v1 -->` marker block in the issue body. Inbox parses the block, downloads on demand via the GitHub Contents API (private-repo-safe), caches locally via SwiftData, and presents through a shared `QuickLookPresenter`. Outbound mail composer gains an attachment picker; SDK-supplied attachments mirror into the email thread as a `{{feedback_attachments}}` template placeholder.

**Tech Stack:** Swift Package Manager (`AppFeedbackSDK`), XCTest, ImageIO (`CGImageSource`/`CGImageDestination`), SwiftUI, SwiftData, QuickLook (`QLPreviewPanel` macOS / `QLPreviewController` iOS), SwiftMail.

**Source design:** `docs/superpowers/specs/2026-05-23-feedback-attachments-design.md`.

**Two repos in play:**

- `~/Developer/AppFeedbackSDK/` — SPM package. SDK changes (Phases A–D) live here. Build/test with `swift build` and `swift test` from that directory.
- `~/Developer/AppFeedback/` — Xcode project (this repo). Inbox + mail changes (Phases E–K) live here. Build/test via the **zcode skill** (project rule: use zcode for all build/run/test/clean).

Phases ordered so each finishes a working, testable slice. Phases A–D can ship to the SDK independently and be released before E–K land in the app.

---

## File Structure

### SDK (`~/Developer/AppFeedbackSDK/`)

**New:**
- `Sources/AppFeedbackCore/FeedbackAttachment.swift` — public value type
- `Sources/AppFeedbackCore/FeedbackAttachmentError.swift` — validation error enum
- `Sources/AppFeedbackCore/FeedbackAttachmentValidator.swift` — internal validator
- `Sources/AppFeedbackCore/ImagePreprocessor.swift` — EXIF/GPS strip, HEIC→JPEG
- `Sources/AppFeedbackCore/Transport/AttachmentUploader.swift` — branch ensure + per-file upload
- `Sources/AppFeedbackUI/AttachmentStripSDK.swift` — picker/strip subview for `FeedbackSheet`
- `Tests/AppFeedbackCoreTests/TestSupport/URLProtocolStub.swift` — extracted shared stub
- `Tests/AppFeedbackCoreTests/FeedbackAttachmentValidatorTests.swift`
- `Tests/AppFeedbackCoreTests/ImagePreprocessorTests.swift`
- `Tests/AppFeedbackCoreTests/AttachmentBodyFormatTests.swift`
- `Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift`
- `Tests/AppFeedbackUITests/FeedbackSheetAttachmentsSmokeTests.swift`
- `Tests/AppFeedbackCoreTests/Fixtures/sample.heic` — 1×1 HEIC with GPS EXIF
- `Tests/AppFeedbackCoreTests/Fixtures/sample.jpg` — 1×1 JPEG with EXIF
- `Tests/AppFeedbackCoreTests/Fixtures/sample.png` — 1×1 PNG with iTXt
- `Tests/AppFeedbackCoreTests/Fixtures/sample.gif` — tiny GIF

**Modified:**
- `Sources/AppFeedbackCore/FeedbackReport.swift` — add `attachments` property
- `Sources/AppFeedbackCore/Errors.swift` — add `attachmentValidation`, `attachmentUpload` cases
- `Sources/AppFeedbackCore/BodyMarkers.swift` — add attachment marker constants
- `Sources/AppFeedbackCore/IssueBodyFormatter.swift` — emit attachments block between extras and votes footer
- `Sources/AppFeedbackCore/IssueBodyParser.swift` — parse block, expose `ParsedAttachment[]`
- `Sources/AppFeedbackCore/Transport/GitHubDirectTransport.swift` — two-phase submit
- `Sources/AppFeedbackUI/FeedbackSheet.swift` — picker button, drop target, paste handler, strip render
- `Tests/AppFeedbackCoreTests/GitHubDirectTransportTests.swift` — use shared stub
- `Tests/AppFeedbackCoreTests/IssueBodyParserTests.swift` — extend
- `Tests/AppFeedbackCoreTests/RoundtripTests.swift` — extend

### Inbox (`~/Developer/AppFeedback/`)

**New:**
- `AppFeedback/Models/FeedbackAttachmentRef.swift` — codable struct mirroring SDK's `ParsedAttachment`
- `AppFeedback/Models/FeedbackAttachmentLocal.swift` — SwiftData model
- `AppFeedback/Services/FeedbackAttachmentDownloader.swift` — actor + `FeedbackAttachmentLocalStore` + holder
- `AppFeedback/Services/QuickLookPresenter.swift` — macOS impl (NSResponder + QLPreviewPanel)
- `AppFeedback/Services/QuickLookPresenter+iOS.swift` — iOS impl (QLPreviewController)
- `AppFeedback/Services/ThumbnailCache.swift` — in-memory NSCache wrapper
- `AppFeedback/Views/Issues/AttachmentThumbnailView.swift`
- `AppFeedback/Views/Issues/AttachmentStripView.swift`
- `AppFeedback/Views/Mail/AttachmentChipsRow.swift` — shared chip row for compose/strip
- `AppFeedbackTests/FeedbackAttachmentDownloaderTests.swift`
- `AppFeedbackTests/MailComposerAttachmentsTests.swift`
- `AppFeedbackTests/AttachmentMirrorTests.swift`
- `AppFeedbackTests/IssueBodyParserShimAttachmentsTests.swift`

**Modified:**
- `AppFeedback/Models/CachedIssue.swift` — add `attachmentsJSON`
- `AppFeedback/Models/FeedbackIssue.swift` — add `attachments`
- `AppFeedback/Services/IssueBodyParser.swift` (shim) — pass attachments through
- `AppFeedback/Services/Mail/MailComposer.swift` — accept attachments, render `{{feedback_attachments}}`
- `AppFeedback/Views/Mail/ComposeRequest.swift` — add `attachments`
- `AppFeedback/Views/Mail/AttachmentChipView.swift` — route through `QuickLookPresenter`, add feedback init
- `AppFeedback/Views/Mail/InlineReplyView.swift` — picker, drop, paste
- `AppFeedback/Views/Mail/ComposeFormCore.swift` — picker, drop, paste
- `AppFeedback/Views/Issues/IssueCardView.swift` — embed `AttachmentStripView`
- `AppFeedback/ViewModels/ComposeMailViewModel.swift` — pass attachments through `PlaceholderContext` + composer
- `AppFeedback/App/AppFeedbackApp.swift` — register `QuickLookPresenter`, `FeedbackAttachmentLocalStore`, `FeedbackAttachmentDownloaderHolder`, `ThumbnailCache` in environment + SwiftData container

---

## Phase A — SDK: data types, validation, image preprocessing

### Task A1: Add `FeedbackAttachment` value type

**Files:**
- Create: `Sources/AppFeedbackCore/FeedbackAttachment.swift`

- [ ] **Step 1: Write the file**

```swift
// Sources/AppFeedbackCore/FeedbackAttachment.swift
import Foundation

/// A binary payload attached to a ``FeedbackReport``.
///
/// Build one per file the user picked, push into ``FeedbackReport/attachments``.
/// The SDK validates count + size + MIME type, image-preprocesses (EXIF strip,
/// HEIC→JPEG), then uploads to a `feedback-attachments` branch of the inbox repo
/// before creating the issue. See <doc:Attachments> for the wire contract.
public struct FeedbackAttachment: Sendable, Equatable {
    /// Display filename. Basename only — leading directories stripped. Sanitized at upload time.
    public let filename: String

    /// Canonical MIME type. Must be one of the SDK allowlist:
    /// `image/png`, `image/jpeg`, `image/heic`, `image/gif`,
    /// `text/plain`, `application/json`, `application/pdf`.
    public let mimeType: String

    /// Raw bytes. Images are re-encoded before upload to strip metadata.
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
```

- [ ] **Step 2: Build the SDK to verify it compiles**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/FeedbackAttachment.swift
git commit -m "feat(sdk): add FeedbackAttachment value type"
```

### Task A2: Add `FeedbackAttachmentError` and extend `FeedbackSubmissionError`

**Files:**
- Create: `Sources/AppFeedbackCore/FeedbackAttachmentError.swift`
- Modify: `Sources/AppFeedbackCore/Errors.swift`

- [ ] **Step 1: Create the validation error type**

```swift
// Sources/AppFeedbackCore/FeedbackAttachmentError.swift
import Foundation

/// Synchronous, pre-network validation failures from ``FeedbackAttachmentValidator``
/// and the SDK's image preprocessor. Surfaced via
/// ``FeedbackSubmissionError/attachmentValidation``.
public enum FeedbackAttachmentError: Error, Sendable, Equatable {
    case tooManyAttachments(limit: Int, got: Int)
    case fileTooLarge(filename: String, sizeBytes: Int, limit: Int)
    case totalSizeTooLarge(totalBytes: Int, limit: Int)
    case unsupportedMimeType(filename: String, mimeType: String)
    case imageProcessingFailed(filename: String)
}
```

- [ ] **Step 2: Read the current Errors.swift to find the enum**

```bash
cat ~/Developer/AppFeedbackSDK/Sources/AppFeedbackCore/Errors.swift
```

- [ ] **Step 3: Add the two new cases to `FeedbackSubmissionError`**

Inside the existing `FeedbackSubmissionError` enum body, append:

```swift
    /// Synchronous validation failure. No network was touched and no state changed.
    case attachmentValidation(FeedbackAttachmentError)

    /// Per-file upload failure. `filename` is empty when the failure occurred before
    /// any specific file (e.g. branch-ensure). Files uploaded before this one in the
    /// same submission remain as orphan blobs on the attachments branch.
    case attachmentUpload(filename: String, underlying: any Error & Sendable)
```

- [ ] **Step 4: Build**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/FeedbackAttachmentError.swift Sources/AppFeedbackCore/Errors.swift
git commit -m "feat(sdk): add attachment validation + upload error cases"
```

### Task A3: `FeedbackAttachmentValidator` (TDD)

**Files:**
- Create: `Sources/AppFeedbackCore/FeedbackAttachmentValidator.swift`
- Test: `Tests/AppFeedbackCoreTests/FeedbackAttachmentValidatorTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
// Tests/AppFeedbackCoreTests/FeedbackAttachmentValidatorTests.swift
import XCTest
@testable import AppFeedbackCore

final class FeedbackAttachmentValidatorTests: XCTestCase {

    private func att(name: String = "f.png", mime: String = "image/png", bytes: Int = 1024) -> FeedbackAttachment {
        FeedbackAttachment(filename: name, mimeType: mime, data: Data(count: bytes))
    }

    func test_empty_attachments_pass() throws {
        XCTAssertNoThrow(try FeedbackAttachmentValidator.validate([]))
    }

    func test_three_at_limit_pass() throws {
        let xs = [att(), att(), att()]
        XCTAssertNoThrow(try FeedbackAttachmentValidator.validate(xs))
    }

    func test_four_exceeds_count_limit() {
        let xs = [att(), att(), att(), att()]
        XCTAssertThrowsError(try FeedbackAttachmentValidator.validate(xs)) { error in
            guard case FeedbackAttachmentError.tooManyAttachments(let limit, let got) = error else {
                return XCTFail("expected tooManyAttachments, got \(error)")
            }
            XCTAssertEqual(limit, 3)
            XCTAssertEqual(got, 4)
        }
    }

    func test_per_file_size_limit() {
        let big = att(name: "big.png", bytes: 5 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try FeedbackAttachmentValidator.validate([big])) { error in
            guard case FeedbackAttachmentError.fileTooLarge(let name, let bytes, let limit) = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
            XCTAssertEqual(name, "big.png")
            XCTAssertEqual(bytes, 5 * 1024 * 1024 + 1)
            XCTAssertEqual(limit, 5 * 1024 * 1024)
        }
    }

    func test_total_size_limit() {
        let xs = [
            att(name: "a.png", bytes: 5 * 1024 * 1024),
            att(name: "b.png", bytes: 5 * 1024 * 1024),
            att(name: "c.png", bytes: 1),
        ]
        XCTAssertThrowsError(try FeedbackAttachmentValidator.validate(xs)) { error in
            guard case FeedbackAttachmentError.totalSizeTooLarge(let bytes, let limit) = error else {
                return XCTFail("expected totalSizeTooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, 10 * 1024 * 1024 + 1)
            XCTAssertEqual(limit, 10 * 1024 * 1024)
        }
    }

    func test_unsupported_mime_type() {
        let bad = att(mime: "application/zip")
        XCTAssertThrowsError(try FeedbackAttachmentValidator.validate([bad])) { error in
            guard case FeedbackAttachmentError.unsupportedMimeType(let name, let mime) = error else {
                return XCTFail("expected unsupportedMimeType, got \(error)")
            }
            XCTAssertEqual(name, "f.png")
            XCTAssertEqual(mime, "application/zip")
        }
    }

    func test_all_allowed_mime_types_pass() throws {
        let mimes = [
            "image/png", "image/jpeg", "image/heic", "image/gif",
            "text/plain", "application/json", "application/pdf",
        ]
        for m in mimes {
            XCTAssertNoThrow(
                try FeedbackAttachmentValidator.validate([att(mime: m)]),
                "expected \(m) to be allowed"
            )
        }
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter FeedbackAttachmentValidatorTests
```

Expected: FAIL — `FeedbackAttachmentValidator` is not defined.

- [ ] **Step 3: Implement the validator**

```swift
// Sources/AppFeedbackCore/FeedbackAttachmentValidator.swift
import Foundation

enum FeedbackAttachmentValidator {

    static let maxCount = 3
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxTotalBytes = 10 * 1024 * 1024
    static let allowedMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/heic",
        "image/gif",
        "text/plain",
        "application/json",
        "application/pdf",
    ]

    static func validate(_ attachments: [FeedbackAttachment]) throws {
        if attachments.count > maxCount {
            throw FeedbackAttachmentError.tooManyAttachments(limit: maxCount, got: attachments.count)
        }
        var total = 0
        for a in attachments {
            if !allowedMimeTypes.contains(a.mimeType) {
                throw FeedbackAttachmentError.unsupportedMimeType(filename: a.filename, mimeType: a.mimeType)
            }
            if a.data.count > maxFileBytes {
                throw FeedbackAttachmentError.fileTooLarge(filename: a.filename, sizeBytes: a.data.count, limit: maxFileBytes)
            }
            total += a.data.count
        }
        if total > maxTotalBytes {
            throw FeedbackAttachmentError.totalSizeTooLarge(totalBytes: total, limit: maxTotalBytes)
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter FeedbackAttachmentValidatorTests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/FeedbackAttachmentValidator.swift Tests/AppFeedbackCoreTests/FeedbackAttachmentValidatorTests.swift
git commit -m "feat(sdk): add FeedbackAttachmentValidator with size/count/mime rules"
```

### Task A4: `ImagePreprocessor` (TDD)

**Files:**
- Create: `Sources/AppFeedbackCore/ImagePreprocessor.swift`
- Test: `Tests/AppFeedbackCoreTests/ImagePreprocessorTests.swift`
- Create: `Tests/AppFeedbackCoreTests/Fixtures/sample.heic`
- Create: `Tests/AppFeedbackCoreTests/Fixtures/sample.jpg`
- Create: `Tests/AppFeedbackCoreTests/Fixtures/sample.png`
- Create: `Tests/AppFeedbackCoreTests/Fixtures/sample.gif`

- [ ] **Step 1: Add fixtures to `Package.swift`**

In `Package.swift`, locate the `.testTarget(name: "AppFeedbackCoreTests", ...)` and add a `resources` parameter (or extend the existing one):

```swift
.testTarget(
    name: "AppFeedbackCoreTests",
    dependencies: ["AppFeedbackCore"],
    resources: [.copy("Fixtures")]
),
```

- [ ] **Step 2: Generate fixtures via a one-off script**

Create `Tests/AppFeedbackCoreTests/Fixtures/` and generate four files using `sips` and `exiftool`. From the SDK repo root:

```bash
mkdir -p Tests/AppFeedbackCoreTests/Fixtures
cd Tests/AppFeedbackCoreTests/Fixtures
# 1×1 JPEG with EXIF + GPS
sips -s format jpeg --resampleHeightWidth 1 1 /System/Library/Desktop\ Pictures/Solid\ Colors/Black.png --out sample.jpg
exiftool -overwrite_original -GPSLatitude=37.7749 -GPSLongitude=-122.4194 -GPSLatitudeRef=N -GPSLongitudeRef=W sample.jpg
# 1×1 PNG with iTXt
sips -s format png --resampleHeightWidth 1 1 /System/Library/Desktop\ Pictures/Solid\ Colors/Black.png --out sample.png
exiftool -overwrite_original -Comment="sensitive-data" sample.png
# 1×1 HEIC with GPS
sips -s format heic --resampleHeightWidth 1 1 /System/Library/Desktop\ Pictures/Solid\ Colors/Black.png --out sample.heic
exiftool -overwrite_original -GPSLatitude=37.7749 -GPSLongitude=-122.4194 -GPSLatitudeRef=N -GPSLongitudeRef=W sample.heic
# Tiny GIF (8-byte 1×1)
printf 'GIF89a\x01\x00\x01\x00\x00\x00\x00\x21\xF9\x04\x00\x00\x00\x00\x00\x2C\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3B' > sample.gif
```

If `exiftool` is not available, skip the metadata-injection lines and add a note that the GPS assertions will be a no-op — that's fine for a starter; iterate later.

- [ ] **Step 3: Write the failing test file**

```swift
// Tests/AppFeedbackCoreTests/ImagePreprocessorTests.swift
import XCTest
import ImageIO
@testable import AppFeedbackCore

final class ImagePreprocessorTests: XCTestCase {

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    private func metadataDict(_ data: Data) -> [String: Any] {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
    }

    func test_jpeg_input_emits_jpeg_output_without_gps() throws {
        let input = FeedbackAttachment(filename: "in.jpg", mimeType: "image/jpeg", data: fixture("sample.jpg"))
        let out = try ImagePreprocessor.process(input)
        XCTAssertEqual(out.mimeType, "image/jpeg")
        XCTAssertEqual(out.filename, "in.jpg")
        let props = metadataDict(out.data)
        XCTAssertNil(props["{GPS}"], "GPS metadata should be stripped")
    }

    func test_heic_input_transcodes_to_jpeg_and_renames_extension() throws {
        let input = FeedbackAttachment(filename: "shot.heic", mimeType: "image/heic", data: fixture("sample.heic"))
        let out = try ImagePreprocessor.process(input)
        XCTAssertEqual(out.mimeType, "image/jpeg")
        XCTAssertEqual(out.filename, "shot.jpg")
        let props = metadataDict(out.data)
        XCTAssertNil(props["{GPS}"], "GPS metadata should be stripped")
    }

    func test_png_input_emits_png_output() throws {
        let input = FeedbackAttachment(filename: "in.png", mimeType: "image/png", data: fixture("sample.png"))
        let out = try ImagePreprocessor.process(input)
        XCTAssertEqual(out.mimeType, "image/png")
        XCTAssertEqual(out.filename, "in.png")
    }

    func test_gif_is_passed_through_unchanged() throws {
        let bytes = fixture("sample.gif")
        let input = FeedbackAttachment(filename: "anim.gif", mimeType: "image/gif", data: bytes)
        let out = try ImagePreprocessor.process(input)
        XCTAssertEqual(out.data, bytes, "GIF should be byte-identical")
        XCTAssertEqual(out.mimeType, "image/gif")
        XCTAssertEqual(out.filename, "anim.gif")
    }

    func test_non_image_is_bypassed() throws {
        let bytes = Data("hello".utf8)
        let input = FeedbackAttachment(filename: "log.txt", mimeType: "text/plain", data: bytes)
        let out = try ImagePreprocessor.process(input)
        XCTAssertEqual(out.data, bytes)
        XCTAssertEqual(out.mimeType, "text/plain")
        XCTAssertEqual(out.filename, "log.txt")
    }

    func test_unreadable_image_throws_processing_failed() {
        let input = FeedbackAttachment(filename: "broken.jpg", mimeType: "image/jpeg", data: Data([0x00, 0x01, 0x02]))
        XCTAssertThrowsError(try ImagePreprocessor.process(input)) { error in
            guard case FeedbackAttachmentError.imageProcessingFailed(let name) = error else {
                return XCTFail("expected imageProcessingFailed, got \(error)")
            }
            XCTAssertEqual(name, "broken.jpg")
        }
    }
}
```

- [ ] **Step 4: Run to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter ImagePreprocessorTests
```

Expected: FAIL — `ImagePreprocessor` not defined.

- [ ] **Step 5: Implement `ImagePreprocessor`**

```swift
// Sources/AppFeedbackCore/ImagePreprocessor.swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Strips metadata (EXIF/GPS) and transcodes HEIC→JPEG before upload.
///
/// Cross-platform — no `#if`s; ImageIO is on every Apple platform.
enum ImagePreprocessor {

    static func process(_ attachment: FeedbackAttachment) throws -> FeedbackAttachment {
        switch attachment.mimeType {
        case "image/heic":
            return try transcode(attachment, to: UTType.jpeg, mime: "image/jpeg", swappingExtensionTo: "jpg")
        case "image/jpeg":
            return try transcode(attachment, to: UTType.jpeg, mime: "image/jpeg", swappingExtensionTo: nil)
        case "image/png":
            return try transcode(attachment, to: UTType.png, mime: "image/png", swappingExtensionTo: nil)
        case "image/gif":
            return attachment   // pass-through preserves animation
        default:
            return attachment   // non-images bypass
        }
    }

    private static func transcode(
        _ attachment: FeedbackAttachment,
        to type: UTType,
        mime: String,
        swappingExtensionTo newExtension: String?
    ) throws -> FeedbackAttachment {
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw FeedbackAttachmentError.imageProcessingFailed(filename: attachment.filename)
        }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw FeedbackAttachmentError.imageProcessingFailed(filename: attachment.filename)
        }
        // Pass empty options dict — drops all source metadata (EXIF, GPS, iTXt, etc.).
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FeedbackAttachmentError.imageProcessingFailed(filename: attachment.filename)
        }
        let newFilename: String
        if let newExtension {
            let stem = (attachment.filename as NSString).deletingPathExtension
            newFilename = "\(stem).\(newExtension)"
        } else {
            newFilename = attachment.filename
        }
        return FeedbackAttachment(filename: newFilename, mimeType: mime, data: output as Data)
    }
}
```

- [ ] **Step 6: Run to confirm they pass**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter ImagePreprocessorTests
```

Expected: all PASS. If GPS strip assertions fail because fixtures lack GPS, regenerate fixtures with `exiftool` or relax those two assertions to `// requires exiftool fixtures`.

- [ ] **Step 7: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/ImagePreprocessor.swift \
        Tests/AppFeedbackCoreTests/ImagePreprocessorTests.swift \
        Tests/AppFeedbackCoreTests/Fixtures/ \
        Package.swift
git commit -m "feat(sdk): add ImagePreprocessor (strip metadata, HEIC→JPEG)"
```

### Task A5: Extend `FeedbackReport.attachments`

**Files:**
- Modify: `Sources/AppFeedbackCore/FeedbackReport.swift`

- [ ] **Step 1: Append the `attachments` property and update the init**

After the `extraFields` property in the existing struct body, add:

```swift
    /// Files attached to this submission. The SDK validates count + size + MIME
    /// type, image-preprocesses, then uploads to a `feedback-attachments` branch
    /// of the inbox repo. URLs are embedded in the issue body inside a
    /// `<!-- attachments-v1 -->` marker block.
    public var attachments: [FeedbackAttachment]
```

Update the `init` signature to:

```swift
    public init(
        type: FeedbackType,
        title: String,
        description: String,
        contactEmail: String? = nil,
        extraFields: [String: String] = [:],
        attachments: [FeedbackAttachment] = []
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.contactEmail = contactEmail
        self.extraFields = extraFields
        self.attachments = attachments
    }
```

- [ ] **Step 2: Build the package and run all tests**

```bash
cd ~/Developer/AppFeedbackSDK && swift build && swift test
```

Expected: existing tests still pass; new types compile.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/FeedbackReport.swift
git commit -m "feat(sdk): add attachments to FeedbackReport"
```

---

## Phase B — SDK: body wire format

### Task B1: Add attachment markers to `BodyMarker`

**Files:**
- Modify: `Sources/AppFeedbackCore/BodyMarkers.swift`

- [ ] **Step 1: Append new constants**

Inside the `BodyMarker` enum, after `votesFooter`, add:

```swift
    static let attachmentsOpen = "<!-- attachments-v1 -->"
    static let attachmentsClose = "<!-- /attachments-v1 -->"
    static let attachmentsHeader = "## Attachments"
```

- [ ] **Step 2: Build**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/BodyMarkers.swift
git commit -m "feat(sdk): add attachments-v1 body markers"
```

### Task B2: `IssueBodyFormatter` emits attachments block (TDD)

**Files:**
- Modify: `Sources/AppFeedbackCore/IssueBodyFormatter.swift`
- Create: `Tests/AppFeedbackCoreTests/AttachmentBodyFormatTests.swift`

This task uses an `UploadedAttachment` type that doesn't exist yet — it's the link between an uploaded file and its `FeedbackAttachment` metadata. Define it here.

- [ ] **Step 1: Write the failing test file**

```swift
// Tests/AppFeedbackCoreTests/AttachmentBodyFormatTests.swift
import XCTest
@testable import AppFeedbackCore

final class AttachmentBodyFormatTests: XCTestCase {

    private let device = DeviceInfo(
        appName: "AcmeApp", appVersion: "1.0", buildNumber: "1",
        model: "Mac", osName: "macOS", osVersion: "Version 15.1"
    )

    func test_empty_attachments_emits_no_markers() {
        let report = FeedbackReport(type: .bug, title: "T", description: "Desc")
        let body = IssueBodyFormatter.format(report: report, deviceInfo: device, uploaded: [])
        XCTAssertFalse(body.contains(BodyMarker.attachmentsOpen))
        XCTAssertFalse(body.contains(BodyMarker.attachmentsClose))
    }

    func test_image_entry_uses_image_embed_markdown() {
        let report = FeedbackReport(type: .bug, title: "T", description: "Desc")
        let uploaded = [
            UploadedAttachment(
                filename: "screenshot.png",
                mimeType: "image/png",
                sizeBytes: 1234,
                url: URL(string: "https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/uuid/screenshot.png")!
            )
        ]
        let body = IssueBodyFormatter.format(report: report, deviceInfo: device, uploaded: uploaded)
        XCTAssertTrue(body.contains(BodyMarker.attachmentsOpen))
        XCTAssertTrue(body.contains("![screenshot.png](https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/uuid/screenshot.png) — image/png"))
        XCTAssertTrue(body.contains(BodyMarker.attachmentsClose))
    }

    func test_file_entry_uses_link_markdown() {
        let report = FeedbackReport(type: .bug, title: "T", description: "Desc")
        let uploaded = [
            UploadedAttachment(
                filename: "crash.log",
                mimeType: "text/plain",
                sizeBytes: 4321,
                url: URL(string: "https://example.com/crash.log")!
            )
        ]
        let body = IssueBodyFormatter.format(report: report, deviceInfo: device, uploaded: uploaded)
        XCTAssertTrue(body.contains("[crash.log](https://example.com/crash.log) — text/plain"))
        XCTAssertFalse(body.contains("![crash.log]"))
    }

    func test_attachments_block_appears_before_votes_footer() {
        let report = FeedbackReport(type: .bug, title: "T", description: "Desc")
        let uploaded = [
            UploadedAttachment(
                filename: "a.png", mimeType: "image/png", sizeBytes: 1,
                url: URL(string: "https://example.com/a.png")!
            )
        ]
        let body = IssueBodyFormatter.format(report: report, deviceInfo: device, uploaded: uploaded)
        let openRange = body.range(of: BodyMarker.attachmentsOpen)!
        let votesRange = body.range(of: BodyMarker.votesFooter)!
        XCTAssertLessThan(openRange.lowerBound, votesRange.lowerBound,
                          "attachments block must precede votes footer")
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter AttachmentBodyFormatTests
```

Expected: FAIL — `UploadedAttachment` and the `uploaded:` parameter don't exist.

- [ ] **Step 3: Add `UploadedAttachment` and extend the formatter**

In `Sources/AppFeedbackCore/IssueBodyFormatter.swift`, at the top of the file (after `import Foundation`), add:

```swift
/// Per-attachment record after the SDK has uploaded bytes to GitHub. Drives
/// the body renderer and is the parsed counterpart on the inbox side
/// (`ParsedAttachment`).
public struct UploadedAttachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let url: URL

    public init(filename: String, mimeType: String, sizeBytes: Int, url: URL) {
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.url = url
    }
}
```

Replace the existing `format(report:deviceInfo:)` with:

```swift
    public static func format(report: FeedbackReport, deviceInfo: DeviceInfo) -> String {
        format(report: report, deviceInfo: deviceInfo, uploaded: [])
    }

    public static func format(
        report: FeedbackReport,
        deviceInfo: DeviceInfo,
        uploaded: [UploadedAttachment]
    ) -> String {
        var body = report.description

        body += "\n\n\(BodyMarker.horizontalRule)\n**\(BodyMarker.deviceHeader)**\n\(deviceInfo.renderForIssueBody())"

        if let email = report.contactEmail, !email.isEmpty {
            body += "\n\n**\(BodyMarker.contactEmailLabel)**\n\(email)"
        }

        for key in report.extraFields.keys.sorted() {
            body += "\n\n**\(key):**\n\(report.extraFields[key]!)"
        }

        if !uploaded.isEmpty {
            body += "\n\n\(BodyMarker.attachmentsOpen)\n\(BodyMarker.attachmentsHeader)\n"
            for a in uploaded {
                let prefix = a.mimeType.hasPrefix("image/") ? "!" : ""
                let size = ByteCountFormatter.string(fromByteCount: Int64(a.sizeBytes), countStyle: .file)
                body += "\n\(prefix)[\(a.filename)](\(a.url.absoluteString)) — \(a.mimeType), \(size)\n"
            }
            body += "\n\(BodyMarker.attachmentsClose)"
        }

        body += "\n\n\(BodyMarker.horizontalRule)\n\(BodyMarker.votesFooter)"
        return body
    }
```

- [ ] **Step 4: Run tests, expect pass**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter AttachmentBodyFormatTests
```

Expected: all PASS. Existing `IssueBodyFormatterTests` / `RoundtripTests` should also still pass because the no-attachments path is preserved by the overload.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/IssueBodyFormatter.swift \
        Tests/AppFeedbackCoreTests/AttachmentBodyFormatTests.swift
git commit -m "feat(sdk): IssueBodyFormatter emits attachments-v1 block"
```

### Task B3: `IssueBodyParser` parses attachments block (TDD)

**Files:**
- Modify: `Sources/AppFeedbackCore/IssueBodyParser.swift`
- Modify: `Tests/AppFeedbackCoreTests/AttachmentBodyFormatTests.swift` (append parser tests)

- [ ] **Step 1: Append parser tests to `AttachmentBodyFormatTests.swift`**

Append to the same file:

```swift
final class AttachmentBodyParseTests: XCTestCase {

    func test_absent_block_yields_empty_attachments() {
        let body = "Just a description.\n\n---\n👍 Votes: 0"
        let parsed = IssueBodyParser.parse(body)
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func test_parses_image_and_file_entries() {
        let body = """
        Desc

        <!-- attachments-v1 -->
        ## Attachments

        ![shot.png](https://example.com/shot.png) — image/png, 312 KB

        [log.txt](https://example.com/log.txt) — text/plain, 4.1 KB

        <!-- /attachments-v1 -->

        ---
        👍 Votes: 0
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 2)
        XCTAssertEqual(parsed.attachments[0].filename, "shot.png")
        XCTAssertEqual(parsed.attachments[0].mimeType, "image/png")
        XCTAssertEqual(parsed.attachments[0].url.absoluteString, "https://example.com/shot.png")
        XCTAssertEqual(parsed.attachments[1].filename, "log.txt")
        XCTAssertEqual(parsed.attachments[1].mimeType, "text/plain")
    }

    func test_missing_suffix_falls_back_to_extension_inference() {
        let body = """
        <!-- attachments-v1 -->
        ## Attachments

        ![s.png](https://example.com/s.png)

        [crash.log](https://example.com/crash.log)

        <!-- /attachments-v1 -->
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 2)
        XCTAssertEqual(parsed.attachments[0].mimeType, "image/png")
        XCTAssertEqual(parsed.attachments[1].mimeType, "text/plain")
        XCTAssertNil(parsed.attachments[0].sizeBytes)
    }

    func test_malformed_line_is_skipped() {
        let body = """
        <!-- attachments-v1 -->
        ## Attachments

        not a link line
        ![good.png](https://example.com/g.png) — image/png, 1 KB

        <!-- /attachments-v1 -->
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "good.png")
    }

    func test_future_version_marker_is_ignored() {
        let body = """
        <!-- attachments-v2 -->
        opaque future content
        <!-- /attachments-v2 -->
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func test_missing_close_marker_parses_through_to_end() {
        let body = """
        <!-- attachments-v1 -->
        ![a.png](https://example.com/a.png) — image/png, 1 KB
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 1)
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter AttachmentBodyParseTests
```

Expected: FAIL — `parsed.attachments` and `ParsedAttachment` don't exist yet.

- [ ] **Step 3: Add `ParsedAttachment` and extend the parser**

In `Sources/AppFeedbackCore/IssueBodyParser.swift`, after the existing `import Foundation` and before the existing `ParsedBody` struct, add:

```swift
import UniformTypeIdentifiers
```

And add the struct:

```swift
public struct ParsedAttachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let url: URL
    public let sizeBytes: Int?

    public init(filename: String, mimeType: String, url: URL, sizeBytes: Int?) {
        self.filename = filename
        self.mimeType = mimeType
        self.url = url
        self.sizeBytes = sizeBytes
    }
}
```

Add `attachments` to `ParsedBody`:

```swift
    public var attachments: [ParsedAttachment] = []
```

In the existing `parse(_:)` function, before the final `return ParsedBody(...)`, add a call to a new helper:

```swift
        parsed.attachments = parseAttachments(in: raw)
```

(Replace whatever the parser currently returns to ensure the new field is populated.)

Add the helper at the bottom of the file:

```swift
private func parseAttachments(in raw: String) -> [ParsedAttachment] {
    guard let openRange = raw.range(of: BodyMarker.attachmentsOpen) else { return [] }
    let afterOpen = openRange.upperBound
    let end = raw.range(of: BodyMarker.attachmentsClose, range: afterOpen..<raw.endIndex)?.lowerBound ?? raw.endIndex
    let block = raw[afterOpen..<end]

    var results: [ParsedAttachment] = []
    for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let parsed = parseAttachmentLine(line) else { continue }
        results.append(parsed)
    }
    return results
}

private func parseAttachmentLine(_ line: String) -> ParsedAttachment? {
    // Image: ![name](url) optional " — mime, size"
    // File:  [name](url)  optional " — mime, size"
    let imagePrefix = "!["
    let filePrefix = "["
    var working = line
    let isImage: Bool
    if working.hasPrefix(imagePrefix) {
        isImage = true
        working.removeFirst(imagePrefix.count)
    } else if working.hasPrefix(filePrefix) {
        isImage = false
        working.removeFirst(filePrefix.count)
    } else {
        return nil
    }

    guard let nameEnd = working.range(of: "](") else { return nil }
    let filename = String(working[..<nameEnd.lowerBound])
    let afterName = working[nameEnd.upperBound...]
    guard let urlEnd = afterName.firstIndex(of: ")") else { return nil }
    let urlString = String(afterName[..<urlEnd])
    guard let url = URL(string: urlString) else { return nil }
    let rest = afterName[afterName.index(after: urlEnd)...].trimmingCharacters(in: .whitespaces)

    var mime: String?
    var size: Int?
    if rest.hasPrefix("—") {
        let suffix = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        let parts = suffix.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if let m = parts.first { mime = m }
        if parts.count > 1 { size = Self.parseHumanByteCount(parts[1]) }
    }

    let resolvedMime = mime ?? Self.inferMimeFromURL(url)
    // Sanity check: image-prefix line should resolve to an image/* MIME, file-prefix should not.
    // We don't strictly enforce — just take what we got.
    _ = isImage

    return ParsedAttachment(filename: filename, mimeType: resolvedMime, url: url, sizeBytes: size)
}

private enum Self_ParseHelpers {} // dummy to avoid forward-ref issues

extension IssueBodyParser {
    static func parseHumanByteCount(_ s: String) -> Int? {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useAll]
        formatter.countStyle = .file
        // No public reverse parser — handle the common cases ourselves.
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        guard let numStr = parts.first, let num = Double(numStr) else { return nil }
        let unit = parts.count > 1 ? parts[1].uppercased() : "B"
        switch unit {
        case "BYTES", "B": return Int(num)
        case "KB":         return Int(num * 1_000)
        case "MB":         return Int(num * 1_000_000)
        case "GB":         return Int(num * 1_000_000_000)
        default:           return Int(num)
        }
    }

    static func inferMimeFromURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
```

Note: this file uses `IssueBodyParser` as both a namespace (the existing `enum IssueBodyParser`) and a place to hang static helpers. Adapt to whatever shape it currently has — if it's a `public enum`, the `extension IssueBodyParser { ... }` block is correct. If it's a `public struct`, same syntax applies.

- [ ] **Step 4: Run the parser tests**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter AttachmentBodyParseTests
```

Expected: all PASS.

- [ ] **Step 5: Run all SDK tests to confirm nothing regressed**

```bash
cd ~/Developer/AppFeedbackSDK && swift test
```

Expected: every existing test plus the new ones PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/IssueBodyParser.swift \
        Tests/AppFeedbackCoreTests/AttachmentBodyFormatTests.swift
git commit -m "feat(sdk): IssueBodyParser extracts attachments-v1 block"
```

---

## Phase C — SDK: transport (two-phase submit)

### Task C1: Extract `URLProtocolStub` to a shared test helper

**Files:**
- Create: `Tests/AppFeedbackCoreTests/TestSupport/URLProtocolStub.swift`
- Modify: `Tests/AppFeedbackCoreTests/GitHubDirectTransportTests.swift`

- [ ] **Step 1: Create the shared helper file**

Copy the `URLProtocolStub` class and `URLRequestSnapshot` struct verbatim from `GitHubDirectTransportTests.swift` (lines 95–end of file) into a new file:

```swift
// Tests/AppFeedbackCoreTests/TestSupport/URLProtocolStub.swift
import Foundation

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequestSnapshot) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var sequence: [Handler] = []

    static func respond(with handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        Self.sequence = []
    }

    /// Use when the test exercises a multi-request flow. Each subsequent call to
    /// `startLoading` consumes one handler from the front of the queue.
    static func enqueue(_ handlers: [Handler]) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = nil
        Self.sequence = handlers
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        Self.handler = nil
        Self.sequence = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let active: Handler?
        if let single = Self.handler {
            active = single
        } else if !Self.sequence.isEmpty {
            active = Self.sequence.removeFirst()
        } else {
            active = nil
        }
        Self.lock.unlock()
        guard let active else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let snapshot = URLRequestSnapshot(request: request)
            let (response, data) = try active(snapshot)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct URLRequestSnapshot {
    let url: URL?
    let httpMethod: String?
    private let headerFields: [String: String]
    let bodyData: Data?

    init(request: URLRequest) {
        self.url = request.url
        self.httpMethod = request.httpMethod
        self.headerFields = request.allHTTPHeaderFields ?? [:]
        if let body = request.httpBody {
            self.bodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                collected.append(buf, count: read)
            }
            self.bodyData = collected
        } else {
            self.bodyData = nil
        }
    }

    func value(forHTTPHeaderField name: String) -> String? { headerFields[name] }
}
```

- [ ] **Step 2: Remove the now-duplicated classes from `GitHubDirectTransportTests.swift`**

Delete lines 93 through end of file in `GitHubDirectTransportTests.swift` (the `URLProtocolStub` and `URLRequestSnapshot` definitions). Replace the `private` references in tests with no prefix (they're now top-level in the test target).

The existing test file already calls `URLProtocolStub.respond(with: ...)` — since the new class is no longer `private`, those calls compile as-is.

- [ ] **Step 3: Run existing transport tests**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportTests
```

Expected: all PASS (zero functional change).

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Tests/AppFeedbackCoreTests/TestSupport/URLProtocolStub.swift \
        Tests/AppFeedbackCoreTests/GitHubDirectTransportTests.swift
git commit -m "refactor(sdk): extract URLProtocolStub to shared TestSupport"
```

### Task C2: `AttachmentUploader` — branch ensure (TDD)

**Files:**
- Create: `Sources/AppFeedbackCore/Transport/AttachmentUploader.swift`
- Create: `Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift`

- [ ] **Step 1: Write the failing test class with two branch-ensure cases**

```swift
// Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift
import XCTest
@testable import AppFeedbackCore

final class GitHubDirectTransportAttachmentTests: XCTestCase {

    override func setUp() { super.setUp(); URLProtocolStub.reset() }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    private func ok(_ url: URL, body: String = "{}") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         body.data(using: .utf8)!)
    }
    private func created(_ url: URL, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!,
         body.data(using: .utf8)!)
    }
    private func notFound(_ url: URL) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
    }

    func test_branch_already_exists_short_circuits() async throws {
        URLProtocolStub.respond { req in
            XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/branches/feedback-attachments")
            XCTAssertEqual(req.httpMethod, "GET")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"name":"feedback-attachments"}"#.data(using: .utf8)!
            )
        }
        let uploader = AttachmentUploader(
            owner: "octocat", repo: "feedback", token: "t", session: makeSession()
        )
        try await uploader.ensureBranchExists()
    }

    func test_missing_branch_is_created_from_default_branch() async throws {
        URLProtocolStub.enqueue([
            // 1. branch-check 404
            { req in
                XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/branches/feedback-attachments")
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            },
            // 2. fetch repo → default_branch
            { req in
                XCTAssertEqual(req.url?.path, "/repos/octocat/feedback")
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"default_branch":"main"}"#.data(using: .utf8)!
                )
            },
            // 3. fetch ref SHA
            { req in
                XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/git/refs/heads/main")
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"object":{"sha":"abc123"}}"#.data(using: .utf8)!
                )
            },
            // 4. create ref
            { req in
                XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/git/refs")
                XCTAssertEqual(req.httpMethod, "POST")
                let body = try! JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as! [String: Any]
                XCTAssertEqual(body["ref"] as? String, "refs/heads/feedback-attachments")
                XCTAssertEqual(body["sha"] as? String, "abc123")
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            },
        ])
        let uploader = AttachmentUploader(
            owner: "octocat", repo: "feedback", token: "t", session: makeSession()
        )
        try await uploader.ensureBranchExists()
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportAttachmentTests
```

Expected: FAIL — `AttachmentUploader` not defined.

- [ ] **Step 3: Implement `AttachmentUploader` (branch ensure only for this task)**

```swift
// Sources/AppFeedbackCore/Transport/AttachmentUploader.swift
import Foundation

/// Owns the side-effecting GitHub calls that get attachment bytes into the
/// `feedback-attachments` branch and return a stable raw URL. Used by
/// ``GitHubDirectTransport`` during the upload phase of a submission.
struct AttachmentUploader {
    let owner: String
    let repo: String
    let token: String
    let session: URLSession
    let branchName = "feedback-attachments"

    init(owner: String, repo: String, token: String, session: URLSession) {
        self.owner = owner
        self.repo = repo
        self.token = token
        self.session = session
    }

    func ensureBranchExists() async throws {
        // 1. Check branch
        let branchURL = api("/repos/\(percent(owner))/\(percent(repo))/branches/\(branchName)")
        let (_, branchResp) = try await get(branchURL)
        if (branchResp as? HTTPURLResponse)?.statusCode == 200 { return }
        guard (branchResp as? HTTPURLResponse)?.statusCode == 404 else {
            throw URLError(.badServerResponse)
        }

        // 2. Get default branch
        let repoURL = api("/repos/\(percent(owner))/\(percent(repo))")
        let (repoData, _) = try await get(repoURL)
        struct RepoInfo: Decodable { let default_branch: String }
        let defaultBranch = try JSONDecoder().decode(RepoInfo.self, from: repoData).default_branch

        // 3. Get ref SHA
        let refURL = api("/repos/\(percent(owner))/\(percent(repo))/git/refs/heads/\(percent(defaultBranch))")
        let (refData, _) = try await get(refURL)
        struct RefResponse: Decodable { struct Obj: Decodable { let sha: String }; let object: Obj }
        let sha = try JSONDecoder().decode(RefResponse.self, from: refData).object.sha

        // 4. Create branch
        let createURL = api("/repos/\(percent(owner))/\(percent(repo))/git/refs")
        let payload: [String: String] = [
            "ref": "refs/heads/\(branchName)",
            "sha": sha,
        ]
        try await post(createURL, json: payload, expecting: 201)
    }

    // MARK: - HTTP helpers

    private func api(_ path: String) -> URL {
        URL(string: "https://api.github.com\(path)")!
    }
    private func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return try await session.data(for: req)
    }

    private func post<T: Encodable>(_ url: URL, json: T, expecting expectedStatus: Int) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.httpBody = try JSONEncoder().encode(json)
        let (_, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == expectedStatus else {
            throw URLError(.badServerResponse)
        }
    }
}
```

- [ ] **Step 4: Run the branch-ensure tests**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportAttachmentTests
```

Expected: both branch-ensure tests PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/Transport/AttachmentUploader.swift \
        Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift
git commit -m "feat(sdk): AttachmentUploader branch-ensure logic"
```

### Task C3: `AttachmentUploader.upload(_:)` (TDD)

**Files:**
- Modify: `Sources/AppFeedbackCore/Transport/AttachmentUploader.swift`
- Modify: `Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift`

- [ ] **Step 1: Append the new tests**

In `GitHubDirectTransportAttachmentTests.swift`, append:

```swift
extension GitHubDirectTransportAttachmentTests {

    func test_upload_puts_to_contents_api_with_base64_body_and_returns_download_url() async throws {
        URLProtocolStub.respond { req in
            XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/contents/attachments/sub-1/shot.png")
            XCTAssertEqual(req.url?.query, nil)
            XCTAssertEqual(req.httpMethod, "PUT")
            let body = try! JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as! [String: Any]
            XCTAssertEqual(body["branch"] as? String, "feedback-attachments")
            XCTAssertNotNil(body["message"] as? String)
            let content = body["content"] as! String
            XCTAssertEqual(Data(base64Encoded: content), Data("imagebytes".utf8))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                #"""
                {"content":{"download_url":"https://raw.githubusercontent.com/octocat/feedback/feedback-attachments/attachments/sub-1/shot.png"}}
                """#.data(using: .utf8)!
            )
        }
        let uploader = AttachmentUploader(
            owner: "octocat", repo: "feedback", token: "t", session: makeSession()
        )
        let url = try await uploader.upload(
            data: Data("imagebytes".utf8),
            sanitizedFilename: "shot.png",
            submissionID: "sub-1"
        )
        XCTAssertEqual(url.absoluteString,
                       "https://raw.githubusercontent.com/octocat/feedback/feedback-attachments/attachments/sub-1/shot.png")
    }

    func test_upload_dedups_same_submission_filename_with_n_suffix() {
        let inputs = [
            FeedbackAttachment(filename: "shot.png", mimeType: "image/png", data: Data([1])),
            FeedbackAttachment(filename: "shot.png", mimeType: "image/png", data: Data([2])),
            FeedbackAttachment(filename: "shot.png", mimeType: "image/png", data: Data([3])),
        ]
        let deduped = AttachmentUploader.deduplicate(inputs.map(\.filename))
        XCTAssertEqual(deduped, ["shot.png", "shot (2).png", "shot (3).png"])
    }

    func test_filename_sanitization_strips_path_and_bad_chars() {
        XCTAssertEqual(AttachmentUploader.sanitize("../etc/passwd"), "passwd")
        XCTAssertEqual(AttachmentUploader.sanitize("a/b/c.png"), "c.png")
        XCTAssertEqual(AttachmentUploader.sanitize(""), "file.bin")
        XCTAssertEqual(AttachmentUploader.sanitize("   "), "file.bin")
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportAttachmentTests
```

Expected: new three FAIL; previous two still PASS.

- [ ] **Step 3: Extend `AttachmentUploader`**

Add to `AttachmentUploader`:

```swift
    func upload(data: Data, sanitizedFilename: String, submissionID: String) async throws -> URL {
        let path = "attachments/\(submissionID)/\(sanitizedFilename)"
        let percentPath = path.split(separator: "/").map { percent(String($0)) }.joined(separator: "/")
        let url = api("/repos/\(percent(owner))/\(percent(repo))/contents/\(percentPath)")

        struct Payload: Encodable {
            let message: String
            let content: String
            let branch: String
        }
        let payload = Payload(
            message: "Add attachment for feedback submission \(submissionID)",
            content: data.base64EncodedString(),
            branch: branchName
        )

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.httpBody = try JSONEncoder().encode(payload)

        let (responseData, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 201 else {
            throw URLError(.badServerResponse)
        }
        struct Response: Decodable {
            struct Content: Decodable { let download_url: String }
            let content: Content
        }
        let parsed = try JSONDecoder().decode(Response.self, from: responseData)
        guard let url = URL(string: parsed.content.download_url) else {
            throw URLError(.badServerResponse)
        }
        return url
    }

    static func sanitize(_ raw: String) -> String {
        let basename = (raw as NSString).lastPathComponent
        var cleaned = basename
            .replacingOccurrences(of: "\\", with: "")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleaned.isEmpty { cleaned = "file.bin" }
        return cleaned
    }

    static func deduplicate(_ filenames: [String]) -> [String] {
        var seen: [String: Int] = [:]
        var result: [String] = []
        for name in filenames {
            if seen[name] == nil {
                seen[name] = 1
                result.append(name)
            } else {
                seen[name, default: 1] += 1
                let n = seen[name]!
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                let suffixed = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                result.append(suffixed)
            }
        }
        return result
    }
```

- [ ] **Step 4: Run the new tests**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportAttachmentTests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/Transport/AttachmentUploader.swift \
        Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift
git commit -m "feat(sdk): AttachmentUploader.upload via Contents API + sanitize/dedup helpers"
```

### Task C4: Wire `GitHubDirectTransport.submit` two-phase

**Files:**
- Modify: `Sources/AppFeedbackCore/Transport/GitHubDirectTransport.swift`
- Modify: `Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift`

- [ ] **Step 1: Append the integration tests**

In `GitHubDirectTransportAttachmentTests.swift`, append:

```swift
extension GitHubDirectTransportAttachmentTests {

    func test_empty_attachments_skips_branch_and_upload_calls() async throws {
        var callCount = 0
        URLProtocolStub.respond { req in
            callCount += 1
            XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/issues",
                           "only issues endpoint should be touched")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                #"{"number":42}"#.data(using: .utf8)!
            )
        }
        let transport = GitHubDirectTransport(owner: "octocat", repo: "feedback", token: "t", session: makeSession())
        let report = FeedbackReport(type: .bug, title: "T", description: "D")
        let n = try await transport.submit(report, deviceInfo: device())
        XCTAssertEqual(n, 42)
        XCTAssertEqual(callCount, 1)
    }

    func test_single_attachment_happy_path_returns_issue_number() async throws {
        URLProtocolStub.enqueue([
            { req in   // branch exists
                XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/branches/feedback-attachments")
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            },
            { req in   // PUT contents
                XCTAssertEqual(req.httpMethod, "PUT")
                XCTAssertTrue(req.url?.path.contains("/contents/attachments/") ?? false)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"content":{"download_url":"https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/x/shot.png"}}"#.data(using: .utf8)!
                )
            },
            { req in   // POST issue
                XCTAssertEqual(req.url?.path, "/repos/octocat/feedback/issues")
                let body = try! JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as! [String: Any]
                let bodyText = body["body"] as! String
                XCTAssertTrue(bodyText.contains("<!-- attachments-v1 -->"))
                XCTAssertTrue(bodyText.contains("https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/x/shot.png"))
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"number":99}"#.data(using: .utf8)!
                )
            },
        ])
        let transport = GitHubDirectTransport(owner: "octocat", repo: "feedback", token: "t", session: makeSession())
        let png = Data([0x89, 0x50, 0x4E, 0x47]) // not a valid PNG; preprocessor will fail
        // Use a non-image to avoid running through ImagePreprocessor for this test.
        let report = FeedbackReport(
            type: .bug, title: "T", description: "D",
            attachments: [
                FeedbackAttachment(filename: "shot.png", mimeType: "text/plain", data: png)
            ]
        )
        let n = try await transport.submit(report, deviceInfo: device())
        XCTAssertEqual(n, 99)
    }

    func test_upload_failure_throws_attachmentUpload_and_skips_issue_create() async throws {
        var sawIssueCall = false
        URLProtocolStub.enqueue([
            { req in   // branch check 200
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            },
            { req in   // PUT 1 ok
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"content":{"download_url":"https://example.com/a.txt"}}"#.data(using: .utf8)!
                )
            },
            { req in   // PUT 2 fails
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            },
            { req in
                sawIssueCall = true
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            },
        ])
        let transport = GitHubDirectTransport(owner: "octocat", repo: "feedback", token: "t", session: makeSession())
        let report = FeedbackReport(
            type: .bug, title: "T", description: "D",
            attachments: [
                FeedbackAttachment(filename: "a.txt", mimeType: "text/plain", data: Data([1])),
                FeedbackAttachment(filename: "b.txt", mimeType: "text/plain", data: Data([2])),
            ]
        )
        do {
            _ = try await transport.submit(report, deviceInfo: device())
            XCTFail("expected throw")
        } catch FeedbackSubmissionError.attachmentUpload(let filename, _) {
            XCTAssertEqual(filename, "b.txt")
        } catch {
            XCTFail("expected attachmentUpload, got \(error)")
        }
        XCTAssertFalse(sawIssueCall, "issue create must not run after upload failure")
    }

    private func device() -> DeviceInfo {
        DeviceInfo(
            appName: "App", appVersion: "1.0", buildNumber: "1",
            model: "Mac", osName: "macOS", osVersion: "Version 15.1"
        )
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportAttachmentTests
```

Expected: three new tests FAIL — `submit` doesn't handle attachments yet.

- [ ] **Step 3: Rewrite `GitHubDirectTransport.submit`**

Open `Sources/AppFeedbackCore/Transport/GitHubDirectTransport.swift`. Replace the existing `submit(_:deviceInfo:)` with:

```swift
    public func submit(_ report: FeedbackReport, deviceInfo: DeviceInfo) async throws -> Int {
        var uploaded: [UploadedAttachment] = []

        if !report.attachments.isEmpty {
            do {
                try FeedbackAttachmentValidator.validate(report.attachments)
            } catch let error as FeedbackAttachmentError {
                throw FeedbackSubmissionError.attachmentValidation(error)
            }

            let processed: [FeedbackAttachment]
            do {
                processed = try report.attachments.map(ImagePreprocessor.process)
            } catch let error as FeedbackAttachmentError {
                throw FeedbackSubmissionError.attachmentValidation(error)
            }

            // Re-validate sizes post-processing.
            do {
                try FeedbackAttachmentValidator.validate(processed)
            } catch let error as FeedbackAttachmentError {
                throw FeedbackSubmissionError.attachmentValidation(error)
            }

            let uploader = AttachmentUploader(owner: owner, repo: repo, token: token, session: session)
            do {
                try await uploader.ensureBranchExists()
            } catch {
                throw FeedbackSubmissionError.attachmentUpload(filename: "", underlying: error as any Error & Sendable)
            }

            let submissionID = UUID().uuidString.lowercased()
            let sanitizedNames = AttachmentUploader.deduplicate(processed.map { AttachmentUploader.sanitize($0.filename) })

            for (i, att) in processed.enumerated() {
                do {
                    let url = try await uploader.upload(
                        data: att.data,
                        sanitizedFilename: sanitizedNames[i],
                        submissionID: submissionID
                    )
                    uploaded.append(UploadedAttachment(
                        filename: sanitizedNames[i],
                        mimeType: att.mimeType,
                        sizeBytes: att.data.count,
                        url: url
                    ))
                } catch {
                    throw FeedbackSubmissionError.attachmentUpload(
                        filename: sanitizedNames[i],
                        underlying: error as any Error & Sendable
                    )
                }
            }
        }

        let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? owner
        let encodedRepo = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        guard let url = URL(string: "https://api.github.com/repos/\(encodedOwner)/\(encodedRepo)/issues") else {
            throw FeedbackSubmissionError.invalidResponse
        }

        let payload = CreateIssueRequest(
            title: report.title,
            body: IssueBodyFormatter.format(report: report, deviceInfo: deviceInfo, uploaded: uploaded),
            labels: IssueBodyFormatter.labels(for: report.type)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedbackSubmissionError.transport(error as any Error & Sendable)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackSubmissionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedbackSubmissionError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8))
        }

        do {
            return try JSONDecoder().decode(IssueResponse.self, from: data).number
        } catch {
            throw FeedbackSubmissionError.decoding(error as any Error & Sendable)
        }
    }
```

- [ ] **Step 4: Run the new tests**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter GitHubDirectTransportAttachmentTests
```

Expected: all PASS.

- [ ] **Step 5: Run the full SDK test suite to confirm zero regression**

```bash
cd ~/Developer/AppFeedbackSDK && swift test
```

Expected: every test PASSES.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackCore/Transport/GitHubDirectTransport.swift \
        Tests/AppFeedbackCoreTests/GitHubDirectTransportAttachmentTests.swift
git commit -m "feat(sdk): GitHubDirectTransport two-phase submit with attachments"
```

### Task C5: Roundtrip test

**Files:**
- Modify: `Tests/AppFeedbackCoreTests/RoundtripTests.swift`

- [ ] **Step 1: Append the roundtrip case**

In `RoundtripTests.swift`, append:

```swift
extension RoundtripTests {
    func test_attachments_roundtrip_through_format_and_parse() {
        let device = DeviceInfo(
            appName: "App", appVersion: "1.0", buildNumber: "1",
            model: "Mac", osName: "macOS", osVersion: "Version 15.1"
        )
        let uploaded = [
            UploadedAttachment(
                filename: "shot.png", mimeType: "image/png", sizeBytes: 312 * 1024,
                url: URL(string: "https://example.com/shot.png")!
            ),
            UploadedAttachment(
                filename: "log.txt", mimeType: "text/plain", sizeBytes: 4096,
                url: URL(string: "https://example.com/log.txt")!
            ),
        ]
        let report = FeedbackReport(type: .bug, title: "T", description: "D")
        let body = IssueBodyFormatter.format(report: report, deviceInfo: device, uploaded: uploaded)
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 2)
        XCTAssertEqual(parsed.attachments[0].filename, "shot.png")
        XCTAssertEqual(parsed.attachments[0].mimeType, "image/png")
        XCTAssertEqual(parsed.attachments[0].url.absoluteString, "https://example.com/shot.png")
        XCTAssertEqual(parsed.attachments[1].filename, "log.txt")
        XCTAssertEqual(parsed.attachments[1].mimeType, "text/plain")
    }
}
```

- [ ] **Step 2: Run**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter RoundtripTests
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Tests/AppFeedbackCoreTests/RoundtripTests.swift
git commit -m "test(sdk): roundtrip attachments through formatter+parser"
```

---

## Phase D — SDK UI: FeedbackSheet picker

### Task D1: Add picker state to `FeedbackSheet`

**Files:**
- Modify: `Sources/AppFeedbackUI/FeedbackSheet.swift`

- [ ] **Step 1: Add state vars and a helper struct near the top of `FeedbackSheet`**

After the existing `@State private var contactEmail = ""` line, add:

```swift
    @State private var pendingAttachments: [PendingAttachmentUI] = []
    @State private var attachmentError: String?
    @State private var isDragTargeted: Bool = false
```

At the bottom of the file, outside the struct, add:

```swift
struct PendingAttachmentUI: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
    let thumbnail: PlatformImage?

    static func == (lhs: PendingAttachmentUI, rhs: PendingAttachmentUI) -> Bool { lhs.id == rhs.id }
}
```

Note: `PlatformImage` is defined in the SDK's `PlatformColors.swift`. If not, add a typealias at the top of `FeedbackSheet.swift`:

```swift
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
```

- [ ] **Step 2: Build**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackUI/FeedbackSheet.swift
git commit -m "feat(sdk-ui): scaffold attachment state on FeedbackSheet"
```

### Task D2: Add picker button + `.fileImporter`

**Files:**
- Modify: `Sources/AppFeedbackUI/FeedbackSheet.swift`

- [ ] **Step 1: Add a `attachmentsCard` view below the existing `emailCard`**

Locate the `formContent` view body. Inside the `VStack`, after `emailCard` and before `privacyNotice`, insert `attachmentsCard`.

Add this property to the struct (after `emailCard`):

```swift
    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel(theme.copy.attachmentsLabel, icon: "paperclip")
                Spacer()
                Button {
                    showFileImporter = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pendingAttachments.count >= 3)
            }
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.png, .jpeg, .heic, .gif, .plainText, .json, .pdf],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                ingest(urls: urls)
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    PendingAttachmentTile(attachment: att, onRemove: {
                        pendingAttachments.removeAll { $0.id == att.id }
                        revalidate()
                    })
                }
            }
        }
        .frame(height: 64)
    }
```

Add the supporting state:

```swift
    @State private var showFileImporter = false
```

Add the supporting tile view at the bottom of the file:

```swift
private struct PendingAttachmentTile: View {
    let attachment: PendingAttachmentUI
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = attachment.thumbnail {
                    Image(platformImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(attachment.filename)
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(width: 56, height: 56)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    private var icon: String {
        switch attachment.mimeType {
        case "application/pdf": return "doc.fill"
        case "application/json": return "curlybraces"
        default: return "doc.text"
        }
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
```

Add the `ingest` and `revalidate` helpers as private methods of `FeedbackSheet`:

```swift
    private func ingest(urls: [URL]) {
        for url in urls {
            guard pendingAttachments.count < 3 else { break }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = mimeType(for: url)
            let thumb: PlatformImage? = mime.hasPrefix("image/") ? PlatformImage(data: data) : nil
            pendingAttachments.append(PendingAttachmentUI(
                filename: url.lastPathComponent,
                mimeType: mime,
                data: data,
                thumbnail: thumb
            ))
        }
        revalidate()
    }

    private func revalidate() {
        let modeled = pendingAttachments.map {
            FeedbackAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        do {
            try FeedbackAttachmentValidator.validate(modeled)
            attachmentError = nil
        } catch let err as FeedbackAttachmentError {
            attachmentError = humanMessage(for: err)
        } catch {
            attachmentError = "Attachment error: \(error.localizedDescription)"
        }
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func humanMessage(for error: FeedbackAttachmentError) -> String {
        switch error {
        case .tooManyAttachments(let limit, _): return "At most \(limit) attachments."
        case .fileTooLarge(let name, _, let limit):
            return "\(name) exceeds \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .totalSizeTooLarge(_, let limit):
            return "Total exceeds \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .unsupportedMimeType(let name, _): return "\(name): unsupported type."
        case .imageProcessingFailed(let name): return "\(name) could not be processed."
        }
    }
```

Add `attachmentsLabel` to the theme copy. In `FeedbackTheme.swift`, find the `Copy` struct and add:

```swift
public var attachmentsLabel: String = "Attachments"
```

Add `UTType` and `UniformTypeIdentifiers` imports to `FeedbackSheet.swift`:

```swift
import UniformTypeIdentifiers
```

- [ ] **Step 2: Wire `submit()` to include `pendingAttachments`**

In the `submit()` method, change the `FeedbackReport` construction to:

```swift
        let modeled = pendingAttachments.map {
            FeedbackAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        let report = FeedbackReport(
            type: selectedType,
            title: title,
            description: description,
            contactEmail: contactEmail.isEmpty ? nil : contactEmail,
            attachments: modeled
        )
```

Also disable submit while `attachmentError != nil`:

In the `footer` view, change `.disabled(isSubmitting)` to `.disabled(isSubmitting || attachmentError != nil)`.

- [ ] **Step 3: Build**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackUI/FeedbackSheet.swift Sources/AppFeedbackUI/FeedbackTheme.swift
git commit -m "feat(sdk-ui): attachment picker + thumbnail strip in FeedbackSheet"
```

### Task D3: Add drag-and-drop drop target (macOS)

**Files:**
- Modify: `Sources/AppFeedbackUI/FeedbackSheet.swift`

- [ ] **Step 1: Apply `onDrop` to the form's outer `VStack`**

In `formContent`, wrap the outer `VStack` or apply `.onDrop` after `.padding`. The cleanest spot is on the `ScrollView`:

```swift
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    typeSelector
                    titleCard
                    descriptionCard
                    emailCard
                    attachmentsCard
                    privacyNotice
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
            #if os(macOS)
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            #endif
```

Add the `handleDrop` helper:

```swift
    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            ingest(urls: urls)
        }
    }
    #endif
```

- [ ] **Step 2: Build**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackUI/FeedbackSheet.swift
git commit -m "feat(sdk-ui): drag-and-drop attachment support on FeedbackSheet (macOS)"
```

### Task D4: Add paste-from-clipboard

**Files:**
- Modify: `Sources/AppFeedbackUI/FeedbackSheet.swift`

- [ ] **Step 1: Wire a `keyboardShortcut`-style paste handler**

After the `.onDrop` modifier on the `ScrollView`, add:

```swift
            .background(PasteHandler { pasteImage() })
```

Add the `PasteHandler` view at the bottom of `FeedbackSheet.swift`:

```swift
#if os(macOS)
private struct PasteHandler: NSViewRepresentable {
    let onPaste: () -> Void
    func makeNSView(context: Context) -> NSView { PasteCatcherView(onPaste: onPaste) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PasteCatcherView: NSView {
    let onPaste: () -> Void
    init(onPaste: @escaping () -> Void) {
        self.onPaste = onPaste
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            onPaste()
        } else {
            super.keyDown(with: event)
        }
    }
}
#else
private struct PasteHandler: View {
    let onPaste: () -> Void
    var body: some View { Color.clear }
}
#endif
```

Add the `pasteImage` helper:

```swift
    private func pasteImage() {
        #if os(macOS)
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let img = images.first {
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let idx = pendingAttachments.count + 1
                pendingAttachments.append(PendingAttachmentUI(
                    filename: "pasted-image-\(idx).png",
                    mimeType: "image/png",
                    data: png,
                    thumbnail: img
                ))
                revalidate()
            }
        }
        #endif
    }
```

For iOS, paste support can lean on the system text-field paste menu for image data (out of v1 scope on iOS; the macOS handler is the primary case).

- [ ] **Step 2: Build**

```bash
cd ~/Developer/AppFeedbackSDK && swift build
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Sources/AppFeedbackUI/FeedbackSheet.swift
git commit -m "feat(sdk-ui): paste-from-clipboard image attachment (macOS)"
```

### Task D5: Smoke test for the attachment flow

**Files:**
- Create: `Tests/AppFeedbackUITests/FeedbackSheetAttachmentsSmokeTests.swift`

- [ ] **Step 1: Write the smoke test**

```swift
// Tests/AppFeedbackUITests/FeedbackSheetAttachmentsSmokeTests.swift
import XCTest
import SwiftUI
@testable import AppFeedbackCore
@testable import AppFeedbackUI

final class FeedbackSheetAttachmentsSmokeTests: XCTestCase {

    /// Sanity: the sheet compiles with a client and renders without crashing.
    @MainActor
    func test_sheet_initializes_with_default_theme() {
        struct NoOpTransport: FeedbackTransport {
            func submit(_ report: FeedbackReport, deviceInfo: DeviceInfo) async throws -> Int { 1 }
        }
        let client = FeedbackClient(transport: NoOpTransport(), deviceInfo: DeviceInfo(
            appName: "T", appVersion: "1", buildNumber: "1",
            model: "Mac", osName: "macOS", osVersion: "Version 15.1"
        ))
        let sheet = FeedbackSheet(client: client)
        let host = NSHostingView(rootView: sheet)
        XCTAssertNotNil(host)
    }
}
```

If you're not on macOS or `NSHostingView` is unavailable, replace with:

```swift
        _ = sheet.body  // ensures the view-builder evaluates
```

- [ ] **Step 2: Run**

```bash
cd ~/Developer/AppFeedbackSDK && swift test --filter FeedbackSheetAttachmentsSmokeTests
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedbackSDK
git add Tests/AppFeedbackUITests/FeedbackSheetAttachmentsSmokeTests.swift
git commit -m "test(sdk-ui): smoke test FeedbackSheet attachment compile path"
```

### Task D6: Bump SDK version (optional checkpoint)

- [ ] **Step 1: Push the SDK so the inbox app can pick up the new API**

```bash
cd ~/Developer/AppFeedbackSDK && git push origin main
```

- [ ] **Step 2: In the inbox repo, run zcode build to refresh the SPM cache**

Invoke the **zcode** skill: "Resolve packages and build the AppFeedback macOS scheme."

Expected: build succeeds. The inbox compiles fine without using the new types yet — they're additive.

---

## Phase E — Inbox: model + parser shim

### Task E1: Add `FeedbackAttachmentRef`

**Files:**
- Create: `AppFeedback/Models/FeedbackAttachmentRef.swift`

- [ ] **Step 1: Write the file**

```swift
// AppFeedback/Models/FeedbackAttachmentRef.swift
import Foundation
import AppFeedbackCore

/// View-layer mirror of ``AppFeedbackCore/ParsedAttachment``. Codable so it can
/// be stored as a JSON blob on `CachedIssue.attachmentsJSON`.
struct FeedbackAttachmentRef: Codable, Sendable, Hashable, Identifiable {
    let filename: String
    let mimeType: String
    let url: URL
    let sizeBytes: Int?

    var id: String { url.absoluteString }
    var isImage: Bool { mimeType.hasPrefix("image/") }

    init(filename: String, mimeType: String, url: URL, sizeBytes: Int?) {
        self.filename = filename
        self.mimeType = mimeType
        self.url = url
        self.sizeBytes = sizeBytes
    }

    init(_ parsed: ParsedAttachment) {
        self.init(filename: parsed.filename, mimeType: parsed.mimeType, url: parsed.url, sizeBytes: parsed.sizeBytes)
    }
}
```

- [ ] **Step 2: Build via the zcode skill**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Models/FeedbackAttachmentRef.swift
git commit -m "feat(inbox): add FeedbackAttachmentRef view-layer model"
```

### Task E2: Extend `CachedIssue` and `FeedbackIssue`

**Files:**
- Modify: `AppFeedback/Models/CachedIssue.swift`
- Modify: `AppFeedback/Models/FeedbackIssue.swift`

- [ ] **Step 1: Add `attachmentsJSON` to `CachedIssue`**

In `CachedIssue.swift`, after `var translationTargetLanguage: String?`, add:

```swift
    var attachmentsJSON: String?
```

Add a static encoder/decoder pair:

```swift
    static func encodeAttachments(_ refs: [FeedbackAttachmentRef]) -> String? {
        guard !refs.isEmpty, let data = try? JSONEncoder().encode(refs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeAttachments(_ json: String?) -> [FeedbackAttachmentRef] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FeedbackAttachmentRef].self, from: data)) ?? []
    }
```

Update `toFeedbackIssue()` to include attachments:

```swift
            attachments: Self.decodeAttachments(attachmentsJSON)
```

(appended to the `FeedbackIssue(...)` initializer list — note `FeedbackIssue`'s init must accept this; see next step).

Update `from(_:repoOwner:repoName:)` to include attachments:

```swift
        let cached = CachedIssue(...)  // existing params
        cached.attachmentsJSON = Self.encodeAttachments(issue.attachments)
        return cached
```

Update `updateFromRemote(_:)` to refresh attachments:

```swift
        self.attachmentsJSON = Self.encodeAttachments(issue.attachments)
```

- [ ] **Step 2: Add `attachments` to `FeedbackIssue`**

In `FeedbackIssue.swift`, after `var translationTargetLanguage: String?`, add:

```swift
    var attachments: [FeedbackAttachmentRef] = []
```

This is `Codable` because `FeedbackAttachmentRef` is `Codable` and the default literal allows decoding from issues fetched before this field existed.

- [ ] **Step 3: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Models/CachedIssue.swift AppFeedback/Models/FeedbackIssue.swift
git commit -m "feat(inbox): persist attachments on CachedIssue + FeedbackIssue"
```

### Task E3: Pass attachments through the parser shim (TDD)

**Files:**
- Modify: `AppFeedback/Services/IssueBodyParser.swift`
- Create: `AppFeedbackTests/IssueBodyParserShimAttachmentsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AppFeedbackTests/IssueBodyParserShimAttachmentsTests.swift
import XCTest
@testable import AppFeedback

final class IssueBodyParserShimAttachmentsTests: XCTestCase {

    func test_shim_passes_attachments_through() {
        let body = """
        Description.

        <!-- attachments-v1 -->
        ## Attachments

        ![s.png](https://example.com/s.png) — image/png, 1 KB

        <!-- /attachments-v1 -->

        ---
        👍 Votes: 0
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "s.png")
        XCTAssertEqual(parsed.attachments[0].mimeType, "image/png")
    }
}
```

- [ ] **Step 2: Run via zcode, expect fail**

Invoke zcode: "Run AppFeedbackTests/IssueBodyParserShimAttachmentsTests on the AppFeedback macOS scheme."

Expected: FAIL — `parsed.attachments` doesn't exist on the shim's `ParsedBody`.

- [ ] **Step 3: Extend the shim**

In `AppFeedback/Services/IssueBodyParser.swift`, modify `ParsedBody`:

```swift
struct ParsedBody: Sendable {
    var description: String = ""
    var app: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var attachments: [FeedbackAttachmentRef] = []
}
```

And modify `parse(_:)`:

```swift
enum IssueBodyParser {
    static func parse(_ raw: String) -> ParsedBody {
        let p = AppFeedbackCore.IssueBodyParser.parse(raw)
        return ParsedBody(
            description: p.description,
            app: p.appName,
            appVersion: p.appVersion,
            device: p.device,
            osVersion: p.osVersion,
            email: p.email,
            attachments: p.attachments.map(FeedbackAttachmentRef.init)
        )
    }
}
```

- [ ] **Step 4: Run, expect pass**

Invoke zcode: "Run AppFeedbackTests/IssueBodyParserShimAttachmentsTests on the AppFeedback macOS scheme."

Expected: PASS.

- [ ] **Step 5: Wire attachments into `IssueLoader`/wherever `FeedbackIssue` is constructed from a parsed body**

Find the call site that builds `FeedbackIssue` from `IssueBodyParser.parse(rawBody)`. (Likely in `IssueLoader.swift`.) After the existing assignment to `description = parsed.description`, add:

```swift
            attachments: parsed.attachments,
```

at the appropriate `FeedbackIssue.init` argument position. Build via zcode to confirm.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/IssueBodyParser.swift \
        AppFeedback/Services/IssueLoader.swift \
        AppFeedbackTests/IssueBodyParserShimAttachmentsTests.swift
git commit -m "feat(inbox): parser shim + loader pass attachments into FeedbackIssue"
```

---

## Phase F — Inbox: downloader + cache

### Task F1: Add `FeedbackAttachmentLocal` SwiftData model

**Files:**
- Create: `AppFeedback/Models/FeedbackAttachmentLocal.swift`

- [ ] **Step 1: Write the model**

```swift
// AppFeedback/Models/FeedbackAttachmentLocal.swift
import Foundation
import SwiftData

@Model
final class FeedbackAttachmentLocal {
    @Attribute(.unique) var url: String = ""
    var localPath: String = ""
    var downloadedAt: Date = Date()

    init(url: String, localPath: String, downloadedAt: Date) {
        self.url = url
        self.localPath = localPath
        self.downloadedAt = downloadedAt
    }
}
```

- [ ] **Step 2: Add it to the ModelContainer**

Find the `ModelContainer(for: ...)` call in `AppFeedback/App/AppFeedbackApp.swift` and append `FeedbackAttachmentLocal.self` to the schema.

- [ ] **Step 3: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Models/FeedbackAttachmentLocal.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(inbox): add FeedbackAttachmentLocal SwiftData model"
```

### Task F2: `FeedbackAttachmentDownloader` actor + local store (TDD)

**Files:**
- Create: `AppFeedback/Services/FeedbackAttachmentDownloader.swift`
- Create: `AppFeedbackTests/FeedbackAttachmentDownloaderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AppFeedbackTests/FeedbackAttachmentDownloaderTests.swift
import XCTest
import SwiftData
@testable import AppFeedback

final class FeedbackAttachmentDownloaderTests: XCTestCase {

    override func setUp() { super.setUp(); FeedbackURLProtocolStub.reset() }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    @MainActor
    private func makeStore() -> FeedbackAttachmentLocalStore {
        let schema = Schema([FeedbackAttachmentLocal.self])
        let container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return FeedbackAttachmentLocalStore(context: ModelContext(container))
    }

    @MainActor
    func test_first_download_writes_file_and_records_path() async throws {
        let bytes = Data("hello".utf8)
        FeedbackURLProtocolStub.respond { req in
            // Inbox downloader routes raw.githubusercontent.com via the Contents API.
            XCTAssertEqual(req.url?.host, "api.github.com")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                bytes
            )
        }
        let store = makeStore()
        let downloader = FeedbackAttachmentDownloader(
            session: makeSession(),
            localStore: store,
            tokenProvider: { "test-token" }
        )
        let raw = URL(string: "https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/abc/shot.png")!
        let path = try await downloader.download(url: raw, filename: "shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertNotNil(store.fetchLocalPath(url: raw.absoluteString))
    }

    @MainActor
    func test_second_call_returns_cached_path_without_hitting_network() async throws {
        FeedbackURLProtocolStub.enqueue([
            { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 Data("hello".utf8))
            },
            { _ in XCTFail("should not be called twice"); return (HTTPURLResponse(), Data()) }
        ])
        let store = makeStore()
        let downloader = FeedbackAttachmentDownloader(
            session: makeSession(),
            localStore: store,
            tokenProvider: { "t" }
        )
        let raw = URL(string: "https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/abc/shot.png")!
        _ = try await downloader.download(url: raw, filename: "shot.png")
        _ = try await downloader.download(url: raw, filename: "shot.png")
    }
}

// Lightweight URL stub local to this test target. See SDK's URLProtocolStub for the
// reference implementation; we duplicate (small) instead of vending across packages.
final class FeedbackURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var single: Handler?
    nonisolated(unsafe) private static var queue: [Handler] = []
    static func respond(_ h: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; single = h; queue = []
    }
    static func enqueue(_ hs: [Handler]) {
        lock.lock(); defer { lock.unlock() }; single = nil; queue = hs
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; single = nil; queue = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let h = Self.single ?? (Self.queue.isEmpty ? nil : Self.queue.removeFirst())
        Self.lock.unlock()
        guard let h else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let (r, d) = h(request)
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: d)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run via zcode, expect fail**

Invoke zcode: "Run AppFeedbackTests/FeedbackAttachmentDownloaderTests on the AppFeedback macOS scheme."

Expected: FAIL — `FeedbackAttachmentDownloader` and `FeedbackAttachmentLocalStore` not defined.

- [ ] **Step 3: Implement**

```swift
// AppFeedback/Services/FeedbackAttachmentDownloader.swift
import Foundation
import SwiftData
import Observation
import CryptoKit

@MainActor
@Observable
final class FeedbackAttachmentLocalStore {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func fetchLocalPath(url: String) -> String? {
        var d = FetchDescriptor<FeedbackAttachmentLocal>(predicate: #Predicate { $0.url == url })
        d.fetchLimit = 1
        return (try? context.fetch(d).first)?.localPath
    }

    func record(url: String, localPath: String) {
        if let existing = try? context.fetch(
            FetchDescriptor<FeedbackAttachmentLocal>(predicate: #Predicate { $0.url == url })
        ).first {
            context.delete(existing)
        }
        context.insert(FeedbackAttachmentLocal(url: url, localPath: localPath, downloadedAt: Date()))
        do { try context.save() } catch {
            assertionFailure("FeedbackAttachmentLocalStore save failed: \(error)")
        }
    }
}

@Observable
final class FeedbackAttachmentDownloaderHolder {
    let downloader: FeedbackAttachmentDownloader?
    init(_ downloader: FeedbackAttachmentDownloader?) { self.downloader = downloader }
}

actor FeedbackAttachmentDownloader {

    private let session: URLSession
    private let localStore: FeedbackAttachmentLocalStore
    private let tokenProvider: @Sendable () -> String?

    init(session: URLSession, localStore: FeedbackAttachmentLocalStore, tokenProvider: @escaping @Sendable () -> String?) {
        self.session = session
        self.localStore = localStore
        self.tokenProvider = tokenProvider
    }

    enum DownloadError: Error, Equatable {
        case writeFailed
        case unsupportedURL
        case httpStatus(Int)
    }

    func download(url: URL, filename: String) async throws -> URL {
        let key = url.absoluteString

        // 1. Cache hit?
        if let path = await MainActor.run(body: { localStore.fetchLocalPath(url: key) }) {
            let onDisk = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: onDisk.path) {
                return onDisk
            }
        }

        // 2. Decide fetch endpoint.
        let request = try buildRequest(for: url)

        // 3. Fetch
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.httpStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }

        // 4. Write to cache dir under url-sha256/filename
        let dir = try resolveCacheDir(for: url)
        let dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            throw DownloadError.writeFailed
        }

        // 5. Record
        await MainActor.run { localStore.record(url: key, localPath: dest.path) }
        return dest
    }

    private func buildRequest(for url: URL) throws -> URLRequest {
        if url.host == "raw.githubusercontent.com", let parsed = parseRawGitHubURL(url) {
            // Re-route through the Contents API so private repos work.
            let path = "/repos/\(parsed.owner)/\(parsed.repo)/contents/\(parsed.path)"
            guard var comps = URLComponents(string: "https://api.github.com\(path)") else { throw DownloadError.unsupportedURL }
            comps.queryItems = [URLQueryItem(name: "ref", value: parsed.branch)]
            guard let apiURL = comps.url else { throw DownloadError.unsupportedURL }
            var req = URLRequest(url: apiURL)
            req.httpMethod = "GET"
            req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            if let token = tokenProvider() {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return req
        }
        // External URL — fetch directly.
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    private struct RawGitHubURLParts { let owner: String; let repo: String; let branch: String; let path: String }
    private func parseRawGitHubURL(_ url: URL) -> RawGitHubURLParts? {
        // /<owner>/<repo>/<branch>/<...path>
        let parts = url.path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        return RawGitHubURLParts(
            owner: String(parts[0]),
            repo: String(parts[1]),
            branch: String(parts[2]),
            path: String(parts[3])
        )
    }

    private func resolveCacheDir(for url: URL) throws -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("FeedbackAttachments/\(hex)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
```

- [ ] **Step 4: Run, expect pass**

Invoke zcode: "Run AppFeedbackTests/FeedbackAttachmentDownloaderTests on the AppFeedback macOS scheme."

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/FeedbackAttachmentDownloader.swift \
        AppFeedbackTests/FeedbackAttachmentDownloaderTests.swift
git commit -m "feat(inbox): FeedbackAttachmentDownloader with Contents-API resolution"
```

### Task F3: `ThumbnailCache` (in-memory)

**Files:**
- Create: `AppFeedback/Services/ThumbnailCache.swift`

- [ ] **Step 1: Write the cache**

```swift
// AppFeedback/Services/ThumbnailCache.swift
import Foundation
import Observation
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

@MainActor
@Observable
final class ThumbnailCache {
    private let cache = NSCache<NSString, PlatformImage>()
    private let dimension: CGFloat

    init(dimension: CGFloat = 256) {
        self.dimension = dimension
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(for url: URL) -> PlatformImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Async-friendly: returns the cached image if present, otherwise decodes
    /// the file at `path` and caches it.
    func thumbnail(for url: URL, localPath: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        guard let img = decode(localPath) else { return nil }
        let scaled = scale(img, to: dimension)
        cache.setObject(scaled, forKey: url.absoluteString as NSString, cost: Int(dimension * dimension * 4))
        return scaled
    }

    private func decode(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        return NSImage(contentsOf: url)
        #else
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
        #endif
    }

    private func scale(_ img: PlatformImage, to dim: CGFloat) -> PlatformImage {
        #if os(macOS)
        let newSize = NSSize(width: dim, height: dim)
        let out = NSImage(size: newSize)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: newSize),
                 from: NSRect(origin: .zero, size: img.size),
                 operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
        #else
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim), format: format)
        return renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: CGSize(width: dim, height: dim)))
        }
        #endif
    }
}
```

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/ThumbnailCache.swift
git commit -m "feat(inbox): ThumbnailCache for issue attachment previews"
```

---

## Phase G — Inbox: Quick Look service

### Task G1: `QuickLookPresenter` (cross-platform)

**Files:**
- Create: `AppFeedback/Services/QuickLookPresenter.swift`

- [ ] **Step 1: Write the cross-platform presenter**

```swift
// AppFeedback/Services/QuickLookPresenter.swift
import Foundation
import Observation
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class QuickLookPresenter {
    private(set) var items: [URL] = []
    private(set) var startIndex: Int = 0
    var isPresented: Bool = false

    func present(urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        self.items = urls
        self.startIndex = max(0, min(index, urls.count - 1))
        self.isPresented = true
        #if os(macOS)
        showMacPanel()
        #endif
    }

    func dismiss() {
        isPresented = false
        #if os(macOS)
        QLPreviewPanel.shared().close()
        #endif
    }

    #if os(macOS)
    private var dataSource: MacDataSource?
    private func showMacPanel() {
        let ds = MacDataSource(urls: items, startIndex: startIndex)
        self.dataSource = ds
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = ds
        panel.delegate = ds
        panel.currentPreviewItemIndex = startIndex
        panel.makeKeyAndOrderFront(nil)
    }
    #endif
}

#if os(macOS)
final class MacDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]
    var startIndex: Int

    init(urls: [URL], startIndex: Int) {
        self.urls = urls
        self.startIndex = startIndex
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
#endif
```

For iOS, the panel-based macOS API doesn't apply. Add iOS support via a small SwiftUI `View` that wraps `QLPreviewController`:

```swift
#if !os(macOS)
import SwiftUI

struct QuickLookHost: View {
    @Environment(QuickLookPresenter.self) private var presenter

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: Binding(
                get: { presenter.isPresented },
                set: { if !$0 { presenter.dismiss() } }
            )) {
                QLPreviewControllerRepresentable(urls: presenter.items, startIndex: presenter.startIndex)
            }
    }
}

private struct QLPreviewControllerRepresentable: UIViewControllerRepresentable {
    let urls: [URL]
    let startIndex: Int

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        vc.currentPreviewItemIndex = startIndex
        return vc
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}
#endif
```

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS and iOS schemes."

Expected: both build.

- [ ] **Step 3: Inject the presenter at app root**

In `AppFeedback/App/AppFeedbackApp.swift`, near where other `@State` services are declared, add:

```swift
    @State private var quickLook = QuickLookPresenter()
```

In the view body, attach to the root:

```swift
            .environment(quickLook)
            #if !os(macOS)
            .overlay(QuickLookHost())
            #endif
```

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/QuickLookPresenter.swift AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(inbox): cross-platform QuickLookPresenter service"
```

---

## Phase H — Inbox UI

### Task H1: `AttachmentThumbnailView`

**Files:**
- Create: `AppFeedback/Views/Issues/AttachmentThumbnailView.swift`

- [ ] **Step 1: Write the tile view**

```swift
// AppFeedback/Views/Issues/AttachmentThumbnailView.swift
import SwiftUI

struct AttachmentThumbnailView: View {
    let attachment: FeedbackAttachmentRef
    let downloader: FeedbackAttachmentDownloader?
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
        guard let downloader else { return }
        if let cached = thumbnailCache.cached(for: attachment.url) {
            thumbnail = cached
            return
        }
        do {
            let path = try await downloader.download(url: attachment.url, filename: attachment.filename)
            thumbnail = await thumbnailCache.thumbnail(for: attachment.url, localPath: path)
        } catch {
            loadFailed = true
        }
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
```

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Issues/AttachmentThumbnailView.swift
git commit -m "feat(inbox): AttachmentThumbnailView for issue card image previews"
```

### Task H2: `AttachmentStripView` and integrate into `IssueCardView`

**Files:**
- Create: `AppFeedback/Views/Issues/AttachmentStripView.swift`
- Modify: `AppFeedback/Views/Issues/IssueCardView.swift`

- [ ] **Step 1: Write the strip view**

```swift
// AppFeedback/Views/Issues/AttachmentStripView.swift
import SwiftUI

struct AttachmentStripView: View {
    let attachments: [FeedbackAttachmentRef]

    @Environment(QuickLookPresenter.self) private var quickLook
    @Environment(FeedbackAttachmentDownloaderHolder.self) private var downloaderHolder
    @Environment(ThumbnailCache.self) private var thumbnailCache

    private var images: [FeedbackAttachmentRef] { attachments.filter(\.isImage) }
    private var files:  [FeedbackAttachmentRef] { attachments.filter { !$0.isImage } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { att in
                    AttachmentThumbnailView(
                        attachment: att,
                        downloader: downloaderHolder.downloader,
                        thumbnailCache: thumbnailCache,
                        onTap: { presentAll(startingAt: att) }
                    )
                }
                ForEach(files) { att in
                    AttachmentChipView(
                        feedbackAttachment: att,
                        downloader: downloaderHolder.downloader,
                        onTap: { presentAll(startingAt: att) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func presentAll(startingAt target: FeedbackAttachmentRef) {
        guard let downloader = downloaderHolder.downloader else { return }
        Task {
            var localURLs: [URL] = []
            var startIdx = 0
            for (i, att) in attachments.enumerated() {
                do {
                    let path = try await downloader.download(url: att.url, filename: att.filename)
                    localURLs.append(path)
                    if att.id == target.id { startIdx = i }
                } catch {
                    // Skip files that failed; keep gallery intact for the rest.
                }
            }
            await MainActor.run {
                quickLook.present(urls: localURLs, startingAt: startIdx)
            }
        }
    }
}
```

- [ ] **Step 2: Embed in `IssueCardView`**

Find `IssueCardView.swift`. Locate where the issue body (description) is rendered. Below the body block — but above the meta/footer column — insert:

```swift
            if !issue.attachments.isEmpty {
                AttachmentStripView(attachments: issue.attachments)
            }
```

- [ ] **Step 3: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Issues/AttachmentStripView.swift \
        AppFeedback/Views/Issues/IssueCardView.swift
git commit -m "feat(inbox): AttachmentStripView in IssueCardView"
```

### Task H3: Migrate `AttachmentChipView` to Quick Look + feedback init

**Files:**
- Modify: `AppFeedback/Views/Mail/AttachmentChipView.swift`

- [ ] **Step 1: Add a new init for feedback-side use and route tap through QL**

In `AttachmentChipView.swift`:

```swift
// Add to top of file
import QuickLook
```

Add a stored property and new init:

```swift
    // Existing mail-side init takes uid/folder/folderBookmark.
    // Feedback-side: we already have a URL on disk after download.
    let feedbackAttachment: FeedbackAttachmentRef?
    let feedbackDownloader: FeedbackAttachmentDownloader?
    let feedbackOnTap: (() -> Void)?

    init(feedbackAttachment: FeedbackAttachmentRef, downloader: FeedbackAttachmentDownloader?, onTap: @escaping () -> Void) {
        self.attachment = MailAttachment(
            messageID: "", partID: "",
            filename: feedbackAttachment.filename,
            mimeType: feedbackAttachment.mimeType,
            sizeBytes: feedbackAttachment.sizeBytes ?? 0
        )
        self.uid = 0
        self.folder = ""
        self.downloader = nil
        self.folderBookmark = nil
        self.feedbackAttachment = feedbackAttachment
        self.feedbackDownloader = downloader
        self.feedbackOnTap = onTap
    }
```

Update the existing mail-init to default the new properties:

```swift
    init(attachment: MailAttachment, uid: UInt32, folder: String, downloader: AttachmentDownloader?, folderBookmark: Data?) {
        self.attachment = attachment
        self.uid = uid
        self.folder = folder
        self.downloader = downloader
        self.folderBookmark = folderBookmark
        self.feedbackAttachment = nil
        self.feedbackDownloader = nil
        self.feedbackOnTap = nil
    }
```

In `private func tap()`:

```swift
    @Environment(QuickLookPresenter.self) private var quickLook

    private func tap() {
        if let onTap = feedbackOnTap {
            onTap()
            return
        }
        guard let downloader else { return }
        if let url = resolvedURL, FileManager.default.fileExists(atPath: url.path) {
            quickLook.present(urls: [url])
            return
        }
        state = .downloading
        Task {
            do {
                let url = try await downloader.download(
                    messageID: attachment.messageID,
                    uid: uid,
                    folder: folder,
                    partID: attachment.partID,
                    filename: attachment.filename,
                    folderBookmark: folderBookmark
                )
                resolvedURL = url
                state = .ready
                quickLook.present(urls: [url])
            } catch {
                state = .failed(message: error.localizedDescription)
            }
        }
    }
```

(Delete the old `openFile(_:)` helper or keep as fallback. The point is: every successful tap goes through `quickLook.present(urls:)` now.)

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Mail/AttachmentChipView.swift
git commit -m "feat(inbox): unify AttachmentChipView through QuickLookPresenter"
```

### Task H4: Wire app-level environment objects

**Files:**
- Modify: `AppFeedback/App/AppFeedbackApp.swift`

- [ ] **Step 1: Construct and inject the new services**

After the existing `@State`s for stores, add:

```swift
    @State private var thumbnailCache = ThumbnailCache()
    @State private var feedbackAttachmentDownloaderHolder = FeedbackAttachmentDownloaderHolder(nil)
    @State private var feedbackAttachmentLocalStore: FeedbackAttachmentLocalStore?
```

Where the SwiftData `ModelContainer` is created, after construction, materialize the local store and downloader on the main actor:

```swift
        let store = FeedbackAttachmentLocalStore(context: ModelContext(container))
        _feedbackAttachmentLocalStore = State(initialValue: store)
        let dl = FeedbackAttachmentDownloader(
            session: .shared,
            localStore: store,
            tokenProvider: { /* read PAT from auth service */ githubAuth.currentToken }
        )
        _feedbackAttachmentDownloaderHolder = State(initialValue: FeedbackAttachmentDownloaderHolder(dl))
```

(`githubAuth.currentToken` is illustrative — substitute the actual accessor used elsewhere in the app for the GitHub PAT.)

In the root view chain, attach:

```swift
            .environment(thumbnailCache)
            .environment(feedbackAttachmentDownloaderHolder)
```

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/App/AppFeedbackApp.swift
git commit -m "feat(inbox): wire ThumbnailCache + FeedbackAttachmentDownloader at app root"
```

---

## Phase I — Mail outbound attachments

### Task I1: Add `PendingAttachment` and extend `ComposeRequest`

**Files:**
- Modify: `AppFeedback/Views/Mail/ComposeRequest.swift`

- [ ] **Step 1: Add the type and field**

At the bottom of `ComposeRequest.swift`:

```swift
struct PendingAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
```

Extend `ComposeRequest` to include `var attachments: [PendingAttachment] = []`.

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Mail/ComposeRequest.swift
git commit -m "feat(mail): add PendingAttachment + ComposeRequest.attachments"
```

### Task I2: Extend `MailComposer.compose` (TDD)

**Files:**
- Modify: `AppFeedback/Services/Mail/MailComposer.swift`
- Create: `AppFeedbackTests/MailComposerAttachmentsTests.swift`

- [ ] **Step 1: Inspect `SwiftMail.Email` for the attachment-attachment API**

```bash
grep -rn "Attachment" ~/Library/Developer/Xcode/DerivedData -l 2>/dev/null | head -3
```

Or look at the SwiftMail source on GitHub: https://github.com/Cocoanetics/SwiftMail. The `SwiftMail.Email` type accepts an `attachments: [SwiftMail.Attachment]` initializer parameter or property. Confirm before writing the test.

- [ ] **Step 2: Write the failing test**

```swift
// AppFeedbackTests/MailComposerAttachmentsTests.swift
import XCTest
@testable import AppFeedback
#if canImport(SwiftMail)
import SwiftMail
#endif

final class MailComposerAttachmentsTests: XCTestCase {

    func test_compose_includes_attachments_when_provided() {
        let composer = MailComposer()
        let draft = DraftMessage(recipient: "u@example.com", subject: "Re", body: NSAttributedString(string: "Hi"))
        let context = PlaceholderContext(
            sender: SMTPCredentials(preset: .gmail, host: "smtp.gmail.com", port: 587,
                                    username: "me@example.com", senderName: "Me"),
            recipient: "u@example.com",
            appName: "App",
            issueTitle: nil,
            issueURL: nil,
            feedbackBody: nil,
            date: Date()
        )
        let template = MailTemplate(headerHTML: "", footerHTML: "")
        let pending = [
            PendingAttachment(filename: "shot.png", mimeType: "image/png", data: Data([1, 2, 3])),
            PendingAttachment(filename: "log.txt", mimeType: "text/plain", data: Data("log".utf8)),
        ]
        let email = composer.compose(
            draft: draft,
            context: context,
            template: template,
            attachments: pending
        )
        XCTAssertEqual(email.attachments?.count, 2)
        XCTAssertEqual(email.attachments?[0].filename, "shot.png")
        XCTAssertEqual(email.attachments?[0].mimeType, "image/png")
    }
}
```

- [ ] **Step 3: Run, expect fail**

Invoke zcode: "Run AppFeedbackTests/MailComposerAttachmentsTests on the AppFeedback macOS scheme."

Expected: FAIL — `attachments` argument doesn't exist on `compose`.

- [ ] **Step 4: Extend `MailComposer.compose`**

Add `attachments: [PendingAttachment] = []` parameter to the `compose(...)` signature. Inside, after constructing `email`, append:

```swift
        if !attachments.isEmpty {
            email.attachments = attachments.map { p in
                SwiftMail.Attachment(filename: p.filename, mimeType: p.mimeType, data: p.data)
            }
        }
```

If the `SwiftMail.Attachment` initializer differs, adapt to the actual API (likely the same shape but argument names may vary — check via `grep -rn "public struct Attachment" $(swift package describe --type json | jq -r ...)` if needed, or read source on github.com/Cocoanetics/SwiftMail).

- [ ] **Step 5: Run, expect pass**

Invoke zcode: "Run AppFeedbackTests/MailComposerAttachmentsTests on the AppFeedback macOS scheme."

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/Mail/MailComposer.swift \
        AppFeedbackTests/MailComposerAttachmentsTests.swift
git commit -m "feat(mail): MailComposer.compose accepts attachments"
```

### Task I3: Picker + drop + paste in `InlineReplyView`

**Files:**
- Modify: `AppFeedback/Views/Mail/InlineReplyView.swift`

- [ ] **Step 1: Add picker button, validation banner, and attachment strip**

Apply the same pattern from Phase D — a paperclip button next to "Send", a `.fileImporter` with the curated allowlist, a horizontal `AttachmentStripView`-like preview (build a `PendingAttachmentStripView` mirroring `AttachmentStripView` but using `PendingAttachment` instances; reuse `PendingAttachmentTile`-style tiles). Reuse `AttachmentChipsRow` for the chip row.

Concretely, copy the relevant code from `Sources/AppFeedbackUI/FeedbackSheet.swift` (the `attachmentsCard`, `ingest`, `revalidate`, drop modifier, and paste handler) and adapt it to `InlineReplyView`'s state model. Add `@State private var pendingAttachments: [PendingAttachment] = []` and `@State private var showFileImporter = false`.

Wire the validation: reuse `FeedbackAttachmentValidator` from the SDK (it's already a dependency). Disable Send while invalid.

When Send is tapped, pass `pendingAttachments` through `ComposeRequest` (or directly to the composer):

```swift
            let email = composer.compose(
                draft: draft,
                context: context,
                template: template,
                messageID: messageID,
                replyHeaders: replyHeaders,
                attachments: pendingAttachments
            )
```

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Mail/InlineReplyView.swift
git commit -m "feat(mail): InlineReplyView attachment picker (button + drop + paste)"
```

### Task I4: Picker + drop + paste in `ComposeFormCore`

**Files:**
- Modify: `AppFeedback/Views/Mail/ComposeFormCore.swift`
- Modify: `AppFeedback/ViewModels/ComposeMailViewModel.swift`

- [ ] **Step 1: Mirror the I3 changes in `ComposeFormCore`**

Same approach. `ComposeMailViewModel.send()` already builds the email via `composer.compose(...)` — extend that call site to pass attachments:

```swift
        let email = composer.compose(
            draft: draft,
            context: context,
            template: template,
            messageID: messageID,
            replyHeaders: replyHeaders,
            attachments: viewModel.pendingAttachments
        )
```

Add `var pendingAttachments: [PendingAttachment] = []` to `ComposeMailViewModel`.

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Views/Mail/ComposeFormCore.swift \
        AppFeedback/ViewModels/ComposeMailViewModel.swift
git commit -m "feat(mail): ComposeFormCore attachment picker + ViewModel plumbing"
```

---

## Phase J — Mail mirror (SDK→email thread)

### Task J1: Extend `PlaceholderContext` with attachments

**Files:**
- Modify: `AppFeedback/Services/Mail/MailComposer.swift`

- [ ] **Step 1: Add the field**

Edit the `PlaceholderContext` struct definition near the top of `MailComposer.swift`:

```swift
struct PlaceholderContext: Sendable {
    var sender: SMTPCredentials
    var recipient: String
    var appName: String
    var issueTitle: String?
    var issueURL: URL?
    var feedbackBody: String?
    var feedbackAttachments: [FeedbackAttachmentRef] = []
    var date: Date
}
```

- [ ] **Step 2: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds — all existing call sites use `feedbackAttachments` default.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/Mail/MailComposer.swift
git commit -m "feat(mail): PlaceholderContext.feedbackAttachments"
```

### Task J2: Render `{{feedback_attachments}}` (TDD)

**Files:**
- Modify: `AppFeedback/Services/Mail/MailComposer.swift`
- Create: `AppFeedbackTests/AttachmentMirrorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AppFeedbackTests/AttachmentMirrorTests.swift
import XCTest
@testable import AppFeedback

final class AttachmentMirrorTests: XCTestCase {

    private func context(with attachments: [FeedbackAttachmentRef]) -> PlaceholderContext {
        PlaceholderContext(
            sender: SMTPCredentials(preset: .gmail, host: "h", port: 1, username: "a@b", senderName: "A"),
            recipient: "u@example.com",
            appName: "App",
            issueTitle: "T",
            issueURL: URL(string: "https://example.com")!,
            feedbackBody: "Body",
            feedbackAttachments: attachments,
            date: Date()
        )
    }

    func test_placeholder_empty_when_no_attachments() {
        let composer = MailComposer()
        let out = composer.applyPlaceholders("Att: {{feedback_attachments}}", context: context(with: []))
        XCTAssertEqual(out, "Att: ")
    }

    func test_placeholder_renders_image_and_file_html_block() {
        let atts = [
            FeedbackAttachmentRef(
                filename: "shot.png", mimeType: "image/png",
                url: URL(string: "https://example.com/shot.png")!, sizeBytes: 1024
            ),
            FeedbackAttachmentRef(
                filename: "log.txt", mimeType: "text/plain",
                url: URL(string: "https://example.com/log.txt?a=1&b=2")!, sizeBytes: 512
            ),
        ]
        let composer = MailComposer()
        let out = composer.applyPlaceholders("X{{feedback_attachments}}Y", context: context(with: atts))
        XCTAssertTrue(out.contains("<img src=\"https://example.com/shot.png\""))
        XCTAssertTrue(out.contains("alt=\"shot.png\""))
        XCTAssertTrue(out.contains("<a href=\"https://example.com/log.txt?a=1&amp;b=2\">log.txt</a>"),
                      "ampersand in URL must be HTML-encoded")
        XCTAssertTrue(out.hasPrefix("X"))
        XCTAssertTrue(out.hasSuffix("Y"))
    }
}
```

- [ ] **Step 2: Run, expect fail**

Invoke zcode: "Run AppFeedbackTests/AttachmentMirrorTests on the AppFeedback macOS scheme."

Expected: FAIL — placeholder not implemented.

- [ ] **Step 3: Extend `applyPlaceholders`**

In `MailComposer.applyPlaceholders(_:context:)`, append before the final `return s`:

```swift
        s = s.replacingOccurrences(of: "{{feedback_attachments}}", with: renderAttachmentsHTML(context.feedbackAttachments))
```

Add the renderer:

```swift
    func renderAttachmentsHTML(_ attachments: [FeedbackAttachmentRef]) -> String {
        guard !attachments.isEmpty else { return "" }
        var html = "<div class=\"feedback-attachments\">"
        for a in attachments {
            let encodedURL = htmlEncode(a.url.absoluteString)
            let encodedName = htmlEncode(a.filename)
            if a.isImage {
                html += "<div><a href=\"\(encodedURL)\"><img src=\"\(encodedURL)\" alt=\"\(encodedName)\" style=\"max-width:240px;border-radius:6px\"/></a></div>"
            } else {
                let sizeText: String
                if let b = a.sizeBytes {
                    sizeText = " (\(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)))"
                } else { sizeText = "" }
                html += "<div><a href=\"\(encodedURL)\">\(encodedName)</a>\(sizeText)</div>"
            }
        }
        html += "</div>"
        return html
    }

    private func htmlEncode(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
```

(The encoder is conservative — applies `&` → `&amp;` *first* to avoid double-encoding entities.)

- [ ] **Step 4: Run, expect pass**

Invoke zcode: "Run AppFeedbackTests/AttachmentMirrorTests on the AppFeedback macOS scheme."

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Services/Mail/MailComposer.swift \
        AppFeedbackTests/AttachmentMirrorTests.swift
git commit -m "feat(mail): {{feedback_attachments}} placeholder renders HTML block"
```

### Task J3: Populate `feedbackAttachments` from the issue in `ComposeMailViewModel`

**Files:**
- Modify: `AppFeedback/ViewModels/ComposeMailViewModel.swift`

- [ ] **Step 1: Add to `placeholderContext`**

In `placeholderContext(date:)`, change the `PlaceholderContext` construction to include:

```swift
            feedbackAttachments: issue.attachments,
```

(Note: `issue` here is the existing `FeedbackIssue` reference on the view model.)

- [ ] **Step 2: Do the same in `InlineReplyView`**

Find where `InlineReplyView` builds its `PlaceholderContext` (it calls `composer.applyPlaceholders(...)` with one). Add the same `feedbackAttachments: issue.attachments,` field.

- [ ] **Step 3: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/ViewModels/ComposeMailViewModel.swift AppFeedback/Views/Mail/InlineReplyView.swift
git commit -m "feat(mail): wire issue.attachments into PlaceholderContext mirror"
```

### Task J4: Update default mail templates to use the new placeholder

**Files:**
- Modify: `AppFeedback/Models/MailSettings.swift` (or wherever default templates live)

- [ ] **Step 1: Find the default template strings**

```bash
grep -rn "feedback_body\|templateHeaderHTML\|templateFooterHTML" /Users/hayekamir/Developer/AppFeedback/AppFeedback --include="*.swift" | head
```

- [ ] **Step 2: Append `{{feedback_attachments}}` to the default body template**

In whichever file defines the default `templateHeaderHTML` / `templateFooterHTML` strings, add a block referencing `{{feedback_attachments}}` somewhere it makes sense — typically right after `{{feedback_body}}`, since the attachments belong with the original submission content. Example:

```swift
    static let defaultBodyHTML = """
    Original feedback:
    {{feedback_body}}
    {{feedback_attachments}}
    """
```

If the templates are user-customizable via settings, the placeholder is recognized either way — this step just sets a sensible default for new accounts.

- [ ] **Step 3: Build via zcode**

Invoke zcode: "Build the AppFeedback macOS scheme."

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/AppFeedback
git add AppFeedback/Models/MailSettings.swift
git commit -m "feat(mail): default template includes {{feedback_attachments}}"
```

---

## Phase K — Manual verification + final polish

### Task K1: End-to-end manual verification

- [ ] **Step 1: SDK → GitHub**

In `AppFeedbackSDK` ship a tiny example app (or use ClaudeUsage if it's already wired):

1. Set a test repo with a PAT that has `repo` scope.
2. Open the feedback sheet; pick a HEIC screenshot + a `.log` file; submit.
3. Verify on github.com: new issue exists; body contains `<!-- attachments-v1 -->`; image renders inline; log file is a link; `feedback-attachments` branch has been created and contains `attachments/<uuid>/screenshot.jpg` and `attachments/<uuid>/file.log`.

- [ ] **Step 2: Inbox issue viewer**

1. Open AppFeedback inbox.
2. Refresh issues; the new one shows in the list.
3. Open the card; verify the thumbnail strip shows the screenshot and the chip shows the log.
4. Tap the thumbnail → Quick Look opens with both items; arrow-keys flip between them.

- [ ] **Step 3: Mail mirror**

1. Reply to the issue from the inbox via `InlineReplyView`.
2. Confirm the rendered HTML (use the dev composer's "preview" if available, or send to yourself) contains the inline image embed and the link to the log.

- [ ] **Step 4: Outbound attachments**

1. In the same reply, attach a PNG via the paperclip + a JSON via drag-and-drop + paste a clipboard image.
2. Send.
3. Receive on the recipient side; confirm three attachments arrive as MIME parts.

- [ ] **Step 5: Inbound attachments + Quick Look**

1. Sync IMAP and locate a thread where the user replied with an attachment.
2. Tap the chip → Quick Look opens. (Previously it called `NSWorkspace.open`; the migration to QL should now be the default.)

- [ ] **Step 6: Note any regressions**

Run the full test suite (SDK and inbox) and fix any breakage.

```bash
cd ~/Developer/AppFeedbackSDK && swift test
# then via zcode: "Run all tests on the AppFeedback macOS scheme"
```

- [ ] **Step 7: Commit any fixes**

```bash
cd ~/Developer/AppFeedback
# (only if changes)
git commit -am "fix(post-verification): <details>"
```

---

## Acceptance checklist

- [ ] SDK: `FeedbackReport.attachments` accepted; validation rejects out-of-allowlist + oversize.
- [ ] SDK: HEIC inputs upload as JPEG (filename ext flipped); GPS stripped on images.
- [ ] SDK: `feedback-attachments` branch is created on first use; subsequent submissions reuse it.
- [ ] SDK: Issue body contains `<!-- attachments-v1 -->` block between extras and votes footer; images embed inline; non-images link.
- [ ] SDK: Failed upload after partial success → `attachmentUpload(filename:underlying:)` thrown; no issue created.
- [ ] SDK: Feedback sheet picker, drop, paste all add attachments; submit gates on validation banner.
- [ ] Inbox: `IssueBodyParser.parse` returns `attachments` field; `CachedIssue` persists JSON.
- [ ] Inbox: `IssueCardView` shows thumbnail strip + chips; tap opens Quick Look gallery starting at tapped index.
- [ ] Inbox: Quick Look gallery contains all issue attachments, navigable.
- [ ] Inbox: Existing mail chips also open via Quick Look (consistent UX).
- [ ] Mail outbound: composer accepts attachments; picker, drop, paste work in InlineReplyView and ComposeFormCore.
- [ ] Mail mirror: `{{feedback_attachments}}` placeholder renders inline images + file links; HTML-encoded.
- [ ] Limits enforced everywhere: 3 files, 5 MB each, 10 MB total.
- [ ] All new and existing tests pass on both SDK and inbox.
