import XCTest
import UniformTypeIdentifiers
@testable import AppFeedback

#if canImport(SwiftMail)

/// `PhotosPickerItem` exposes no filename — reading the real one would require a full
/// photo-library authorization prompt that `PHPickerViewController` otherwise avoids.
/// These cover the naming/MIME we synthesise from the item's content type instead.
final class PhotoAttachmentNamingTests: XCTestCase {

    func test_descriptor_pngPickDerivesExtensionAndMIME() {
        let d = PhotoAttachmentNaming.descriptor(for: .png, avoiding: [])
        XCTAssertEqual(d.filename, "Photo.png")
        XCTAssertEqual(d.mimeType, "image/png")
    }

    /// HEIC must stay HEIC here: `ImagePreprocessor` keys off `image/heic` to transcode
    /// to JPEG. Naming it jpeg up front would skip the transcode.
    func test_descriptor_heicPickKeepsHEICMIME() {
        let d = PhotoAttachmentNaming.descriptor(for: .heic, avoiding: [])
        XCTAssertEqual(d.filename, "Photo.heic")
        XCTAssertEqual(d.mimeType, "image/heic")
    }

    func test_descriptor_suffixesNameAlreadyTaken() {
        let d = PhotoAttachmentNaming.descriptor(for: .png, avoiding: ["Photo.png"])
        XCTAssertEqual(d.filename, "Photo-2.png")
    }

    func test_descriptor_keepsCountingPastTheFirstSuffix() {
        let d = PhotoAttachmentNaming.descriptor(for: .png, avoiding: ["Photo.png", "Photo-2.png"])
        XCTAssertEqual(d.filename, "Photo-3.png")
    }

    /// A pick whose type we can't map gets an honestly-unsupported MIME so the validator
    /// says so, rather than a guess that mislabels the bytes.
    func test_descriptor_unknownTypeIsNotGuessed() {
        let d = PhotoAttachmentNaming.descriptor(for: nil, avoiding: [])
        XCTAssertEqual(d.filename, "Photo.dat")
        XCTAssertEqual(d.mimeType, "application/octet-stream")
    }
}

#endif
