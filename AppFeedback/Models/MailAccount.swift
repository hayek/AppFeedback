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
    var pollingEnabled: Bool = true
    var backfillCompleted: Bool = false
    /// Exactly one configured account has this true at a time. Used as the default FROM for
    /// new replies. `MailAccountStore` enforces the invariant.
    var isDefaultSender: Bool = false
    var createdAt: Date = Date()
    /// nil ⇒ legacy reply-mirror account; non-nil ⇒ feedback inbox for that product.
    /// The inbox-vs-reply-mirror "role" is DERIVED from this; there is no stored role.
    var feedbackProductID: UUID? = nil

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
        pollingEnabled: Bool = true,
        backfillCompleted: Bool = false,
        isDefaultSender: Bool = false,
        createdAt: Date = Date(),
        feedbackProductID: UUID? = nil
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
        self.pollingEnabled = pollingEnabled
        self.backfillCompleted = backfillCompleted
        self.isDefaultSender = isDefaultSender
        self.createdAt = createdAt
        self.feedbackProductID = feedbackProductID
    }

    var preset: SMTPCredentials.Preset {
        SMTPCredentials.Preset(rawValue: presetRaw) ?? .gmail
    }
}
