import Foundation

enum ThreadMatcher {

    struct Candidate: Equatable, Sendable {
        let messageID: String
        let subject: String
        let participants: [String]
        let lastMessageAt: Date
    }

    enum AttachResult: Equatable, Sendable {
        case header(threadIndex: Int)
        case subject(threadIndex: Int)
        case newThread
    }

    // MARK: - Public API

    static func attach(
        message: ParsedInboundMessage,
        existing: [Candidate]
    ) -> AttachResult {

        // 1. Header — In-Reply-To
        if let inReplyTo = message.inReplyTo {
            for (i, candidate) in existing.enumerated() {
                if candidate.messageID == inReplyTo {
                    return .header(threadIndex: i)
                }
            }
        }

        // 2. Header — References chain
        for ref in message.references {
            for (i, candidate) in existing.enumerated() {
                if candidate.messageID == ref {
                    return .header(threadIndex: i)
                }
            }
        }

        // 3. Subject fallback
        let strippedMessageSubject = stripReplyPrefixes(message.subject)

        // Build the message's address set (case-insensitive)
        let messageAddresses = Set(
            ([message.fromAddress] + message.toAddresses + message.ccAddresses)
                .map { $0.lowercased() }
        )

        // Collect candidates that match on stripped subject + participant overlap,
        // then pick the one with the latest lastMessageAt.
        var bestIndex: Int? = nil
        var bestDate: Date? = nil

        for (i, candidate) in existing.enumerated() {
            guard stripReplyPrefixes(candidate.subject).lowercased() == strippedMessageSubject.lowercased() else {
                continue
            }
            let candidateAddresses = Set(candidate.participants.map { $0.lowercased() })
            guard !messageAddresses.isDisjoint(with: candidateAddresses) else {
                continue
            }
            if bestDate == nil || candidate.lastMessageAt > bestDate! {
                bestIndex = i
                bestDate = candidate.lastMessageAt
            }
        }

        if let idx = bestIndex {
            return .subject(threadIndex: idx)
        }

        // 4. No match
        return .newThread
    }

    static func matchToIssue(
        threadSubject: String,
        knownIssueTitles: [(owner: String, repo: String, number: Int, title: String)]
    ) -> (owner: String, repo: String, number: Int)? {
        let stripped = stripReplyPrefixes(threadSubject)

        // Minimum title length to avoid spurious matches (e.g. a single digit "1" matching everything)
        let minimumTitleLength = 4

        var bestMatch: (owner: String, repo: String, number: Int)? = nil
        var bestNumber = Int.min

        for issue in knownIssueTitles {
            guard issue.title.count >= minimumTitleLength else { continue }
            if stripped.range(of: issue.title, options: [.caseInsensitive]) != nil {
                if issue.number > bestNumber {
                    bestNumber = issue.number
                    bestMatch = (owner: issue.owner, repo: issue.repo, number: issue.number)
                }
            }
        }

        return bestMatch
    }

    // MARK: - Internal Helper

    /// Strips chained `Re:`, `RE:`, `re:`, `Fwd:`, `FWD:`, `Fw:`, `FW:` prefixes
    /// (case-insensitive, with optional surrounding whitespace) from a subject string.
    /// Examples:
    ///   "Re: Re: Fwd: foo" → "foo"
    ///   "Re:Fwd:bar"       → "bar"
    internal static func stripReplyPrefixes(_ subject: String) -> String {
        // Matches optional whitespace, one of the known prefixes, optional whitespace
        // Anchored at the start of the remaining string; applied repeatedly until no more match.
        let prefixPattern = #"^\s*(?:Re|Fwd|Fw)\s*:\s*"#
        guard let regex = try? NSRegularExpression(pattern: prefixPattern, options: .caseInsensitive) else {
            return subject
        }

        var result = subject
        while true {
            let range = NSRange(result.startIndex..., in: result)
            let match = regex.firstMatch(in: result, options: [], range: range)
            guard let m = match else { break }
            // Remove the matched prefix
            if let swiftRange = Range(m.range, in: result) {
                result = String(result[swiftRange.upperBound...])
            } else {
                break
            }
        }
        return result
    }
}
