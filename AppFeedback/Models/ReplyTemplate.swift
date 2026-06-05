import Foundation
import SwiftData

@Model
final class ReplyTemplate: Identifiable {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), repoOwner: String, repoName: String,
         title: String, body: String,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
