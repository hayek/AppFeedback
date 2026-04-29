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
            if html[i] == "<", let close = findTagClose(in: html, from: i) {
                let tagToken = String(html[i...close])
                let inner = tagToken.dropFirst().dropLast()
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

    /// Find the index of the `>` that closes the tag starting at `start`,
    /// skipping any `>` that appears inside double or single-quoted attribute values.
    private static func findTagClose(in s: String, from start: String.Index) -> String.Index? {
        var i = s.index(after: start)
        var quote: Character? = nil
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: - Plain-text extraction

    /// Strips all HTML tags and decodes common entities, returning a plain-text representation.
    /// Used when a message has no plain-text body part and when composing the text/plain MIME part.
    static func plainText(from html: String) -> String {
        let reOpts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        return html
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: reOpts)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: reOpts)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: reOpts)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func filterAttributes(tag: String, attrs: String) -> String {
        let allowed = allowedAttributesByTag[tag] ?? []
        var i = attrs.startIndex
        var kept: [String] = []

        while i < attrs.endIndex {
            // Skip whitespace
            while i < attrs.endIndex, attrs[i].isWhitespace { i = attrs.index(after: i) }
            guard i < attrs.endIndex else { break }

            // Read attribute name (until `=`, whitespace, or end).
            let nameStart = i
            while i < attrs.endIndex,
                  attrs[i] != "=",
                  !attrs[i].isWhitespace,
                  attrs[i] != "/" {
                i = attrs.index(after: i)
            }
            let name = attrs[nameStart..<i].lowercased()
            guard !name.isEmpty else { break }

            // Optional `=` and value.
            var value = ""
            var hadValue = false
            // Skip whitespace before `=`.
            var j = i
            while j < attrs.endIndex, attrs[j].isWhitespace { j = attrs.index(after: j) }
            if j < attrs.endIndex, attrs[j] == "=" {
                hadValue = true
                j = attrs.index(after: j)
                while j < attrs.endIndex, attrs[j].isWhitespace { j = attrs.index(after: j) }
                if j < attrs.endIndex, (attrs[j] == "\"" || attrs[j] == "'") {
                    let quote = attrs[j]
                    j = attrs.index(after: j)
                    let valueStart = j
                    while j < attrs.endIndex, attrs[j] != quote { j = attrs.index(after: j) }
                    value = String(attrs[valueStart..<j])
                    if j < attrs.endIndex { j = attrs.index(after: j) }   // consume closing quote
                } else {
                    let valueStart = j
                    while j < attrs.endIndex, !attrs[j].isWhitespace { j = attrs.index(after: j) }
                    value = String(attrs[valueStart..<j])
                }
                i = j
            }

            guard allowed.contains(name) else { continue }
            if name == "href" && value.lowercased().hasPrefix("javascript:") { continue }
            if hadValue {
                kept.append("\(name)=\"\(value)\"")
            } else {
                kept.append(name)   // boolean attribute
            }
        }
        return kept.joined(separator: " ")
    }
}
