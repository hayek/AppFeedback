import Foundation

struct RepoConfig: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var owner: String
    var repo: String

    init(id: UUID = UUID(), displayName: String, owner: String, repo: String) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
    }
}
