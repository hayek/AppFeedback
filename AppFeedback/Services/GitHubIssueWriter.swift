import Foundation

/// One issue as GitHub currently has it. `tasks link` rewrites the machine-managed addresses
/// block against this rather than the cache, which can be up to a poll interval behind.
struct FetchedIssue: Sendable {
    let number: Int
    let title: String
    let body: String
    let labels: [String]
    let state: String
}

/// Narrow seam over `GitHubIssueWriter` so synthesis coordinators can inject a fake writer in
/// tests. The signatures mirror the actor's exactly.
protocol IssueWriting: Sendable {
    func createIssue(owner: String, repo: String, title: String, body: String,
                     labels: [String], milestoneNumber: Int?, token: String) async throws -> Int
    func updateIssue(owner: String, repo: String, number: Int,
                     title: String?, body: String?, labels: [String]?,
                     milestoneNumber: Int??, state: String?, token: String) async throws
    func fetchIssue(owner: String, repo: String, number: Int, token: String) async throws -> FetchedIssue
}

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

        /// True when the issue no longer exists on GitHub (REST 404, or the GraphQL
        /// "Could not resolve to an Issue" error). Lets callers purge a stale phantom.
        var isNotFound: Bool {
            guard case let .apiError(code, message) = self else { return false }
            if code == 404 { return true }
            guard let message else { return false }
            return message.localizedCaseInsensitiveContains("could not resolve")
                || message.localizedCaseInsensitiveContains("not found")
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

    /// Reads one issue. `tasks link`/`unlink` need the LIVE body: rewriting the addresses block
    /// from the cached copy would clobber any edit made since the last poll.
    func fetchIssue(owner: String, repo: String, number: Int, token: String) async throws -> FetchedIssue {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)")!)
        request.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WriteError.apiError(0, message: nil) }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw WriteError.apiError(http.statusCode, message: message)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issueNumber = object["number"] as? Int else {
            throw WriteError.apiError(http.statusCode, message: "Malformed issue response")
        }
        return FetchedIssue(
            number: issueNumber,
            title: object["title"] as? String ?? "",
            body: object["body"] as? String ?? "",
            labels: (object["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [],
            state: object["state"] as? String ?? "open")
    }

    /// PATCHes any subset of issue fields. Pass `state` as "open"/"closed".
    func updateIssue(owner: String, repo: String, number: Int,
                     title: String? = nil, body: String? = nil, labels: [String]? = nil,
                     milestoneNumber: Int?? = nil, state: String? = nil, token: String) async throws {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
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

    /// Permanently deletes the issue via GraphQL (REST has no delete). Requires the caller to have
    /// admin/maintain on the repo (or be its owner).
    func deleteIssue(owner: String, repo: String, number: Int, token: String) async throws {
        let idResponse = try await graphQL(
            query: "query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}",
            variables: ["o": owner, "n": repo, "num": number], token: token)
        if let errors = idResponse["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw WriteError.apiError(0, message: message)
        }
        guard let id = (((idResponse["data"] as? [String: Any])?["repository"] as? [String: Any])?["issue"] as? [String: Any])?["id"] as? String else {
            throw WriteError.apiError(0, message: "Issue not found")
        }
        let delResponse = try await graphQL(
            query: "mutation($id:ID!){deleteIssue(input:{issueId:$id}){clientMutationId}}",
            variables: ["id": id], token: token)
        if let errors = delResponse["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw WriteError.apiError(0, message: message)
        }
    }

    private func graphQL(query: String, variables: [String: Any], token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WriteError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0, message: nil)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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

extension GitHubIssueWriter: IssueWriting {}
