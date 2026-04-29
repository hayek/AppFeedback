import Foundation
import SwiftData

@Model
final class MailAttachmentLocal {
    var messageID: String = ""
    var partID: String = ""
    var localPath: String = ""
    var downloadedAt: Date = Date()

    init(
        messageID: String = "",
        partID: String = "",
        localPath: String = "",
        downloadedAt: Date = Date()
    ) {
        self.messageID = messageID
        self.partID = partID
        self.localPath = localPath
        self.downloadedAt = downloadedAt
    }
}
