import Foundation

/// Default-on filter that drops non-feedback inbound mail from a feedback inbox:
/// delivery-failure bounces and machine-generated auto-replies. Pure & Sendable so it
/// is trivially testable and callable from any actor.
enum InboundNoiseFilter {

    /// True ⇒ the message is noise and must NOT become a feedback issue/comment.
    static func isNoise(_ message: ParsedInboundMessage) -> Bool {
        isBounce(message) || isAutoReply(message)
    }

    // MARK: - Bounces

    private static let daemonLocalParts: Set<String> = [
        "mailer-daemon", "postmaster"
    ]

    private static func isBounce(_ message: ParsedInboundMessage) -> Bool {
        // Empty Return-Path ("" or "<>") is the canonical bounce envelope.
        if let rp = message.returnPath {
            let trimmed = rp.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "<>" { return true }
        }
        // mailer-daemon / postmaster sender local-parts.
        let local = message.fromAddress
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.lowercased() } ?? message.fromAddress.lowercased()
        return daemonLocalParts.contains(local)
    }

    // MARK: - Auto-replies

    private static func isAutoReply(_ message: ParsedInboundMessage) -> Bool {
        // RFC 3834: Auto-Submitted: auto-* (auto-replied / auto-generated / auto-notified).
        // The only non-auto value is "no", which is an explicit human-sent marker.
        if let auto = message.autoSubmitted?.trimmingCharacters(in: .whitespaces).lowercased(),
           auto.hasPrefix("auto-") {
            return true
        }
        // Legacy Precedence: bulk | list marks mailing-list / bulk traffic.
        if let prec = message.precedence?.trimmingCharacters(in: .whitespaces).lowercased(),
           prec == "bulk" || prec == "list" {
            return true
        }
        return false
    }
}
