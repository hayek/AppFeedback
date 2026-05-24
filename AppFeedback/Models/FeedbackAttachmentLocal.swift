import Foundation
import SwiftData

@Model
final class FeedbackAttachmentLocal {
    @Attribute(.unique) var url: String = ""
    var localPath: String = ""
    var downloadedAt: Date = Date()

    init(url: String, localPath: String, downloadedAt: Date) {
        self.url = url
        self.localPath = localPath
        self.downloadedAt = downloadedAt
    }
}
