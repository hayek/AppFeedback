import Foundation
import SwiftData

@Model
final class CachedIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var number: Int = 0
    var title: String = ""
    var createdAt: Date = Date()
    var rawBody: String = ""
    var appName: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var issueDescription: String = ""
    var labelsJSON: String?

    init(
        repoOwner: String,
        repoName: String,
        number: Int,
        title: String,
        createdAt: Date,
        rawBody: String,
        appName: String?,
        appVersion: String?,
        device: String?,
        osVersion: String?,
        email: String?,
        issueDescription: String,
        labels: [IssueLabel] = []
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.number = number
        self.title = title
        self.createdAt = createdAt
        self.rawBody = rawBody
        self.appName = appName
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.email = email
        self.issueDescription = issueDescription
        self.labelsJSON = Self.encode(labels)
    }

    func toFeedbackIssue() -> FeedbackIssue {
        FeedbackIssue(
            number: number,
            title: title,
            createdAt: createdAt,
            rawBody: rawBody,
            appName: appName,
            appVersion: appVersion,
            device: device,
            osVersion: osVersion,
            email: email,
            description: issueDescription,
            labels: Self.decode(labelsJSON)
        )
    }

    static func from(_ issue: FeedbackIssue, repoOwner: String, repoName: String) -> CachedIssue {
        CachedIssue(
            repoOwner: repoOwner,
            repoName: repoName,
            number: issue.number,
            title: issue.title,
            createdAt: issue.createdAt,
            rawBody: issue.rawBody,
            appName: issue.appName,
            appVersion: issue.appVersion,
            device: issue.device,
            osVersion: issue.osVersion,
            email: issue.email,
            issueDescription: issue.description,
            labels: issue.labels
        )
    }

    private static func encode(_ labels: [IssueLabel]) -> String? {
        guard !labels.isEmpty, let data = try? JSONEncoder().encode(labels) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ json: String?) -> [IssueLabel] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([IssueLabel].self, from: data)) ?? []
    }
}
