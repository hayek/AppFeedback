import Foundation

enum HTMLSanitizer {
    private static let allowedTags: Set<String> = [
        "p", "br", "strong", "em", "u", "a",
        "ul", "ol", "li", "blockquote", "span"
    ]

    private static let allowedAttributesByTag: [String: Set<String>] = [
        "a": ["href"]
    ]

    static func sanitize(_ html: String) -> String {
        // 1. Strip <script>...</script> and <style>...</style> blocks (including content).
        var s = html
        s = stripBlock(in: s, tag: "script")
        s = stripBlock(in: s, tag: "style")
        // 2. Walk tokens; drop disallowed tags (keeping content) and disallowed attributes.
        return rewrite(s)
    }

    // MARK: - Block stripping

    private static func stripBlock(in s: String, tag: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>",
            options: [.caseInsensitive]
        ) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    // MARK: - Tag rewrite

    /// Walks through tag tokens and rebuilds the HTML, dropping disallowed tags
    /// (keeping their inner content) and stripping disallowed attributes.
    private static func rewrite(_ html: String) -> String {
        var result = ""
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<", let close = html[i...].firstIndex(of: ">") {
                let tagToken = String(html[i...close])
                let inner = tagToken.dropFirst().dropLast()  // drop "<" and ">"
                let isClosing = inner.first == "/"
                let nameAndAttrs = isClosing ? inner.dropFirst() : inner
                let parts = nameAndAttrs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let rawName = parts.first.map(String.init) ?? ""
                let name = rawName.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if allowedTags.contains(name) {
                    if isClosing {
                        result += "</\(name)>"
                    } else {
                        let attrs = parts.count > 1 ? String(parts[1]) : ""
                        let cleaned = filterAttributes(tag: name, attrs: attrs)
                        result += cleaned.isEmpty ? "<\(name)>" : "<\(name) \(cleaned)>"
                    }
                }
                // else: drop the tag, keep walking — inner content will survive.
                i = html.index(after: close)
            } else {
                result.append(html[i])
                i = html.index(after: i)
            }
        }
        return result
    }

    private static func filterAttributes(tag: String, attrs: String) -> String {
        let allowed = allowedAttributesByTag[tag] ?? []
        let scanner = Scanner(string: attrs)
        scanner.charactersToBeSkipped = .whitespaces
        var kept: [String] = []
        while !scanner.isAtEnd {
            guard let key = scanner.scanUpToString("=")?.lowercased().trimmingCharacters(in: .whitespaces),
                  !key.isEmpty else { break }
            _ = scanner.scanString("=")
            var value = ""
            if scanner.scanString("\"") != nil {
                value = scanner.scanUpToString("\"") ?? ""
                _ = scanner.scanString("\"")
            } else if scanner.scanString("'") != nil {
                value = scanner.scanUpToString("'") ?? ""
                _ = scanner.scanString("'")
            } else {
                value = scanner.scanUpToCharacters(from: .whitespaces) ?? ""
            }
            guard allowed.contains(key) else { continue }
            if key == "href" && value.lowercased().hasPrefix("javascript:") { continue }
            kept.append("\(key)=\"\(value)\"")
        }
        return kept.joined(separator: " ")
    }
}
