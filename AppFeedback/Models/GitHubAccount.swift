import Foundation
import SwiftData

@Model
final class GitHubAccount {
    var id: UUID = UUID()
    /// GitHub username (login), e.g. "octocat". Case-insensitive identity key.
    var login: String = ""
    /// owner.avatar_url from GET /user, for the section header. Optional for CloudKit.
    var avatarURL: String? = nil
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        login: String = "",
        avatarURL: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.createdAt = createdAt
    }
}
