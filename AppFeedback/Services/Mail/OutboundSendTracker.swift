import Foundation
import Observation

/// In-memory set of messageIDs whose SMTP transmission is in flight. `.sent` and `.failed`
/// outcomes are derived at the view layer from `MailMessage.sentAt` (CloudKit-synced) and
/// `OutboundFailureStore` (device-local) — this tracker only carries the transient sending
/// state that doesn't need to survive a relaunch.
@MainActor
@Observable
final class OutboundSendTracker {
    private var sending: Set<String> = []

    func markSending(_ messageID: String) {
        sending.insert(messageID)
    }

    func clear(_ messageID: String) {
        sending.remove(messageID)
    }

    func isSending(_ messageID: String) -> Bool {
        sending.contains(messageID)
    }
}
