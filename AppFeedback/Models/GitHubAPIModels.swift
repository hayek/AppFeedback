import Foundation

struct GitHubIssue: Decodable, Sendable {
    let number: Int
    let title: String
    let body: String?
    let createdAt: Date
    let pullRequest: PullRequestRef?
    let labels: [GitHubLabel]

    struct PullRequestRef: Decodable {}

    enum CodingKeys: String, CodingKey {
        case number, title, body, labels
        case createdAt = "created_at"
        case pullRequest = "pull_request"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pullRequest = try c.decodeIfPresent(PullRequestRef.self, forKey: .pullRequest)
        labels = (try? c.decode([GitHubLabel].self, forKey: .labels)) ?? []
    }
}

struct GitHubLabel: Decodable, Sendable {
    let name: String
    let color: String
}
