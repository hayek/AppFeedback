import Foundation

/// What the summary prompt emphasizes (picked in ``IssueListViewModel/aiSummarizesUnreadIssuesOnly``).
enum AISummaryPromptContext: Equatable, Sendable {
    case unreadIssues
    case rollingLastThirtyDays
}

enum SummaryPromptBuilder {
    /// First attempt favors coverage; subsequent pairs shrink prompts for the 4096-token session ceiling (TN3193).
    static func contextSafeConfigs() -> [(issueCap: Int, bodyCharCap: Int)] {
        [(28, 160), (20, 120), (14, 80), (8, 56), (5, 40)]
    }

    /// Maximum issues embedded before an “(+ N more…)“ line — used when tests pin older expectations.
    static let defaultIssueCap = 28
    /// Truncated body snippet length per ticket.
    static let defaultBodyCharCap = 160

    static func build(
        issues: [FeedbackIssue],
        targetLanguage: String,
        issueCap: Int = defaultIssueCap,
        bodyCharCap: Int = defaultBodyCharCap,
        promptContext: AISummaryPromptContext = .rollingLastThirtyDays
    ) -> String {
        let included = Array(issues.prefix(max(issueCap, 1)))
        let extra = max(0, issues.count - included.count)

        var lines: [String] = []
        switch promptContext {
        case .unreadIssues:
            lines.append("Each issue below is new / unread in this inbox right now (newest first).")
            lines.append("Summarize what's fresh for the reviewer: themes, urgency, standout praise vs pain.")
        case .rollingLastThirtyDays:
            lines.append("Each issue below was filed within roughly the past 30 days (newest first).")
            lines.append("Write a factual headline, then what's working vs what needs attention as instructed.")
        }
        lines.append("Target output language: \(languageDisplayName(targetLanguage)).")
        lines.append("")
        lines.append(
            """
            Constraints:
              • Mention patterns and approximate counts grounded in these issues only.
              • Keep both sections in plain prose (no bullets, lists, headings, markdown).
              • Put only genuine praise under pros; if there is none, leave it empty rather than restating complaints or listing requests.
              • Feature requests and unmet needs belong under cons, not pros.
            """
        )
        lines.append("")

        for issue in included {
            let body = stripCodeBlocks(issue.description)
                .prefix(max(bodyCharCap, 20))
            let labels = issue.labels.map(\.name).joined(separator: ", ")
            let labelSuffix = labels.isEmpty ? "" : " [labels: \(labels)]"
            lines.append("- #\(issue.number) \(issue.title): \(body)\(labelSuffix)")
        }

        if extra > 0 {
            lines.append("")
            let scope = promptContext == .unreadIssues ? "more unread issues" : "more recent issues"
            lines.append("(+\(extra) \(scope) omitted to fit Apple Intelligence prompt budget)")
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
