import Foundation

/// Creates and mutates GitHub issues used to model tasks. Mirrors `GitHubCommentPoster`'s
/// REST conventions: injected session, Bearer token, 2xx check, typed error.
actor GitHubIssueWriter {
    enum WriteError: LocalizedError {
        case apiError(Int, message: String?)
        var errorDescription: String? {
            switch self {
            case let .apiError(code, message?): return "GitHub API \(code): \(message)"
            case let .apiError(code, nil):      return "GitHub API \(code)"
            }
        }
    }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// Creates an issue and returns its number.
    func createIssue(owner: String, repo: String, title: String, body: String,
                     labels: [String], milestoneNumber: Int?, token: String) async throws -> Int {
        var payload: [String: Any] = ["title": title, "body": body, "labels": labels]
        if let milestoneNumber { payload["milestone"] = milestoneNumber }
        let data = try await send(
            "https://api.github.com/repos/\(owner)/\(repo)/issues",
            method: "POST", json: payload, token: token)
        guard let number = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["number"] as? Int else {
            throw WriteError.apiError(0, message: "Missing number in response")
        }
        return number
    }

    /// PATCHes any subset of issue fields. Pass `state` as "open"/"closed".
    func updateIssue(owner: String, repo: String, number: Int,
                     body: String? = nil, labels: [String]? = nil,
                     milestoneNumber: Int?? = nil, state: String? = nil, token: String) async throws {
        var payload: [String: Any] = [:]
        if let body { payload["body"] = body }
        if let labels { payload["labels"] = labels }
        if let state { payload["state"] = state }
        if let milestoneNumber {                      // double optional: .some(nil) clears it
            payload["milestone"] = milestoneNumber as Any? ?? NSNull()
        }
        _ = try await send(
            "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)",
            method: "PATCH", json: payload, token: token)
    }

    // MARK: - Shared request

    @discardableResult
    private func send(_ url: String, method: String, json: [String: Any], token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)",              forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json",  forHTTPHeaderField: "Accept")
        request.setValue("application/json",             forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WriteError.apiError(0, message: nil) }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw WriteError.apiError(http.statusCode, message: message)
        }
        return data
    }
}
