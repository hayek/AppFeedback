import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailThreadStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - recordOutbound

    @discardableResult
    func recordOutbound(
        messageID: String,
        repoOwner: String, repoName: String, issueNumber: Int,
        from: String, fromName: String?,
        to: [String], cc: [String],
        subject: String, bodyPlain: String, bodyHTML: String?,
        date: Date,
        replyHeaders: ReplyHeaderBuilder.Output?
    ) -> MailMessage {
        // Dedupe: return existing message if messageID already stored
        if let existing = findMessage(byMessageID: messageID) {
            return existing
        }

        // Determine which thread to append to (header-based lookup)
        let thread = resolveThread(
            inReplyTo: replyHeaders?.inReplyTo,
            references: replyHeaders?.references ?? [],
            fallback: {
                // Create new thread
                let newThread = MailThread(
                    messageIDRoot: messageID,
                    subject: subject,
                    lastMessageAt: date,
                    issueRepoOwner: issueNumber > 0 ? repoOwner : "",
                    issueRepoName: issueNumber > 0 ? repoName : "",
                    issueNumber: issueNumber > 0 ? issueNumber : 0,
                    matchSourceRaw: MailThread.MatchSource.direct.rawValue
                )
                self.context.insert(newThread)
                return newThread
            }
        )

        // Update thread metadata
        thread.lastMessageAt = max(thread.lastMessageAt, date)
        let newParticipants = ([from] + to + cc).filter { !$0.isEmpty }
        thread.participants = unionPreservingOrder(thread.participants, newParticipants)

        // Build the new message
        let msg = MailMessage(
            messageID: messageID,
            inReplyTo: replyHeaders?.inReplyTo,
            references: replyHeaders?.references.joined(separator: "\n") ?? "",
            fromAddress: from,
            fromName: fromName,
            toAddresses: to,
            ccAddresses: cc,
            date: date,
            subject: subject,
            bodyPlain: bodyPlain,
            bodyHTML: bodyHTML,
            directionRaw: MailMessage.Direction.outbound.rawValue,
            thread: thread
        )
        context.insert(msg)

        try? context.save()
        return msg
    }

    // MARK: - recordInbound

    @discardableResult
    func recordInbound(message: ParsedInboundMessage) -> MailMessage? {
        // Dedupe: skip if messageID already exists
        if findMessage(byMessageID: message.messageID) != nil {
            return nil
        }

        // Determine thread via direct header lookup only (no ThreadMatcher)
        let thread = resolveThread(
            inReplyTo: message.inReplyTo,
            references: message.references,
            fallback: {
                // Create orphan thread — issueNumber = 0, matchSource = .direct (placeholder)
                let newThread = MailThread(
                    messageIDRoot: message.messageID,
                    subject: message.subject,
                    lastMessageAt: message.date,
                    issueRepoOwner: "",
                    issueRepoName: "",
                    issueNumber: 0,
                    matchSourceRaw: MailThread.MatchSource.direct.rawValue
                )
                self.context.insert(newThread)
                return newThread
            }
        )

        // Update thread metadata
        thread.lastMessageAt = max(thread.lastMessageAt, message.date)
        let newParticipants = ([message.fromAddress] + message.toAddresses + message.ccAddresses)
            .filter { !$0.isEmpty }
        thread.participants = unionPreservingOrder(thread.participants, newParticipants)

        // Build message
        let msg = MailMessage(
            messageID: message.messageID,
            inReplyTo: message.inReplyTo,
            references: message.references.joined(separator: "\n"),
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            toAddresses: message.toAddresses,
            ccAddresses: message.ccAddresses,
            date: message.date,
            subject: message.subject,
            bodyPlain: message.bodyPlain,
            bodyHTML: message.bodyHTML,
            directionRaw: MailMessage.Direction.inbound.rawValue,
            thread: thread
        )
        context.insert(msg)

        // Create MailAttachment rows for each parsed attachment
        for meta in message.attachments {
            let attachment = MailAttachment(
                messageID: message.messageID,
                partID: meta.partID,
                filename: meta.filename,
                mimeType: meta.mimeType,
                sizeBytes: meta.sizeBytes,
                message: msg
            )
            context.insert(attachment)
        }

        try? context.save()
        return msg
    }

    // MARK: - attachToIssue

    func attachToIssue(thread: MailThread, owner: String, repo: String, number: Int) {
        thread.issueRepoOwner = owner
        thread.issueRepoName = repo
        thread.issueNumber = number
        try? context.save()
    }

    // MARK: - threads(forIssue:)

    func threads(forIssue issue: (owner: String, repo: String, number: Int)) -> [MailThread] {
        // SwiftData #Predicate does not support tuple captures, so fetch-then-filter.
        let allThreads = (try? context.fetch(FetchDescriptor<MailThread>(
            sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]
        ))) ?? []
        return allThreads.filter {
            $0.issueRepoOwner == issue.owner &&
            $0.issueRepoName == issue.repo &&
            $0.issueNumber == issue.number
        }
    }

    // MARK: - mergeThreads

    func mergeThreads(into keep: MailThread, drop: MailThread) {
        // Collect messageIDs already in keep for dedupe
        let keepMessageIDs = Set(keep.messages.map(\.messageID))

        // Reparent messages from drop to keep (skip duplicates)
        for msg in drop.messages {
            if keepMessageIDs.contains(msg.messageID) {
                // Duplicate — delete the copy on drop
                context.delete(msg)
            } else {
                msg.thread = keep
            }
        }

        // Update keep's lastMessageAt to the max across all reparented messages
        let allDates = keep.messages.map(\.date)
        if let maxDate = allDates.max() {
            keep.lastMessageAt = max(keep.lastMessageAt, maxDate)
        }

        // Union participants
        keep.participants = unionPreservingOrder(keep.participants, drop.participants)

        // Delete the dropped thread
        context.delete(drop)

        try? context.save()
    }

    // MARK: - Private helpers

    private func findMessage(byMessageID messageID: String) -> MailMessage? {
        let all = (try? context.fetch(FetchDescriptor<MailMessage>())) ?? []
        return all.first(where: { $0.messageID == messageID })
    }

    /// Resolve a thread from inReplyTo / references headers, or call `fallback` to create a new one.
    private func resolveThread(
        inReplyTo: String?,
        references: [String],
        fallback: () -> MailThread
    ) -> MailThread {
        // 1. Check inReplyTo against any stored MailMessage.messageID
        if let inReplyTo, !inReplyTo.isEmpty,
           let parent = findMessage(byMessageID: inReplyTo),
           let parentThread = parent.thread {
            return parentThread
        }

        // 2. Walk references chain — pick the thread of the newest matching message
        if !references.isEmpty {
            let allMessages = (try? context.fetch(FetchDescriptor<MailMessage>())) ?? []
            let matched = allMessages.filter { references.contains($0.messageID) && $0.thread != nil }
            if let newest = matched.max(by: { ($0.date) < ($1.date) }),
               let thread = newest.thread {
                return thread
            }
        }

        // 3. No match — invoke fallback to create a new thread
        return fallback()
    }

    /// Merge `additions` into `base`, preserving insertion order and skipping duplicates.
    private func unionPreservingOrder(_ base: [String], _ additions: [String]) -> [String] {
        var seen = Set(base)
        var result = base
        for item in additions {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }
}
