import Foundation

struct ParsedBody: Sendable {
    var description: String = ""
    var app: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
}

enum IssueBodyParser {
    static func parse(_ raw: String) -> ParsedBody {
        var result = ParsedBody()
        let lines = raw.components(separatedBy: "\n")
        var descLines: [String] = []
        var inDevice = false
        var expectEmail = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^\*\*|\*\*$"#, with: "", options: .regularExpression)

            if trimmed == "Device Information:" {
                inDevice = true
                continue
            }

            guard inDevice else {
                descLines.append(line)
                continue
            }

            if expectEmail {
                if !trimmed.isEmpty && trimmed.contains("@") { result.email = trimmed }
                expectEmail = false
                continue
            }

            if trimmed.hasPrefix("App Version:") {
                result.appVersion = trimmed.dropPrefix("App Version:").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("App:") {
                result.app = trimmed.dropPrefix("App:").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:") {
                result.device = trimmed.dropPrefix("Device:").trimmingCharacters(in: .whitespaces)
            } else if trimmed.range(of: #"^(OS|macOS|iOS|iPadOS|watchOS|tvOS|visionOS) Version:"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil {
                let parts = trimmed.components(separatedBy: ":")
                result.osVersion = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if trimmed == "Contact Email:" {
                expectEmail = true
            } else if trimmed.hasPrefix("Contact Email:") {
                let val = trimmed.dropPrefix("Contact Email:").trimmingCharacters(in: .whitespaces)
                if val.contains("@") { result.email = val }
                else { expectEmail = true }
            }
        }

        result.description = descLines
            .filter { $0.trimmingCharacters(in: .whitespaces) != "---" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
