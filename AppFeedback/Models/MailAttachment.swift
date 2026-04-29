import Foundation
import SwiftData

@Model
final class MailAttachment {
    var id: UUID = UUID()
    var messageID: String = ""
    var partID: String = ""
    var filename: String = ""
    var mimeType: String = ""
    var sizeBytes: Int = 0
    var message: MailMessage? = nil

    init(
        id: UUID = UUID(),
        messageID: String = "",
        partID: String = "",
        filename: String = "",
        mimeType: String = "",
        sizeBytes: Int = 0,
        message: MailMessage? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.partID = partID
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.message = message
    }
}
