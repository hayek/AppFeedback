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

    struct InboundReply: Sendable {
        struct IssueRef: Sendable {
            let owner: String
            let repo: String
            let number: Int
        }
        let messageID: String
        let fromName: String?
        let fromAddress: String
        let subject: String
        /// When the reply matched a GitHub issue, this triggers the deeplink on tap.
        let issue: IssueRef?
    }

    func notifyInboundReplies(_ replies: [InboundReply]) async {
        guard settings.isEnabled, !replies.isEmpty else { return }

        let fresh = replies.filter { !notifiedStore.contains(Self.replyKey($0.messageID)) }
        guard !fresh.isEmpty else { return }

        if fresh.count <= 3 {
            for reply in fresh {
                let sender = reply.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? reply.fromAddress
                var userInfo: [AnyHashable: Any] = [:]
                if let issue = reply.issue {
                    userInfo["issueKey"] = NotifiedIssueStore.issueKey(
                        owner: issue.owner, repo: issue.repo, number: issue.number
                    )
                }
                await send(
                    identifier: "appfeedback.reply.\(reply.messageID)",
                    title: "Reply from \(sender)",
                    subtitle: reply.subject,
                    threadID: Self.replyThreadID,
                    userInfo: userInfo
                )
            }
        } else {
            await send(
                identifier: "appfeedback.replysummary.\(UUID().uuidString)",
                title: "\(fresh.count) new replies",
                subtitle: nil,
                threadID: Self.replyThreadID
            )
        }

        notifiedStore.insert(fresh.map { Self.replyKey($0.messageID) })
    }

    private func send(
        identifier: String,
        title: String,
        subtitle: String?,
        threadID: String,
        userInfo: [AnyHashable: Any] = [:]
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.threadIdentifier = threadID
        content.sound = .default
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(req)
    }

    private static let replyThreadID = "appfeedback.newreply"
    private static func replyKey(_ messageID: String) -> String { "mail:\(messageID)" }
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
