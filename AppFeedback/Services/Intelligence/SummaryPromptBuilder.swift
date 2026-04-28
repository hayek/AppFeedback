import Foundation

enum SummaryPromptBuilder {
    static let issueCap = 30
    static let bodyCharCap = 200

    static func build(issues: [FeedbackIssue], targetLanguage: String) -> String {
        let included = Array(issues.prefix(issueCap))
        let extra = max(0, issues.count - issueCap)

        var lines: [String] = []
        lines.append("Summarize the following unread feedback issues.")
        lines.append("Target output language: \(languageDisplayName(targetLanguage)).")
        lines.append("Group related issues into 3-5 themed bullets, each with an issueCount.")
        lines.append("")

        for issue in included {
            let body = stripCodeBlocks(issue.description)
                .prefix(bodyCharCap)
            let labels = issue.labels.map(\.name).joined(separator: ", ")
            let labelSuffix = labels.isEmpty ? "" : " [labels: \(labels)]"
            lines.append("- #\(issue.number) \(issue.title): \(body)\(labelSuffix)")
        }

        if extra > 0 {
            lines.append("")
            lines.append("(+\(extra) more issues not shown)")
        }
        return lines.joined(separator: "\n")
    }

    static func stripCodeBlocks(_ text: String) -> String {
        var result = text
        while let openRange = result.range(of: "```") {
            let afterOpen = openRange.upperBound
            if let closeRange = result.range(of: "```", range: afterOpen..<result.endIndex) {
                result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
            } else {
                result.replaceSubrange(openRange.lowerBound..<result.endIndex, with: "")
                break
            }
        }
        return result.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("    ") }
            .joined(separator: "\n")
    }

    private static func languageDisplayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
