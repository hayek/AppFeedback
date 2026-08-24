import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import SwiftUI
#endif

/// Names photo-library picks.
///
/// `PhotosPickerItem` carries no filename: the picker runs out of process, so all we get
/// back are bytes and a content type. Reading the real name would mean resolving the
/// `PHAsset`, which needs full photo-library authorization — the very prompt
/// `PHPickerViewController` exists to avoid. So we synthesise a name from the type.
enum PhotoAttachmentNaming {
    static let baseName = "Photo"

    /// - Parameter taken: names already spoken for — earlier picks in the same batch and
    ///   anything already on the compose strip — so a second pick doesn't shadow the first.
    static func descriptor(for type: UTType?, avoiding taken: Set<String>) -> (filename: String, mimeType: String) {
        let ext = type?.preferredFilenameExtension ?? "dat"
        // No guessing: an unmappable type gets an honestly-unsupported MIME, so the
        // validator names it rather than mislabelling the bytes as something they aren't.
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        var filename = "\(baseName).\(ext)"
        var suffix = 2
        while taken.contains(filename) {
            filename = "\(baseName)-\(suffix).\(ext)"
            suffix += 1
        }
        return (filename, mime)
    }
}

#if os(iOS)
/// Turns the picker's opaque items into `RawAttachmentInput`s the composer can ingest.
enum PhotoAttachmentLoader {

    /// Loads each pick's bytes in order, naming them as it goes so names stay unique
    /// across the batch. Items that fail to load are dropped — `ComposeFormCore` reports
    /// the shortfall, since a silent no-op reads as a broken button.
    static func load(_ items: [PhotosPickerItem], avoiding taken: Set<String>) async -> [RawAttachmentInput] {
        var used = taken
        var loaded: [RawAttachmentInput] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let descriptor = PhotoAttachmentNaming.descriptor(
                for: item.supportedContentTypes.first,
                avoiding: used
            )
            used.insert(descriptor.filename)
            loaded.append(RawAttachmentInput(
                filename: descriptor.filename,
                mimeType: descriptor.mimeType,
                data: data
            ))
        }
        return loaded
    }
}
#endif
