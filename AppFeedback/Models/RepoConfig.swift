import Foundation

struct RepoConfig: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var owner: String
    var repo: String
    var mirrorEmailsToGitHub: Bool
    var redactEmailAddresses: Bool
    var connectedRepoOwner: String?
    var connectedRepoName: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        owner: String,
        repo: String,
        mirrorEmailsToGitHub: Bool = true,
        redactEmailAddresses: Bool = true,
        connectedRepoOwner: String? = nil,
        connectedRepoName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.mirrorEmailsToGitHub = mirrorEmailsToGitHub
        self.redactEmailAddresses = redactEmailAddresses
        self.connectedRepoOwner = connectedRepoOwner
        self.connectedRepoName = connectedRepoName
    }
}
