import Foundation

/// Posts a comment to a GitHub issue. Used by `MailToGitHubMirror` to mirror outbound
/// and inbound emails into the corresponding issue thread, building a self-contained
/// conversation backup on GitHub even after this app disappears.
actor GitHubCommentPoster {
    enum PostError: LocalizedError {
        case apiError(Int, message: String?)

        var errorDescription: String? {
            switch self {
            case let .apiError(code, message?): return "GitHub API \(code): \(message)"
            case let .apiError(code, nil):      return "GitHub API \(code)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Posts `body` as a new issue comment. Returns the comment ID on success so the
    /// caller can persist it as a dedupe key.
    func postComment(
        owner: String,
        repo: String,
        issueNumber: Int,
        body: String,
        token: String
    ) async throws -> Int {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(issueNumber)/comments")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)",                forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json",   forHTTPHeaderField: "Accept")
        request.setValue("application/json",               forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PostError.apiError(0, message: nil)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw PostError.apiError(http.statusCode, message: message)
        }

        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = decoded?["id"] as? Int else {
            throw PostError.apiError(http.statusCode, message: "Missing id in response")
        }
        return id
    }
}
