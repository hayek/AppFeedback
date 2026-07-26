import Foundation
import SwiftData

@Model
final class CachedIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var number: Int = 0
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Raw `IssueState.rawValue`. SwiftData stores primitives, so the typed view goes through
    /// `issueState`/`setIssueState`. Predicates compare against `IssueState.open.rawValue`.
    var state: String = IssueState.open.rawValue
    var rawBody: String = ""
    var appName: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var issueDescription: String = ""
    var labelsJSON: String?
    var milestoneTitle: String?
    var detectedLanguageCode: String?
    var translatedTitle: String?
    var translatedBody: String?
    var translationTargetLanguage: String?
    var attachmentsJSON: String?
    /// Originating feedback source raw value ("sdk" | "app-store" | "email");
    /// nil for legacy issues cached before Phase 1 — treated as `.sdk` on read.
    var source: String?
    /// App Store star rating (1…5) for App Store reviews; nil otherwise.
    var rating: Int?

    init(
        repoOwner: String,
        repoName: String,
        number: Int,
        title: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        state: IssueState = .open,
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
        self.updatedAt = updatedAt ?? createdAt
        self.state = state.rawValue
        self.rawBody = rawBody
        self.appName = appName
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.email = email
        self.issueDescription = issueDescription
        self.labelsJSON = Self.encodeLabels(labels)
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
            labels: Self.decodeLabels(labelsJSON),
            // Carry state/updatedAt back out so the cache round-trip is lossless. The UI's
            // cache path only ever loads OPEN rows, so this changes nothing there; the CLI
            // reads every state and needs both fields to be truthful.
            updatedAt: updatedAt,
            state: IssueState(rawValue: state) ?? .open,
            milestoneTitle: milestoneTitle,
            detectedLanguageCode: detectedLanguageCode,
            translatedTitle: translatedTitle,
            translatedBody: translatedBody,
            translationTargetLanguage: translationTargetLanguage,
            attachments: Self.decodeAttachments(attachmentsJSON),
            source: FeedbackSource(rawValue: source ?? "") ?? .sdk,
            rating: rating
        )
    }

    static func from(_ issue: FeedbackIssue, repoOwner: String, repoName: String) -> CachedIssue {
        let cached = CachedIssue(
            repoOwner: repoOwner,
            repoName: repoName,
            number: issue.number,
            title: issue.title,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt ?? issue.createdAt,
            state: issue.state ?? .open,
            rawBody: issue.rawBody,
            appName: issue.appName,
            appVersion: issue.appVersion,
            device: issue.device,
            osVersion: issue.osVersion,
            email: issue.email,
            issueDescription: issue.description,
            labels: issue.labels
        )
        cached.milestoneTitle = issue.milestoneTitle
        cached.attachmentsJSON = Self.encodeAttachments(issue.attachments)
        cached.source = issue.source.rawValue
        cached.rating = issue.rating
        return cached
    }

    /// Updates GitHub-side fields in place. Translation fields are intentionally untouched
    /// so on-device translations survive every refresh.
    func updateFromRemote(_ issue: FeedbackIssue) {
        self.title = issue.title
        self.createdAt = issue.createdAt
        self.updatedAt = issue.updatedAt ?? issue.createdAt
        self.state = (issue.state ?? IssueState(rawValue: state) ?? .open).rawValue
        self.rawBody = issue.rawBody
        self.appName = issue.appName
        self.appVersion = issue.appVersion
        self.device = issue.device
        self.osVersion = issue.osVersion
        self.email = issue.email
        self.issueDescription = issue.description
        self.milestoneTitle = issue.milestoneTitle
        self.labelsJSON = Self.encodeLabels(issue.labels)
        self.attachmentsJSON = Self.encodeAttachments(issue.attachments)
        self.source = issue.source.rawValue
        self.rating = issue.rating
    }

    static func encodeLabels(_ labels: [IssueLabel]) -> String? {
        guard !labels.isEmpty, let data = try? JSONEncoder().encode(labels) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeLabels(_ json: String?) -> [IssueLabel] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([IssueLabel].self, from: data)) ?? []
    }

    static func encodeAttachments(_ refs: [FeedbackAttachmentRef]) -> String? {
        guard !refs.isEmpty, let data = try? JSONEncoder().encode(refs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeAttachments(_ json: String?) -> [FeedbackAttachmentRef] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FeedbackAttachmentRef].self, from: data)) ?? []
    }
}
