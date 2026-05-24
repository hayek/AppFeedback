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
