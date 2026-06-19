import Foundation

struct IssueLabel: Codable, Sendable, Hashable {
    let name: String
    let colorHex: String
}

enum IssueState: String, Codable, Sendable {
    case open
    case closed
}

enum IssueType: String, Codable {
    case bug
    case featureRequest = "feature-request"

    var displayName: String {
        switch self {
        case .bug: return "Bug"
        case .featureRequest: return "Feature"
        }
    }

    var systemImage: String {
        switch self {
        case .bug: return "ant.fill"
        case .featureRequest: return "sparkles"
        }
    }
}

extension Array where Element == IssueLabel {
    var issueType: (type: IssueType, color: String)? {
        for label in self {
            if let t = IssueType(rawValue: label.name) { return (t, label.colorHex) }
        }
        return nil
    }

    var withoutTypeAndUserSubmitted: [IssueLabel] {
        filter { IssueType(rawValue: $0.name) == nil && $0.name != "user-submitted" }
    }
}

struct FeedbackIssue: Identifiable, Codable, Sendable {
    let number: Int
    let title: String
    let createdAt: Date
    let rawBody: String
    let appName: String?
    let appVersion: String?
    let device: String?
    let osVersion: String?
    let email: String?
    let description: String
    let labels: [IssueLabel]
    var updatedAt: Date?
    var state: IssueState?
    var milestoneTitle: String?
    var detectedLanguageCode: String?
    var translatedTitle: String?
    var translatedBody: String?
    var translationTargetLanguage: String?
    var attachments: [FeedbackAttachmentRef] = []
    var source: FeedbackSource = .sdk
    var rating: Int?

    var id: Int { number }

    init(
        number: Int,
        title: String,
        createdAt: Date,
        rawBody: String,
        appName: String?,
        appVersion: String?,
        device: String?,
        osVersion: String?,
        email: String?,
        description: String,
        labels: [IssueLabel],
        updatedAt: Date? = nil,
        state: IssueState? = nil,
        milestoneTitle: String? = nil,
        detectedLanguageCode: String? = nil,
        translatedTitle: String? = nil,
        translatedBody: String? = nil,
        translationTargetLanguage: String? = nil,
        attachments: [FeedbackAttachmentRef] = [],
        source: FeedbackSource = .sdk,
        rating: Int? = nil
    ) {
        self.number = number
        self.title = title
        self.createdAt = createdAt
        self.rawBody = rawBody
        self.appName = appName
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.email = email
        self.description = description
        self.labels = labels
        self.updatedAt = updatedAt
        self.state = state
        self.milestoneTitle = milestoneTitle
        self.detectedLanguageCode = detectedLanguageCode
        self.translatedTitle = translatedTitle
        self.translatedBody = translatedBody
        self.translationTargetLanguage = translationTargetLanguage
        self.attachments = attachments
        self.source = source
        self.rating = rating
    }

    func displayedTitle(translated: Bool) -> String {
        translated ? (translatedTitle ?? title) : title
    }

    func displayedBody(translated: Bool) -> String {
        translated ? (translatedBody ?? description) : description
    }

    /// True only when every non-empty field has a translation. A title-only partial
    /// (translatedBody nil while the body is non-empty) returns false so the UI never
    /// labels an issue "translated" while still showing its original-language body.
    var hasTranslation: Bool {
        let titleResolved = translatedTitle != nil || title.isEmpty
        let bodyResolved = translatedBody != nil || description.isEmpty
        let anyTranslated = translatedTitle != nil || translatedBody != nil
        return anyTranslated && titleResolved && bodyResolved
    }
}
