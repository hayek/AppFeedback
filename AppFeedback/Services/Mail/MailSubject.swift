import Foundation

enum MailSubject {
    /// Strips all chained Re:/RE:/Fwd:/FWD:/Fw:/FW: prefixes and prepends a single "Re: ".
    static func replyPrefixed(_ subject: String) -> String {
        let stripped = ThreadMatcher.stripReplyPrefixes(subject).trimmingCharacters(in: .whitespaces)
        return "Re: \(stripped)"
    }
}
