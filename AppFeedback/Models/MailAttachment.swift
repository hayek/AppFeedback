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
    var contentID: String? = nil
    var message: MailMessage? = nil

    var isInlineImage: Bool {
        contentID != nil && mimeType.lowercased().hasPrefix("image/")
    }

    init(
        id: UUID = UUID(),
        messageID: String = "",
        partID: String = "",
        filename: String = "",
        mimeType: String = "",
        sizeBytes: Int = 0,
        contentID: String? = nil,
        message: MailMessage? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.partID = partID
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentID = contentID
        self.message = message
    }
}
