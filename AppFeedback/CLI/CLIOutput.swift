#if os(macOS)
import Foundation

enum CLIOutput {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":"encoding_failed","message":"Could not encode the response."}}"#
        }
        return text
    }
}

/// Human-readable rendering for `--text`. Explicitly NOT a stable contract — the skill tells
/// agents to use the JSON default and never parse this.
enum CLIText {
    private static let titleWidth = 60

    private static func clip(_ text: String, _ width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func render(products: [ProductSummary]) -> String {
        guard !products.isEmpty else { return "No products configured." }
        return products.map { product in
            """
            \(product.displayName)  [\(product.repo)]
              feedback: \(product.feedbackCount)   tasks: \(product.taskCount)
              code repo: \(product.connectedRepo ?? "—")
              id: \(product.id)
            """
        }.joined(separator: "\n\n")
    }

    static func render(feedback items: [FeedbackItem]) -> String {
        guard !items.isEmpty else { return "No matching feedback." }
        return items.map { item in
            let tasks = item.tasks.isEmpty ? "" : "  → " + item.tasks.map { "#\($0.number)" }.joined(separator: " ")
            let rating = item.rating.map { " \($0)★" } ?? ""
            return "#\(pad(String(item.number), 5)) \(pad(item.state, 7))"
                 + "\(pad(clip(item.app ?? "—", 18), 19))"
                 + "\(clip(item.title, titleWidth))\(rating)\(tasks)"
        }.joined(separator: "\n")
    }

    static func render(detail: FeedbackDetail) -> String {
        var lines = [
            "#\(detail.number)  \(detail.title)",
            "\(detail.state) · \(detail.source) · \(detail.app ?? "—") \(detail.appVersion ?? "")",
            "\(detail.device ?? "—") · \(detail.os ?? "—") · \(CLIOutput.iso8601.string(from: detail.createdAt))",
        ]
        if let email = detail.email { lines.append("reporter: \(email)") }
        if !detail.labels.isEmpty { lines.append("labels: \(detail.labels.joined(separator: ", "))") }
        if !detail.tasks.isEmpty {
            lines.append("tasks: " + detail.tasks.map { "#\($0.number) \($0.status)" }.joined(separator: ", "))
        }
        if let thread = detail.thread {
            lines.append("thread: \(thread.messageCount) messages, last \(thread.lastDirection ?? "—")")
        }
        if !detail.attachments.isEmpty {
            lines.append("attachments: " + detail.attachments.map(\.filename).joined(separator: ", "))
        }
        lines.append("")
        lines.append(detail.description)
        lines.append("")
        lines.append(detail.url)
        return lines.joined(separator: "\n")
    }

    static func render(tasks: [TaskItemDTO]) -> String {
        guard !tasks.isEmpty else { return "No matching tasks." }
        return tasks.map { task in
            let feedback = task.feedback.isEmpty ? "" : "  ← " + task.feedback.map { "#\($0)" }.joined(separator: " ")
            return "#\(pad(String(task.number), 5)) \(pad(task.status, 12))\(pad(task.priority, 6))"
                 + "\(clip(task.title, titleWidth))\(feedback)"
        }.joined(separator: "\n")
    }

    static func render(taskDetail: TaskDetail) -> String {
        var lines = [
            "#\(taskDetail.number)  \(taskDetail.title)",
            "\(taskDetail.status) · \(taskDetail.priority) · \(taskDetail.milestone ?? "no version")",
        ]
        if !taskDetail.feedback.isEmpty {
            lines.append("addresses: " + taskDetail.feedback
                .map { "#\($0.number) \(clip($0.title, 40))" }.joined(separator: "\n           "))
        }
        lines.append("")
        lines.append(taskDetail.notes.isEmpty ? "(no notes)" : taskDetail.notes)
        lines.append("")
        lines.append(taskDetail.url)
        return lines.joined(separator: "\n")
    }
}
#endif
