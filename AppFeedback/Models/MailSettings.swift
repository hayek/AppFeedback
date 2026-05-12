import Foundation
import SwiftData

/// Shared mail settings that apply across all configured `MailAccount`s. The store keeps a
/// single row; if more exist they are coalesced to the oldest one. CloudKit-synced so a new
/// device picks up the user's header/footer and folder choice on first launch.
@Model
final class MailSettings {
    var id: UUID = UUID()
    var templateHeaderHTML: String = ""
    var templateFooterHTML: String = ""
    var attachmentFolderBookmark: Data? = nil
    var pollIntervalSeconds: Int = 300
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        templateHeaderHTML: String = "",
        templateFooterHTML: String = "",
        attachmentFolderBookmark: Data? = nil,
        pollIntervalSeconds: Int = 300,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.templateHeaderHTML = templateHeaderHTML
        self.templateFooterHTML = templateFooterHTML
        self.attachmentFolderBookmark = attachmentFolderBookmark
        self.pollIntervalSeconds = pollIntervalSeconds
        self.createdAt = createdAt
    }
}
