import Foundation

/// An editable subject/body template with `{placeholder}` tokens, rendered per recipient.
struct ReleaseEmailTemplate: Sendable {
    var subject: String
    var body: String

    struct Rendered: Sendable { let subject: String; let body: String }

    func render(appName: String, version: String, whatsNew: String, feedbackNumbers: [Int]) -> Rendered {
        let theirFeedbacks = feedbackNumbers.map { "#\($0)" }.joined(separator: ", ")
        func fill(_ s: String) -> String {
            s.replacingOccurrences(of: "{appName}", with: appName)
             .replacingOccurrences(of: "{version}", with: version)
             .replacingOccurrences(of: "{whatsNew}", with: whatsNew)
             .replacingOccurrences(of: "{theirFeedbacks}", with: theirFeedbacks)
        }
        return Rendered(subject: fill(subject), body: fill(body))
    }

    static func `default`(appName: String, version: String, whatsNew: String) -> ReleaseEmailTemplate {
        ReleaseEmailTemplate(
            subject: "{appName} {version} is out",
            body: """
            Hi,

            {appName} {version} is now available. Here's what's new:

            {whatsNew}

            This update addresses your feedback: {theirFeedbacks}

            Thanks for helping improve {appName}!
            """)
    }
}
