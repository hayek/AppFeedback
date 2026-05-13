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
    /// Seed value for the Subject field on new (non-reply) composes. Supports the same
    /// placeholders as header/footer templates. Empty string means "no default".
    var defaultSubjectTemplate: String = ""
    var attachmentFolderBookmark: Data? = nil
    var pollIntervalSeconds: Int = 300
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        templateHeaderHTML: String = "",
        templateFooterHTML: String = "",
        defaultSubjectTemplate: String = "",
        attachmentFolderBookmark: Data? = nil,
        pollIntervalSeconds: Int = 300,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.templateHeaderHTML = templateHeaderHTML
        self.templateFooterHTML = templateFooterHTML
        self.defaultSubjectTemplate = defaultSubjectTemplate
        self.attachmentFolderBookmark = attachmentFolderBookmark
        self.pollIntervalSeconds = pollIntervalSeconds
        self.createdAt = createdAt
    }
}
