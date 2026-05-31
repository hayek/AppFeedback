import Foundation

/// REST client for GitHub milestones, releases, and label bootstrap. Same conventions as
/// `GitHubIssueWriter`/`GitHubCommentPoster`.
actor GitHubMilestoneReleaseClient {
    struct Milestone: Sendable, Equatable {
        let number: Int
        let title: String
        let state: String          // "open" | "closed"
        let description: String?
    }
    struct Release: Sendable, Equatable {
        let id: Int
        let tagName: String
        let draft: Bool
    }
    enum ClientError: LocalizedError {
        case apiError(Int, message: String?)
        var errorDescription: String? {
            switch self {
            case let .apiError(c, m?): return "GitHub API \(c): \(m)"
            case let .apiError(c, nil): return "GitHub API \(c)"
            }
        }
    }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    // MARK: Milestones

    func listMilestones(owner: String, repo: String, token: String) async throws -> [Milestone] {
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/milestones?state=all&per_page=100",
                                  method: "GET", json: nil, token: token)
        let arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return arr.map(Self.milestone(from:))
    }

    func createMilestone(owner: String, repo: String, title: String, description: String, token: String) async throws -> Milestone {
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/milestones",
            method: "POST", json: ["title": title, "description": description], token: token)
        return Self.milestone(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func updateMilestone(owner: String, repo: String, number: Int,
                         title: String? = nil, description: String? = nil, state: String? = nil, token: String) async throws -> Milestone {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let description { payload["description"] = description }
        if let state { payload["state"] = state }
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/milestones/\(number)",
            method: "PATCH", json: payload, token: token)
        return Self.milestone(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    // MARK: Releases

    func createRelease(owner: String, repo: String, tag: String, name: String, body: String,
                       draft: Bool, target: String?, token: String) async throws -> Release {
        var payload: [String: Any] = ["tag_name": tag, "name": name, "body": body, "draft": draft]
        if let target { payload["target_commitish"] = target }
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/releases",
            method: "POST", json: payload, token: token)
        return Self.release(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func updateRelease(owner: String, repo: String, id: Int, body: String? = nil, draft: Bool? = nil, token: String) async throws -> Release {
        var payload: [String: Any] = [:]
        if let body { payload["body"] = body }
        if let draft { payload["draft"] = draft }
        let data = try await send("https://api.github.com/repos/\(owner)/\(repo)/releases/\(id)",
            method: "PATCH", json: payload, token: token)
        return Self.release(from: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    // MARK: Labels (bootstrap)

    /// Idempotently creates a label; a 422 "already_exists" is treated as success.
    func ensureLabel(owner: String, repo: String, name: String, color: String, token: String) async throws {
        do {
            _ = try await send("https://api.github.com/repos/\(owner)/\(repo)/labels",
                method: "POST", json: ["name": name, "color": color], token: token)
        } catch ClientError.apiError(422, _) {
            return   // already exists
        }
    }

    // MARK: - Mapping + request

    private static func milestone(from d: [String: Any]) -> Milestone {
        Milestone(number: d["number"] as? Int ?? 0,
                  title: d["title"] as? String ?? "",
                  state: d["state"] as? String ?? "open",
                  description: d["description"] as? String)
    }
    private static func release(from d: [String: Any]) -> Release {
        Release(id: d["id"] as? Int ?? 0,
                tagName: d["tag_name"] as? String ?? "",
                draft: d["draft"] as? Bool ?? false)
    }

    @discardableResult
    private func send(_ url: String, method: String, json: [String: Any]?, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.apiError(0, message: nil) }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw ClientError.apiError(http.statusCode, message: message)
        }
        return data
    }
}
