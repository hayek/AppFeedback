import Foundation
import SwiftData

@Model
final class MailAttachmentLocal {
    var id: UUID = UUID()
    var messageID: String = ""
    var partID: String = ""
    var localPath: String = ""
    var downloadedAt: Date = Date()

    init(
        id: UUID = UUID(),
        messageID: String = "",
        partID: String = "",
        localPath: String = "",
        downloadedAt: Date = Date()
    ) {
        self.id = id
        self.messageID = messageID
        self.partID = partID
        self.localPath = localPath
        self.downloadedAt = downloadedAt
    }
}
