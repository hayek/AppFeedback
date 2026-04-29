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
}
