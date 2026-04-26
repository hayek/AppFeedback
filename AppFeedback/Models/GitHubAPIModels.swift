import Foundation

struct GitHubIssue: Decodable, Sendable {
    let number: Int
    let title: String
    let body: String?
    let createdAt: Date
    let pullRequest: PullRequestRef?

    struct PullRequestRef: Decodable {}

    enum CodingKeys: String, CodingKey {
        case number, title, body
        case createdAt = "created_at"
        case pullRequest = "pull_request"
    }
}
