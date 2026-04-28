import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject {
    private let center: UserNotificationCenterProtocol
    private let notifiedStore: NotifiedIssueStore
    private let settings: NotificationSettings
    private let router: NotificationRouter

    init(
        center: UserNotificationCenterProtocol,
        notifiedStore: NotifiedIssueStore,
        settings: NotificationSettings,
        router: NotificationRouter
    ) {
        self.center = center
        self.notifiedStore = notifiedStore
        self.settings = settings
        self.router = router
    }

    /// Group of issues currently loaded for one repo.
    typealias RepoIssues = (owner: String, repo: String, issues: [FeedbackIssue])

    func diffAndNotify(loadedByRepo: [RepoIssues]) async {
        guard settings.isEnabled else { return }

        var newOnes: [(repoOwner: String, repoName: String, issue: FeedbackIssue, key: String)] = []
        for group in loadedByRepo {
            for issue in group.issues {
                let key = NotifiedIssueStore.issueKey(
                    owner: group.owner, repo: group.repo, number: issue.number
                )
                if !notifiedStore.contains(key) {
                    newOnes.append((group.owner, group.repo, issue, key))
                }
            }
        }
        guard !newOnes.isEmpty else { return }

        if newOnes.count <= 3 {
            for entry in newOnes {
                await postSingle(owner: entry.repoOwner, repo: entry.repoName, issue: entry.issue, key: entry.key)
            }
        } else {
            await postSummary(count: newOnes.count)
        }

        notifiedStore.insert(newOnes.map(\.key))
    }

    private func postSingle(owner: String, repo: String, issue: FeedbackIssue, key: String) async {
        let content = UNMutableNotificationContent()
        content.title = issue.title
        content.subtitle = "\(owner)/\(repo)"
        content.userInfo = ["issueKey": key]
        content.threadIdentifier = "appfeedback.newissue"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "appfeedback.\(key)", content: content, trigger: nil)
        try? await center.add(req)
    }

    private func postSummary(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(count) new issues"
        content.threadIdentifier = "appfeedback.newissue"
        content.sound = .default
        let id = "appfeedback.summary.\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(req)
    }
}
