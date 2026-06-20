import Foundation
@testable import AppFeedback

/// Records create/update calls and returns deterministic issue numbers so coordinator tests can
/// assert synthesis without touching the network.
actor FakeIssueWriting: IssueWriting {
    struct CreateCall: Sendable { let owner, repo, title, body: String; let labels: [String] }
    struct UpdateCall: Sendable { let owner, repo: String; let number: Int; let title: String?; let body: String?; let labels: [String]?; let state: String? }

    private(set) var creates: [CreateCall] = []
    private(set) var updates: [UpdateCall] = []
    private var nextNumber: Int
    var failNextCreate = false

    init(startingNumber: Int = 100) { self.nextNumber = startingNumber }

    func createIssue(owner: String, repo: String, title: String, body: String,
                     labels: [String], milestoneNumber: Int?, token: String) async throws -> Int {
        if failNextCreate { failNextCreate = false; throw GitHubIssueWriter.WriteError.apiError(500, message: "synthetic") }
        creates.append(CreateCall(owner: owner, repo: repo, title: title, body: body, labels: labels))
        defer { nextNumber += 1 }
        return nextNumber
    }
    func updateIssue(owner: String, repo: String, number: Int,
                     title: String?, body: String?, labels: [String]?,
                     milestoneNumber: Int??, state: String?, token: String) async throws {
        updates.append(UpdateCall(owner: owner, repo: repo, number: number, title: title, body: body, labels: labels, state: state))
    }
}
