import Foundation

/// Reads and writes the machine-managed "Addresses: #n, #n" block that links a task
/// issue to the feedback issues it addresses. This block is the source of truth for the
/// many-to-many task↔feedback relationship; GitHub renders backlinks on each feedback.
enum FeedbackTaskRefParser {
    static let openMarker  = "<!-- appfeedback:addresses -->"
    static let closeMarker = "<!-- /appfeedback:addresses -->"

    /// Returns the addressed feedback numbers, deduplicated and ascending.
    static func parse(_ body: String) -> [Int] {
        guard let range = blockRange(in: body) else { return [] }
        let inner = String(body[range])
        let numbers = matches(of: "#([0-9]+)", in: inner).compactMap { Int($0) }
        return Array(Set(numbers)).sorted()
    }

    /// Returns `body` with the addresses block inserted/replaced (or removed when `refs` is empty).
    static func upsert(into body: String, refs: [Int]) -> String {
        let stripped = removingBlock(from: body)
        let sorted = Array(Set(refs)).sorted()
        guard !sorted.isEmpty else { return stripped.trimmingTrailingNewlines() }
        let line = "Addresses: " + sorted.map { "#\($0)" }.joined(separator: ", ")
        let block = "\(openMarker)\n\(line)\n\(closeMarker)"
        let base = stripped.trimmingTrailingNewlines()
        return base.isEmpty ? block : "\(base)\n\n\(block)"
    }

    /// The task's prose with the machine-managed addresses block stripped out (for editing notes).
    static func prose(of body: String) -> String {
        upsert(into: body, refs: [])
    }

    // MARK: - Internals

    private static func blockRange(in body: String) -> Range<String.Index>? {
        guard let open = body.range(of: openMarker),
              let close = body.range(of: closeMarker),
              open.upperBound <= close.lowerBound else { return nil }
        return open.upperBound..<close.lowerBound
    }

    private static func removingBlock(from body: String) -> String {
        guard let open = body.range(of: openMarker),
              let close = body.range(of: closeMarker),
              open.lowerBound <= close.upperBound else { return body }
        var result = body
        result.removeSubrange(open.lowerBound..<close.upperBound)
        return result
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while let last = s.last, last == "\n" || last == "\r" { s.removeLast() }
        return s
    }
}
