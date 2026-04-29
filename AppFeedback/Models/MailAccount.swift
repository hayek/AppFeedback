import Foundation
import SwiftData

@Model
final class MailAccount {
    var id: UUID = UUID()
    var presetRaw: String = SMTPCredentials.Preset.gmail.rawValue
    var smtpHost: String = ""
    var smtpPort: Int = 587
    var smtpUsername: String = ""
    var senderName: String = ""
    var imapHost: String = ""
    var imapPort: Int = 993
    var imapUsername: String = ""
    var pollIntervalSeconds: Int = 300
    var pollingEnabled: Bool = true
    var attachmentFolderBookmark: Data? = nil
    var templateHeaderHTML: String = ""
    var templateFooterHTML: String = ""
    var backfillCompleted: Bool = false
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        presetRaw: String = SMTPCredentials.Preset.gmail.rawValue,
        smtpHost: String = "",
        smtpPort: Int = 587,
        smtpUsername: String = "",
        senderName: String = "",
        imapHost: String = "",
        imapPort: Int = 993,
        imapUsername: String = "",
        pollIntervalSeconds: Int = 300,
        pollingEnabled: Bool = true,
        attachmentFolderBookmark: Data? = nil,
        templateHeaderHTML: String = "",
        templateFooterHTML: String = "",
        backfillCompleted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.presetRaw = presetRaw
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.senderName = senderName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUsername = imapUsername
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollingEnabled = pollingEnabled
        self.attachmentFolderBookmark = attachmentFolderBookmark
        self.templateHeaderHTML = templateHeaderHTML
        self.templateFooterHTML = templateFooterHTML
        self.backfillCompleted = backfillCompleted
        self.createdAt = createdAt
    }

    var preset: SMTPCredentials.Preset {
        SMTPCredentials.Preset(rawValue: presetRaw) ?? .gmail
    }
}
