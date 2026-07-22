import Foundation

/// Prompts for the two triage stages, with shrinking-size ladders for the
/// 4096-token session ceiling (TN3193). Stage 2 returns the roster entries
/// actually embedded so the caller can validate the model's answer against
/// exactly what it saw.
enum TriagePromptBuilder {
    /// Stage-1 body-char caps, largest first.
    static func classifyConfigs() -> [Int] { [1_200, 600, 300] }
    /// Stage-2 roster caps, largest first.
    static func matchConfigs() -> [Int] { [60, 30, 12] }

    static func buildClassifyPrompt(issue: FeedbackIssue, bodyCharCap: Int) -> String {
        let body = String(SummaryPromptBuilder.stripCodeBlocks(issue.description).prefix(max(bodyCharCap, 40)))
        var meta: [String] = []
        if let app = issue.appName { meta.append("app: \(app)") }
        if let version = issue.appVersion { meta.append("version: \(version)") }
        if let os = issue.osVersion { meta.append("os: \(os)") }
        if let rating = issue.rating { meta.append("rating: \(rating)/5") }
        let metaLine = meta.isEmpty ? "" : " (\(meta.joined(separator: ", ")))"
        return """
        Classify this single piece of user feedback\(metaLine):

        Title: \(issue.title)
        Body: \(body)

        Decide whether a developer can act on it (bug/crash/regression, concrete \
        feature request, or usability complaint) or not (praise, vague negativity, \
        question/support request).
        """
    }

    static func buildMatchPrompt(
        signal: String, kind: TriageKind,
        roster: [TriageTaskRosterEntry], rosterCap: Int
    ) -> (prompt: String, included: [TriageTaskRosterEntry]) {
        let included = Array(roster.prefix(max(rosterCap, 0)))
        var lines: [String] = []
        lines.append("A new \(kindNoun(kind)) came in from user feedback:")
        lines.append("  \(signal)")
        lines.append("")
        if included.isEmpty {
            lines.append("There are no existing tasks. Propose a new task (taskNumber 0).")
        } else {
            lines.append("Existing open tasks:")
            for entry in included {
                lines.append("- #\(entry.number): \"\(entry.title)\"")
            }
            lines.append("")
            lines.append("""
            If one of these tasks covers the same specific problem or request, answer \
            with its number and copy its exact title. Otherwise answer taskNumber 0 and \
            propose a new task title and summary.
            """)
        }
        return (lines.joined(separator: "\n"), included)
    }

    private static func kindNoun(_ kind: TriageKind) -> String {
        switch kind {
        case .bug: return "bug report"
        case .featureRequest: return "feature request"
        case .usability: return "usability complaint"
        }
    }
}
