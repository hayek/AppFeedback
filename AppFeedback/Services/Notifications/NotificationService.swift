import Foundation
import SwiftUI
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
        let id = "appfeedback.summary.\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(req)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground: suppress banner — issue is already visible in the list.
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo["issueKey"] as? String
        Task { @MainActor in
            if let key { self.router.pendingIssueKey = key }
        }
        completionHandler()
    }
}

// MARK: - SwiftUI Environment

private struct NotificationServiceKey: EnvironmentKey {
    static let defaultValue: NotificationService? = nil
}

extension EnvironmentValues {
    var notificationService: NotificationService? {
        get { self[NotificationServiceKey.self] }
        set { self[NotificationServiceKey.self] = newValue }
    }
}

extension NotificationService {
    func requestAuthorizationIfNeeded() async {
        guard !settings.hasRequestedAuthorization else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        settings.hasRequestedAuthorization = true
        settings.isEnabled = granted
    }

    /// Mark all currently-loaded issues as already-notified, so the user isn't spammed
    /// with the existing backlog when notifications are first enabled.
    func snapshotExistingIssues(loadedByRepo: [RepoIssues]) {
        var keys: [String] = []
        for group in loadedByRepo {
            for issue in group.issues {
                keys.append(NotifiedIssueStore.issueKey(owner: group.owner, repo: group.repo, number: issue.number))
            }
        }
        notifiedStore.snapshot(keys)
    }
}
