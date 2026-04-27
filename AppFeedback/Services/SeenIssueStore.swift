import Foundation
import SwiftData

@MainActor
final class SeenIssueStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func seenNumbers(owner: String, repo: String) -> Set<Int> {
        let predicate = #Predicate<SeenIssue> {
            $0.repoOwner == owner && $0.repoName == repo
        }
        let descriptor = FetchDescriptor<SeenIssue>(predicate: predicate)
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.issueNumber))
    }

    func markSeen(owner: String, repo: String, issueNumber: Int) {
        guard !exists(owner: owner, repo: repo, issueNumber: issueNumber) else { return }
        context.insert(SeenIssue(repoOwner: owner, repoName: repo, issueNumber: issueNumber))
        try? context.save()
    }

    func markSeenBulk(owner: String, repo: String, issueNumbers: [Int]) {
        guard !issueNumbers.isEmpty else { return }
        let existing = seenNumbers(owner: owner, repo: repo)
        var inserted = false
        for n in issueNumbers where !existing.contains(n) {
            context.insert(SeenIssue(repoOwner: owner, repoName: repo, issueNumber: n))
            inserted = true
        }
        if inserted { try? context.save() }
    }

    private func exists(owner: String, repo: String, issueNumber: Int) -> Bool {
        let predicate = #Predicate<SeenIssue> {
            $0.repoOwner == owner && $0.repoName == repo && $0.issueNumber == issueNumber
        }
        var descriptor = FetchDescriptor<SeenIssue>(predicate: predicate)
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first) != nil
    }
}
