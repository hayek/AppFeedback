import Foundation
import SwiftData

@Model
final class MailAccountLocalState {
    @Attribute(.unique) var accountID: UUID = UUID()
    var inboxLastUID: UInt32 = 0
    var inboxUIDValidity: UInt32 = 0
    var sentLastUID: UInt32 = 0
    var sentUIDValidity: UInt32 = 0
    var lastSuccessfulPollAt: Date? = nil
    var consecutiveFailures: Int = 0

    init(
        accountID: UUID = UUID(),
        inboxLastUID: UInt32 = 0,
        inboxUIDValidity: UInt32 = 0,
        sentLastUID: UInt32 = 0,
        sentUIDValidity: UInt32 = 0,
        lastSuccessfulPollAt: Date? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.accountID = accountID
        self.inboxLastUID = inboxLastUID
        self.inboxUIDValidity = inboxUIDValidity
        self.sentLastUID = sentLastUID
        self.sentUIDValidity = sentUIDValidity
        self.lastSuccessfulPollAt = lastSuccessfulPollAt
        self.consecutiveFailures = consecutiveFailures
    }
}
