import Foundation

enum MessageIDGenerator {
    static let outboundDomain = "app-feedback.local"
    private static let syntheticDomain = "imap-synthetic"

    static func generate() -> String {
        "<\(UUID().uuidString.lowercased())@\(outboundDomain)>"
    }

    static func isSynthetic(_ messageID: String) -> Bool {
        messageID.contains("@\(syntheticDomain)")
    }

    /// Synthesises a stable Message-ID from an IMAP UID + UIDValidity pair.
    /// Format: `<uid-{uid}.{uidValidity}@imap-synthetic>`
    static func synthesize(uid: UInt32, uidValidity: UInt32) -> String {
        "<uid-\(uid).\(uidValidity)@\(syntheticDomain)>"
    }
}
