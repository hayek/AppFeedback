import Foundation

struct IssueLabel: Codable, Sendable, Hashable {
    let name: String
    let colorHex: String
}

enum IssueType: String {
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
    var detectedLanguageCode: String?
    var translatedTitle: String?
    var translatedBody: String?
    var translationTargetLanguage: String?

    var id: Int { number }

    func displayedTitle(translated: Bool) -> String {
        translated ? (translatedTitle ?? title) : title
    }

    func displayedBody(translated: Bool) -> String {
        translated ? (translatedBody ?? description) : description
    }

    var hasTranslation: Bool {
        translatedTitle != nil || translatedBody != nil
    }
}
